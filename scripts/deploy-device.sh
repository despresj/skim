#!/usr/bin/env bash
# Build-gated deploy to Joe's iPhone.
#
# Builds the Skim app for the physical device and installs + launches it ONLY if
# the build succeeds — so a broken tree never lands on the phone. Used by the
# agent to "reload onto device" after a change is verified clean (see CLAUDE.md).
#
# Usage: scripts/deploy-device.sh
# Exit:  0 = built, installed, launched. Non-zero = build failed (nothing installed).

set -euo pipefail
cd "$(dirname "$0")/.."

UDID="00008140-001C28661142801C"   # Joe's iPhone (hardware UDID, not the CoreDevice UUID)
BUNDLE_ID="com.despresj.skim"
DD="build/dd"
APP="$DD/Build/Products/Debug-iphoneos/Skim.app"

echo "▸ Building for device…"
# Build first; if this fails we exit (set -e) before touching the device.
xcodebuild \
  -project Skim.xcodeproj \
  -scheme Skim \
  -destination "id=$UDID" \
  -configuration Debug \
  -allowProvisioningUpdates \
  -derivedDataPath "$DD" \
  build

echo "▸ Installing onto device…"
xcrun devicectl device install app --device "$UDID" "$APP"

echo "▸ Launching…"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID"

echo "✓ Deployed to device."
