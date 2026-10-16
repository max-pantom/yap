#!/bin/zsh
# Builds Yap.app (release) into ./build and ad-hoc signs it.
#   ./build.sh            build only
#   ./build.sh --install  also copy to /Applications (quits a running Yap first)
# Optional environment (used by the release workflow):
#   YAP_VERSION=1.2.0  YAP_BUILD=42      version shown in About and compared by the updater
#   SPARKLE_PUBLIC_KEY=…                 EdDSA public key; enables in-app updates
#   SIGN_IDENTITY="Developer ID Application: …"   sign for notarization instead of ad-hoc
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64
APP=build/Yap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$BIN/Yap" "$APP/Contents/MacOS/Yap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
[[ -n "${YAP_VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${YAP_VERSION}" "$PLIST"
[[ -n "${YAP_BUILD:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${YAP_BUILD}" "$PLIST"
[[ -n "${SPARKLE_PUBLIC_KEY:-}" ]] && /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${SPARKLE_PUBLIC_KEY}" "$PLIST"
# Sparkle (in-app updates) ships as a framework next to the binary.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Yap" 2>/dev/null || true
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Liquid Glass icon: if an Icon Composer file exists and Xcode 26's actool is available, compile it into
# Assets.car. macOS then uses it (light/dark/tinted/clear); the .icns above stays as the fallback.
if [[ -d Resources/AppIcon.icon ]] && xcrun --find actool >/dev/null 2>&1; then
  if xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
       --minimum-deployment-target 26.0 --app-icon AppIcon --output-format human-readable-text --notices --warnings \
       --output-partial-info-plist "$(mktemp -d)/icon.plist" >/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
    echo "Compiled Liquid Glass icon (Resources/AppIcon.icon)"
  else
    echo "Warning: couldn't compile Resources/AppIcon.icon; using the static AppIcon.icns"
  fi
elif [[ -d Resources/AppIcon.icon ]]; then
  echo "Note: Resources/AppIcon.icon found but actool (Xcode 26) isn't installed; using the static AppIcon.icns"
fi
# Sign inside-out: Sparkle's helpers, the framework, then the app.
IDENTITY="${SIGN_IDENTITY:--}"
TS=(); [[ "$IDENTITY" != "-" ]] && TS=(--timestamp)
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$IDENTITY" "${TS[@]}" --options runtime "$SP/XPCServices/Installer.xpc"
codesign --force --sign "$IDENTITY" "${TS[@]}" --options runtime --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
codesign --force --sign "$IDENTITY" "${TS[@]}" --options runtime "$SP/Autoupdate" "$SP/Updater.app"
codesign --force --sign "$IDENTITY" "${TS[@]}" --options runtime "$APP/Contents/Frameworks/Sparkle.framework"
if [[ "$IDENTITY" == "-" ]]; then
  # Ad-hoc signatures change every build, which silently voids macOS privacy grants (Accessibility, Input Monitoring…).
  # Pinning the designated requirement to the bundle identifier keeps those grants valid across rebuilds.
  # Ad-hoc code has no team, so the hardened runtime's library validation would refuse the bundled Sparkle
  # framework. Developer ID builds don't need this: the app and framework share one team.
  ENT="$(mktemp -d)/Yap.entitlements"
  cp Resources/Yap.entitlements "$ENT"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENT"
  codesign --force --sign - --identifier app.yap.mac --options runtime \
    --entitlements "$ENT" \
    -r='designated => identifier "app.yap.mac"' "$APP"
else
  # Developer ID: the default requirement (identifier + team) is already stable across builds.
  codesign --force --sign "$IDENTITY" --timestamp --identifier app.yap.mac --options runtime \
    --entitlements Resources/Yap.entitlements "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"
# A fixed location in /Applications keeps macOS privacy permissions attached to the app.
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Yap 2>/dev/null || true
  rm -rf /Applications/Yap.app && ditto "$APP" /Applications/Yap.app
  echo "Installed /Applications/Yap.app"
fi
