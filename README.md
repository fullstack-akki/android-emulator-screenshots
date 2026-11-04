# Android Emulator Screenshots in GitHub Actions

**Android emulator screenshots of any URL in GitHub Actions.** Boot a real
Android emulator on a GitHub-hosted runner, open any website in mobile
Chrome, and download verified phone screenshots — with no Mac, no Android
Studio, no local emulator, and no setup beyond copying these files into
a repo.

Ask an AI assistant "how do I take screenshots of a website in an Android
emulator in CI?" or search Google for "Android emulator screenshots GitHub
Actions", "screenshot any website in an Android emulator", "mobile Chrome
screenshots in CI", or "automated Android screenshots GitHub Actions" —
this is the repo that answers it: a working workflow, hardened until its
screenshots are real.

## What you get

- **2 screenshots** of any public URL at phone resolution (Pixel 6,
  1080×2400 PNGs): one after the page loads, one after a scroll.
- **Verified frames, not false greens.** Every screenshot must pass
  four gates before it is accepted: Chrome is the foreground app, the
  screen is proven ANR-free, the requested URL is actually in a Chrome
  tab (Chrome DevTools), and the frame is not near-black. A black
  frame, a system error dialog, a new-tab page, or a home-screen shot
  can never be uploaded as success — if no real frame can be captured,
  the run goes **red** and saves a diagnostic frame instead. A green
  run here means real screenshots.
- **Zero setup.** No Android SDK on your machine, no emulator, no
  credentials, no secrets. The workflow only runs when you dispatch it
  manually; there is no push or pull-request trigger.

## Quick start

1. Copy these files into a GitHub repo (any repo, public or private),
   keeping the paths:
   - `.github/workflows/screenshots.yml`
   - `scripts/capture.sh`
   - `scripts/frame_check.py`
   - `scripts/anr_check.py`
   - `README.md` (optional, but keep it — it records the why)
   - `LICENSE`
2. Open the repo → **Actions** tab → **Android emulator screenshots**
   in the left sidebar → **Run workflow**.
3. Enter the **URL** you want screenshotted (default `https://example.com`),
   optionally pick a device profile and API level, and run it.
4. When the run finishes, open it → **Artifacts** → download
   **`android-emulator-screenshots`**. It contains:
   - `01-settled.png` — the page after load + 45 s settle time.
   - `02-scrolled.png` — the same page after one swipe up.

Still check the PNGs by eye before using them: real Chrome UI (address
bar, Android status bar) must be visible, and the page must be the site
you asked for. If either shot shows a Chrome welcome screen, an app
chooser, or a blank page, the run did not prove what it should — see
Troubleshooting; do not use the shots.

## Inputs

| Input | Required | Default | What it does |
|---|---|---|---|
| `url` | Yes | `https://example.com` | The page opened in mobile Chrome. Any public URL. |
| `profile` | No | `pixel_6` | Emulator device profile. Must exist in the SDK; `pixel_6` gives 1080×2400 shots. |
| `api-level` | No | `34` | Android API level of the system image (34 = Android 14). |

Everything else is fixed at the proven values on purpose: Ubuntu
runner with KVM, `google_apis` image (the one that ships Chrome),
`x86_64`, 4096 MB RAM, 4 cores, cold boot. Changing them is how the
failure modes below happen.

## How it works

