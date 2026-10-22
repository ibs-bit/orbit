#!/usr/bin/env bash
# Builds Orbit with SwiftPM and wraps it into dist/Orbit.app (ad-hoc signed).
set -euo pipefail

APP_NAME="Orbit"
BUNDLE_ID="com.ibsbit.Orbit"
VERSION="${ORBIT_VERSION:-0.1.0}"
MIN_MACOS="14.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
cd "$ROOT"

echo "==> Building $APP_NAME (release)…"
swift build -c release 2>&1 | grep -E 'error|Compiling|Build' || true
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN" >&2; exit 1; }

echo "==> Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICON_PNG="$ROOT/Assets/AppIcon.png"
if [[ ! -f "$ICON_PNG" ]]; then
  echo "==> Drawing icon…"
  swift "$ROOT/scripts/make_icon.swift" "$ICON_PNG"
fi
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"

ZIP="$DIST/$APP_NAME-$VERSION-macOS.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "✅ $APP"
echo "   $ZIP"
