#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="build/Intent Planner.app"
ICONSET="build/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"
cp .build/release/IntentPlanner "$APP/Contents/MacOS/IntentPlanner"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" icon-rounded.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" icon-rounded.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>IntentPlanner</string>
<key>CFBundleIdentifier</key><string>com.intentplanner.app</string>
<key>CFBundleName</key><string>Intent Planner</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
touch "$APP"
echo "Built $APP"
