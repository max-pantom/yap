#!/bin/zsh
# Builds Yap.app (release) into ./build and ad-hoc signs it.
#   ./build.sh            build only
#   ./build.sh --install  also copy to /Applications (quits a running Yap first)
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64
APP=build/Yap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/Yap" "$APP/Contents/MacOS/Yap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Liquid Glass icon: if an Icon Composer file exists and Xcode 26's actool is available, compile it into
# Assets.car. macOS then uses it (light/dark/tinted/clear); the .icns above stays as the fallback.
if [[ -d Resources/AppIcon.icon ]] && xcrun --find actool >/dev/null 2>&1; then
  xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon --output-format human-readable-text --notices --warnings \
    --output-partial-info-plist "$(mktemp -d)/icon.plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
  echo "Compiled Liquid Glass icon (Resources/AppIcon.icon)"
elif [[ -d Resources/AppIcon.icon ]]; then
  echo "Note: Resources/AppIcon.icon found but actool (Xcode 26) isn't installed; using the static AppIcon.icns"
fi
# Ad-hoc signatures change every build, which silently voids macOS privacy grants (Accessibility, Input Monitoring…).
# Pinning the designated requirement to the bundle identifier keeps those grants valid across rebuilds.
codesign --force --deep --sign - --identifier app.yap.mac --options runtime \
  --entitlements Resources/Yap.entitlements \
  -r='designated => identifier "app.yap.mac"' "$APP"
echo "Built $APP"
# A fixed location in /Applications keeps macOS privacy permissions attached to the app.
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Yap 2>/dev/null || true
  rm -rf /Applications/Yap.app && ditto "$APP" /Applications/Yap.app
  echo "Installed /Applications/Yap.app"
fi
