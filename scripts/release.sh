#!/bin/bash
# Builds a universal release of AgentScope.app, signs it, notarizes it when credentials are set,
# zips it for GitHub Releases and updates Casks/agentscope.rb.
#
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"  signing identity (optional; ad-hoc otherwise)
#   NOTARY_PROFILE=agentscope                                 `xcrun notarytool store-credentials` profile (optional)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
scripts/build-app.sh release --universal >/dev/null
APP=build/AgentScope.app
mkdir -p dist
ZIP="dist/AgentScope-$VERSION.zip"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP/Contents/Helpers/agentscope"
  codesign --force --options runtime --timestamp --entitlements Support/AgentScope.entitlements --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "warning: DEVELOPER_ID not set; the app is ad-hoc signed. Users must run: xattr -cr /Applications/AgentScope.app" >&2
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/agentscope.rb
echo "$ZIP"
echo "sha256 $SHA"
