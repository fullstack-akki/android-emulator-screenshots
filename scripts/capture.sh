#!/usr/bin/env bash
# Capture two screenshots of a URL inside the emulator and VERIFY each
# frame is real before accepting it. Usage:
#   bash scripts/capture.sh [URL]
# URL may also come from the CAPTURE_URL environment variable; default
# is https://example.com.
#
# Optional LOGIN mode: when BOTH LOGIN_EMAIL and LOGIN_PASSWORD are
# set (never logged, never echoed — the password arrives from a
# CI secret), the script logs in to the app after Chrome launch
# (identifier + password form) and verifies the logged-in dashboard
# before any shot. With only one of the two set, login is skipped
# and the run proceeds logged-out. A failed login exits 1 with a
# diagnostic frame — a logged-out screen is never captured as if
# it were logged in.
#
# Optional SCREENS mode: SCREENS is newline-separated "label|target"
# lines (or ';'-separated on one line, for GitHub's single-line
# workflow_dispatch input, which collapses pasted newlines to spaces);
# target is a full URL, or "tap:voice" for the floating voice
# assistant (opened from the dashboard — it has no route). When set,
# one verified settled frame is captured per screen (named
# NN-label.png) instead of the settled+scrolled pair. Empty SCREENS
# keeps the original single-URL behaviour (01-settled + 02-scrolled).
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
# public page. Without LOGIN_* it is never typed into and nothing is
# submitted. With LOGIN_* set, the login form IS typed into (see the
# login phase) — and only then.
set -euo pipefail

URL="${1:-${CAPTURE_URL:-https://example.com}}"
OUT_DIR="screenshots"
mkdir -p "$OUT_DIR"

# Login credentials come from the environment ONLY (CI secret in
# production). They are NEVER logged or echoed anywhere in this
# script — not even the email. Only "login enabled/disabled" is
# logged.
LOGIN_EMAIL="${LOGIN_EMAIL:-}"
LOGIN_PASSWORD="${LOGIN_PASSWORD:-}"
# SCREENS: newline-separated "label|target" lines (see header).
SCREENS="${SCREENS:-}"

# APP_ORIGIN is the scheme+host of URL; LOGIN_URL / DASHBOARD_URL are
# derived from it (the app's routes: /login is public, /dashboard is
# the post-login landing page). CURRENT_URL is what gate C checks and
# what refire_intent re-fires; it moves as the run navigates.
APP_ORIGIN="$(printf '%s' "$URL" | sed -E 's#^(https?://[^/]+).*#\1#')"
LOGIN_URL="$APP_ORIGIN/login"
DASHBOARD_URL="$APP_ORIGIN/dashboard"
CURRENT_URL="$URL"

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

# url_matches <tab-url>: 0 when the tab URL is the CURRENT_URL
# (scheme-insensitive, trailing slash ignored, sub-path/query/
# fragment allowed — redirects and tracking params must not fail it).
# CURRENT_URL moves as the run navigates (login, per-screen URLs).
url_matches() {
  local tab="$1" norm_tab="" norm_url=""
  norm_url="${CURRENT_URL#http://}"
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
  log "Re-firing VIEW intent at $CURRENT_URL ..."
  adb shell am start -a android.intent.action.VIEW -d "$CURRENT_URL" com.android.chrome || true
  wait_for_chrome_foreground
  sleep 15
}

do_swipe() {
  log "Scrolling down once..."
  adb shell input swipe 540 1600 540 700 300 || true
  sleep 5
}

# adb_type <text>: type text with `adb shell input text`, escaping
# the two characters that command treats specially: % (the escape
# introducer — a bare % corrupts the text) and space (typed as %s).
# The login inputs are restricted by construction (email charset
# letters/digits/+/@/. and an alphanumeric password), so no shell
# metacharacters reach the device shell.
adb_type() {
  local text="$1"
  text="${text//%/%%}"
  text="${text// /%s}"
  adb shell input text "$text" || true
}

