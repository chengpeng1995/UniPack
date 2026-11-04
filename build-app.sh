#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/swift-module-cache"
# 当前 Swift 6.4 的 native 构建后端可稳定构建大小写不同的产品和资源 bundle。
swift build --disable-sandbox --build-system native --configuration release --scratch-path "$PROJECT_ROOT/.build/native"
BIN_DIR="$(swift build --disable-sandbox --build-system native --configuration release --scratch-path "$PROJECT_ROOT/.build/native" --show-bin-path)"
APP="${UNIPACK_APP_OUTPUT:-$PROJECT_ROOT/dist/UniPack.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/UniPack" "$APP/Contents/MacOS/UniPack"
cp "$BIN_DIR/unipack-cli" "$APP/Contents/MacOS/unipack-cli"
rsync -a "$BIN_DIR/UniPack_UniPackCore.bundle/" "$APP/Contents/Resources/UniPack_UniPackCore.bundle/"
"$PROJECT_ROOT/tools/build-file-signer.sh" "$PROJECT_ROOT/.build/file-signer"
cp "$PROJECT_ROOT/.build/file-signer/bin/unipack-file-signer" "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Frameworks"
rsync -a "$PROJECT_ROOT/.build/file-signer/Frameworks/" "$APP/Contents/Frameworks/"
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$PROJECT_ROOT/Vendor/zsign/LICENSE" "$APP/Contents/Resources/Licenses/zsign.txt"
# OpenSSL's distribution license is available in the Homebrew package metadata.
cp "$PROJECT_ROOT/Vendor/OpenSSL-LICENSE.txt" "$APP/Contents/Resources/Licenses/OpenSSL.txt"
cp "$PROJECT_ROOT/Vendor/zlib-minizip-LICENSE.txt" "$APP/Contents/Resources/Licenses/zlib-minizip.txt"

ICON_OUTPUT="$PROJECT_ROOT/.build/icon-output"
mkdir -p "$ICON_OUTPUT"
xcrun actool "$PROJECT_ROOT/UniPack.icon" --compile "$ICON_OUTPUT" --platform macosx --minimum-deployment-target 26.0 --app-icon UniPack --output-partial-info-plist "$PROJECT_ROOT/.build/icon-info.plist"
cp "$ICON_OUTPUT/Assets.car" "$APP/Contents/Resources/Assets.car"
find "$ICON_OUTPUT" -maxdepth 1 -name '*.icns' -exec cp {} "$APP/Contents/Resources/" \;
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>UniPack</string>
<key>CFBundleIdentifier</key><string>com.unipack.desktop</string>
<key>CFBundleName</key><string>UniPack</string>
<key>CFBundleDisplayName</key><string>UniPack</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>UniPack.icns</string>
<key>CFBundleIconName</key><string>UniPack</string>
<key>CFBundleShortVersionString</key><string>0.9.1</string>
<key>CFBundleVersion</key><string>16</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP"
echo "应用已生成：$APP"
