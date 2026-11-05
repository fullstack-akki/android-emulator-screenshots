#!/usr/bin/env bash
# Capture two screenshots of a URL inside the emulator and VERIFY each
# frame is real before accepting it. Usage:
#   bash scripts/capture.sh [URL]
# URL may also come from the CAPTURE_URL environment variable; default
# is https://example.com.
#
# Why the verification exists — three green runs produced useless
# frames, each exposing a new hole in the previous check:
#   Run #2 (Nov 2026): 01-settled.png completely black; 02-scrolled.png
#     an ANR dialog. Nothing checked the frames at all.
#   Run #3 (Nov 2026, generic repo run #1 at 18:21 IST, and the twin
#     KhetBook run 41830351860, 15m 21s): BOTH frames showed a
#     "Process system isn't responding" ANR dialog over a BRIGHT
#     screen — one over Chrome's new-tab page (the URL never
#     rendered), one over the launcher home screen (Chrome had lost
#     the foreground entirely). The pixel check passed both
#     (nonblack 0.9993 and 0.5201) because it only rejects DARK
#     frames, and the ANR check degraded to "unknown" when the
#     UI-dump pull failed — and "unknown" was treated as "proceed".
#     The dialog persisted for ~1 minute across a foreground change,
#     so the Wait-tap dismissal never happened.
#
# This script now gates EVERY shot on all three of:
#   A. Chrome is the foreground app (a launcher/home frame is a
#      failure, not a screenshot). Re-asserted before every shot
#      and every retry; a bounded re-fire of the VIEW intent
#      recovers a lost foreground (max 1 re-fire per shot).
#   B. ANR state is KNOWN and CLEAR. The dump is obtained by a
#      3-method chain (stdout dump, file+cat, dumpsys focus) with
#      stderr kept in the log. UNKNOWN rejects the frame — it never
#      accepts. A Wait tap must be VERIFIED gone by a re-dump.
#   C. The requested URL is actually in a Chrome tab, proven via
#      Chrome DevTools (adb forward + /json). Required for shot 1
#      and after any re-fire. A new-tab page can never pass.
#   D. The frame is not (near-)black (pixel check, as before).
# If any gate cannot be satisfied in 5 attempts, the script exits 1
# (the workflow goes RED) and saves the last failed frame as a
# diagnostic. A green run means real screenshots.
#
# One more pre-shot step, added after run 41847287396: Chrome's
# notifications promo card ("Chrome notifications make things
# easier", "No thanks" / "Continue") is NOT suppressed by the
# --disable-fre flags on the google_apis API 34 image. That run
# went green with a real frame — and the card covering the middle
# of the page, hiding the heading. Before any shot is accepted the
# script dumps the UI hierarchy, taps "No thanks" if the card is
# present, and verifies by re-dump that it is gone (max 3
# attempts). A card that cannot be dismissed, or a dump that
# cannot be obtained, fails the run: an obscured frame must never
# be accepted.
#
# Since run 41857851484 the script also revokes Chrome's
# POST_NOTIFICATIONS permission before launch (best-effort), so the
# card should not appear at all; the dismiss step stays as the
# safety net, with transient dump/parse failures retried and an
# Android Back press as the last resort before failing.
#
# The URL is passed as the first argument (or CAPTURE_URL); it is a
# public page. Nothing is typed, nothing is submitted, no login.
set -euo pipefail

URL="${1:-${CAPTURE_URL:-https://example.com}}"
OUT_DIR="screenshots"
mkdir -p "$OUT_DIR"

# ANR_RECOVERY_DONE: 1 once the single bounded ANR recovery has run
# for the current shot (see ensure_no_anr). Reset to 0 by
# capture_verified_frame at the start of each shot.
ANR_RECOVERY_DONE=0

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
command -v curl >/dev/null 2>&1 || {
  echo "ERROR: curl is required for the Chrome DevTools URL check and was not found." >&2
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

  log "Boot settle: sleeping 10s for System UI to stabilise..."
  sleep 10
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
      sleep 10
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log "WARN: launcher not observed in 120s; continuing anyway."
  sleep 10
}

# chrome_is_foreground: 0 when a com.android.chrome activity is the
# resumed/focused activity, 1 otherwise (including dumpsys failure).
# Only ever called in a condition, so its non-zero status is safe
# under `set -e`.
chrome_is_foreground() {
  adb shell dumpsys activity activities 2>/dev/null \
    | grep -E "mResumedActivity|mFocusedApp" \
    | grep -q "com.android.chrome"
}

wait_for_chrome_foreground() {
  log "Waiting for Chrome to be the foreground app..."
  local waited=0
  while [ "$waited" -lt 90 ]; do
    if chrome_is_foreground; then
      log "Chrome foreground after ${waited}s"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log "WARN: Chrome not observed in the foreground in 90s; continuing anyway (per-attempt gates re-check)."
  return 0
}