# find_text_button <dumpfile> <exact-text>: print exactly one line:
#   "TAP <x> <y>" when a node has that exact text or content-desc,
#   "ABSENT" when the dump parses and has no such node,
#   "UNPARSABLE" when the dump is not usable XML. The centre of the
#   node's bounds is the tap point. Used for the homepage
#   "લોગિન કરો" button, the save-password "Never" button, and the
#   floating voice-assistant button (aria-label "Voice Assistant").
find_text_button() {
  python3 - "$1" "$2" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
want = sys.argv[2]
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

for node in root.iter("node"):
    if (node.get("text") or "") == want or (node.get("content-desc") or "") == want:
        c = center(node.get("bounds", ""))
        if c:
            print("TAP %d %d" % c)
            sys.exit(0)
print("ABSENT")
PYEOF
}

# find_login_fields <dumpfile>: print exactly one line on stdout:
#   "FIELDS <id_x> <id_y> <pw_x> <pw_y> <sub_x> <sub_y>" when the
#   identifier + password + submit controls are all found,
#   "NOFIELDS <missing>" when the form is not fully present,
#   "UNPARSABLE" when the dump is not usable XML.
# Matching order (web content in Chrome's accessibility tree has no
# stable resource-ids, so hints and order carry the weight):
#   identifier — resource-id containing "identifier"/"username",
#     else a node carrying the "email@example.com" placeholder,
#     else the FIRST EditText on screen.
#   password — resource-id containing "password", else an EditText
#     with password="true", else the first EditText that is not the
#     identifier.
#   submit — exact text (or content-desc) "લોગિન કરો", else a Button
#     whose text contains "લોગિન".
find_login_fields() {
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

edits = [n for n in root.iter("node") if n.get("class") == "android.widget.EditText"]

ident = None
for node in edits:
    rid = (node.get("resource-id") or "").lower()
    if "identifier" in rid or "username" in rid:
        ident = node
        break
if ident is None:
    for node in edits:
        t = (node.get("text") or "") + " " + (node.get("content-desc") or "")
        if "email@example.com" in t:
            ident = node
            break
if ident is None and edits:
    ident = edits[0]

pw = None
for node in edits:
    rid = (node.get("resource-id") or "").lower()
    if "password" in rid:
        pw = node
        break
if pw is None:
    for node in edits:
        if node.get("password") == "true":
            pw = node
            break
if pw is None:
    for node in edits:
        if node is not ident:
            pw = node
            break

submit = None
for node in root.iter("node"):
    if (node.get("text") or "") == "લોગિન કરો" or (node.get("content-desc") or "") == "લોગિન કરો":
        submit = node
        break
if submit is None:
    for node in root.iter("node"):
        cls = node.get("class") or ""
        if cls.endswith("Button") and "લોગિન" in (node.get("text") or ""):
            submit = node
            break

missing = []
if ident is None:
    missing.append("identifier")
if pw is None:
    missing.append("password")
if submit is None:
    missing.append("submit")
if missing:
    print("NOFIELDS %s" % ",".join(missing))
    sys.exit(0)

ci = center(ident.get("bounds", ""))
cp = center(pw.get("bounds", ""))
cs = center(submit.get("bounds", ""))
if not ci or not cp or not cs:
    print("NOFIELDS no-bounds")
    sys.exit(0)
print("FIELDS %d %d %d %d %d %d" % (ci[0], ci[1], cp[0], cp[1], cs[0], cs[1]))
PYEOF
}

