#!/usr/bin/env bash
# driver.sh — build, launch, and drive the Crowly iOS demo-mode app in the
# iOS Simulator, and screenshot it. This is the agent-facing harness for the
# `run-crowly` skill: the simulator can't be clicked headlessly, so we drive
# it through `xcrun simctl` (install / launch / openurl / screenshot).
#
# Crowly M1 is demo mode — fully client-side from Shared/Demo/ fixtures, no
# companion / relay / signing — so a clean build + boot + launch is the whole
# app. The home-screen WIDGET still can't be added to a sim home screen
# headlessly, but its only interactive contract (the crowly:// deeplink) IS
# driveable here via `openurl` (see the `deeplink` subcommand).
#
# Usage (run from the repo root):
#   .claude/skills/run-crowly/driver.sh up        # gen + build + boot + install + launch + screenshot inbox
#   .claude/skills/run-crowly/driver.sh deeplink   # open a demo digest via crowly:// and screenshot detail
#   .claude/skills/run-crowly/driver.sh shot NAME  # screenshot current sim screen to SHOT_DIR/NAME.png
#   .claude/skills/run-crowly/driver.sh test       # run the Swift Testing suite
#   .claude/skills/run-crowly/driver.sh build      # gen + build only
#
# Env overrides:
#   SIM      simulator device name      (default: iPhone 17 Pro)
#   SHOT_DIR screenshot output dir      (default: /tmp/crowly-shots)
#   DIGEST   digest id for `deeplink`   (default: dgst_2026-06-29_ai-news)

set -euo pipefail

# Repo root = two levels up from .claude/skills/run-crowly/.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

SIM="${SIM:-iPhone 17 Pro}"
SHOT_DIR="${SHOT_DIR:-/tmp/crowly-shots}"
DIGEST="${DIGEST:-dgst_2026-06-29_ai-news}"
BUNDLE_ID="com.crowly.Crowly"
APP="$ROOT/build/Build/Products/Debug-iphonesimulator/Crowly.app"
DEST="platform=iOS Simulator,name=$SIM"

log() { printf '\033[1;34m▸ %s\033[0m\n' "$*"; }

gen()   { log "xcodegen generate"; xcodegen generate; }
build() {
  gen
  log "xcodebuild build ($SIM)"
  xcodebuild -project Crowly.xcodeproj -scheme Crowly \
    -destination "$DEST" -derivedDataPath build build \
    2>&1 | tail -3
  test -d "$APP" || { echo "build did not produce $APP" >&2; exit 1; }
}
boot() {
  log "boot $SIM"
  xcrun simctl boot "$SIM" 2>/dev/null || true   # no-op if already booted
  open -a Simulator 2>/dev/null || true
  xcrun simctl bootstatus "$SIM" -b 2>/dev/null || sleep 8
}
install_launch() {
  log "install + launch $BUNDLE_ID"
  xcrun simctl install booted "$APP"
  xcrun simctl launch booted "$BUNDLE_ID"
  sleep 4   # give SwiftUI a beat to render the inbox
}
shot() {
  local name="${1:-screen}"
  mkdir -p "$SHOT_DIR"
  xcrun simctl io booted screenshot "$SHOT_DIR/$name.png"
  log "screenshot → $SHOT_DIR/$name.png"
}

case "${1:-up}" in
  build) build ;;
  boot)  boot ;;
  up)
    build; boot; install_launch; shot inbox
    log "inbox screenshot at $SHOT_DIR/inbox.png — open it and confirm the digest list renders"
    ;;
  deeplink)
    log "openurl crowly://digest/$DIGEST"
    xcrun simctl openurl booted "crowly://digest/$DIGEST"
    sleep 3
    shot detail
    log "detail screenshot at $SHOT_DIR/detail.png — confirm header → bottom line → summary → sections"
    ;;
  shot) shot "${2:-screen}" ;;
  test)
    gen
    log "xcodebuild test ($SIM)"
    xcodebuild -project Crowly.xcodeproj -scheme Crowly \
      -destination "$DEST" -derivedDataPath build test \
      2>&1 | tail -8
    ;;
  *)
    echo "usage: driver.sh {up|build|boot|deeplink|shot NAME|test}" >&2
    exit 2
    ;;
esac