# check_anr_state: print exactly ONE token on stdout:
#   NO_ANR | WAIT <x> <y> | ANR_NO_WAIT | UNKNOWN
# Diagnostics go to stderr (never stdout, so the captured token stays
# clean). Always exits 0; callers branch on the token. UNKNOWN means
# every dump method failed to produce usable output — the caller must
# REJECT the frame. It must never be treated as "no dialog".
check_anr_state() {
  local out err result win
  out="$OUT_DIR/.anr-dump.xml"
  err="$OUT_DIR/.anr-method.err"

  # Method 1: uiautomator dump straight to stdout (no file, no pull).
  # The old dump-to-file + adb pull path failed silently in run #3
  # (no dump file, pull error, stderr discarded) — this method
  # removes the file transfer entirely.
  rm -f "$out" "$err"
  if run_with_timeout 60 adb exec-out uiautomator dump /dev/tty >"$out" 2>"$err"; then
    if [ -s "$out" ]; then
      # Python's stderr is KEPT (the ANR dialog title, e.g. "Pixel
      # Launcher isn't responding", goes there): discarding it with
      # 2>/dev/null hid which app was ANRing in run #6's log.
      result="$(python3 "$ANR_CHECK" - <"$out" 2>"$OUT_DIR/.anr-py.err" || true)"
      case "$result" in
        NO_ANR|WAIT*|ANR_NO_WAIT)
          if [ -s "$OUT_DIR/.anr-py.err" ]; then
            echo "[capture] ANR detail: $(head -c 200 "$OUT_DIR/.anr-py.err" | tr '\n' ' ')" >&2
          fi
          echo "$result"
          return 0
          ;;
      esac
      echo "[capture] WARN: ANR method 1 output unparsable; python stderr: $(head -c 300 "$OUT_DIR/.anr-py.err" | tr '\n' ' '); dump stderr: $(head -c 300 "$err" | tr '\n' ' ')" >&2
    else
      echo "[capture] WARN: ANR method 1 returned empty output; stderr: $(head -c 300 "$err" | tr '\n' ' ')" >&2
    fi
  else
    echo "[capture] WARN: ANR method 1 (exec-out dump) failed/timed out; stderr: $(head -c 300 "$err" | tr '\n' ' ')" >&2
  fi

  # Method 2: dump to a file on the device, read it back with `cat`
  # through the normal adb shell channel. No `adb pull`: the pull
  # was the step that failed in run #3.
  rm -f "$out" "$err"
  if run_with_timeout 60 adb shell uiautomator dump /sdcard/window_dump.xml >"$OUT_DIR/.anr-m2.log" 2>"$err"; then
    if run_with_timeout 30 adb shell cat /sdcard/window_dump.xml >"$out" 2>"$err"; then
      if [ -s "$out" ]; then
        result="$(python3 "$ANR_CHECK" - <"$out" 2>"$OUT_DIR/.anr-py.err" || true)"
        case "$result" in
          NO_ANR|WAIT*|ANR_NO_WAIT)
            if [ -s "$OUT_DIR/.anr-py.err" ]; then
              echo "[capture] ANR detail: $(head -c 200 "$OUT_DIR/.anr-py.err" | tr '\n' ' ')" >&2
            fi
            echo "$result"
            return 0
            ;;
        esac
        echo "[capture] WARN: ANR method 2 output unparsable; python stderr: $(head -c 300 "$OUT_DIR/.anr-py.err" | tr '\n' ' ')" >&2
      else
        echo "[capture] WARN: ANR method 2 (cat) returned empty output." >&2
      fi
    else
      echo "[capture] WARN: ANR method 2 (cat) failed/timed out; stderr: $(head -c 300 "$err" | tr '\n' ' ')" >&2
    fi
  else
    echo "[capture] WARN: ANR method 2 (dump to file) failed/timed out; stderr: $(head -c 300 "$err" | tr '\n' ' ')" >&2
  fi

  # Method 3: dumpsys window focus. The ANR/crash dialog is the
  # focused window and its title carries "Application Error" or
  # "Application Not Responding" — the exact pattern Chromium's
  # device_utils.py uses to detect and dismiss crash dialogs
  # (mCurrentFocus ... Application (Error|Not Responding): ...).
  # This method cannot give Wait-button coordinates, so a hit
  # reports ANR_NO_WAIT (reject + retry, no tap).
  win=""
  if win="$(run_with_timeout 60 adb shell dumpsys window windows 2>"$err")"; then
    if [ -n "$win" ]; then
      if printf '%s' "$win" | grep -Eq "mCurrentFocus.*Application (Error|Not Responding):"; then
        echo "ANR_NO_WAIT"
        return 0
      fi
      echo "NO_ANR"
      return 0
    fi
    echo "[capture] WARN: ANR method 3 (dumpsys) returned empty output." >&2
  else
    echo "[capture] WARN: ANR method 3 (dumpsys) failed/timed out; stderr: $(head -c 300 "$err" | tr '\n' ' ')" >&2
  fi

  echo "UNKNOWN"
  return 0
}