# login_field_state <dumpfile> <expected-email>: print exactly one
# line on stdout describing the login form's current state:
#   "STATE ident=<exact|extra|empty|other|missing>
#          pw_focused=<0|1> id_focused=<0|1> any_focused=<0|1>"
# or "UNPARSABLE" when the dump is not usable XML.
#   ident — the identifier node's text vs the expected email:
#     exact (equal), extra (starts with the email but longer —
#     the run #8 failure mode, where the password was typed into
#     the identifier field after the email), empty (no text yet),
#     other (non-empty and different), missing (no identifier
#     node). The password field's text is masked in real dumps,
#     so it is never reported or compared.
#   pw_focused / id_focused — the focused="true" flag on the
#     password / identifier node. any_focused — whether ANY node
#     in the dump is focused (some builds do not expose focus for
#     web content at all; then focus is undeterminable and the
#     caller must not treat "not focused" as a definite miss).
# Field matching mirrors find_login_fields exactly.
login_field_state() {
  python3 - "$1" "$2" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
want_email = sys.argv[2]
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

edits = [n for n in root.iter("node") if n.get("class") == "android.widget.EditText"]

ident = None
for node in edits:
    rid = (node.get("resource-id") or "").lower()
    if "identifier" in rid or "username" in rid:
        ident = node
        break
if ident is None:
    for node in edits:
        t = (node.get("text") or "") + " " + (node.get("content-desc") or "")
        if "email@example.com" in t:
            ident = node
            break
if ident is None and edits:
    ident = edits[0]

pw = None
for node in edits:
    rid = (node.get("resource-id") or "").lower()
    if "password" in rid:
        pw = node
        break
if pw is None:
    for node in edits:
        if node.get("password") == "true":
            pw = node
            break
if pw is None:
    for node in edits:
        if node is not ident:
            pw = node
            break

if ident is None:
    ident_state = "missing"
else:
    t = ident.get("text") or ""
    if t == "":
        ident_state = "empty"
    elif t == want_email:
        ident_state = "exact"
    elif t.startswith(want_email):
        ident_state = "extra"
    else:
        ident_state = "other"

def focused(node):
    return "1" if node is not None and node.get("focused") == "true" else "0"

any_focused = "1" if any((n.get("focused") == "true") for n in root.iter("node")) else "0"
print("STATE ident=%s pw_focused=%s id_focused=%s any_focused=%s" % (
    ident_state, focused(pw), focused(ident), any_focused))
PYEOF
}

# state_field <state-line> <key>: print the value of key in a
# "STATE k=v ..." line from login_field_state, or "" when the line
# is not a STATE line (unparsable dump). The caller treats "" as
# "cannot determine" and fails closed.
state_field() {
  case "$1" in
    STATE*)
      local rest="${1#*$2=}"
      echo "${rest%% *}"
      ;;
    *) echo "" ;;
  esac
}

# dismiss_save_password_prompt: Chrome may offer to save the password
# after a successful login ("Save password?" bottom sheet). It would
# cover the dashboard, so tap "Never" once if it is showing (or Back
# once if there is no "Never" button). Best-effort only — always
# returns 0; the dashboard verification after it is what decides.
dismiss_save_password_prompt() {
  local dump="$OUT_DIR/.savepw-dump.xml" tap=""
  if ! fetch_ui_dump "$dump" 2>/dev/null; then
    return 0
  fi
  if grep -q "Save password" "$dump"; then
    tap="$(find_text_button "$dump" "Never" || true)"
    case "$tap" in
      TAP*)
        set -- $tap
        log "Save-password prompt showing; tapping 'Never' at $2,$3."
        adb shell input tap "$2" "$3" || true
        sleep 5
        ;;
      *)
        log "Save-password prompt showing but no 'Never' button found; pressing Back once."
        adb shell input keyevent 4 || true
        sleep 5
        ;;
    esac
  fi
  return 0
}

# dismiss_keyboard_panel: Gboard's clipboard panel ("Copy more for
# faster pasting" / "Turn on Clipboard") can pop up while typing
# and cover the lower half of the screen — taps then land on the
# panel instead of the form (run #8: the password-field tap missed
# and the password went into the identifier field). The soft
# keyboard itself also shifts the form. If the dump shows the
# panel's distinctive text or the IME window (a package containing
# "inputmethod"), press Back — the IME consumes Back, so this
# hides the keyboard/panel rather than navigating — bounded to 2
# presses, re-dumping after each. 0 = keyboard/panel absent (or
# the dump was unavailable — the focus check decides then);
# 1 = still showing after the bounded retries.
dismiss_keyboard_panel() {
  local dump="$OUT_DIR/.kbd-dump.xml" round=1
  while [ "$round" -le 2 ]; do
    if ! fetch_ui_dump "$dump" 2>/dev/null; then
      return 0
    fi
    if grep -q "Copy more for faster pasting\|Turn on Clipboard" "$dump" || grep -q "inputmethod" "$dump"; then
      log "Keyboard/Gboard panel showing; pressing Back to hide it (round $round)."
      adb shell input keyevent 4 || true
      sleep 3
      round=$((round + 1))
      continue
    fi
    return 0
  done
  if fetch_ui_dump "$dump" 2>/dev/null && { grep -q "Copy more for faster pasting\|Turn on Clipboard" "$dump" || grep -q "inputmethod" "$dump"; }; then
    log "WARN: keyboard/Gboard panel still showing after bounded Back presses."
    return 1
  fi
  return 0
}

