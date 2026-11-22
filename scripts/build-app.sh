#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "正在建置蒼鷹輸入法 (Goshawk) 最佳化版本⋯"
# GOSHAWK_UNIVERSAL=1 建出 Apple 晶片與 Intel 共用的執行檔，給發行版用。需要完整的 Xcode。
ARCH_FLAGS=()
if [[ "${GOSHAWK_UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product GoshawkApp
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BIN_PATH="$BIN_DIR/GoshawkApp"
RESOURCE_BUNDLE="$BIN_DIR/goshawk-ime_GoshawkCore.bundle"

APP_DIR="$ROOT_DIR/dist/GoshawkIME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" \
  "$RESOURCES_DIR/zh_TW.lproj" \
  "$RESOURCES_DIR/zh-Hant.lproj" \
  "$RESOURCES_DIR/en.lproj"

cp "$BIN_PATH" "$MACOS_DIR/GoshawkApp"
cp "$ROOT_DIR/artwork/Goshawk.icns" "$ROOT_DIR"/artwork/GoshawkTemplate*.png "$RESOURCES_DIR/"
# 隨附詞庫的授權要求顯名，散布的套件裡必須帶著授權與來源聲明。
cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/"
# 隨附離線互動說明與 30 秒練習場，零外部請求，從選單與安裝完成頁可直接以瀏覽器開啟。
mkdir -p "$RESOURCES_DIR/Guide/assets"
cp "$ROOT_DIR/docs/index.html" "$ROOT_DIR/docs/styles.css" "$ROOT_DIR/docs/app.js" \
  "$ROOT_DIR/docs/guide.md" "$ROOT_DIR/docs/llms.txt" "$RESOURCES_DIR/Guide/"
cp "$ROOT_DIR/docs/assets/goshawk.svg" "$RESOURCES_DIR/Guide/assets/"
chmod +x "$MACOS_DIR/GoshawkApp"

if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

# 輸入來源清單與選單列顯示的名稱。模式名稱的鍵就是輸入模式 ID，套件本體那一筆取
# `CFBundleName`，依據是 Apple 技術文件 TN2128 與系統內建輸入法的 InfoPlist.loctable。
# 語言對不上任何 .lproj 時 CFBundle 會落到 en.lproj，所以英文那份要寫英文名。
for lproj in zh_TW.lproj zh-Hant.lproj; do
  cat > "$RESOURCES_DIR/$lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleName" = "蒼鷹 Goshawk";
"CFBundleDisplayName" = "蒼鷹輸入法 (Goshawk)";
"com.kc.inputmethod.Goshawk.Cangjie" = "蒼鷹輸入法";
STRINGS
done

cat > "$RESOURCES_DIR/en.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleName" = "Goshawk";
"CFBundleDisplayName" = "Goshawk";
"com.kc.inputmethod.Goshawk.Cangjie" = "Goshawk";
STRINGS

# 介面文字的英文翻譯。中文語系查不到翻譯就用程式裡的中文原文，不需要檔案。
cp "$ROOT_DIR/Resources/en.lproj/Localizable.strings" "$RESOURCES_DIR/en.lproj/Localizable.strings"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Goshawk</string>
    <key>CFBundleExecutable</key>
    <string>GoshawkApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.kc.inputmethod.Goshawk</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>Goshawk.icns</string>
    <key>CFBundleName</key>
    <string>Goshawk</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.0</string>
    <key>CFBundleVersion</key>
    <string>0.0.0</string>
    <key>ComponentInputModeDict</key>
    <dict>
        <key>tsInputModeListKey</key>
        <dict>
            <key>com.kc.inputmethod.Goshawk.Cangjie</key>
            <dict>
                <key>tsInputModeMenuIconFileKey</key>
                <string>GoshawkTemplate.png</string>
                <key>TISIconLabels</key>
                <dict>
                    <key>Primary</key>
                    <string>蒼鷹</string>
                </dict>
                <key>TISInputSourceID</key>
                <string>com.kc.inputmethod.Goshawk.Cangjie</string>
                <key>TISIntendedLanguage</key>
                <string>zh-Hant</string>
                <key>tsInputModeCharacterRepertoireKey</key>
                <array>
                    <string>Hant</string>
                </array>
                <key>tsInputModeDefaultStateKey</key>
                <true/>
                <key>tsInputModeIsVisibleKey</key>
                <true/>
                <key>tsInputModePrimaryInScriptKey</key>
                <true/>
                <key>tsInputModeScriptKey</key>
                <string>smTradChinese</string>
            </dict>
        </dict>
        <key>tsVisibleInputModeOrderedArrayKey</key>
        <array>
            <string>com.kc.inputmethod.Goshawk.Cangjie</string>
        </array>
    </dict>
    <key>InputMethodConnectionName</key>
    <string>com.kc.inputmethod.Goshawk_Connection</string>
    <key>InputMethodServerControllerClass</key>
    <string>GoshawkInputController</string>
    <key>InputMethodServerDelegateClass</key>
    <string>GoshawkInputController</string>
    <key>LSHasLocalizedDisplayName</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>TISInputSourceID</key>
    <string>com.kc.inputmethod.Goshawk</string>
    <key>TISIntendedLanguage</key>
    <string>zh-Hant</string>
    <key>tsInputMethodCharacterRepertoireKey</key>
    <array>
        <string>Hant</string>
    </array>
</dict>
</plist>
PLIST

# 版本號只寫在根目錄的 VERSION。上面兩個 0.0.0 是佔位，這裡填進實際的版本。
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION 的內容不是「數字.數字.數字」：${VERSION}" >&2
  exit 1
fi
# 同一發行版可能試用多組引擎或詞庫。用簽章前的執行檔和詞庫辨識實際建置。
BUILD_DIGEST="$(
  cd "$BIN_DIR"
  export LC_ALL=C
  shasum -a 256 GoshawkApp goshawk-ime_GoshawkCore.bundle/Contents/Resources/*.tsv | shasum -a 256 | cut -c1-16
)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" \
  -c "Add :GoshawkBuildIdentifier string ${VERSION}+${BUILD_DIGEST}" "$CONTENTS_DIR/Info.plist"

plutil -lint "$CONTENTS_DIR/Info.plist"
# 預設是只能在本機執行的臨時簽章。發行版把 GOSHAWK_SIGN_IDENTITY 設成 Developer ID 憑證名稱，
# 公證要求同時開啟 hardened runtime 與時間戳記。
SIGN_IDENTITY="${GOSHAWK_SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP_DIR"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"
echo "正在執行輸入法套件自我檢查⋯"
"$MACOS_DIR/GoshawkApp" --self-test
echo "已完成打包： $APP_DIR"
