#!/usr/bin/env bash
# Build a tvOS .ipa from this repo on a Mac.
#
# Unsigned (default), for sideloading:
#   ./scripts/build-tvos-ipa.sh
#
# Development-signed, when a team is available:
#   TEAM_ID=ABCDE12345 ./scripts/build-tvos-ipa.sh
#
# The finished IPA path is printed on the last line as "IPA: <path>".

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.tuist_state}"
TVOS_WORKSPACE="$ROOT_DIR/tvosApp/NuvioTV.xcworkspace"
TVOS_SCHEME="NuvioTV"
OUTPUT_DIR="${NUVIO_IPA_OUTPUT_DIR:-$ROOT_DIR/build-ipa}"
WORK_DIR="$(mktemp -d)"
ARCHIVE_PATH="$WORK_DIR/NuvioTV.xcarchive"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

echo "==> Checking prerequisites..."

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "this script must run on macOS with Xcode. This machine is $(uname -s)."
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  fail "xcodebuild was not found. Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  fail "xcodebuild cannot run. Point the active developer directory at Xcode: sudo xcode-select -s /Applications/Xcode.app"
fi

if ! xcrun --sdk appletvos --show-sdk-path >/dev/null 2>&1; then
  fail "the appletvos SDK is missing. Open Xcode once and install the tvOS platform from Settings → Components."
fi

if ! command -v git >/dev/null 2>&1; then
  fail "git is required to fetch the MPVKit submodule. Install the Xcode command line tools: xcode-select --install"
fi

if ! command -v zip >/dev/null 2>&1; then
  fail "zip is required to package the unsigned IPA."
fi

TUIST_CMD=()
if command -v tuist >/dev/null 2>&1; then
  TUIST_CMD=(tuist)
elif command -v mise >/dev/null 2>&1; then
  TUIST_CMD=(mise exec -- tuist)
else
  fail "tuist was not found. From the repo root run 'mise install' (Tuist is pinned in mise.toml), or 'brew install tuist'."
fi

if [[ ! -f "$ROOT_DIR/MPVKit/Package.swift" ]]; then
  echo "==> Initializing git submodules (MPVKit)..."
  git -C "$ROOT_DIR" submodule update --init --recursive
fi

if [[ ! -f "$ROOT_DIR/MPVKit/Package.swift" ]]; then
  fail "MPVKit is still missing. Run: git submodule update --init --recursive"
fi

echo "==> Generating the Xcode project with Tuist..."
(cd "$ROOT_DIR/tvosApp" && "${TUIST_CMD[@]}" generate --no-open)

if [[ ! -d "$TVOS_WORKSPACE" ]]; then
  fail "Tuist did not create $TVOS_WORKSPACE"
fi

echo "==> Resolving Swift packages..."
xcodebuild -resolvePackageDependencies \
  -workspace "$TVOS_WORKSPACE" \
  -scheme "$TVOS_SCHEME"

VERSION="latest"
sign_and_package_unsigned() {
  local app_path="$1"
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_path/Info.plist" 2>/dev/null || echo "latest")
  echo "==> Packaging unsigned IPA for version ${VERSION}..."
  rm -rf "$OUTPUT_DIR/Payload" "$OUTPUT_DIR"/*.ipa
  mkdir -p "$OUTPUT_DIR/Payload"
  cp -R "$app_path" "$OUTPUT_DIR/Payload/"

  # The archive is built without entitlements. Embed only the Top Shelf App
  # Group so a sideloader can re-sign and the shelf can still read the feed.
  local app_group
  app_group=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups:0" \
    "$ROOT_DIR/tvosApp/TopShelf/TopShelf.entitlements" 2>/dev/null || true)
  if [[ -n "$app_group" ]] && command -v codesign >/dev/null 2>&1; then
    echo "==> Embedding App Group ${app_group} for Top Shelf..."
    local entitlements="$WORK_DIR/app-group.entitlements"
    cat > "$entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>${app_group}</string>
	</array>
</dict>
</plist>
PLIST
    local payload_app="$OUTPUT_DIR/Payload/NuvioTV.app"
    local bundle executable
    for bundle in "$payload_app"/PlugIns/*.appex "$payload_app"; do
      [[ -d "$bundle" ]] || continue
      executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$bundle/Info.plist")
      codesign --force --sign - --entitlements "$entitlements" "$bundle/$executable"
    done
  elif [[ -n "$app_group" ]]; then
    echo "warning: codesign is unavailable, so the unsigned IPA has no App Group and Top Shelf stays empty after sideloading." >&2
  fi

  (
    cd "$OUTPUT_DIR"
    zip -qry "NuvioTV-${VERSION}-unsigned-release.ipa" Payload
  )
  echo "IPA: $OUTPUT_DIR/NuvioTV-${VERSION}-unsigned-release.ipa"
}

if [[ -n "${TEAM_ID:-}" ]]; then
  echo "==> Archiving ${TVOS_SCHEME} for tvOS (Release, team ${TEAM_ID})..."
  xcodebuild archive \
    -workspace "$TVOS_WORKSPACE" \
    -scheme "$TVOS_SCHEME" \
    -configuration Release \
    -destination 'generic/platform=tvOS' \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates

  APP_PATH="$ARCHIVE_PATH/Products/Applications/NuvioTV.app"
  [[ -d "$APP_PATH" ]] || fail "archive failed; NuvioTV.app was not produced"
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Info.plist" 2>/dev/null || echo "latest")

  EXPORT_PLIST="$WORK_DIR/ExportOptions.plist"
  cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>development</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
	<key>compileBitcode</key>
	<false/>
</dict>
</plist>
PLIST

  echo "==> Exporting a development-signed IPA..."
  rm -rf "$OUTPUT_DIR/signed"
  mkdir -p "$OUTPUT_DIR/signed"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$OUTPUT_DIR/signed" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates

  EXPORTED="$(find "$OUTPUT_DIR/signed" -maxdepth 1 -name '*.ipa' -print -quit)"
  [[ -n "$EXPORTED" ]] || fail "exportArchive finished without an .ipa in $OUTPUT_DIR/signed"
  FINAL="$OUTPUT_DIR/NuvioTV-${VERSION}.ipa"
  cp "$EXPORTED" "$FINAL"
  echo "IPA: $FINAL"
else
  echo "==> Archiving ${TVOS_SCHEME} for tvOS (Release, unsigned)..."
  xcodebuild archive \
    -workspace "$TVOS_WORKSPACE" \
    -scheme "$TVOS_SCHEME" \
    -configuration Release \
    -destination 'generic/platform=tvOS' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_ENTITLEMENTS=""

  APP_PATH="$ARCHIVE_PATH/Products/Applications/NuvioTV.app"
  [[ -d "$APP_PATH" ]] || fail "archive failed; NuvioTV.app was not produced"
  sign_and_package_unsigned "$APP_PATH"
fi