# refresh_login_fields: re-dump and re-find the login form,
# updating the caller's id_x/id_y/pw_x/pw_y/sub_x/sub_y globals
# (bash dynamic scope — these are login_or_die's locals). The
# layout shifts when the keyboard hides/shows, so coordinates
# from an earlier dump go stale after a Back press. 0 = fresh
# coordinates; 1 = form not found or dump failed (old
# coordinates kept).
refresh_login_fields() {
  local dump="$OUT_DIR/.login-refresh-dump.xml" found=""
  if ! fetch_ui_dump "$dump" 2>/dev/null; then
    log "WARN: could not re-dump the login form; keeping previous coordinates."
    return 1
  fi
  found="$(find_login_fields "$dump" || true)"
  case "$found" in
    FIELDS*)
      set -- $found
      id_x="$2"; id_y="$3"; pw_x="$4"; pw_y="$5"; sub_x="$6"; sub_y="$7"
      return 0
      ;;
    *)
      log "WARN: login form not found on refresh ($found); keeping previous coordinates."
      return 1
      ;;
  esac
}

# tap_password_with_focus_check <dumpfile>: tap the password field
# (globals pw_x/pw_y) and verify focus actually moved there. A tap
# that lands on a Gboard panel leaves focus in the identifier
# field — that is the run #8 bug, and the password typed next
# appends to the identifier. On a definite miss (identifier still
# focused, or focus somewhere else entirely) press Back once,
# re-find the form for fresh coordinates, and retry — bounded to
# 2 retries. When the dump carries no focus information at all
# (no node focused — some builds do not expose focus for web
# content), focus is undeterminable: log a warning and proceed,
# because the identifier-exactness guard before submit is the
# backstop that catches a misdirected password. 0 = password
# focused (or focus undeterminable); 1 = focus never moved.
# NB: updates the caller's coordinate globals (bash dynamic
# scope) when it re-finds the form.
tap_password_with_focus_check() {
  local dump="$1" state="" pwf="" idf="" anyf="" ident="" try=1
  while [ "$try" -le 3 ]; do
    adb shell input tap "$pw_x" "$pw_y" || true
    sleep 2
    if fetch_ui_dump "$dump" 2>/dev/null; then
      state="$(login_field_state "$dump" "$LOGIN_EMAIL" || true)"
      pwf="$(state_field "$state" pw_focused)"
      idf="$(state_field "$state" id_focused)"
      anyf="$(state_field "$state" any_focused)"
      ident="$(state_field "$state" ident)"
      if [ -z "$pwf" ] && [ -z "$anyf" ]; then
        log "WARN: login field state unparsable after password tap $try; retrying."
      elif [ "$pwf" = "1" ]; then
        log "Password field focused (tap $try)."
        return 0
      elif [ "$anyf" = "0" ]; then
        log "WARN: no focus information in the UI dump; proceeding (the identifier guard decides)."
        return 0
      else
        log "WARN: password field not focused after tap $try (ident=$ident id_focused=$idf); pressing Back and retrying."
      fi
    else
      log "WARN: could not re-dump after password tap $try; retrying."
    fi
    adb shell input keyevent 4 || true
    sleep 2
    refresh_login_fields || true
    try=$((try + 1))
  done
  log "ERROR: password field never gained focus after 3 taps."
  return 1
}

