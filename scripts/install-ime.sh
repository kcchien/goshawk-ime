#!/usr/bin/env bash
# 從原始碼建置並安裝到目前使用者。需要 Swift 6 工具鏈。
# 不想建置的人用 scripts/install.sh，它下載已簽章的發行版。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$ROOT_DIR/scripts/build-app.sh"
rm -rf "$HOME/Library/Input Methods/KCIME.app"  # 2026-11-19 改名前的安裝位置
"$ROOT_DIR/dist/GoshawkIME.app/Contents/MacOS/GoshawkApp" --install
