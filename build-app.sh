#!/bin/zsh
# Builds "Living Scroll PDF.app" (signed with the local Apple Development identity, ad-hoc if none) into ./dist
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="dist/Living Scroll PDF.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LivingScrollPDF "$APP/Contents/MacOS/LivingScrollPDF"
cp assets/AppIcon.icns assets/tip-wechat.jpg assets/contact-wechat.jpg "$APP/Contents/Resources/"
# Chinese systems show the Chinese name in Finder, the menu bar and System Settings.
for lang in zh-Hans zh-Hant; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
  printf '"CFBundleDisplayName" = "卷轴PDF";\n"CFBundleName" = "卷轴PDF";\n' > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Living Scroll PDF</string>
  <key>CFBundleDisplayName</key><string>Living Scroll PDF</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleIdentifier</key><string>io.github.lululynne.livingscrollpdf</string>
  <key>CFBundleExecutable</key><string>LivingScrollPDF</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>卷轴PDF 需要截取你选中的窗口来拼长图。Living Scroll PDF captures the window you pick to stitch a long image.</string>
</dict>
</plist>
PLIST
# A stable signing identity keeps the Screen Recording grant valid across rebuilds;
# ad-hoc signatures change every build and macOS silently stops honoring the toggle.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "built $APP"