# guard_identifier_exact <dumpfile>: the identifier field must
# contain EXACTLY the login email before the form is submitted.
# Run #8's failure mode was the password typed into the
# identifier field, so the identifier held email+password and the
# submit failed with garbage credentials. If the identifier holds
# extra/other text, recover once: clear the field, re-type the
# email, re-do the password step, and re-check. 0 = identifier
# exactly the email; 1 = still wrong after the one recovery (or
# the identifier is empty/missing, or the dump is unparsable) —
# the caller fails the attempt with a diagnostic frame.
# NB: calls tap_password_with_focus_check and updates the
# caller's coordinate globals via refresh_login_fields.
guard_identifier_exact() {
  local dump="$1" state="" ident="" del_args="" i=0
  if ! fetch_ui_dump "$dump" 2>/dev/null; then
    log "WARN: could not re-dump for the identifier guard."
    return 1
  fi
  state="$(login_field_state "$dump" "$LOGIN_EMAIL" || true)"
  ident="$(state_field "$state" ident)"
  if [ -z "$ident" ]; then
    log "WARN: login field state unparsable in the identifier guard."
    return 1
  fi
  if [ "$ident" = "exact" ]; then
    return 0
  fi
  if [ "$ident" != "extra" ] && [ "$ident" != "other" ]; then
    log "WARN: identifier guard: identifier is '$ident', not the login email; not recovering (email never landed)."
    return 1
  fi
  log "WARN: identifier holds extra text (run #8 pattern); clearing it and re-entering the credentials once."
  # Clear the identifier: tap it, move to the end, delete
  # generously (email + password length, bounded at 80 DELs;
  # extra DELs on an empty field are no-ops). `input keyevent`
  # accepts several key codes in one call.
  adb shell input tap "$id_x" "$id_y" || true
  sleep 1
  adb shell input keyevent 123 || true
  while [ "$i" -lt 80 ]; do del_args="$del_args 67"; i=$((i + 1)); done
  # Word-splitting the DEL list is intentional.
  # shellcheck disable=SC2086
  adb shell input keyevent $del_args || true
  sleep 1
  adb_type "$LOGIN_EMAIL"
  sleep 2
  if ! fetch_ui_dump "$dump" 2>/dev/null; then
    log "WARN: could not re-dump after clearing the identifier."
    return 1
  fi
  state="$(login_field_state "$dump" "$LOGIN_EMAIL" || true)"
  ident="$(state_field "$state" ident)"
  if [ "$ident" != "exact" ]; then
    log "WARN: identifier still '$ident' after clearing and re-typing; giving up."
    return 1
  fi
  log "Identifier re-entered exactly; re-doing the password step."
  dismiss_keyboard_panel || true
  refresh_login_fields || true
  if ! tap_password_with_focus_check "$dump"; then
    return 1
  fi
  adb_type "$LOGIN_PASSWORD"
  sleep 2
  if ! fetch_ui_dump "$dump" 2>/dev/null; then
    log "WARN: could not re-dump after the recovered password entry."
    return 1
  fi
  state="$(login_field_state "$dump" "$LOGIN_EMAIL" || true)"
  ident="$(state_field "$state" ident)"
  if [ "$ident" = "exact" ]; then
    log "Identifier guard passed after recovery."
    return 0
  fi
  log "WARN: identifier is '$ident' after recovery; giving up."
  return 1
}

# verify_logged_in_dashboard: 0 only when BOTH hold: a Chrome tab
# holds the /dashboard URL (DevTools) and the UI dump carries a
# logged-in dashboard marker ("ડેશબોર્ડ" nav label or the "નમસ્તે"
# greeting). Up to 3 rounds; the caller decides on failure.
verify_logged_in_dashboard() {
  local round=1 dump="$OUT_DIR/.dashboard-dump.xml" saved_url="$CURRENT_URL"
  CURRENT_URL="$DASHBOARD_URL"
  while [ "$round" -le 3 ]; do
    if verify_url_loaded; then
      log "Dashboard URL verified in a Chrome tab."
      if fetch_ui_dump "$dump" 2>/dev/null && grep -q "ડેશબોર્ડ\|નમસ્તે" "$dump"; then
        log "Dashboard marker found in the UI dump (round $round)."
        CURRENT_URL="$saved_url"
        return 0
      fi
      log "WARN: dashboard URL OK but no dashboard marker in the dump (round $round)."
    else
      log "WARN: dashboard URL not verified yet (round $round)."
    fi
    sleep 10
    round=$((round + 1))
  done
  CURRENT_URL="$saved_url"
  return 1
}

