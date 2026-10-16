#!/bin/bash
# Membangun "Perekam Rapat.app" tanpa Xcode project.
# Butuh: macOS 13+ dan Xcode atau Command Line Tools (xcode-select --install).
#   ./build.sh              -> build untuk arsitektur Mac ini
#   ./build.sh --universal  -> build Apple Silicon + Intel
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Perekam Rapat.app"
BIN="PerekamRapat"
if [[ "${1:-}" == "--universal" ]]; then ARCHS=(arm64 x86_64); else ARCHS=("$(uname -m)"); fi

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for arch in "${ARCHS[@]}"; do
  echo "› Kompilasi ($arch)…"
  xcrun swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos13.0" \
    -framework SwiftUI -framework AppKit -framework AVFoundation -framework ScreenCaptureKit \
    -framework CoreAudio -framework AudioToolbox -framework CoreMedia -framework Accelerate \
    Sources/*.swift -o "build/obj/$BIN-$arch"
done
lipo -create build/obj/$BIN-* -output "$APP/Contents/MacOS/$BIN"

cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ -f Resources/AppIcon.png ]]; then
  echo "› Membuat ikon…"
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "› Tanda tangan ad-hoc…"
codesign --force --deep --sign - "$APP"

echo "✓ Selesai: $APP"
echo "  Pindahkan ke /Applications:  cp -R \"$APP\" /Applications/"
