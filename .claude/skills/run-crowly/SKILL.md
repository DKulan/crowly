---
name: run-crowly
description: Build, launch, screenshot, and drive the Crowly iOS demo-mode app in the iOS Simulator. Use when asked to run, start, build, test, or screenshot Crowly, or to confirm an inbox/digest-detail/widget-deeplink change works in the real running app (not just tests).
---

# Run Crowly (iOS demo-mode app)

Crowly is a native Swift/SwiftUI **iOS 26** inbox/reader. M1 is **demo mode** —
fully client-side from `Shared/Demo/` fixtures; no companion, relay, App Group,
or signing. It runs simulator-only and unsigned.

The simulator can't be clicked headlessly, so the harness drives it through
`xcrun simctl` (install / launch / `openurl` / screenshot). The driver is
**`.claude/skills/run-crowly/driver.sh`** — that's the agent path; use it
first. **All paths below are relative to the repo root** (`<unit>/`).

## Prerequisites

- macOS with **Xcode 26.1.1** (verified) and the **iOS 26.1 simulator runtime**.
- **XcodeGen** (`brew install xcodegen` — verified 2.45.4). `project.yml` is the
  source of truth; `Crowly.xcodeproj` is generated and gitignored.
- An `iPhone 17 Pro` (iOS 26) simulator — present by default. Override with
  `SIM=...` if you use a different device name.

No `apt-get` / Linux setup: this is a macOS-native build, not the
container-Linux case.

## Run (agent path)

From the repo root:

```bash
# Generate project, build, boot the sim, install, launch, screenshot the inbox.
.claude/skills/run-crowly/driver.sh up
```

Then **open and look at** `/tmp/crowly-shots/inbox.png` — confirm the sectioned
digest list renders (Demo Mode banner, "Weather — severe thunderstorm watch",
"AI news — Monday roundup", etc.).

```bash
# Drive the widget's deeplink contract (crowly://digest/<id>) and screenshot
# the digest detail. This is how you verify the widget's only interactive
# surface without a headless widget render.
.claude/skills/run-crowly/driver.sh deeplink
```

Look at `/tmp/crowly-shots/detail.png` — confirm header → BOTTOM LINE card →
summary → sections, opened from the deeplink.

Other subcommands:

```bash
.claude/skills/run-crowly/driver.sh build        # xcodegen generate + xcodebuild build only
.claude/skills/run-crowly/driver.sh shot myname   # screenshot current sim screen → /tmp/crowly-shots/myname.png
.claude/skills/run-crowly/driver.sh test          # run the Swift Testing suite (26 tests)
```

Env overrides: `SIM` (device name), `SHOT_DIR` (screenshot dir, default
`/tmp/crowly-shots`), `DIGEST` (digest id for `deeplink`, default
`dgst_2026-06-29_ai-news`). Valid demo digest ids live in
`Shared/Demo/DemoFixtures.swift` (e.g. `dgst_2026-06-29_weather`,
`dgst_2026-06-28_community`).

## Build (raw commands, what the driver runs)

```bash
xcodegen generate
xcodebuild -project Crowly.xcodeproj -scheme Crowly \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build build
```

The app bundle lands at
`build/Build/Products/Debug-iphonesimulator/Crowly.app`; bundle id is
`com.crowly.Crowly`.

## Test

```bash
xcodebuild -project Crowly.xcodeproj -scheme Crowly \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build test
```

26 Swift Testing tests pass (~5s). Covers the digest store, search, deeplink
parsing, and fixture sanity — a sanity check, not a substitute for looking at
the screenshots.

## Gotchas

- **The widget can't be verified headlessly.** A simulator can't add a
  home-screen widget without manual interaction. What you *can* verify is the
  widget's only interactive contract — the `crowly://digest/<id>` deeplink —
  via `driver.sh deeplink`. The widget render itself still needs a manual eye.
- **Launch ≠ rendered.** `simctl launch` returns a PID immediately; SwiftUI
  needs a beat. The driver sleeps 4s before the inbox shot, 3s before the
  detail shot. If a screenshot is blank, the sim was mid-render — re-run `shot`.
- **Deeplink only pushes if the id exists.** `InboxView` ignores a
  `crowly://digest/<id>` whose id isn't in the store, so a typo'd `DIGEST`
  silently leaves you on the inbox (not an error). Use an id from
  `DemoFixtures.swift`.
- **`Crowly.xcodeproj` is gitignored and generated.** Always `xcodegen
  generate` after adding/moving/renaming source files — the driver does this
  on `build`/`up`/`test`. Editing the `.xcodeproj` directly is pointless; edit
  `project.yml`.
- **Unsigned, simulator-only by design.** `CODE_SIGNING_ALLOWED: NO` in
  `project.yml`. Don't try to run on a physical device or expect signing.
- **Liquid Glass / iOS 26 APIs are used freely** (e.g. `.buttonStyle(.glass)`,
  `.searchToolbarBehavior(.minimize)`). Building against an older simulator
  runtime will fail to compile — keep the iOS 26.1 runtime.

## Troubleshooting

- **`xcodegen: command not found`** → `brew install xcodegen`.
- **`Unable to find a device matching ... iPhone 17 Pro`** → list devices with
  `xcrun simctl list devices available`, pick an iOS 26 device, and pass it as
  `SIM='iPhone 17'` (etc.) to the driver.
- **`build did not produce .../Crowly.app`** → the `tail -3` hid the real
  error; re-run the raw `xcodebuild ... build` (no pipe) to see the full
  compiler diagnostics.
- **Blank/old screenshot** → the previous app launch is still showing or the
  sim is mid-boot. Re-run `driver.sh shot inbox`, or `driver.sh up` to
  reinstall+relaunch.