# login_or_die: log in to the app with LOGIN_EMAIL / LOGIN_PASSWORD
# (both must be set; the caller checks). 0 = the logged-in dashboard
# is verified. 1 = login failed after bounded retries — the caller
# exits 1 with a diagnostic frame; a logged-out screen is never
# captured as if it were logged in. Credential values are NEVER
# logged; only the presence/absence of the form and the verification
# outcome appear in the log.
login_or_die() {
  local attempt=1 dump="$OUT_DIR/.login-dump.xml" found="" tap=""
  local id_x="" id_y="" pw_x="" pw_y="" sub_x="" sub_y="" tried_home_button=0 proceed=1
  log "Login mode: enabled (credentials provided via environment)."
  log "Navigating to the login page..."
  adb shell am start -a android.intent.action.VIEW -d "$LOGIN_URL" com.android.chrome || true
  wait_for_chrome_foreground
  sleep 15
  # The promo card can cover the form — dismiss it before touching it.
  dismiss_notifications_card || log "WARN: promo dismiss returned non-zero before login; continuing (the form check decides)."
  while [ "$attempt" -le 3 ]; do
    if ! fetch_ui_dump "$dump" 2>"$OUT_DIR/.login-dump.err"; then
      cat "$OUT_DIR/.login-dump.err" 2>/dev/null || true
      log "WARN: could not obtain a UI dump for the login form (attempt $attempt); retrying."
      sleep 5
      attempt=$((attempt + 1))
      continue
    fi
    cat "$OUT_DIR/.login-dump.err" 2>/dev/null || true
    found="$(find_login_fields "$dump" || true)"
    case "$found" in
      FIELDS*)
        set -- $found
        id_x="$2"; id_y="$3"; pw_x="$4"; pw_y="$5"; sub_x="$6"; sub_y="$7"
        log "Login form found (attempt $attempt); typing credentials."
        adb shell input tap "$id_x" "$id_y" || true
        sleep 2
        adb_type "$LOGIN_EMAIL"
        sleep 2
        # Verify the email landed in the field (re-dump; the value
        # itself is never logged). One re-type if it did not.
        if fetch_ui_dump "$dump" 2>/dev/null && grep -qF "$LOGIN_EMAIL" "$dump"; then
          log "Identifier field shows the entered email."
        else
          log "WARN: identifier field does not show the email after typing; re-tapping and re-typing once."
          adb shell input tap "$id_x" "$id_y" || true
          sleep 2
          adb_type "$LOGIN_EMAIL"
          sleep 2
        fi
        # The Gboard clipboard panel can pop up while typing and
        # cover the lower half of the screen (run #8): hide the
        # keyboard/panel, then re-find the form — the layout shifts
        # when the keyboard hides, so the old coordinates may be
        # stale.
        dismiss_keyboard_panel || log "WARN: keyboard/panel may still be showing; the focus check decides."
        refresh_login_fields || true
        proceed=1
        if ! tap_password_with_focus_check "$dump"; then
          log "WARN: password field never gained focus (attempt $attempt); skipping submit."
          proceed=0
        fi
        if [ "$proceed" -eq 1 ]; then
          adb_type "$LOGIN_PASSWORD"
          sleep 2
          # The identifier must be exactly the login email before
          # submit — if the password rode into it, this catches it.
          if ! guard_identifier_exact "$dump"; then
            log "WARN: identifier guard failed (attempt $attempt); skipping submit."
            proceed=0
          fi
        fi
        if [ "$proceed" -eq 1 ]; then
          # One last panel dismissal before submit (the panel can
          # cover the submit button too); refresh coordinates
          # after it.
          dismiss_keyboard_panel || true
          refresh_login_fields || true
          log "Submitting the login form."
          adb shell input tap "$sub_x" "$sub_y" || true
          sleep 15
          dismiss_save_password_prompt
          dismiss_notifications_card || true
          if verify_logged_in_dashboard; then
            log "Login verified: dashboard loaded."
            return 0
          fi
          log "WARN: dashboard not verified after submit (attempt $attempt)."
        fi
        ;;
      NOFIELDS*)
        log "Login form not found in the dump ($found; attempt $attempt)."
        if [ "$tried_home_button" -eq 0 ]; then
          tried_home_button=1
          log "Falling back to the homepage 'લોગિન કરો' button."
          adb shell am start -a android.intent.action.VIEW -d "$URL" com.android.chrome || true
          wait_for_chrome_foreground
          sleep 10
          if fetch_ui_dump "$dump" 2>/dev/null; then
            tap="$(find_text_button "$dump" "લોગિન કરો" || true)"
            case "$tap" in
              TAP*)
                set -- $tap
                log "Tapping 'લોગિન કરો' at $2,$3."
                adb shell input tap "$2" "$3" || true
                sleep 10
                ;;
              *) log "WARN: 'લોગિન કરો' button not found on the homepage." ;;
            esac
          fi
        fi
        ;;
      *)
        log "WARN: login form dump unparsable (attempt $attempt; result: '$found'); retrying."
        ;;
    esac
    sleep 5
    attempt=$((attempt + 1))
  done
  log "Capturing a diagnostic frame of the failed login screen..."
  adb exec-out screencap -p > "$OUT_DIR/00-last-failed-frame-login.png" || true
  if [ ! -s "$OUT_DIR/00-last-failed-frame-login.png" ]; then
    rm -f "$OUT_DIR/00-last-failed-frame-login.png" 2>/dev/null || true
  else
    log "Diagnostic saved: 00-last-failed-frame-login.png"
  fi
  log "ERROR: login failed; refusing to capture logged-out screens as if logged in."
  return 1
}

