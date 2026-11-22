#!/usr/bin/env bash
# 產生發行用的 dist/GoshawkIME.dmg：通用執行檔、品牌視窗底圖、Developer ID 簽章，
# 給了公證設定就一併公證。
#
#   GOSHAWK_SIGN_IDENTITY   必填。Developer ID Application 憑證的完整名稱。
#   GOSHAWK_NOTARY_PROFILE  選填。`xcrun notarytool store-credentials` 存下的設定名稱。
#                           沒給就只簽章不公證，下載的人會被 Gatekeeper 擋下，只適合自己測試。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${GOSHAWK_SIGN_IDENTITY:?要設定 GOSHAWK_SIGN_IDENTITY（Developer ID Application 憑證名稱）}"

# 發行的版本一定要在變更紀錄裡有一節，免得發了新版卻沒寫改了什麼。
RELEASE_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
if ! grep -qE "^## ${RELEASE_VERSION//./\\.}( |$)" "$ROOT_DIR/CHANGELOG.md"; then
  echo "CHANGELOG.md 沒有「## ${RELEASE_VERSION}」這一節。先寫這一版的變更再發行。" >&2
  exit 1
fi

GOSHAWK_UNIVERSAL=1 bash "$ROOT_DIR/scripts/build-app.sh"

APP="$ROOT_DIR/dist/GoshawkIME.app"
DMG="$ROOT_DIR/dist/GoshawkIME.dmg"
BG_IMAGE="$ROOT_DIR/artwork/dmg-background.png"
VOLNAME="蒼鷹輸入法"
STAGE="$(mktemp -d)"
RW_DMG="$STAGE/GoshawkIME-rw.dmg"
MOUNT_DIR=""

cleanup() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet || true
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT

# 先公證 App 並把票據釘在它身上，再裝進 dmg。只公證 dmg 的話，裡面的 App 要靠線上查詢，
# 公證完成後的頭一兩分鐘與離線的電腦會把它判定為未公證而拒絕開啟。
if [[ -n "${GOSHAWK_NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP" "$STAGE/GoshawkIME.zip"
  xcrun notarytool submit "$STAGE/GoshawkIME.zip" --keychain-profile "$GOSHAWK_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$STAGE/GoshawkIME.zip"
fi

CONTENT_DIR="$STAGE/content"
mkdir -p "$CONTENT_DIR/.background"
cp -R "$APP" "$CONTENT_DIR/"
if [[ -f "$BG_IMAGE" ]]; then
  cp "$BG_IMAGE" "$CONTENT_DIR/.background/background.png"
fi

# 先建立可讀寫映像並套用 Finder 視窗版面（600x360、隱藏工具列、品牌底圖、置中圖示），再轉成唯讀壓縮檔。
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$CONTENT_DIR" -ov -format UDRW "$RW_DMG"

if [[ -f "$BG_IMAGE" ]]; then
  ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
  MOUNT_DIR="$(echo "$ATTACH_OUT" | awk '/\/Volumes\// { idx = index($0, "/Volumes/"); print substr($0, idx); exit }')"
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    MOUNT_NAME="$(basename "$MOUNT_DIR")"
    if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$MOUNT_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 160, 800, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.png"
    set position of item "GoshawkIME.app" of container window to {300, 136}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
    then
      echo "警告：無法透過 Finder 套用 DMG 視窗版面（可能是非圖形工作階段），將保留預設版面。" >&2
    fi
    sync
    hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet
    MOUNT_DIR=""
  fi
fi

rm -f "$DMG"
hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"
codesign --force --timestamp --sign "$GOSHAWK_SIGN_IDENTITY" "$DMG"

if [[ -n "${GOSHAWK_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$GOSHAWK_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
else
  echo "未公證：沒有設定 GOSHAWK_NOTARY_PROFILE。這份 dmg 不能發行。" >&2
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "已產生 ${DMG}（版本 ${VERSION}，$(lipo -archs "$APP/Contents/MacOS/GoshawkApp")）"