# collect_anr_diagnostics: best-effort evidence capture when an ANR
# is confirmed, so the artifact PROVES (not guesses) whether the
# device was overloaded. Files land in OUT_DIR and are uploaded
# with the artifact. Never fails the script. Run #6 died on a
# launcher ANR with no evidence at all — no logcat, no meminfo,
# no host numbers — so the next run must not repeat that.
collect_anr_diagnostics() {
  log "Collecting ANR diagnostics into $OUT_DIR ..."
  adb logcat -b all -d 2>/dev/null \
    | grep -iE "ANR|am_anr|lowmemorykiller|onTrimMemory|oom" \
    | tail -50 > "$OUT_DIR/.anr-logcat.txt" 2>/dev/null || true
  adb shell dumpsys meminfo com.google.android.apps.nexuslauncher 2>/dev/null \
    | head -30 > "$OUT_DIR/.launcher-meminfo.txt" 2>/dev/null || true
  { free -m; uptime; } > "$OUT_DIR/.host-resources.txt" 2>/dev/null || true
  log "ANR diagnostics collected (logcat lines: $(wc -l <"$OUT_DIR/.anr-logcat.txt" 2>/dev/null || echo 0))."
}

# anr_dialog_info <dumpfile>: print on stdout:
#   TITLE <dialog title text>     (the node text containing
#     "isn't responding" / "not responding")
#   CLOSE <x> <y> | CLOSE ABSENT  (the dialog's Close-app button,
#     by resource-id android:id/aerr_close; fallback exact text
#     "Close app". Coordinates come from the dump — never guessed.)
#   UNPARSABLE (single line) if the dump cannot be parsed.
anr_dialog_info() {
  python3 - "$1" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
try:
    with open(path, "rb") as fh:
        data = fh.read()
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    start = data.find(b"<?xml")
    if start < 0:
        start = data.find(b"<hierarchy")
    if start < 0:
        raise ValueError("no XML start marker")
    end = data.rfind(b"</hierarchy>")
    if end >= start:
        data = data[: end + len(b"</hierarchy>")]
    root = ET.fromstring(data[start:])
except Exception as exc:
    print("UNPARSABLE: %s" % exc, file=sys.stderr)
    print("UNPARSABLE")
    sys.exit(0)

def center(bounds):
    try:
        a, b = bounds.split("][")
        x1, y1 = a.lstrip("[").split(",")
        x2, y2 = b.rstrip("]").split(",")
        return ((int(x1) + int(x2)) // 2, (int(y1) + int(y2)) // 2)
    except Exception:
        return None

title = ""
for node in root.iter("node"):
    t = (node.get("text") or "")
    low = t.lower()
    if "isn't responding" in low or "not responding" in low:
        title = t
        break
print("TITLE %s" % title)

close = None
for node in root.iter("node"):
    if node.get("resource-id") == "android:id/aerr_close":
        close = center(node.get("bounds", ""))
        if close:
            break
if not close:
    for node in root.iter("node"):
        if node.get("text") == "Close app" or node.get("content-desc") == "Close app":
            close = center(node.get("bounds", ""))
            if close:
                break
if close:
    print("CLOSE %d %d" % close)
else:
    print("CLOSE ABSENT")
PYEOF
}

# anr_close_launcher: 0 only when a LAUNCHER ANR was closed and the
# screen is verified recovered (dialog gone, Chrome foreground, URL
# verified). Any other ANR app — Chrome itself, System UI, or an
# unidentifiable dialog — fails fast with diagnostics: closing the
# wrong app blindly would kill Chrome or the system UI and the run
# would still fail, just later and with less evidence. The Close
# tap happens at most once per call, and the caller runs this at
# most once per shot.
anr_close_launcher() {
  local dump="$OUT_DIR/.anr-dialog-dump.xml" info="" title="" close="" x="" y="" state=""
  if ! fetch_ui_dump "$dump" 2>"$OUT_DIR/.anr-dialog-dump.err"; then
    cat "$OUT_DIR/.anr-dialog-dump.err" 2>/dev/null || true
    log "ERROR: cannot obtain a UI dump to identify the ANR app; failing fast (never blindly Close)."
    return 1
  fi
  cat "$OUT_DIR/.anr-dialog-dump.err" 2>/dev/null || true
  info="$(anr_dialog_info "$dump" || true)"
  if printf '%s' "$info" | grep -q "UNPARSABLE"; then
    log "ERROR: ANR dialog dump unparsable; cannot identify the ANR app; failing fast."
    return 1
  fi
  title="$(printf '%s\n' "$info" | sed -n 's/^TITLE //p')"
  close="$(printf '%s\n' "$info" | sed -n 's/^CLOSE //p')"
  log "ANR dialog title: '$title' (Close button: ${close:-ABSENT})."
  case "$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')" in
    *launcher*)
      ;;
    *)
      log "ERROR: ANR is '$title' — not the launcher; failing fast with diagnostics (no Close tap)."
      return 1
      ;;
  esac
  case "$close" in
    ABSENT|UNPARSABLE|"")
      log "ERROR: launcher ANR confirmed but no Close-app button found in the dump; failing fast."
      return 1
      ;;
  esac
  set -- $close
  x="$1"
  y="$2"
  log "Launcher ANR confirmed; tapping Close app at $x,$y (once)."
  adb shell input tap "$x" "$y" || true
  sleep 10
  state="$(check_anr_state 2>"$OUT_DIR/.anr-state.err")"
  cat "$OUT_DIR/.anr-state.err" 2>/dev/null || true
  if [ "$state" != "NO_ANR" ]; then
    log "ERROR: ANR dialog still present after Close tap (state: $state); failing fast."
    return 1
  fi
  if ! chrome_is_foreground; then
    log "WARN: Chrome lost the foreground after closing the launcher ANR; re-firing the intent."
    refire_intent
    if ! chrome_is_foreground; then
      log "ERROR: Chrome is still not the foreground app after re-fire; failing fast."
      return 1
    fi
  fi
  if verify_url_loaded; then
    log "Launcher ANR recovered: dialog gone, Chrome foreground, URL verified."
    return 0
  fi
  log "ERROR: URL not verified in a Chrome tab after launcher ANR recovery; failing fast."
  return 1
}