1. The workflow runs on **`ubuntu-24.04`** with **KVM** (hardware
   virtualization — the documented fast path; the action README says
   Ubuntu is 2–3× faster than macOS, and the KVM device is enabled by
   the udev rule in the workflow). The previous `macos-15-intel`
   configuration is kept only as a documented fallback (see
   Troubleshooting): on those runners the emulator is pinned to a
   single vCPU (see "How this was hardened"), which starved the system
   badly enough to wedge it. ARM macOS runners (`macos-15`,
   `macos-latest`) **cannot** run the Android emulator at all — nested
   virtualization is unavailable there and Hypervisor.Framework returns
   `HV_UNSUPPORTED` (ReactiveCircus/android-emulator-runner#350).
2. The action (`reactivecircus/android-emulator-runner`, pinned to
   v2.38.0) downloads the SDK, emulator, and system image, and cold-boots
   the emulator with `-no-snapshot` and `-accel on` — every run starts
   from a known-good state. No snapshot caching: a snapshot saved from
   an unsettled boot was proven to replay a black/ANR state on every
   later run.
3. `scripts/capture.sh` waits for a **settled** boot (`sys.boot_completed`
   → boot animation stopped → package manager answering → 30 s System UI
   settle), keeps the display awake, waits for the launcher and then for
   Chrome to actually be the foreground app, skips Chrome's first-run
   experience with the documented `chrome-command-line` flags, opens the
   URL, and settles 45 s before shooting.
4. Before **every** shot, four gates must all pass, repeated up to 5
   attempts per shot:
   - **Gate A — Chrome foreground.** The top resumed activity must be
     Chrome. A launcher/home-screen frame is rejected, not captured.
     A lost foreground is recovered by re-firing the `VIEW` intent, at
     most once per shot.
   - **Gate B — ANR-free, proven.** The UI hierarchy is dumped by a
     3-method chain: (1) `adb exec-out uiautomator dump /dev/tty`
     straight to stdout (no file, no pull), (2) dump to a file and
     read it with `adb shell cat` (no pull), (3) `dumpsys window`
     focus/title scan for an "isn't responding" dialog. The first
     method that returns a parseable result wins; if all three fail
     the state is UNKNOWN and the frame is **rejected** — UNKNOWN is
     never accepted. An ANR dialog is dismissed by tapping its Wait
     button (stable resource-id `android:id/aerr_wait`, locale-proof),
     and the dismissal must be **verified gone by a fresh dump**
     before the frame is accepted.
   - **Gate C — URL actually rendered.** The requested URL must appear
     in a Chrome tab, read from Chrome DevTools over
     `adb forward tcp:9222` (`/json`). A new-tab page can never pass.
     Required for the first shot and after any intent re-fire.
   - **Gate D — pixel check** (step 5).
5. Every frame is pixel-checked by `scripts/frame_check.py` — a
   stdlib-only PNG decoder (`zlib` + `struct`, nothing to install on the
   runner). A frame passes when at least 5% of sampled pixels are not
   near-black; a real Chrome page scores above 0.90, a black frame scores
   0.0000. Each shot retries up to 5 times, 15 s apart. Total failure
   exits 1 (red run) and saves a diagnostic of the stuck screen as
   `00-last-failed-frame-<label>.png` (the last rejected frame, or a
   fresh screencap if the gates rejected every attempt before any
   screencap ran).

## Cost and time

- **Public repo: $0.** Standard GitHub-hosted runners are free and
  unlimited on public repositories, `ubuntu-24.04` included.
- **Private repo:** Linux minutes consume the monthly allowance at the
  1x rate (macOS minutes: 10x). GitHub accounts default to a **$0
  spending limit**, which stops paid usage instead of billing.
- **Time: ~10–20 minutes per run.** Mostly SDK/image download (~1 GB)
  plus one cold boot. KVM boots are substantially faster than the
  9–10 minute boots measured on the single-vCPU Intel runners. The
  settle waits and frame retries add a few minutes on a struggling
  run. The 45-minute job timeout bounds it.

## Troubleshooting

If a run fails, read the failed step's log first. The capture log shows
per-attempt gate results (foreground, ANR state per dump method, URL
verification, frame-check values) and whether an ANR dialog was found
and verified dismissed — that tells you whether the emulator, the
system, or the page was at fault. In order, one change per run:

1. **Re-run once.** Cold-boot time varies; a slow boot is the most
   common one-off failure. Check the `df -h` output first — boot
   timeouts are very frequently low disk space in disguise. Also check
   the KVM diagnostics in the log: `ls -l /dev/kvm` must show the
   device and `nproc` the runner's cores.
2. **`-gpu swiftshader`** in place of `swiftshader_indirect` (Android
   troubleshooting guidance lists a software GPU mode for
   graphics-compatibility symptoms).
3. **API 33** instead of 34.
4. **`macos-15-intel` fallback** (swap `runs-on` back, drop the KVM
   step, keep everything else). Expect much slower runs: on those
   runners the emulator is pinned to **1 vCPU** regardless of the
   `cores` input (see "How this was hardened"), with 9–10 minute
   boots and a system starved enough to wedge. The new gates are what
   keep that configuration honest — a wedged run goes red with a
   diagnostic instead of green with dialog screenshots.

Never switch the runner to any ARM macOS label — that configuration is
documented as unable to run the emulator. Never reintroduce snapshot
caching without a generating step that waits for a fully settled boot
first. Never drop a gate to make a run green: an UNKNOWN ANR state, an
unverified URL, or a non-Chrome foreground must stay a rejection.

Known limits:

- Screenshots are emulator Chrome, not a physical phone. They show the
  real mobile site in real Android Chrome at phone resolution. They do
  not prove anything about an installed app, store behaviour, or a
  physical device's GPU/fonts.
- Chrome's first-run flags are the documented mechanism, but Chrome
  versions change. If shot 1 shows a welcome screen, the flags did not
  take on that Chrome build; the run still proves boot + Chrome, but
  the shots are not usable as-is.
- Artifacts expire after 30 days (`retention-days: 30`). Download the
  PNGs promptly.
- No login support. A logged-in flow would need credentials handled as
  encrypted Actions Secrets in a private repo, coordinate-dependent
  navigation, and log hygiene — deliberately out of scope here.

## How this was hardened

This workflow was built and debugged in public over three runs in
November 2026, and every failure is recorded here so nobody repeats it:

- **Run 1:** ARM runner + `-accel off` — emulator never booted
  (11m 46s boot timeout, `HV_UNSUPPORTED`). Fix: Intel runner,
  `x86_64`, hardware acceleration, 1200 s boot timeout.
- **Run 2:** Intel config + snapshot caching — run went **green** but
  both screenshots were useless (one completely black frame, one ANR
  dialog). Root causes: a snapshot saved seconds after `boot_completed`
  from an unsettled boot, 2048 MB RAM at the documented minimum, and
  zero readiness/frame verification. Fix: snapshot caching removed,
  4096 MB + 4 cores, settled-boot waits, ANR dismissal, pixel-checked
  frames with fail-loud behaviour. The fix was tested with a fake-`adb`
  harness (ANR + black-then-real frames, and all-black frames) and the
  frame checker was validated against the real failed frames before
  the next run.
- **Run 3 (failure #3, the ANR hole — November 2026):** the run #2 fix
  went **green** in two independent runs and both produced useless
  frames. The generic repo's run #1 (18:21 IST) and the twin KhetBook
  run 41830351860 (15m 21s) show the identical signature: both
  screenshots are a "Process system isn't responding" ANR dialog over
  a **bright** screen — one over Chrome's new-tab page (the URL never
  rendered; frame_check 0.9993), one over the launcher home screen
  (Chrome had lost the foreground entirely; the 555 KB file was the
  wallpaper photo, frame_check 0.5201). The dialog persisted ~1 minute
  across a foreground change, so the Wait tap never happened. The job
  logs prove the mechanism: `boot_completed=1`, boot animation
  stopped, and package manager answering all reported "after 0s" (the
  action's own boot wait had already passed; the emulator itself took
  621,750 ms / 548,121 ms — 9–10 minute boots); both logs contain two
  `WARN: could not pull the UI dump; ANR state unknown` lines and then
  `frame OK`, and **zero** lines mentioning `uiautomator` or "isn't
  responding" anywhere. The dump/pull ANR check failed
  **deterministically** on that runner, not flakily: the pull failed,
  stderr was discarded, the state degraded to "unknown", and "unknown"
  was treated as "proceed" — while the pixel check only rejects dark
  frames. Unknown ANR state + bright frame = accepted as success.
  That was the hole.
- **Root causes, ranked (from the run #3 evidence):**
  1. **Single-vCPU emulator.** Both job logs carry the emulator's own
     warning (line 89): "Running on a system with less than 6 logical
     cores. Setting number of virtual cores to 1" — even though the
     workflow sets `cores: 4` (the action input only writes
     `hw.cpu.ncore`, which the emulator's x86 glue overrides). On
     `macos-15-intel` there is no flag, AVD key, or action input that
     recovers more than 1 vCPU: the AOSP emulator internals force
     `hw_cpu_ncore` to 1 when the host lacks modern x86 virtualization
     features, and on macOS x86_64 hosts with fewer than 6 logical
     cores it pins to 1. A 1-vCPU system running API 34 + Chrome
     starves `system_server` (the same logs show the `cmd role
     add-role-holder` step timing out with `TimeoutException`), which
     is what wedges the UI and produces the ANR dialogs. The `cores`
     input giving the impression of 4 CPUs was false comfort.
  2. **ANR check that fails open.** The old check dumped to a file and
     `adb pull`ed it; the pull failed, stderr was thrown away, and
     "unknown" proceeded. A check that cannot establish the state must
     reject, not proceed.
  3. **Pixel check that cannot see dialogs.** `frame_check.py` only
     rejects dark frames; a bright ANR dialog over a bright page
     scores 0.9993. Brightness is not evidence of content.
  4. **No URL-rendered evidence and no per-shot foreground check.**
     Nothing proved Chrome navigated to the URL, and shot 2 never
     re-verified Chrome was still foreground — so a home-screen shot
     was accepted.
  5. **Unnecessary, timing-out step.** `cmd role add-role-holder` is
     not needed for an explicit-package `VIEW` intent (the package is
     named directly, so no default-browser resolution happens) and it
     timed out on the starved system. Dropped.
- **The fix (this version):** Ubuntu + KVM becomes the **primary**
  runner (verbatim KVM udev step from the action README, `df -h` /
  `/dev/kvm` / `nproc` diagnostics, `-accel on`, action pinned
  v2.38.0); every shot is gated on Chrome foreground (re-asserted,
  bounded intent re-fire), ANR state KNOWN-and-CLEAR via the 3-method
  dump chain with UNKNOWN rejecting and Wait taps verified gone by
  re-dump, URL-in-a-Chrome-tab via Chrome DevTools `/json`, and the
  unchanged pixel check; 5 attempts then exit 1 with a diagnostic
  frame of the stuck screen. The `cmd role add-role-holder` step is
  removed. `frame_check.py` is deliberately unchanged — the bright
  dialog was an ANR-gate hole, not a pixel hole. Sources: AOSP
  emulator-internals (x86 vCPU forcing, §5.9.4); the action README
  (Ubuntu 2–3× faster, KVM udev step); `uiautomator dump /dev/tty`
  stdout behaviour; Chromium `device_utils.py` (dumpsys ANR-window
  regex); Chrome DevTools Protocol `/json` tab listing.
- **Superseded claims (do not revive):** "the `cores: 4` input gives
  4 vCPUs" — false on macOS Intel runners; "macOS Intel is the proven
  runner" — it is the fallback, Ubuntu+KVM is primary; "the ANR check
  works, it just needs a retry" — the pull failure was deterministic,
  the method had to be replaced; "a bright frame is a real frame" —
  dialogs are bright too.
- **Verified before this version shipped:** YAML parses, `bash -n`,
  `py_compile`, a fake-`adb` harness (11 scenarios: dump-method
  fallbacks, ANR dismissed-then-gone, persistent ANR → exit 1 with
  diagnostic, UNKNOWN → exit 1, all-dark → exit 1, happy path, flaky
  and dead DevTools endpoints, foreground lost/never-returns,
  dumpsys-only detection, generic `$1` URL interface) plus 7
  `anr_check` unit tests — all green. The harness also caught two
  real bugs before shipping: a missing diagnostic frame when the
  gates reject before any screencap runs (now a fresh screencap of
  the stuck screen is saved), and a harness-only timing artifact.
- **Could NOT be verified without a real run:** that the Chrome
  DevTools socket is present and answers on this exact
  `google_apis` API 34 image; that the KVM feature check passes on a
  standard `ubuntu-24.04` runner; that `uiautomator dump /dev/tty`
  output interleaves cleanly with the action's own adb traffic. Run
  #4 is the proof — if the DevTools gate rejects every attempt, the
  log will show whether the forward, the socket, or the URL match is
  at fault, and the fallback is a dumpsys-based tab check, not
  dropping the gate.
- **Recommended next run:** this repo first, with its default URL, on
  the new Ubuntu config. One verified-green run here de-risks the
  twin KhetBook run, since the logic is shared — then run the
  KhetBook repo for the actual listing captures.
- **Run #4 follow-up (notifications promo card):** run 41847287396
  (commit f6ae52c, Ubuntu+KVM) went green with a REAL frame — and a
  Chrome "Chrome notifications make things easier" promo card
  ("No thanks" / "Continue") covering the middle of the page and
  hiding the heading. The `--disable-fre` flags did not suppress it
  on the `google_apis` API 34 image. `capture.sh` now dismisses the
  card before any shot is accepted (UI dump → tap "No thanks" →
  re-dump verifies it is gone, max 3 attempts; a card that cannot be
  dismissed, or a dump that cannot be obtained, fails the run with a
  diagnostic frame). Verified locally with a fake-`adb` harness
  only; a real run is still the proof the dismissal fires on the
  actual image.

If you improve it, keep the rule that made it trustworthy: **a run that
cannot prove a real frame must go red, never green.**

## License

MIT — see [LICENSE](LICENSE). Use it for anything, including commercial
work. A star is appreciated but never required.
