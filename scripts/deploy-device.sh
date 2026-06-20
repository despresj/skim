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
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

build_app() {
  xcodebuild \
    -project Skim.xcodeproj \
    -scheme Skim \
    -destination "id=$UDID" \
    -configuration Debug \
    -allowProvisioningUpdates \
    -derivedDataPath "$DD" \
    build
}

# Unlock the login keychain so codesign can reach the signing key. Reads the Mac
# password from $KC_PASS if set (non-interactive), else prompts when a terminal
# is attached. Returns non-zero if it has no way to get the password.
unlock_keychain() {
  local pass="${KC_PASS:-}"
  if [[ -z "$pass" ]]; then
    if [[ -t 0 ]]; then
      read -rsp "Mac login password (to unlock keychain for codesign): " pass
      echo
    else
      echo "✗ Keychain is locked and no password available." >&2
      echo "  Rerun in a terminal, or set KC_PASS, so the keychain can be unlocked." >&2
      return 1
    fi
  fi
  security unlock-keychain -p "$pass" "$KEYCHAIN" &&
    security set-key-partition-list -S apple-tool:,apple: -s -k "$pass" "$KEYCHAIN" >/dev/null
}

echo "▸ Building for device…"
# Build first; if this fails we exit before touching the device. A locked
# keychain shows up here as a codesign failure — try unlocking once and retry.
if ! build_app; then
  echo "▸ Build failed — attempting keychain unlock and one retry…"
  unlock_keychain
  build_app
fi

echo "▸ Installing onto device…"
xcrun devicectl device install app --device "$UDID" "$APP"

echo "▸ Launching…"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID"

echo "✓ Deployed to device."