# ensure_no_anr: 0 only when the screen is PROVEN ANR-free.
# BOUNDED recovery (run #6 fix): the old code probed up to 3 times
# per shot attempt and tapped Wait on every probe — up to 15 Wait
# taps on the same stuck "Pixel Launcher isn't responding" dialog
# across 5 attempts, and the run still died at the ANR gate. Now
# the recovery runs AT MOST ONCE per shot (ANR_RECOVERY_DONE, reset
# by capture_verified_frame per shot): on the first ANR, collect
# diagnostics, tap Wait ONCE and verify; if still ANR, only a
# confirmed launcher ANR gets one Close tap (anr_close_launcher),
# verified end to end. Any later ANR in the same shot rejects
# immediately without re-tapping. UNKNOWN states still get up to 3
# probes (they are transient dump failures, not a stuck dialog).
ensure_no_anr() {
  local probe=1 state="" x="" y=""
  while [ "$probe" -le 3 ]; do
    state="$(check_anr_state 2>"$OUT_DIR/.anr-state.err")"
    cat "$OUT_DIR/.anr-state.err" 2>/dev/null || true
    case "$state" in
      NO_ANR)
        log "ANR check: clear (probe $probe)."
        return 0
        ;;
      WAIT*|ANR_NO_WAIT)
        if [ "$ANR_RECOVERY_DONE" -eq 1 ]; then
          log "ERROR: ANR still present and the one recovery for this shot was already used; rejecting without re-tapping (state: $state)."
          return 1
        fi
        ANR_RECOVERY_DONE=1
        log "ANR dialog present (state: $state); running the single bounded recovery for this shot."
        collect_anr_diagnostics
        if [ "$state" != "ANR_NO_WAIT" ]; then
          set -- $state
          x="$2"
          y="$3"
          log "Tapping Wait at $x,$y (once)."
          adb shell input tap "$x" "$y" || true
          sleep 10
          state="$(check_anr_state 2>"$OUT_DIR/.anr-state.err")"
          cat "$OUT_DIR/.anr-state.err" 2>/dev/null || true
          if [ "$state" = "NO_ANR" ]; then
            log "ANR dialog dismissed by Wait (verified by re-dump)."
            return 0
          fi
          log "WARN: ANR dialog still present after Wait tap (state: $state)."
        else
          log "WARN: ANR dialog present but no Wait button found; skipping the Wait tap."
        fi
        if anr_close_launcher; then
          return 0
        fi
        return 1
        ;;
      UNKNOWN)
        log "WARN: ANR state UNKNOWN — all dump methods failed (probe $probe)."
        ;;
      *)
        log "WARN: unexpected ANR state '$state' (probe $probe)."
        ;;
    esac
    sleep 10
    probe=$((probe + 1))
  done
  log "ERROR: could not establish an ANR-free screen after 3 probes (last: $state)."
  return 1
}

