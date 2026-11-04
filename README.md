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
- **Verified frames, not false greens.** Every screenshot is pixel-checked
  before it is accepted. A black frame or a system error dialog can never
  be uploaded as success — if no real frame can be captured, the run goes
  **red** and saves a diagnostic frame instead. A green run here means
  real screenshots.
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

Everything else is fixed at the proven values on purpose: Intel runner,
`google_apis` image (the one that ships Chrome), `x86_64`, 4096 MB RAM,
4 cores, cold boot. Changing them is how the failure modes below happen.

## How it works

1. The workflow runs on **`macos-15-intel`**, a standard GitHub-hosted
   runner. ARM macOS runners (`macos-15`, `macos-latest`) **cannot** run
   the Android emulator at all — nested virtualization is unavailable
   there and Hypervisor.Framework returns `HV_UNSUPPORTED`
   (ReactiveCircus/android-emulator-runner#350). Intel Mac runners are
   bare-metal, so hardware acceleration works.
2. The action (`reactivecircus/android-emulator-runner`, pinned to
   v2.38.0) downloads the SDK, emulator, and system image, and cold-boots
   the emulator with `-no-snapshot` — every run starts from a known-good
   state. No snapshot caching: a snapshot saved from an unsettled boot
   was proven to replay a black/ANR state on every later run.
3. `scripts/capture.sh` waits for a **settled** boot (`sys.boot_completed`
   → boot animation stopped → package manager answering → 30 s System UI
   settle), keeps the display awake, waits for the launcher and then for
   Chrome to actually be the foreground app, skips Chrome's first-run
   experience with the documented `chrome-command-line` flags, opens the
   URL, and settles 45 s before shooting.
4. Before every shot, an ANR ("isn't responding") dialog is detected via
   `uiautomator dump` and dismissed by tapping its **Wait** button, located
   by the stable resource-id `android:id/aerr_wait` (locale-proof).
5. Every frame is pixel-checked by `scripts/frame_check.py` — a
   stdlib-only PNG decoder (`zlib` + `struct`, nothing to install on the
   runner). A frame passes when at least 5% of sampled pixels are not
   near-black; a real Chrome page scores above 0.90, a black frame scores
   0.0000. Each shot retries up to 5 times, 15 s apart. Total failure
   exits 1 (red run) and saves `00-last-failed-frame-<label>.png`.

## Cost and time

- **Public repo: $0.** Standard GitHub-hosted runners are free and
  unlimited on public repositories, `macos-15-intel` included.
- **Private repo:** macOS minutes consume the monthly allowance at 10x
  wall-clock time. GitHub accounts default to a **$0 spending limit**,
  which stops paid usage instead of billing.
- **Time: ~10–25 minutes per run.** Mostly SDK/image download (~1 GB)
  plus one cold boot. The settle waits and frame retries add a few
  minutes on a struggling run. The 45-minute job timeout bounds it.

## Troubleshooting

If a run fails, read the failed step's log first. The capture log shows
per-attempt frame-check values (`nonblack_fraction=...`) and whether an
ANR dialog was found and dismissed — that tells you whether the
emulator, the system, or the page was at fault. In order, one change
per run:

1. **Re-run once.** Cold-boot time varies; a slow boot is the most
   common one-off failure. Check the `df -h` output first — boot
   timeouts are very frequently low disk space in disguise.
2. **`-gpu swiftshader`** in place of `swiftshader_indirect` (Android
   troubleshooting guidance lists a software GPU mode for
   graphics-compatibility symptoms).
3. **API 33** instead of 34.
4. **Ubuntu runner with KVM** (the action README notes Ubuntu + KVM is
   2–3x faster and avoids Hypervisor.Framework entirely; it needs the
   KVM udev step from the action README).

Never switch the runner to any ARM macOS label — that configuration is
documented as unable to run the emulator. Never reintroduce snapshot
caching without a generating step that waits for a fully settled boot
first.

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
- **Run 3:** the fixed config, verified by reading the screenshots.

If you improve it, keep the rule that made it trustworthy: **a run that
cannot prove a real frame must go red, never green.**

## License

MIT — see [LICENSE](LICENSE). Use it for anything, including commercial
work. A star is appreciated but never required.
