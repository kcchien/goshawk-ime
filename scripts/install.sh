#!/usr/bin/env bash
# 下載已簽章的發行版並安裝到目前使用者。不需要 Xcode，也不需要管理員權限。
#
#   curl -fsSL https://raw.githubusercontent.com/kcchien/goshawk-ime/main/scripts/install.sh | bash
#
# GOSHAWK_DMG_URL 可以換成別的 dmg 位置（含 file://），簽章檢查不會因此放寬。
set -euo pipefail

DMG_URL="${GOSHAWK_DMG_URL:-https://github.com/kcchien/goshawk-ime/releases/latest/download/GoshawkIME.dmg}"
TEAM_ID="DPNCSH8U5S"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "蒼鷹輸入法只支援 macOS。" >&2
  exit 1
fi
if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]]; then
  echo "需要 macOS 14 以上，這台是 $(sw_vers -productVersion)。" >&2
  exit 1
fi

WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
cleanup() {
  hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "下載 $DMG_URL"
curl -fL --progress-bar -o "$WORK/GoshawkIME.dmg" "$DMG_URL"
mkdir "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$WORK/GoshawkIME.dmg"

APP="$MOUNT/GoshawkIME.app"
codesign --verify --deep --strict "$APP"
SIGNED_BY="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ "$SIGNED_BY" != "$TEAM_ID" ]]; then
  echo "簽章的開發者不符：預期 ${TEAM_ID}，實際是 ${SIGNED_BY:-無}。已停止，沒有安裝任何東西。" >&2
  exit 1
fi

"$APP/Contents/MacOS/GoshawkApp" --install
echo "從選單列的輸入法選單選「蒼鷹輸入法」就能開始打字。"
echo "選單裡沒有的話：系統設定 → 鍵盤 → 文字輸入 → 編輯 → ＋ → 繁體中文。"