# navigate_to <url>: open the URL in Chrome (VIEW intent), wait for
# the foreground, and settle (SPA navigations are fast; 20s).
navigate_to() {
  local target="$1"
  CURRENT_URL="$target"
  log "Navigating to $target ..."
  adb shell am start -a android.intent.action.VIEW -d "$target" com.android.chrome || true
  wait_for_chrome_foreground
  sleep 20
}

# open_voice_assistant: tap the floating voice-assistant button
# (aria-label "Voice Assistant") and verify the panel opened (its
# Gujarati title "વૉઇસ સહાયક" or tap hint in the dump). The assistant
# has no route — this tap is the only way in. 0 = panel open.
open_voice_assistant() {
  local dump="$OUT_DIR/.voice-dump.xml" tap=""
  if ! fetch_ui_dump "$dump" 2>"$OUT_DIR/.voice-dump.err"; then
    cat "$OUT_DIR/.voice-dump.err" 2>/dev/null || true
    log "ERROR: could not obtain a UI dump to find the voice assistant button."
    return 1
  fi
  cat "$OUT_DIR/.voice-dump.err" 2>/dev/null || true
  tap="$(find_text_button "$dump" "Voice Assistant" || true)"
  case "$tap" in
    TAP*)
      set -- $tap
      log "Tapping the floating voice assistant button at $2,$3."
      adb shell input tap "$2" "$3" || true
      sleep 10
      if fetch_ui_dump "$dump" 2>/dev/null && grep -q "વૉઇસ સહાયક\|બોલવા માટે ટેપ કરો" "$dump"; then
        log "Voice assistant panel is open."
        return 0
      fi
      log "ERROR: voice assistant panel did not open (no panel title in the dump)."
      return 1
      ;;
    *)
      log "ERROR: voice assistant button not found (result: '$tap')."
      return 1
      ;;
  esac
}

# capture_screen <label> <target> <outfile>: navigate to one screen
# and capture one verified settled frame. target is a full URL, or
# "tap:voice" (dashboard + floating-button tap). The promo card is
# dismissed before the shot; the shot itself reuses the settled
# gates (foreground + ANR + URL + pixel). 0 = frame captured.
capture_screen() {
  local label="$1" target="$2" outfile="$3"
  if [ "$target" = "tap:voice" ]; then
    navigate_to "$DASHBOARD_URL"
    if ! open_voice_assistant; then
      log "ERROR: could not open the voice assistant for screen '$label'."
      return 1
    fi
    CURRENT_URL="$DASHBOARD_URL"
  else
    navigate_to "$target"
  fi
  dismiss_promo_or_die "promo-$label"
  capture_verified_frame "$OUT_DIR/$outfile" "$label" 1
}

