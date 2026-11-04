#!/usr/bin/env bash
# Capture two screenshots of a URL inside the emulator and VERIFY each
# frame is real before accepting it. Usage:
#   bash scripts/capture.sh [URL]
# URL may also come from the CAPTURE_URL environment variable; default
# is https://example.com.
#
# Why the verification exists: an earlier version of this workflow
# went green while one screenshot was a completely black frame and
# the other showed only a "Process system isn't responding" ANR
# dialog. The emulator had booted, but no useful UI ever rendered,
# and nothing checked. This script now:
#   1. waits for a SETTLED boot (boot_completed + boot animation stopped
#      + package manager answering), not just the first boot signal;
#   2. keeps the display awake so a sleeping screen cannot produce a
#      black frame;
#   3. waits for the launcher, then for Chrome to actually be the
#      foreground app, before screenshotting;
#   4. dismisses an ANR dialog via its "Wait" button when one appears;
#   5. pixel-checks every capture with scripts/frame_check.py (stdlib
#      python3) and retries up to 5 times per shot, failing LOUDLY
#      (exit 1) instead of uploading black frames, leaving the last
#      failed frame as a diagnostic.
#
# The URL is passed as the first argument (or CAPTURE_URL); it is a
# public page. Nothing is typed, nothing is submitted, no login.
set -euo pipefail

URL="${1:-${CAPTURE_URL:-https://example.com}}"
OUT_DIR="screenshots"
mkdir -p "$OUT_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAME_CHECK="$SCRIPT_DIR/frame_check.py"
ANR_CHECK="$SCRIPT_DIR/anr_check.py"
MIN_NONBLACK="0.05"

for helper in "$FRAME_CHECK" "$ANR_CHECK"; do
  [ -f "$helper" ] || { echo "ERROR: missing helper $helper" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 is required for the frame/ANR checks and was not found." >&2
  exit 1
}

log() { echo "[capture] $*"; }

# run_with_timeout <seconds> <command...>
# Portable replacement for GNU `timeout` (not present on macOS runners).
# Returns 124 if the command was still running when the deadline hit.
run_with_timeout() {
  local timeout_secs="$1"
  shift
  "$@" &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$timeout_secs" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 2
    waited=$((waited + 2))
  done
  wait "$pid"
}

# Wait until a shell command prints the expected value, polling every
# 5s for up to <timeout> seconds. Never fails the script by itself:
# returns 0 on success, 1 on timeout, and the caller decides.
# Note: adb shell output ends in CR-LF, so the carriage return is
# stripped before comparing.
wait_for_prop() {
  local label="$1" timeout_secs="$2" expected="$3"
  shift 3
  local waited=0 value=""
  while [ "$waited" -lt "$timeout_secs" ]; do
    value="$("$@" 2>/dev/null | tr -d '\r' || true)"
    if [ "$value" = "$expected" ]; then
      log "$label ready after ${waited}s (value: $value)"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log "WARN: $label not ready after ${timeout_secs}s (last value: '$value')"
  return 1
}

wait_for_boot() {
  log "Waiting for sys.boot_completed..."
  wait_for_prop "sys.boot_completed" 300 "1" \
    adb shell getprop sys.boot_completed || true

  log "Waiting for the boot animation to stop..."
  wait_for_prop "boot animation" 120 "stopped" \
    adb shell getprop init.svc.bootanim || true

  log "Waiting for the package manager to answer..."
  wait_for_prop "package manager" 60 "package:com.android.chrome" \
    adb shell pm list packages com.android.chrome || true

  log "Boot settle: sleeping 30s for System UI to stabilise..."
  sleep 30
}

keep_display_awake() {
  # "Stay awake" equivalent + a long screen-off timeout, so the display
  # cannot sleep mid-run under -no-window and produce a black frame.
  # Non-persistent settings; they revert on reboot. Best-effort only:
  # a failure here must not kill the run.
  adb shell svc power stayon true || true
  adb shell settings put system screen_off_timeout 1800000 || true
  adb shell input keyevent 82 || true
  adb shell wm dismiss-keyguard || true
  log "Display stay-on requested; keyguard dismissal attempted."
}

wait_for_launcher() {
  log "Waiting for the launcher to be the foreground app..."
  local waited=0
  while [ "$waited" -lt 120 ]; do
    if adb shell dumpsys activity activities 2>/dev/null \
        | grep -E "mResumedActivity|mFocusedApp" \
        | grep -qi "launcher"; then
      log "Launcher foreground after ${waited}s"
      sleep 30
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log "WARN: launcher not observed in 120s; continuing anyway."
  sleep 30
}

wait_for_chrome_foreground() {
  log "Waiting for Chrome to be the foreground app..."
  local waited=0
  while [ "$waited" -lt 90 ]; do
    if adb shell dumpsys activity activities 2>/dev/null \
        | grep -E "mResumedActivity|mFocusedApp" \
        | grep -q "com.android.chrome"; then
      log "Chrome foreground after ${waited}s"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log "WARN: Chrome not observed in the foreground in 90s; continuing anyway."
  return 0
}

