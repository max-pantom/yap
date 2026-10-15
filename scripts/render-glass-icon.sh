#!/bin/zsh
# Renders Resources/AppIcon.icon (Icon Composer) with Apple's own Liquid Glass renderer (ictool, shipped inside
# Icon Composer) and installs it as the static AppIcon.icns. Use until Xcode 26's actool can compile the live icon.
#   scripts/render-glass-icon.sh [path/to/Icon Composer.app]
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.IconComposer'" | head -1)}
[[ -z "$APP" ]] && APP=$(ps -axo command | grep -o "/.*Icon Composer.app" | head -1)
ICTOOL="$APP/Contents/Executables/ictool"
[[ -x "$ICTOOL" ]] || { echo "Can't find Icon Composer. Pass its path: scripts/render-glass-icon.sh '/path/Icon Composer.app'"; exit 1; }
OUT=design/icon-glass/renders; mkdir -p "$OUT"
for r in Default Dark ClearLight ClearDark TintedLight TintedDark; do
  "$ICTOOL" Resources/AppIcon.icon --export-image --output-file "$OUT/app-$r.png" --platform macOS \
    --rendition $r --width 1024 --height 1024 --scale 1 >/dev/null
done
# ictool renders full-bleed; place it on the macOS grid (824 in 1024) with the standard drop shadow.
swift - "$OUT/app-Default.png" design/icon-glass/icon-glass-default.png <<'SWIFT'
import AppKit
let a = CommandLine.arguments
let src = NSImage(contentsOfFile: a[1])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.cgContext.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
src.draw(in: NSRect(x: 100, y: 100, width: 824, height: 824))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
SWIFT
scripts/set-icon.sh design/icon-glass/icon-glass-default.png
echo "Rendered all appearances to $OUT and set the Default as the app icon."