# capture_screens: one verified settled frame per SCREENS line
# ("label|target", # comments and blank lines skipped). A bad line
# or a failed screen fails the run — a missing screen must never
# pass silently as a shorter set.
capture_screens() {
  local i=0 line="" label="" target="" outfile=""
  # GitHub's workflow_dispatch form is a single-line input: a pasted
  # multi-line list arrives space-joined, so ';' is also accepted as
  # a line separator (no label or URL here contains ';'). Newlines
  # keep working, so API dispatches are unaffected.
  local screens_normalized
  screens_normalized="$(printf '%s' "$SCREENS" | tr ';' '\n')"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue;; esac
    label="${line%%|*}"
    target="${line#*|}"
    if [ -z "$label" ] || [ -z "$target" ] || [ "$label" = "$line" ]; then
      log "ERROR: bad SCREENS line (want 'label|target'): '$line'"
      return 1
    fi
    # A target with a space is never a valid URL or tap:voice — it
    # means a pasted multi-line list was collapsed to spaces by a
    # single-line form. Fail fast here, not after boot + login.
    case "$target" in
      *\ * )
        log "ERROR: bad SCREENS target (contains a space — use ';' between screens, not spaces): '$target'"
        return 1
        ;;
    esac
    i=$((i + 1))
    outfile="$(printf '%02d-%s.png' "$i" "$label")"
    log "Screen $i ($label): target $target"
    if ! capture_screen "$label" "$target" "$outfile"; then
      return 1
    fi
  done <<<"$screens_normalized"
  if [ "$i" -lt 1 ]; then
    log "ERROR: SCREENS was set but contained no usable lines."
    return 1
  fi
  log "Captured $i screen(s)."
  return 0
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

# Chrome's notifications promo card ("Chrome notifications make
# things easier", "No thanks" / "Continue") is not suppressed by
# the --disable-fre flags on the google_apis API 34 image: run
# 41847287396 went green with the card covering the middle of the
# page. Dismiss it before any shot is accepted — a card over the
# page must never reach a listing frame.
# dismiss_promo_or_die [label]: dismiss the notifications promo card;
# on failure capture a diagnostic frame (named for the label) and exit
# 1 — an obscured frame must never be accepted.
# (Defined here with the other helpers, not in the main flow below:
# capture_screen calls it, and a definition sitting after the first
# main-flow command would be easy to reorder past its first use.)
dismiss_promo_or_die() {
  local tag="${1:-promo-card}"
  if dismiss_notifications_card; then
    return 0
  fi
  log "Capturing a diagnostic frame of the stuck screen..."
  adb exec-out screencap -p > "$OUT_DIR/00-last-failed-frame-$tag.png" || true
  if [ ! -s "$OUT_DIR/00-last-failed-frame-$tag.png" ]; then
    rm -f "$OUT_DIR/00-last-failed-frame-$tag.png" 2>/dev/null || true
    log "WARN: diagnostic screencap was empty; no diagnostic frame saved."
  else
    log "Diagnostic saved: 00-last-failed-frame-$tag.png"
  fi
  log "ERROR: notifications promo card could not be dismissed; refusing to capture obscured frames."
  exit 1
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

dismiss_promo_or_die
# The card can appear AFTER the first check (run #6's failed frame
# still showed it) — re-run the dismiss immediately before the
# first shot so a late-appearing card is caught, not captured.
dismiss_promo_or_die

# Login phase (only when BOTH credentials are set — see login_or_die).
if [ -n "$LOGIN_EMAIL" ] && [ -n "$LOGIN_PASSWORD" ]; then
  login_or_die || exit 1
elif [ -n "$LOGIN_EMAIL" ] || [ -n "$LOGIN_PASSWORD" ]; then
  log "WARN: only one of LOGIN_EMAIL / LOGIN_PASSWORD is set; skipping login (both are required)."
fi

if [ -n "$SCREENS" ]; then
  # Multi-screen mode: one verified settled frame per SCREENS line.
  capture_screens || exit 1
else
  capture_verified_frame "$OUT_DIR/01-settled.png" "settled" 1

  do_swipe

  capture_verified_frame "$OUT_DIR/02-scrolled.png" "scrolled" 0
fi

log "Screenshots (verified frames):"
ls -la "$OUT_DIR"
