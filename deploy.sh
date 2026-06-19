#!/usr/bin/env bash
# Build Skim and install it on a connected iPhone — no Xcode GUI, works over SSH.
#
#   ./deploy.sh                 # build + install to the connected device
#   DEVICE="Joe’s iPhone" ./deploy.sh   # target a specific device by name
#
# Requires: full Xcode (xcodebuild + devicectl), xcodegen, a paired device
# (USB or network), and the login keychain unlocked for code signing
# (see "Over SSH" in README.md).
set -euo pipefail
cd "$(dirname "$0")"

APP=".build/ios/Build/Products/Debug-iphoneos/Skim.app"

# Resolve the target device: $DEVICE if set, else the first connected one.
if [[ -z "${DEVICE:-}" ]]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null \
    | awk -F'  +' '/connected/ {print $1; exit}')"
fi
[[ -n "$DEVICE" ]] || { echo "No connected device found."; exit 1; }
echo "Target device: $DEVICE"

echo "==> Regenerating project"
xcodegen generate

echo "==> Building for device (signed)"
xcodebuild \
  -project Skim.xcodeproj \
  -scheme Skim \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build/ios \
  -allowProvisioningUpdates \
  build

echo "==> Installing on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP"

echo "==> Done. Launch Skim on the phone."