# If an "isn't responding" dialog is on screen, tap its "Wait" button.
# Returns 0 when there is no dialog or the tap was sent, 1 when a dialog
# is present but its Wait button could not be found. Never fatal: a
# timeout or a missing dump is treated as "unknown", and the frame
# pixel check remains the backstop.
dismiss_anr_if_present() {
  local dump="$OUT_DIR/.ui-dump.xml"
  rm -f "$dump"
  if ! run_with_timeout 45 adb shell uiautomator dump /sdcard/window_dump.xml \
      >/dev/null 2>&1; then
    log "WARN: uiautomator dump timed out; ANR state unknown."
    return 0
  fi
  if ! run_with_timeout 30 adb pull /sdcard/window_dump.xml "$dump" \
      >/dev/null 2>&1; then
    log "WARN: could not pull the UI dump; ANR state unknown."
    return 0
  fi
  local result
  result="$(python3 "$ANR_CHECK" "$dump" 2>/dev/null || echo "ANR_CHECK_ERROR")"
  case "$result" in
    NO_ANR*)
      return 0
      ;;
    WAIT*)
      local x y
      set -- $result
      x="$2"
      y="$3"
      log "ANR dialog found; tapping Wait at $x,$y."
      adb shell input tap "$x" "$y" || true
      sleep 10
      return 0
      ;;
    *)
      log "WARN: ANR dialog present but no Wait button found ($result)."
      return 1
      ;;
  esac
}

# capture_verified_frame <outfile> <label>
# Screenshots until the pixel check passes, up to 5 attempts. On total
# failure, exits 1 (the workflow must go RED, never green-with-black)
# and leaves the last failed frame as a diagnostic.
capture_verified_frame() {
  local outfile="$1" label="$2"
  local tmp="$OUT_DIR/.tmp-$label.png"
  local attempt=1 check_output=""
  while [ "$attempt" -le 5 ]; do
    log "$label: attempt $attempt/5"
    dismiss_anr_if_present || log "WARN: ANR dialog could not be dismissed; retrying after a wait."
    rm -f "$tmp"
    adb exec-out screencap -p > "$tmp" || true
    if [ ! -s "$tmp" ]; then
      log "WARN: empty screencap; retrying in 15s."
      sleep 15
      attempt=$((attempt + 1))
      continue
    fi
    if check_output="$(python3 "$FRAME_CHECK" "$tmp" "$MIN_NONBLACK" 2>"$OUT_DIR/.frame-check.err")"; then
      log "$label: frame OK ($check_output)"
      mv "$tmp" "$outfile"
      return 0
    fi
    log "$label: frame REJECTED ($check_output)"
    cat "$OUT_DIR/.frame-check.err" 2>/dev/null || true
    sleep 15
    attempt=$((attempt + 1))
  done
  cp "$tmp" "$OUT_DIR/00-last-failed-frame-$label.png" 2>/dev/null || true
  log "ERROR: could not capture a real $label frame after 5 attempts."
  log "Diagnostic saved: 00-last-failed-frame-$label.png"
  return 1
}

wait_for_boot
keep_display_awake
wait_for_launcher

log "Checking Chrome is present..."
if ! adb shell pm list packages 2>/dev/null | grep -q "com.android.chrome"; then
  log "Chrome package list (diagnostic):"
  adb shell pm list packages 2>/dev/null | head -50 || true
  echo "ERROR: Chrome (com.android.chrome) is not installed on this image." >&2
  exit 1
fi
log "Chrome is present."

log "Setting Chrome as the default browser (role holder)..."
adb shell cmd role add-role-holder android.app.role.BROWSER com.android.chrome || true

log "Applying Chrome first-run-experience skip flags..."
# Documented Chrome mechanism: flags in /data/local/tmp/chrome-command-line
# are picked up on launch. --disable-fre skips the welcome / sign-in flow.
adb shell 'echo "chrome --disable-fre --no-first-run --disable-startup-promos-for-testing --no-default-browser-check" > /data/local/tmp/chrome-command-line' || true
adb shell am force-stop com.android.chrome || true

log "Launching Chrome at $URL ..."
adb shell am start -a android.intent.action.VIEW -d "$URL" com.android.chrome || true

wait_for_chrome_foreground
log "Page settle: sleeping 45s for the page to render..."
sleep 45

capture_verified_frame "$OUT_DIR/01-settled.png" "settled"

log "Scrolling down once..."
adb shell input swipe 540 1600 540 700 300 || true
sleep 5

capture_verified_frame "$OUT_DIR/02-scrolled.png" "scrolled"

log "Screenshots (verified frames):"
ls -la "$OUT_DIR"
