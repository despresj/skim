#!/bin/bash
# Watch Skim sources; on any change, (re)generate the project if its file
# set changed, build for the connected iPhone, and install (and relaunch) it.
#
# Usage: scripts/watch_deploy.sh
# Stop:  Ctrl-C, or kill the background job.

set -uo pipefail
cd "$(dirname "$0")/.."

DEVICE_ID="00008140-001C28661142801C"   # Joe's iPhone (xcodebuild/devicectl UDID)
BUNDLE_ID="com.despresj.skim"
DD="/Users/joe/skim/.dd"
APP="$DD/Build/Products/Debug-iphoneos/Skim.app"
WATCH=(App Sources/SkimCore project.yml)

ts() { date +"%H:%M:%S"; }
log() { echo "[$(ts)] $*"; }

# Signature of file contents+mtimes — changes on any edit.
content_sig() {
  { find App Sources/SkimCore -type f -name '*.swift' -exec stat -f '%N %m' {} +;
    stat -f '%N %m' project.yml; } 2>/dev/null | sort | shasum | awk '{print $1}'
}
# Signature of the file *set* + project.yml content — changes when files are
# added/removed/renamed, which is when xcodegen must regenerate the project.
struct_sig() {
  { find App Sources/SkimCore -type f -name '*.swift' | sort; shasum project.yml; } \
    | shasum | awk '{print $1}'
}

build_and_deploy() {
  local need_regen="$1"
  if [ "$need_regen" = "1" ]; then
    log "file set changed → xcodegen generate"
    xcodegen generate >/dev/null 2>&1 || { log "✗ xcodegen failed"; return 1; }
  fi

  log "building for device…"
  if ! xcodebuild -project Skim.xcodeproj -scheme Skim \
        -destination "platform=iOS,id=$DEVICE_ID" \
        -allowProvisioningUpdates -derivedDataPath "$DD" \
        build >/tmp/skim_build.log 2>&1; then
    log "✗ BUILD FAILED — see /tmp/skim_build.log"
    grep -E "error:" /tmp/skim_build.log | head -5
    return 1
  fi

  log "installing on iPhone…"
  if ! xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >/tmp/skim_install.log 2>&1; then
    log "✗ INSTALL FAILED — see /tmp/skim_install.log"
    return 1
  fi

  # Relaunch so the latest build is on screen.
  xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1
  log "✓ deployed & launched"
}

log "watching ${WATCH[*]} — edit & save to redeploy (Ctrl-C to stop)"
prev_content="$(content_sig)"
prev_struct="$(struct_sig)"

while true; do
  sleep 2
  cur_content="$(content_sig)"
  [ "$cur_content" = "$prev_content" ] && continue

  # Debounce: wait for writes to settle before building.
  sleep 1
  cur_content="$(content_sig)"
  cur_struct="$(struct_sig)"
  regen=0
  [ "$cur_struct" != "$prev_struct" ] && regen=1

  log "change detected"
  build_and_deploy "$regen"

  prev_content="$cur_content"
  prev_struct="$cur_struct"
done
