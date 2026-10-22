#!/bin/bash
# Builds build/AgentScope.app with the CLI bundled at Contents/Helpers/agentscope.
# Usage: scripts/build-app.sh [debug|release] [--universal]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
ARCH_FLAGS=()
if [[ "${2:-}" == "--universal" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product AgentScopeApp
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product agentscope
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/AgentScope.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/AgentScopeApp" "$APP/Contents/MacOS/AgentScope"
cp "$BIN/agentscope" "$APP/Contents/Helpers/agentscope"
if [[ -d Support/Resources ]]; then
  cp -R Support/Resources/. "$APP/Contents/Resources/"
fi

# Ad-hoc signature; release signing and notarization live in scripts/release.sh.
codesign --force --sign - "$APP/Contents/Helpers/agentscope"
codesign --force --sign - --entitlements Support/AgentScope.entitlements "$APP"
echo "$APP"