# url_matches <tab-url>: 0 when the tab URL is the requested URL
# (scheme-insensitive, trailing slash ignored, sub-path/query/
# fragment allowed — redirects and tracking params must not fail it).
url_matches() {
  local tab="$1" norm_tab="" norm_url=""
  norm_url="${URL#http://}"
  norm_url="${norm_url#https://}"
  norm_url="${norm_url%/}"
  norm_tab="${tab#http://}"
  norm_tab="${norm_tab#https://}"
  norm_tab="${norm_tab%/}"
  case "$norm_tab" in
    "$norm_url"|"$norm_url"/*|"$norm_url"?*|"$norm_url"#*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# verify_url_loaded: 0 = a Chrome page tab holds the requested URL;
# 1 = DevTools reachable but no tab holds the URL; 2 = DevTools
# unreachable. Uses the documented Chrome remote-debugging socket
# (adb forward tcp:9222 localabstract:chrome_devtools_remote, then
# http://127.0.0.1:9222/json). Probes up to 3 times internally
# because navigation may still be in flight. Every observed tab URL
# is logged. Callers must use `verify_url_loaded || rc=$?` (a
# non-zero return under `set -e` exits the script otherwise).
verify_url_loaded() {
  local probe=1 json="" urls="" tab="" rc=2
  if ! adb forward tcp:9222 localabstract:chrome_devtools_remote >"$OUT_DIR/.cdp-forward.log" 2>&1; then
    log "WARN: adb forward for Chrome DevTools failed."
    head -5 "$OUT_DIR/.cdp-forward.log" 2>/dev/null || true
    return 2
  fi
  while [ "$probe" -le 3 ]; do
    json="$(curl -s --max-time 10 "http://127.0.0.1:9222/json" 2>/dev/null || true)"
    if [ -n "$json" ]; then
      urls="$(printf '%s' "$json" | python3 -c '
import sys, json
try:
    targets = json.load(sys.stdin)
except Exception as exc:
    print("JSON_ERROR: %s" % exc)
    sys.exit(0)
for t in targets:
    if isinstance(t, dict) and t.get("type") == "page":
        print(t.get("url", ""))
' 2>/dev/null || true)"
      if printf '%s' "$urls" | grep -q "JSON_ERROR"; then
        log "WARN: DevTools /json unparsable (probe $probe): $urls"
        rc=2
      elif [ -z "$urls" ]; then
        log "WARN: DevTools /json lists no page tabs (probe $probe)."
        rc=2
      else
        log "DevTools page tabs (probe $probe): $(printf '%s' "$urls" | tr '\n' ' ' | head -c 400)"
        rc=1
        while IFS= read -r tab; do
          [ -z "$tab" ] && continue
          if url_matches "$tab"; then
            log "URL verified in Chrome tab: $tab"
            adb forward --remove tcp:9222 >/dev/null 2>&1 || true
            return 0
          fi
        done <<<"$urls"
      fi
    else
      log "WARN: DevTools /json empty (probe $probe)."
      rc=2
    fi
    probe=$((probe + 1))
    [ "$probe" -le 3 ] && sleep 10
  done
  adb forward --remove tcp:9222 >/dev/null 2>&1 || true
  return "$rc"
}

refire_intent() {
  log "Re-firing VIEW intent at $URL ..."
  adb shell am start -a android.intent.action.VIEW -d "$URL" com.android.chrome || true
  wait_for_chrome_foreground
  sleep 15
}

do_swipe() {
  log "Scrolling down once..."
  adb shell input swipe 540 1600 540 700 300 || true
  sleep 5
}

# fetch_ui_dump <outfile>: write the current UI hierarchy XML to
# <outfile>; 0 = usable dump written, 1 = every method failed. The
# two methods mirror check_anr_state (same commands, same order): a
# stdout dump first (no file transfer), then dump-to-file read back
# with `cat` (no `adb pull`). The third ANR method, dumpsys window
# focus, is deliberately NOT used here: it reports which window is
# focused, not the node hierarchy, so it can neither prove the
# promo card present nor absent — treating its output as
# card-absence evidence would re-open the fail-open hole this
# script exists to close. A dump is accepted only if it is
# non-empty and contains nodes. Diagnostics go to stderr.
fetch_ui_dump() {
  local out="$1" err="$OUT_DIR/.dump-method.err"
  rm -f "$out" "$err"
  if run_with_timeout 60 adb exec-out uiautomator dump /dev/tty >"$out" 2>"$err"; then
    if [ -s "$out" ] && grep -q "<node" "$out"; then
      return 0
    fi
    echo "[capture] WARN: UI dump method 1 returned empty/unusable output; stderr: $(head -c 300 "$err" | tr '\n' ' ')" >&2
  else
    echo "[capture] WARN: UI dump method 1 (exec-out dump) failed/timed out; stderr: $(head -c 300 "$err" | tr '\n' ' ')" >&2
  fi
  rm -f "$out" "$err"
  if run_with_timeout 60 adb shell uiautomator dump /sdcard/window_dump.xml >"$OUT_DIR/.dump-m2.log" 2>"$err"; then
    if run_with_timeout 30 adb shell cat /sdcard/window_dump.xml >"$out" 2>"$err"; then
      if [ -s "$out" ] && grep -q "<node" "$out"; then
        return 0
      fi
      echo "[capture] WARN: UI dump method 2 (cat) returned empty/unusable output." >&2
    else
      echo "[capture] WARN: UI dump method 2 (cat) failed/timed out; stderr: $(head -c 300 "$err" | tr '\n' ' ')" >&2
    fi
  else
    echo "[capture] WARN: UI dump method 2 (dump to file) failed/timed out; stderr: $(head -c 300 "$err" | tr '\n' ' ')" >&2
  fi
  return 1
}

# find_promo_button <dumpfile>: print exactly one line on stdout:
#   "TAP <x> <y>" when the notifications promo's "No thanks" button
#   is in the dump, "CARD_NO_BUTTON" when the card's title text is
#   in the dump but no "No thanks" button was found (card present,
#   caller tries Back once — never ABSENT), "ABSENT" when the dump
#   parses and has no card text/button at all, "UNPARSABLE" when the
#   dump is not usable XML. Matches
#   the button by its exact text first; falls back to a resource-id
#   containing "no_thanks" (id spelling unverified on this image —
#   it can only fire on an id that literally says so). The centre
#   of the button's bounds is the tap point.
find_promo_button() {
  python3 - "$1" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
try:
    with open(path, "rb") as fh:
        data = fh.read()
    # uiautomator dump prefixes its stdout with a one-line status
    # message ("UI hierchary dumped to: ...") before the XML; strip
    # everything before the XML start, or the parse below fails on
    # the prefix even though the dump itself is valid.
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    start = data.find(b"<?xml")
    if start < 0:
        start = data.find(b"<hierarchy")
    if start < 0:
        raise ValueError("no XML start marker")
    # uiautomator's stdout can also carry trailing junk AFTER the
    # closing </hierarchy> tag (status lines, shell noise); the
    # parser rejects anything past the root element, so slice the
    # dump to the end of the hierarchy before parsing. Without
    # this, a valid dump with trailing junk reads as UNPARSABLE
    # and the dismiss step fails on attempt 1.
    end = data.rfind(b"</hierarchy>")
    if end >= start:
        data = data[: end + len(b"</hierarchy>")]
    root = ET.fromstring(data[start:])
except Exception as exc:
    # Print the real parse error to stderr for the log; stdout must
    # stay exactly one token ("UNPARSABLE") for the caller.
    print("UNPARSABLE: %s" % exc, file=sys.stderr)
    print("UNPARSABLE")
    sys.exit(0)

def center(bounds):
    try:
        a, b = bounds.split("][")
        x1, y1 = a.lstrip("[").split(",")
        x2, y2 = b.rstrip("]").split(",")
        return ((int(x1) + int(x2)) // 2, (int(y1) + int(y2)) // 2)
    except Exception:
        return None

for node in root.iter("node"):
    if node.get("text") == "No thanks" or node.get("content-desc") == "No thanks":
        c = center(node.get("bounds", ""))
        if c:
            print("TAP %d %d" % c)
            sys.exit(0)
for node in root.iter("node"):
    rid = (node.get("resource-id") or "").lower()
    if "no_thanks" in rid:
        c = center(node.get("bounds", ""))
        if c:
            print("TAP %d %d" % c)
            sys.exit(0)
# The card's title text proves the card is present even when the
# "No thanks" button node is missed (run #6's failed frame still
# showed the card after the dismiss step reported ABSENT): a dump
# carrying the title counts as present, not absent. There is no
# button to tap, so the caller treats this as "card present, try
# Back once" rather than a dismissal tap.
for node in root.iter("node"):
    if "chrome notifications make things easier" in (node.get("text") or "").lower():
        print("CARD_NO_BUTTON")
        sys.exit(0)
print("ABSENT")
PYEOF
}

# dismiss_notifications_card: 0 = the notifications promo card is
# absent, or was present and is now verified gone. Transient dump
# failures and unparsable dumps are RETRIED (sleep 5, next
# attempt) — a single bad dump must not fail the run (that is the
# bug that killed run 41857851484: the old code returned 1 on
# attempt 1). After 3 attempts without a verified dismissal,
# Android Back is pressed once and the card's absence is
# re-verified by a fresh dump. 1 = the card is still present, or
# the UI dump could not be obtained/parsed, after the Back
# fallback — an obscured or unverifiable frame must never be
# accepted, so the caller fails the run. Every step is logged; a
# tap is verified gone by a fresh re-dump, never assumed. On final
# failure the first ~500 chars of the dump are printed to the log.
dismiss_notifications_card() {
  local attempt=1 dump="$OUT_DIR/.promo-dump.xml" found="" x="" y="" back_tried=0
  while [ "$attempt" -le 3 ]; do
    if ! fetch_ui_dump "$dump" 2>"$OUT_DIR/.promo-dump.err"; then
      cat "$OUT_DIR/.promo-dump.err" 2>/dev/null || true
      log "WARN: could not obtain a UI dump to check for the notifications promo card (attempt $attempt); retrying."
      sleep 5
      attempt=$((attempt + 1))
      continue
    fi
    cat "$OUT_DIR/.promo-dump.err" 2>/dev/null || true
    found="$(find_promo_button "$dump" || true)"
    case "$found" in
      ABSENT)
        log "Notifications promo card: absent (attempt $attempt)."
        return 0
        ;;
      TAP*)
        set -- $found
        x="$2"
        y="$3"
        log "Notifications promo card found; tapping \"No thanks\" at $x,$y (attempt $attempt)."
        adb shell input tap "$x" "$y" || true
        sleep 10
        ;;
      CARD_NO_BUTTON)
        # Card title present but no "No thanks" button to tap:
        # treat as PRESENT (never ABSENT) and try Android Back
        # once; the next attempt re-dumps to verify it is gone.
        if [ "$back_tried" -eq 0 ]; then
          back_tried=1
          log "Notifications promo card title present but no \"No thanks\" button (attempt $attempt); pressing Back once."
          adb shell input keyevent 4 || true
          sleep 10
        else
          log "Notifications promo card title still present after Back (attempt $attempt); retrying the dump."
          sleep 5
        fi
        ;;
      *)
        log "WARN: UI dump unparsable while checking for the notifications promo card (attempt $attempt; result: '$found'); retrying."
        sleep 5
        ;;
    esac
    attempt=$((attempt + 1))
  done
  # 3 attempts did not verify the card gone (taps, transient dump
  # failures, or unparsable dumps). Last resort before failing:
  # press Android Back — the promo card is a dialog-like overlay
  # that Back dismisses — then re-dump to verify it is actually
  # gone. If Back instead exits Chrome, the per-shot gates + intent
  # re-fire recover the foreground; the run is already heading for
  # failure without this attempt, so the fallback can only help.
  log "Notifications promo card not verified gone after 3 attempts; pressing Back as a last resort..."
  adb shell input keyevent 4 || true
  sleep 10
  if ! fetch_ui_dump "$dump" 2>"$OUT_DIR/.promo-dump.err"; then
    cat "$OUT_DIR/.promo-dump.err" 2>/dev/null || true
    log "ERROR: could not obtain a final UI dump to verify the notifications promo card is gone."
    if [ -s "$dump" ]; then
      log "Dump head (first 500 chars): $(head -c 500 "$dump" | tr '\n' ' ')"
    fi
    return 1
  fi
  cat "$OUT_DIR/.promo-dump.err" 2>/dev/null || true
  found="$(find_promo_button "$dump" || true)"
  if [ "$found" = "ABSENT" ]; then
    log "Notifications promo card dismissed (verified gone by re-dump after Back)."
    return 0
  fi
  log "ERROR: notifications promo card still present after 3 dismissal attempts + Back (last check: '$found')."
  if [ -s "$dump" ]; then
    log "Dump head (first 500 chars): $(head -c 500 "$dump" | tr '\n' ' ')"
  fi
  return 1
}

# capture_verified_frame <outfile> <label> <check_url: 0|1>
# Gates, in order, on EVERY attempt: (A) Chrome foreground,
# (B) ANR-free verified, (C) URL evidence when required (shot 1, and
# after any re-fire), (D) pixel check. At most 1 intent re-fire per
# shot. On total failure, exits 1 (workflow goes RED) and leaves the
# last failed frame as a diagnostic.
capture_verified_frame() {
  local outfile="$1" label="$2" check_url="$3"
  local tmp="$OUT_DIR/.tmp-$label.png"
  local attempt=1 refired=0 need_url="$check_url" url_rc=0 check_output=""
  ANR_RECOVERY_DONE=0  # one bounded ANR recovery per shot (see ensure_no_anr).
  while [ "$attempt" -le 5 ]; do
    log "$label: attempt $attempt/5"
    # Gate A: Chrome must be the foreground app.
    if ! chrome_is_foreground; then
      log "WARN: Chrome is not the foreground app (attempt $attempt)."
      if [ "$refired" -eq 0 ]; then
        refire_intent
        refired=1
        need_url=1
        if [ "$label" = "scrolled" ]; then do_swipe; fi
        attempt=$((attempt + 1))
        continue
      fi
      log "$label: REJECTED (Chrome not foreground after re-fire)."
      sleep 15
      attempt=$((attempt + 1))
      continue
    fi
    # Gate B: ANR-free, verified.
    if ! ensure_no_anr; then
      log "$label: REJECTED (ANR state not clear)."
      sleep 15
      attempt=$((attempt + 1))
      continue
    fi
    # Gate C: the tab must hold the requested URL.
    if [ "$need_url" -eq 1 ]; then
      url_rc=0
      verify_url_loaded || url_rc=$?
      if [ "$url_rc" -ne 0 ]; then
        log "$label: REJECTED (URL not verified in a Chrome tab, rc=$url_rc)."
        if [ "$refired" -eq 0 ]; then
          refire_intent
          refired=1
          if [ "$label" = "scrolled" ]; then do_swipe; fi
        fi
        sleep 15
        attempt=$((attempt + 1))
        continue
      fi
      need_url=0
      log "$label: URL evidence OK."
    fi
    # Gate D: pixel check (rejects dark/blank frames).
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
  if [ -s "$tmp" ]; then
    cp "$tmp" "$OUT_DIR/00-last-failed-frame-$label.png" 2>/dev/null || true
  else
    # The gates rejected every attempt before any screencap ran (e.g.
    # ANR state never became known) — capture the stuck screen itself
    # as the diagnostic instead of saving nothing.
    log "Capturing a diagnostic frame of the stuck screen..."
    adb exec-out screencap -p > "$OUT_DIR/00-last-failed-frame-$label.png" || true
    if [ ! -s "$OUT_DIR/00-last-failed-frame-$label.png" ]; then
      rm -f "$OUT_DIR/00-last-failed-frame-$label.png" 2>/dev/null || true
      log "WARN: diagnostic screencap was empty; no diagnostic frame saved."
    fi
  fi
  log "ERROR: could not capture a real $label frame after 5 attempts."
  if [ -s "$OUT_DIR/00-last-failed-frame-$label.png" ]; then
    log "Diagnostic saved: 00-last-failed-frame-$label.png"
  fi
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

# NOTE: no `cmd role add-role-holder` step. It only sets the DEFAULT
# browser for implicit intents; the VIEW intent below names
# com.android.chrome explicitly, which bypasses default resolution
# entirely. The role step added nothing and timed out
# (java.util.concurrent.TimeoutException) on the starved 1-vCPU
# system in run #3's log — removed as a failure point.

log "Applying Chrome first-run-experience skip flags..."
# Documented Chrome mechanism: flags in /data/local/tmp/chrome-command-line
# are picked up on launch. --disable-fre skips the welcome / sign-in flow.
adb shell 'echo "chrome --disable-fre --no-first-run --disable-startup-promos-for-testing --no-default-browser-check" > /data/local/tmp/chrome-command-line' || true
adb shell am force-stop com.android.chrome || true

# Chrome's notifications promo card appears because Chrome holds the
# POST_NOTIFICATIONS runtime permission on this image. Revoke it
# before launch so the card never appears in the first place; the
# revoke grants nothing and is best-effort (|| true). The dismiss
# step below stays as the safety net regardless.
log "Revoking Chrome's POST_NOTIFICATIONS permission so the notifications promo card cannot appear..."
# The revoke's REAL exit code is logged (round-1 hid it behind
# || true): a failed revoke is the first suspect when the card
# still appears. The permission state is verified right after.
revoke_rc=0
adb shell pm revoke com.android.chrome android.permission.POST_NOTIFICATIONS || revoke_rc=$?
log "POST_NOTIFICATIONS revoke exit code: $revoke_rc"
log "Chrome POST_NOTIFICATIONS state after revoke:"
adb shell dumpsys package com.android.chrome 2>/dev/null | grep -i "POST_NOTIFICATIONS" || log "  (no POST_NOTIFICATIONS line in dumpsys output)"

log "Launching Chrome at $URL ..."
adb shell am start -a android.intent.action.VIEW -d "$URL" com.android.chrome || true

wait_for_chrome_foreground
log "Page settle: sleeping 45s for the page to render..."
sleep 45

# Chrome's notifications promo card ("Chrome notifications make
# things easier", "No thanks" / "Continue") is not suppressed by
# the --disable-fre flags on the google_apis API 34 image: run
# 41847287396 went green with the card covering the middle of the
# page. Dismiss it before any shot is accepted — a card over the
# page must never reach a listing frame.
# dismiss_promo_or_die: dismiss the notifications promo card; on
# failure capture a diagnostic frame and exit 1 — an obscured frame
# must never be accepted.
dismiss_promo_or_die() {
  if dismiss_notifications_card; then
    return 0
  fi
  log "Capturing a diagnostic frame of the stuck screen..."
  adb exec-out screencap -p > "$OUT_DIR/00-last-failed-frame-promo-card.png" || true
  if [ ! -s "$OUT_DIR/00-last-failed-frame-promo-card.png" ]; then
    rm -f "$OUT_DIR/00-last-failed-frame-promo-card.png" 2>/dev/null || true
    log "WARN: diagnostic screencap was empty; no diagnostic frame saved."
  else
    log "Diagnostic saved: 00-last-failed-frame-promo-card.png"
  fi
  log "ERROR: notifications promo card could not be dismissed; refusing to capture obscured frames."
  exit 1
}

dismiss_promo_or_die
# The card can appear AFTER the first check (run #6's failed frame
# still showed it) — re-run the dismiss immediately before the
# first shot so a late-appearing card is caught, not captured.
dismiss_promo_or_die

capture_verified_frame "$OUT_DIR/01-settled.png" "settled" 1

do_swipe

capture_verified_frame "$OUT_DIR/02-scrolled.png" "scrolled" 0

log "Screenshots (verified frames):"
ls -la "$OUT_DIR"
