#!/usr/bin/env bash
# 產生發行用的 dist/GoshawkIME.dmg：通用執行檔、Developer ID 簽章，給了公證設定就一併公證。
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
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 先公證 App 並把票據釘在它身上，再裝進 dmg。只公證 dmg 的話，裡面的 App 要靠線上查詢，
# 公證完成後的頭一兩分鐘與離線的電腦會把它判定為未公證而拒絕開啟。
if [[ -n "${GOSHAWK_NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP" "$STAGE/GoshawkIME.zip"
  xcrun notarytool submit "$STAGE/GoshawkIME.zip" --keychain-profile "$GOSHAWK_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$STAGE/GoshawkIME.zip"
fi

cp -R "$APP" "$STAGE/"
rm -f "$DMG"
hdiutil create -quiet -volname "蒼鷹輸入法" -srcfolder "$STAGE" -format UDZO "$DMG"
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
