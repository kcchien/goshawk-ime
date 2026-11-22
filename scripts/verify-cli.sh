#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

EVIDENCE_DIR="$ROOT_DIR/.scratch/verify-goshawk"
TMP_MARKER="/tmp/goshawk-verify-$$.tmp"
mkdir -p "$EVIDENCE_DIR"

cleanup() {
  rm -f "$TMP_MARKER"
}
trap cleanup EXIT

echo "[1/5] Launch: building GoshawkCLI and packaging GoshawkIME.app..."
swift build --product GoshawkCLI
BIN_DIR="$(swift build --show-bin-path)"
CLI="$BIN_DIR/GoshawkCLI"
test -x "$CLI"
bash "$ROOT_DIR/scripts/build-app.sh" >/dev/null
APP_BIN="$ROOT_DIR/dist/GoshawkIME.app/Contents/MacOS/GoshawkApp"
test -x "$APP_BIN"
# 隨附詞庫的授權要求顯名，散布的套件缺了授權與來源聲明就不算通過。
APP_RESOURCES="$ROOT_DIR/dist/GoshawkIME.app/Contents/Resources"
test -s "$APP_RESOURCES/LICENSE"
test -s "$APP_RESOURCES/THIRD_PARTY_NOTICES.md"
grep -q "MIT License" "$APP_RESOURCES/LICENSE"
grep -q "Public Domain" "$APP_RESOURCES/THIRD_PARTY_NOTICES.md"
grep -q "Creative Commons Attribution 3.0" "$APP_RESOURCES/THIRD_PARTY_NOTICES.md"
grep -q "政府資料開放授權條款" "$APP_RESOURCES/THIRD_PARTY_NOTICES.md"
# Unicode License v3 要求著作權與許可聲明隨副本或說明文件一起散布。
grep -q "Copyright © 1991-2026 Unicode, Inc." "$APP_RESOURCES/THIRD_PARTY_NOTICES.md"
# 英文系統要看到英文名稱與英文介面，所以英文語系的兩份字串檔都得在。
test -s "$APP_RESOURCES/en.lproj/InfoPlist.strings"
test -s "$APP_RESOURCES/en.lproj/Localizable.strings"
plutil -convert json -o "$EVIDENCE_DIR/strings-en-infoplist.json" "$APP_RESOURCES/en.lproj/InfoPlist.strings"
plutil -convert json -o "$EVIDENCE_DIR/strings-en-localizable.json" "$APP_RESOURCES/en.lproj/Localizable.strings"
plutil -convert json -o "$EVIDENCE_DIR/strings-zh-hant-infoplist.json" "$APP_RESOURCES/zh-Hant.lproj/InfoPlist.strings"
plutil -convert json -o "$EVIDENCE_DIR/strings-zh-tw-infoplist.json" "$APP_RESOURCES/zh_TW.lproj/InfoPlist.strings"
plutil -convert json -o "$EVIDENCE_DIR/app-info-plist.json" "$ROOT_DIR/dist/GoshawkIME.app/Contents/Info.plist"

echo "[2/5] Doctor: checking CLI health and full lexicon..."
DOCTOR_JSON="$("$CLI" --doctor)"
echo "$DOCTOR_JSON" > "$EVIDENCE_DIR/doctor.json"

python3 - "$DOCTOR_JSON" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["status"] == "ok", doc
assert doc["cangjieV5Codes"] > 10_000, doc
assert doc["cangjieV3Codes"] > 10_000, doc
assert doc["englishWords"] > 9_000, doc
assert doc["readingSyllables"] > 400, doc
assert doc["readingTonedSyllables"] > 1_200, doc
assert doc["readingCharacters"] > 10_000, doc
assert doc["sampleDualSpace"] == "下", doc
assert doc["sampleDualTab"] == "my ", doc
PY

echo "[3/5] Drive: executing mapped feature scenarios..."
"$CLI" --script "m y SPACE" --evidence-out "$EVIDENCE_DIR/case-cangjie-space.json" >/dev/null
"$CLI" --script "i d TAB" --evidence-out "$EVIDENCE_DIR/case-short-tab.json" >/dev/null
"$CLI" --script "n o t BKSP" --evidence-out "$EVIDENCE_DIR/dual-track.json" >/dev/null
"$CLI" --script "o n f SPACE v n d SPACE h e l l o TAB COMMA SPACE w o r l d TAB BANG" --evidence-out "$EVIDENCE_DIR/auto-space.json" >/dev/null
"$CLI" --script "h e l l o TAB LPAREN o n f SPACE RPAREN" --evidence-out "$EVIDENCE_DIR/case-paren-pair.json" >/dev/null
"$CLI" --script "DBL_SHIFT m y SPACE DBL_SHIFT m y SPACE" --evidence-out "$EVIDENCE_DIR/modes.json" >/dev/null
"$CLI" --script "k 8 TAB" --evidence-out "$EVIDENCE_DIR/case-k8s.json" >/dev/null
"$CLI" --script "n o DOWN SPACE" --evidence-out "$EVIDENCE_DIR/case-cand-arrow.json" >/dev/null
"$CLI" --script "m y SHIFT_2" --evidence-out "$EVIDENCE_DIR/case-shift2.json" >/dev/null
"$CLI" --script "m y . f i l e ENTER" --evidence-out "$EVIDENCE_DIR/case-dotted-name.json" >/dev/null
"$CLI" --script "m y SPACE ." --evidence-out "$EVIDENCE_DIR/case-chinese-period.json" >/dev/null
"$CLI" --script ". / b u i l d . s h ENTER" --evidence-out "$EVIDENCE_DIR/case-path-period.json" >/dev/null
"$CLI" --script "c d ENTER SPACE . ." --evidence-out "$EVIDENCE_DIR/case-manual-space-period.json" >/dev/null
"$CLI" --script "DQUOTE h e l l o DQUOTE LBRACKET RBRACKET LBRACE RBRACE" --evidence-out "$EVIDENCE_DIR/case-quotes-brackets.json" >/dev/null
"$CLI" --script "m y OPT_." --evidence-out "$EVIDENCE_DIR/case-option-period.json" >/dev/null
"$CLI" --script "m y CAPS_ON . f i l e CAPS_OFF SPACE m y SPACE" --evidence-out "$EVIDENCE_DIR/case-caps-lock.json" >/dev/null
"$CLI" --script "m y SHIFT_SPACE ." --evidence-out "$EVIDENCE_DIR/case-shift-space.json" >/dev/null
"$CLI" --script "f u n c SHIFT_2 f u n c TAB i d TAB" --evidence-out "$EVIDENCE_DIR/case-english-learning.json" >/dev/null
"$CLI" --script "m y LOOKUP h j i 4 ESC SPACE" --evidence-out "$EVIDENCE_DIR/case-reading-escape.json" >/dev/null
"$CLI" --script "m y LOOKUP h j i 4 DOWN DOWN DOWN DOWN DOWN ENTER m y SPACE" --evidence-out "$EVIDENCE_DIR/case-reading-pick.json" >/dev/null
"$CLI" --script "m y LOOKUP TAB c u o 4 PICK_5" --evidence-out "$EVIDENCE_DIR/case-reading-pinyin.json" >/dev/null
"$CLI" --script "n o DOWN LOOKUP h j i ESC SPACE" --evidence-out "$EVIDENCE_DIR/case-reading-selecting.json" >/dev/null
"$CLI" --script "o j DOWN SPACE o j DOWN SPACE o j SPACE" --evidence-out "$EVIDENCE_DIR/case-cangjie-learning.json" >/dev/null
"$CLI" --script "LOOKUP 1 i SPACE DOWN 2 LOOKUP 1 i SPACE" --evidence-out "$EVIDENCE_DIR/case-reading-learning.json" >/dev/null
"$CLI" --script "m y SPACE SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-revert-to-english.json" >/dev/null
"$CLI" --script "m y SPACE SHIFT_SPACE SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-revert-twice.json" >/dev/null
"$CLI" --script "m y TAB SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-revert-to-chinese.json" >/dev/null
"$CLI" --script "m y SPACE m y SPACE SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-revert-spacing.json" >/dev/null
"$CLI" --script "m y SPACE SHIFT_SPACE COMMA" --evidence-out "$EVIDENCE_DIR/case-revert-comma.json" >/dev/null
"$CLI" --script "m y SPACE a BKSP SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-revert-expired.json" >/dev/null
"$CLI" --script "o j DOWN SPACE SHIFT_SPACE SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-revert-focused.json" >/dev/null
# 打完標點立刻按 Shift+空白 對調它的寬度。
"$CLI" --script "i d TAB COMMA SHIFT_SPACE SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-width-english.json" >/dev/null
"$CLI" --script "m y SPACE PERIOD SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-width-chinese.json" >/dev/null
"$CLI" --script "m y PERIOD SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-width-prefix.json" >/dev/null
"$CLI" --script "m p 3 BACKSLASH SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-width-backslash.json" >/dev/null
"$CLI" --script "v 2 : SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-width-colon.json" >/dev/null
"$CLI" --script "BACKTICK i d SPACE COMMA SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-width-snippet.json" >/dev/null
"$CLI" --script "i d ENTER CTRL_SEMICOLON CTRL_BANG CTRL_QUESTION CTRL_LPAREN CTRL_RPAREN CTRL_BACKSLASH" --evidence-out "$EVIDENCE_DIR/case-ctrl-fullwidth.json" >/dev/null
# 行內程式片段語境。反引號在這裡寫成 BACKTICK，才不會被 shell 當成命令替換。
"$CLI" --script "BACKTICK i d SPACE BACKTICK" --evidence-out "$EVIDENCE_DIR/case-snippet-space.json" >/dev/null
"$CLI" --script "BACKTICK i d TAB" --evidence-out "$EVIDENCE_DIR/case-snippet-tab.json" >/dev/null
"$CLI" --script "m y SPACE BACKTICK i d SPACE BACKTICK PERIOD" --evidence-out "$EVIDENCE_DIR/case-snippet-transparent-zh.json" >/dev/null
"$CLI" --script "i d TAB BACKTICK m y BACKTICK PERIOD" --evidence-out "$EVIDENCE_DIR/case-snippet-transparent-en.json" >/dev/null
"$CLI" --script "BACKTICK m y SHIFT_SPACE SPACE i d SPACE" --evidence-out "$EVIDENCE_DIR/case-snippet-sticky-zh.json" >/dev/null
"$CLI" --script "BACKTICK m y SPACE SHIFT_SPACE SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-snippet-revert.json" >/dev/null
"$CLI" --script "BACKTICK o j DIGIT2 ENTER o j DIGIT2" --evidence-out "$EVIDENCE_DIR/case-snippet-newline-reset.json" >/dev/null
# 符號面板。SYMBOLS 是開關鍵，面板裡的數字、方向鍵、Enter、Tab 與 Esc 都歸面板。
"$CLI" --script "m y SYMBOLS ESC SPACE" --evidence-out "$EVIDENCE_DIR/case-symbols-escape.json" >/dev/null
"$CLI" --script "m y SYMBOLS 8 m y SPACE" --evidence-out "$EVIDENCE_DIR/case-symbols-digit.json" >/dev/null
"$CLI" --script "SYMBOLS DOWN DOWN ENTER" --evidence-out "$EVIDENCE_DIR/case-symbols-arrow-enter.json" >/dev/null
"$CLI" --script "SYMBOLS TAB TAB TAB TAB PGDN 2" --evidence-out "$EVIDENCE_DIR/case-symbols-tab.json" >/dev/null
"$CLI" --script "SYMBOLS 8 SYMBOLS 9 SYMBOLS ESC" --evidence-out "$EVIDENCE_DIR/case-symbols-recent.json" >/dev/null
"$CLI" --script "i d TAB SYMBOLS TAB 4" --evidence-out "$EVIDENCE_DIR/case-symbols-collapse.json" >/dev/null
# 右方括號跟隨游標前未關閉的開頭，不論開頭是哪個鍵打出來的。
"$CLI" --script "CTRL_SHIFT_LBRACKET m y SPACE RBRACKET" --evidence-out "$EVIDENCE_DIR/case-pair-ctrl-opener.json" >/dev/null
"$CLI" --script "LBRACKET LBRACE a SPACE RBRACKET RBRACKET" --evidence-out "$EVIDENCE_DIR/case-pair-nested.json" >/dev/null
"$CLI" --context "中" --script "BACKTICK LBRACKET SHIFT_SPACE x RBRACKET RBRACKET" --evidence-out "$EVIDENCE_DIR/case-pair-snippet.json" >/dev/null
"$CLI" --script "LBRACKET SHIFT_SPACE SHIFT_SPACE m y SPACE RBRACKET" --evidence-out "$EVIDENCE_DIR/case-pair-opener-cycle.json" >/dev/null
"$CLI" --script "LBRACKET SHIFT_SPACE 1 RBRACKET" --evidence-out "$EVIDENCE_DIR/case-pair-opener-digit.json" >/dev/null
"$CLI" --script "LBRACKET m y SPACE RBRACKET SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-pair-switch.json" >/dev/null
"$CLI" --script "i d TAB LBRACKET i d TAB RBRACKET SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-pair-switch-spaces.json" >/dev/null
"$CLI" --script "LBRACKET m y SPACE RBRACKET SHIFT_SPACE SHIFT_SPACE 4" --evidence-out "$EVIDENCE_DIR/case-pair-digit-pick.json" >/dev/null
"$CLI" --script "LBRACKET m y SPACE RBRACKET SHIFT_SPACE 4 4 SHIFT_SPACE" --evidence-out "$EVIDENCE_DIR/case-pair-digit-once.json" >/dev/null

# 讀音反查索引是唯讀查詢，不算進上面的組字劇本數量。
"$CLI" --reading "hji4" --scheme dachen --version v5 > "$EVIDENCE_DIR/reading-cuo-dachen.json"
"$CLI" --reading "cuo4" --scheme pinyin --version v5 > "$EVIDENCE_DIR/reading-cuo-pinyin.json"
"$CLI" --reading "yk3" --scheme dachen --version v5 > "$EVIDENCE_DIR/reading-zen-v5.json"
"$CLI" --reading "zen3" --scheme pinyin --version v3 > "$EVIDENCE_DIR/reading-zen-v3.json"

# 補完只有在使用者啟用並明確採用時才改變送出文字。
"$CLI" --context "用 SQL 查詢資" --chinese-continuation --script "f d y j SPACE ACCEPT_CONTINUATION" --evidence-out "$EVIDENCE_DIR/case-chinese-continuation.json" >/dev/null
"$CLI" --context "存放檔案的資" --chinese-continuation --script "f d y j SPACE i d TAB" --evidence-out "$EVIDENCE_DIR/case-ignored-continuation.json" >/dev/null
"$CLI" --personal-term GoshawkIME --script "g o s h a w TAB i d TAB" --evidence-out "$EVIDENCE_DIR/case-personal-term.json" >/dev/null

# 同一批案例要能辨別兩種排序各自猜對、猜錯和應該安靜的情況。
printf '%s\t%s\n' 'SQL 資料' '庫' '交易資料' '夾' '新增檔案' '內容' \
    '未知' '字' '另一段資料' '' '這場大雨' '' > "$EVIDENCE_DIR/continuation-cases.tsv"
"$CLI" --evaluate-continuation "$EVIDENCE_DIR/continuation-cases.tsv" > "$EVIDENCE_DIR/continuation-evaluation.json"

echo "[4/5] Benchmark & App Self-Test: measuring release latency, RSS, and IMK controller..."
swift build -c release --product GoshawkCLI >/dev/null
RELEASE_CLI="$(swift build -c release --show-bin-path)/GoshawkCLI"
"$RELEASE_CLI" --benchmark > "$EVIDENCE_DIR/benchmark.json"
"$APP_BIN" --self-test > "$EVIDENCE_DIR/app-self-test.json"

echo "[5/5] Evidence: verifying assertions and summarizing proof..."
touch "$TMP_MARKER"
python3 - "$EVIDENCE_DIR" "$EVIDENCE_DIR/latest-proof.json" <<'PY'
import json, pathlib, re, sys

edir = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])

# 還沒選過任何符號時，符號面板「最近使用」分頁的九列，都是鍵盤直接打不出來的符號。
INITIAL_RECENT = ["——", "……", "‧", "〔", "〕", "※", "→", "×", "±"]
# 「標點」與「符號」分頁的第一頁。
PUNCTUATION_FIRST_PAGE = ["。", "．", ".", "，", ",", "、", "；", ";", "："]
SYMBOLS_FIRST_PAGE = ["【", "】", "〔", "〕", "［", "］", "｛", "｝", "〖"]


def panel_symbols(step):
    return [row["symbol"] for row in step["symbolPanel"]["rows"]]


checks = [
    ("case-chinese-continuation.json", "用 SQL 查詢資料庫", lambda d: d["steps"][4]["chineseContinuation"] == "庫"),
    ("case-ignored-continuation.json", "存放檔案的資料 id ", lambda d: d["steps"][4]["chineseContinuation"] == "夾"
        and d["steps"][5].get("chineseContinuation") is None),
    ("case-personal-term.json", "GoshawkIME id ", lambda d: d["steps"][5]["englishPredictions"][0] == "GoshawkIME"
        and d["steps"][-2]["englishPredictions"][0] == "id"),
    ("case-cangjie-space.json", "下", lambda d: d["steps"][1]["state"] == "composingDual"),
    ("case-short-tab.json", "id ", lambda d: d["steps"][1]["englishPredictions"][0] == "id"),
    ("dual-track.json", "", lambda d: d["steps"][2]["state"] == "composingEnglishOnly" and d["steps"][3]["state"] == "composingDual" and d["steps"][3]["buffer"] == "no"),
    ("auto-space.json", "你好 hello, world!", lambda d: all(s["deletedBackwardCount"] == 1 for s in d["steps"] if s["token"] in ("COMMA", "BANG"))),
    ("case-paren-pair.json", "hello (你)", lambda d: True),
    ("modes.json", "my 下", lambda d: d["steps"][0]["state"] == "pureEnglish" and d["steps"][4]["state"] == "idle"),
    ("case-k8s.json", "k8s ", lambda d: d["steps"][1]["state"] == "composingEnglishOnly"),
    ("case-cand-arrow.json", "欠", lambda d: d["steps"][2]["state"] == "selectingCandidate"),
    ("case-shift2.json", "myself ", lambda d: d["steps"][1]["englishPredictions"][1] == "myself"),
    ("case-dotted-name.json", "my.file", lambda d: d["steps"][2]["committedText"] == "my." and d["steps"][2]["deletedBackwardCount"] == 0),
    ("case-chinese-period.json", "下。", lambda d: True),
    ("case-path-period.json", "./build.sh", lambda d: all(s["deletedBackwardCount"] == 0 for s in d["steps"])),
    ("case-manual-space-period.json", "cd ..", lambda d: all(s["deletedBackwardCount"] == 0 for s in d["steps"])),
    ("case-quotes-brackets.json", "\"hello\"「」『』", lambda d: True),
    ("case-option-period.json", "my.", lambda d: d["steps"][2]["committedText"] == "my."),
    ("case-caps-lock.json", "my.file 下", lambda d: d["steps"][2]["committedText"] == "my" and d["steps"][2]["state"] == "idle"),
    ("case-shift-space.json", "下。", lambda d: d["steps"][2]["state"] == "selectingCandidate" and d["steps"][2]["buffer"] == "my"),
    ("case-english-learning.json", "functions functions id ", lambda d: d["steps"][3]["englishPredictions"][0] == "function" and d["steps"][8]["englishPredictions"][0] == "functions"),
    # 讀音反查：取消後原組字一個字元都沒變，宿主也沒收到查詢字元。
    ("case-reading-escape.json", "下", lambda d: all(s["buffer"] == "my" for s in d["steps"][1:8])
        and all(s.get("committedText") is None for s in d["steps"][2:8])
        and d["steps"][6]["readingLookupPanel"]["inputDisplay"] == "ㄘㄨㄛˋ"
        and d["steps"][7].get("readingLookupPanel") is None),
    # 「厝」是第 5 個候選：選它只送出一次，下一個 my 回到雙軌。
    ("case-reading-pick.json", "厝下", lambda d: d["documentText"].count("厝") == 1
        and d["steps"][11]["readingLookupPanel"]["focusedRow"] == 4
        and d["steps"][12]["committedText"] == "厝"
        and d["steps"][12].get("readingLookupPanel") is None),
    # 拼音查同一個讀音，點第 5 列選「厝」，面板列出原生碼與字根。
    ("case-reading-pinyin.json", "厝", lambda d: d["steps"][3]["readingLookupPanel"]["scheme"] == "pinyin"
        and d["steps"][7]["readingLookupPanel"]["rows"][4] == {
            "number": 5, "character": "厝", "code": "mta", "radicals": "一廿日", "directInputAvailable": True}),
    # 選字中開反查再取消，焦點仍在原候選，空白鍵送出「欠」。
    ("case-reading-selecting.json", "欠", lambda d: d["steps"][2]["state"] == "selectingCandidate"
        and d["steps"][3]["readingLookupPanel"]["status"] == "empty"
        and d["steps"][7].get("readingLookupPanel") is None),
    # 倉頡重碼學習：`oj` 原本先出「午」，送出「什」兩次之後，第三輪的空白鍵就送「什」。
    ("case-cangjie-learning.json", "什什什", lambda d: d["steps"][1]["cangjieCandidates"] == ["午", "什"]
        and d["steps"][5]["cangjieCandidates"] == ["午", "什"]
        and d["steps"][9]["cangjieCandidates"] == ["什", "午"]
        and d["steps"][10]["committedText"] == "什"),
    # 讀音反查學習：ㄅㄛ 一聲原本先出「玻」，選過「波」之後它排第一。
    ("case-reading-learning.json", "波", lambda d:
        [r["character"] for r in d["steps"][3]["readingLookupPanel"]["rows"][:3]] == ["玻", "波", "剝"]
        and d["steps"][5]["committedText"] == "波"
        and d["steps"][9]["readingLookupPanel"]["rows"][0]["character"] == "波"),
    # 一鍵反悔：空白送出「下」後 Shift+空白 換成英文，回刪的是整個「下」。
    ("case-revert-to-english.json", "my ", lambda d: d["steps"][2]["revertible"]
        and d["steps"][2]["revertPreview"] == "my"
        and d["steps"][3]["committedText"] == "my " and d["steps"][3]["deletedBackwardCount"] == 1
        and d["steps"][3]["revertible"] and d["steps"][3]["revertPreview"] == "下"),
    # 再按一次換回來，回刪的是 `my ` 三個字元。
    ("case-revert-twice.json", "下", lambda d: d["steps"][4]["committedText"] == "下"
        and d["steps"][4]["deletedBackwardCount"] == 3 and d["steps"][4]["revertPreview"] == "my"),
    # Tab 送出英文後反悔成中文。
    ("case-revert-to-chinese.json", "下", lambda d: d["steps"][2]["committedText"] == "my "
        and d["steps"][2]["revertPreview"] == "下"
        and d["steps"][3]["commitKind"] == "chinese" and d["steps"][3]["deletedBackwardCount"] == 3),
    # 中文後面對調成英文：中英之間補一格，與直接按 Tab 相同。
    ("case-revert-spacing.json", "下 my ", lambda d: d["steps"][6]["committedText"] == " my "
        and d["steps"][6]["deletedBackwardCount"] == 1),
    # 反悔成英文後接逗號，尾端空格照常收合；逗號自己留下的是寬度對調的紀錄，不顯示提示。
    ("case-revert-comma.json", "my,", lambda d: d["steps"][4]["deletedBackwardCount"] == 1
        and d["steps"][4]["revertible"] and d["steps"][4].get("revertPreview") is None),
    # 送出後按了別的鍵，Shift+空白 只是空白，不回刪。
    ("case-revert-expired.json", "下 ", lambda d: not d["steps"][3]["revertible"]
        and d["steps"][5]["committedText"] == " " and d["steps"][5]["deletedBackwardCount"] == 0
        and not d["steps"][5]["revertible"]),
    # 聚焦第二個候選時送出、反悔、再反悔，回到第二個字。
    ("case-revert-focused.json", "什", lambda d: d["steps"][3]["committedText"] == "什"
        and d["steps"][4]["committedText"] == "oj " and d["steps"][5]["committedText"] == "什"
        and d["steps"][5]["deletedBackwardCount"] == 3),
    # 片段裡英文優先：`id` 加空白得 `id `，浮窗標英文軌並標出片段。
    ("case-snippet-space.json", "`id `", lambda d: d["steps"][0]["snippet"] == "inside:-"
        and d["steps"][1]["inCodeSnippet"] and d["steps"][1]["spaceCommits"] == "english"
        and d["steps"][2]["cangjieCandidates"][0] == "床"
        and d["steps"][3]["committedText"] == "id " and d["steps"][3]["commitKind"] == "rawEnglish"
        and not d["steps"][3]["pendingAutoSpace"]
        and d["steps"][4]["snippet"] == "just-closed:-"),
    # 片段裡的 Tab 不附尾端空格。
    ("case-snippet-tab.json", "`id", lambda d: d["steps"][3]["committedText"] == "id"
        and not d["steps"][3]["pendingAutoSpace"]),
    # 透明：漢字後面的片段，關上後第一個句點出全形。
    ("case-snippet-transparent-zh.json", "下`id `。", lambda d: d["steps"][2]["snippet"] == "none"
        and d["steps"][3]["snippet"] == "inside:下"
        and d["steps"][7]["snippet"] == "just-closed:下"
        and d["steps"][8]["committedText"] == "。"
        and d["steps"][8]["deletedBackwardCount"] == 0),
    # 透明：英數後面的片段，關上後第一個句點出半形。
    ("case-snippet-transparent-en.json", "id `my`.", lambda d: d["steps"][3]["snippet"] == "inside:d"
        and d["steps"][7]["committedText"] == "." and d["steps"][7]["deletedBackwardCount"] == 0),
    # 黏中：片段裡聚焦候選選字之後，空白鍵回到中文優先，中英之間不補空格。
    ("case-snippet-sticky-zh.json", "`下床", lambda d: d["steps"][4]["committedText"] == "下"
        and d["steps"][4]["snippet"] == "inside+zh:-"
        and d["steps"][5]["spaceCommits"] == "chinese"
        and d["steps"][7]["committedText"] == "床"),
    # 片段裡的一鍵反悔：來回對調，回刪的是上一次送出的完整文字。
    ("case-snippet-revert.json", "`my ", lambda d: d["steps"][3]["committedText"] == "my "
        and d["steps"][3]["revertible"] and d["steps"][3]["revertPreview"] == "下"
        and d["steps"][4]["committedText"] == "下" and d["steps"][4]["deletedBackwardCount"] == 3
        and d["steps"][4]["snippet"] == "inside+zh:-"
        and d["steps"][5]["committedText"] == "my " and d["steps"][5]["deletedBackwardCount"] == 1
        and d["steps"][5]["snippet"] == "inside:-"),
    # 片段裡數字不選字；閒置時交給宿主的 Enter 換行會離開片段，之後數字照常選字。
    ("case-snippet-newline-reset.json", "什", lambda d: d["steps"][3]["documentText"] == "`oj2"
        and d["steps"][4]["snippet"] == "none"
        and d["steps"][7]["committedText"] == "什"),
    # 標點寬度對調：英數後的半形逗號換成全形，收合掉的那一格不會跑回來，再按一次換回去。
    # 可反悔但不顯示提示。
    ("case-width-english.json", "id,", lambda d: d["steps"][3]["documentText"] == "id,"
        and d["steps"][3]["deletedBackwardCount"] == 1
        and d["steps"][3]["revertible"] and d["steps"][3].get("revertPreview") is None
        and d["steps"][4]["committedText"] == "，" and d["steps"][4]["deletedBackwardCount"] == 1
        and d["steps"][4]["documentText"] == "id，"
        and d["steps"][5]["committedText"] == "," and d["steps"][5]["documentText"] == "id,"),
    # 中文後的全形句點換成半形。
    ("case-width-chinese.json", "下.", lambda d: d["steps"][3]["committedText"] == "。"
        and d["steps"][4]["committedText"] == "." and d["steps"][4]["deletedBackwardCount"] == 1),
    # 連帶送出的原字母不動，只換句點：回刪整段 `my.` 再接上 `my。`。
    ("case-width-prefix.json", "my。", lambda d: d["steps"][2]["committedText"] == "my."
        and d["steps"][3]["committedText"] == "my。" and d["steps"][3]["deletedBackwardCount"] == 3),
    # 沒有鍵可按的位置：`mp3\` 一鍵換成 `mp3、`。
    ("case-width-backslash.json", "mp3、", lambda d: d["steps"][3]["documentText"] == "mp3\\"
        and d["steps"][4]["committedText"] == "mp3、" and d["steps"][4]["deletedBackwardCount"] == 4),
    # 冒號沒有 Ctrl 鍵（`Ctrl+Shift+;` 是讀音反查），走對調：`v2:` 換成 `v2：`。
    ("case-width-colon.json", "v2：", lambda d: d["steps"][2]["documentText"] == "v2:"
        and d["steps"][3]["committedText"] == "：" and d["steps"][3]["deletedBackwardCount"] == 1),
    # 片段裡的半形標點也能換成全形，片段語境與那一格內容空格都不動。
    ("case-width-snippet.json", "`id ，", lambda d: d["steps"][4]["documentText"] == "`id ,"
        and d["steps"][5]["committedText"] == "，" and d["steps"][5]["deletedBackwardCount"] == 1
        and d["steps"][5]["snippet"] == "inside:-"),
    # Ctrl 全形標點的新鍵各出一個字，都不可反悔。
    ("case-ctrl-fullwidth.json", "id；！？（）、", lambda d: all(
        not s["revertible"] for s in d["steps"]) and all(
        s["deletedBackwardCount"] == 0 for s in d["steps"])),
    # 符號面板：組字中開啟再取消，原組字一個字元都沒變，空白鍵照舊送出「下」。
    ("case-symbols-escape.json", "下", lambda d: all(s["buffer"] == "my" for s in d["steps"][1:4])
        and all(s["state"] == "composingDual" for s in d["steps"][1:4])
        and all(s.get("committedText") is None for s in d["steps"][:4])
        and d["steps"][2]["symbolPanel"]["tab"] == "recent"
        and panel_symbols(d["steps"][2]) == INITIAL_RECENT
        and d["steps"][2]["symbolPanel"]["focusedRow"] == 0
        and d["steps"][3].get("symbolPanel") is None
        and d["steps"][4]["committedText"] == "下"),
    # 組字中按數字直選：底下的 my 照逗號鍵的規則送出首選字「下」，與「×」一次送出，
    # 只送一次，不可反悔，下一個 my 回到雙軌。
    ("case-symbols-digit.json", "下×下", lambda d: d["documentText"].count("×") == 1
        and d["steps"][2]["symbolPanel"]["rows"][7]["symbol"] == "×"
        and d["steps"][2]["buffer"] == "my" and d["steps"][2].get("committedText") is None
        and d["steps"][3]["committedText"] == "下×" and d["steps"][3]["commitKind"] == "punctuation"
        and d["steps"][3]["deletedBackwardCount"] == 0 and not d["steps"][3]["revertible"]
        and d["steps"][3]["state"] == "idle" and d["steps"][3].get("symbolPanel") is None
        and d["steps"][5]["state"] == "composingDual"
        and d["steps"][6]["committedText"] == "下"),
    # 方向鍵移動焦點，Enter 送出焦點那一列；移動時文件不收到任何字。
    ("case-symbols-arrow-enter.json", "‧", lambda d:
        [s["symbolPanel"]["focusedRow"] for s in d["steps"][:3]] == [0, 1, 2]
        and all(s.get("committedText") is None for s in d["steps"][:3])
        and d["steps"][2]["symbolPanel"]["rows"][2]["symbol"] == "‧"
        and d["steps"][3]["committedText"] == "‧"
        and d["steps"][3].get("symbolPanel") is None),
    # Tab 依最近使用、標點、符號的順序輪流，第三次回到最近使用，每次焦點都回第一列。
    # 「標點」分頁列出標準標點的全形與半形寫法；翻到第 2 頁後數字選的是那一頁的列。
    ("case-symbols-tab.json", "「", lambda d:
        [s["symbolPanel"]["tab"] for s in d["steps"][:6]]
            == ["recent", "punctuation", "symbols", "recent", "punctuation", "punctuation"]
        and [s["symbolPanel"]["pageCount"] for s in d["steps"][:5]] == [1, 5, 13, 1, 5]
        and all(s["symbolPanel"]["focusedRow"] == 0 and s["symbolPanel"]["page"] == 1 for s in d["steps"][:5])
        and panel_symbols(d["steps"][0]) == INITIAL_RECENT
        and panel_symbols(d["steps"][1]) == PUNCTUATION_FIRST_PAGE
        and d["steps"][1]["symbolPanel"]["rows"][3] == {
            "number": 4, "symbol": "，", "name": "逗號", "englishName": "Fullwidth comma",
            "group": "逗號", "englishGroup": "Comma"}
        and d["steps"][1]["symbolPanel"]["rows"][4] == {
            "number": 5, "symbol": ",", "name": "半形逗號", "englishName": "Comma",
            "group": "逗號", "englishGroup": "Comma"}
        and panel_symbols(d["steps"][2]) == SYMBOLS_FIRST_PAGE
        and d["steps"][2]["symbolPanel"]["rows"][0] == {
            "number": 1, "symbol": "【", "name": "左方頭括號", "englishName": "Left black lenticular bracket",
            "group": "其他括號", "englishGroup": "Other brackets"}
        and panel_symbols(d["steps"][3]) == INITIAL_RECENT
        and d["steps"][5]["symbolPanel"]["page"] == 2
        and d["steps"][5]["symbolPanel"]["focusedRow"] == 0
        and panel_symbols(d["steps"][5]) == [":", "「", "」", "『", "』", "“", "”", "‘", "’"]
        and all(s.get("committedText") is None for s in d["steps"][:6])
        and d["steps"][6]["committedText"] == "「"),
    # 選過的符號下次排在「最近使用」第一列，其餘順序不變，清單不重複也不變長。
    ("case-symbols-recent.json", "×±", lambda d: panel_symbols(d["steps"][0]) == INITIAL_RECENT
        and d["steps"][1]["committedText"] == "×"
        and panel_symbols(d["steps"][2]) == ["×", "——", "……", "‧", "〔", "〕", "※", "→", "±"]
        and d["steps"][2]["symbolPanel"]["focusedRow"] == 0
        and d["steps"][3]["committedText"] == "±"
        and panel_symbols(d["steps"][4]) == ["±", "×", "——", "……", "‧", "〔", "〕", "※", "→"]
        and d["steps"][5].get("committedText") is None
        and d["steps"][5].get("symbolPanel") is None),
    # 英文後自動補上的那一格，開面板與切到「標點」分頁時都還在，選收尾標點時收合，只回刪那一格。
    ("case-symbols-collapse.json", "id，", lambda d: d["steps"][2]["documentText"] == "id "
        and d["steps"][4]["symbolPanel"]["tab"] == "punctuation"
        and panel_symbols(d["steps"][4]) == PUNCTUATION_FIRST_PAGE
        and all(s["pendingAutoSpace"] and s["documentText"] == "id "
                and s["deletedBackwardCount"] == 0 for s in d["steps"][2:5])
        and d["steps"][5]["committedText"] == "，" and d["steps"][5]["deletedBackwardCount"] == 1
        and not d["steps"][5]["pendingAutoSpace"] and not d["steps"][5]["revertible"]),
    # Ctrl+Shift+[ 送出的『不留紀錄，右方括號靠掃描前文配成』。
    ("case-pair-ctrl-opener.json", "『下』", lambda d: not d["steps"][0]["revertible"]
        and d["steps"][4]["committedText"] == "』" and d["steps"][4]["revertible"]),
    # 巢狀由內而外，各層是不同種類。
    ("case-pair-nested.json", "「『日』」", lambda d: d["steps"][4]["committedText"] == "』"
        and d["steps"][5]["committedText"] == "」"),
    # 片段裡先選好全形開頭，結尾跟著它；片段裡沒有開頭了就回到半形，不去關片段外的。
    ("case-pair-snippet.json", "中`「x」]", lambda d: d["steps"][2]["documentText"] == "中`「"
        and d["steps"][4]["committedText"] == "x」" and d["steps"][5]["committedText"] == "]"
        and d["steps"][5]["snippet"] != "none"),
    # 左方括號的 Shift+空白 走八種循環：第一下換寬度，第二下到雙角引號，結尾跟著選好的開頭。
    # 選項列只在切換之後出現，開頭側的數字不直選。
    ("case-pair-opener-cycle.json", "『下』", lambda d: d["steps"][0]["documentText"] == "「"
        and d["steps"][0]["revertible"] and d["steps"][0].get("pairChoice") is None
        and d["steps"][1]["documentText"] == "[" and d["steps"][1]["deletedBackwardCount"] == 1
        and d["steps"][1]["pairChoice"] == {"current": "square", "digitsPick": False}
        and d["steps"][2]["documentText"] == "『" and d["steps"][2]["revertible"]
        and d["steps"][2]["pairChoice"] == {"current": "doubleCorner", "digitsPick": False}
        and d["steps"][2].get("revertPreview") is None
        and d["steps"][3].get("pairChoice") is None
        and d["steps"][6]["committedText"] == "』"),
    # 守門：開頭切換之後的數字是內容，不拿來選種類。
    ("case-pair-opener-digit.json", "[1]", lambda d: d["steps"][1]["documentText"] == "["
        and d["steps"][2]["documentText"] == "[1" and d["steps"][2]["committedText"] == "1"
        and d["steps"][2].get("pairChoice") is None
        and d["steps"][3]["committedText"] == "]"),
    # 配到開頭的右方括號之後 Shift+空白：開頭與結尾一起換，回刪整段再送出整段。
    ("case-pair-switch.json", "[下]", lambda d: d["steps"][4]["documentText"] == "「下」"
        and d["steps"][4]["committedText"] == "」" and d["steps"][4]["revertible"]
        and d["steps"][4].get("pairChoice") is None
        and d["steps"][5]["committedText"] == "[下]" and d["steps"][5]["deletedBackwardCount"] == 3
        and d["steps"][5]["revertible"] and d["steps"][5].get("revertPreview") is None
        and d["steps"][5]["pairChoice"] == {"current": "square", "digitsPick": True}),
    # 成對切換不改空格數：結尾收合掉的那一格不回來，開頭前面那一格不動。
    ("case-pair-switch-spaces.json", "id 「id」", lambda d: d["steps"][7]["documentText"] == "id [id]"
        and d["steps"][7]["deletedBackwardCount"] == 1
        and d["steps"][8]["committedText"] == "「id」" and d["steps"][8]["deletedBackwardCount"] == 4
        and not d["steps"][8]["pendingAutoSpace"]),
    # 數字直選：緊接一次切換的數字跳到那個編號的種類，同樣回刪整段再送出整段；
    # 選完之後選項列留著，但不再顯示編號。
    ("case-pair-digit-pick.json", "《下》", lambda d: d["steps"][6]["documentText"] == "『下』"
        and d["steps"][6]["pairChoice"] == {"current": "doubleCorner", "digitsPick": True}
        and d["steps"][7]["committedText"] == "《下》" and d["steps"][7]["deletedBackwardCount"] == 3
        and d["steps"][7]["revertible"] and d["steps"][7].get("revertPreview") is None
        and d["steps"][7]["pairChoice"] == {"current": "doubleAngle", "digitsPick": False}),
    # 守門：選完之後的數字是內容，最多只吃掉一個；紀錄跟著那個數字結束，之後的 Shift+空白 是一般空白。
    ("case-pair-digit-once.json", "《下》4 ", lambda d: d["steps"][6]["documentText"] == "《下》"
        and d["steps"][7]["documentText"] == "《下》4" and d["steps"][7]["committedText"] == "4"
        and d["steps"][7]["deletedBackwardCount"] == 0 and d["steps"][7].get("pairChoice") is None
        and not d["steps"][7]["revertible"]
        and d["steps"][8]["committedText"] == " " and d["steps"][8]["deletedBackwardCount"] == 0),
]

summary = []
for fname, expected_doc, extra_pred in checks:
    data = json.loads((edir / fname).read_text(encoding="utf-8"))
    actual_doc = data["documentText"]
    assert actual_doc == expected_doc, f"{fname}: expected {expected_doc!r}, got {actual_doc!r}"
    assert extra_pred(data), f"{fname}: predicate failed"
    summary.append({
        "file": fname,
        "tokens": " ".join(data["tokens"]),
        "documentText": actual_doc,
        "finalState": data["finalState"],
        "passed": True,
    })

assert len(summary) == 63, f"劇本數量應為 63，實得 {len(summary)}"

# 兩種鍵盤查同一個讀音，面板第一頁必須一字不差。
dachen_rows = json.loads((edir / "case-reading-escape.json").read_text(encoding="utf-8"))["steps"][6]["readingLookupPanel"]["rows"]
pinyin_rows = json.loads((edir / "case-reading-pinyin.json").read_text(encoding="utf-8"))["steps"][7]["readingLookupPanel"]["rows"]
assert dachen_rows == pinyin_rows, "大千與拼音的面板第一頁不一致"


def reading(fname):
    return json.loads((edir / fname).read_text(encoding="utf-8"))


def candidate(doc, char):
    for item in doc["candidates"]:
        if item["character"] == char:
            return item
    raise AssertionError(f"{char} 不在候選中：{doc['keys']} {doc['scheme']}")


# 讀音反查：兩種鍵盤查「厝」須得到同一讀音與同一串候選，「怎」須顯示所選代別的原生碼。
cuo_dachen = reading("reading-cuo-dachen.json")
cuo_pinyin = reading("reading-cuo-pinyin.json")
for doc in (cuo_dachen, cuo_pinyin):
    assert doc["status"] == "syllable", doc
    assert doc["bopomofo"] == "ㄘㄨㄛ" and doc["tone"] == 4, doc
    assert doc["displayDachen"] == "ㄘㄨㄛˋ" and doc["displayPinyin"] == "cuo4", doc
    assert candidate(doc, "厝") == {
        "character": "厝",
        "nativeCodes": ["mta"],
        "radicals": ["一廿日"],
    }, doc
assert [c["character"] for c in cuo_dachen["candidates"]] == [
    c["character"] for c in cuo_pinyin["candidates"]
], "兩種鍵盤的候選順序不一致"

zen_v5 = reading("reading-zen-v5.json")
zen_v3 = reading("reading-zen-v3.json")
assert zen_v5["bopomofo"] == "ㄗㄜ" and zen_v5["tone"] == 3, zen_v5
assert zen_v3["bopomofo"] == "ㄗㄣ" and zen_v3["tone"] == 3, zen_v3
assert candidate(zen_v5, "怎")["nativeCodes"][0] == "osp", zen_v5
assert candidate(zen_v5, "怎")["radicals"][0] == "人尸心", zen_v5
assert candidate(zen_v3, "怎")["nativeCodes"][0] == "hsp", zen_v3
assert candidate(zen_v3, "怎")["radicals"][0] == "竹尸心", zen_v3

reading_proof = {
    "cuoDachen": cuo_dachen["displayDachen"],
    "cuoPinyin": cuo_pinyin["displayPinyin"],
    "cuoCandidates": len(cuo_dachen["candidates"]),
    "zenV5": candidate(zen_v5, "怎"),
    "zenV3": candidate(zen_v3, "怎"),
}

bench = json.loads((edir / "benchmark.json").read_text(encoding="utf-8"))
assert bench["status"] == "ok" and bench["p99Ms"] < 2.0 and bench["rssMB"] < 50.0, bench

app_self = json.loads((edir / "app-self-test.json").read_text(encoding="utf-8"))
assert app_self["status"] == "ok", app_self

ranking = json.loads((edir / "continuation-evaluation.json").read_text(encoding="utf-8"))
assert ranking["cases"] == 6 and ranking["contextOnlyHits"] == ranking["frequencyOnlyHits"] == 1, ranking
for arm in ("context", "frequencyOnly"):
    assert ranking[arm]["counts"] == dict(hits=1, wrongSuffixes=2, missedSuggestions=1,
                                          unwantedSuggestions=1, correctAbstentions=1), ranking
    assert ranking[arm]["suggestionPrecision"] == ranking[arm]["exactSuffixRecall"] == 0.25, ranking

# 語系：英文系統看到的三個名稱都是 Goshawk，中文兩個語系維持「蒼鷹輸入法」。
MODE_KEY = "com.kc.inputmethod.Goshawk.Cangjie"
en_info = json.loads((edir / "strings-en-infoplist.json").read_text(encoding="utf-8"))
assert en_info["CFBundleName"] == "Goshawk", en_info
assert en_info["CFBundleDisplayName"] == "Goshawk", en_info
assert en_info[MODE_KEY] == "Goshawk", en_info
for name in ("strings-zh-hant-infoplist.json", "strings-zh-tw-infoplist.json"):
    zh_info = json.loads((edir / name).read_text(encoding="utf-8"))
    assert zh_info[MODE_KEY] == "蒼鷹輸入法", (name, zh_info)
    assert zh_info["CFBundleDisplayName"] == "蒼鷹輸入法 (Goshawk)", (name, zh_info)
# 語言對不上任何 .lproj 時要落到英文，所以未本地化的預設值也必須是英文。
app_plist = json.loads((edir / "app-info-plist.json").read_text(encoding="utf-8"))
assert re.fullmatch(re.escape(app_plist["CFBundleShortVersionString"]) + r"\+[0-9a-f]{16}",
                    app_plist["GoshawkBuildIdentifier"]), app_plist
assert app_plist["CFBundleDevelopmentRegion"] == "en", app_plist["CFBundleDevelopmentRegion"]
assert app_plist["CFBundleName"] == "Goshawk", app_plist["CFBundleName"]

# 英文翻譯必須涵蓋程式裡每一個經過在地化函式的字串，少一條就失敗。
en_strings = json.loads((edir / "strings-en-localizable.json").read_text(encoding="utf-8"))
missing = [key for key in app_self["localizableStrings"] if key not in en_strings]
assert not missing, f"en.lproj/Localizable.strings 缺少翻譯：{missing}"
unused = [key for key in en_strings if key not in app_self["localizableStrings"]]
assert not unused, f"en.lproj/Localizable.strings 有程式沒用到的鍵：{unused}"
assert en_strings["設定…"] == "Settings…", en_strings["設定…"]

# 離線互動指南必須完整打包進 App 資源目錄，從選單與安裝完成頁才能離線開啟。
guide_dir = pathlib.Path("dist/GoshawkIME.app/Contents/Resources/Guide")
for rel in ("index.html", "styles.css", "app.js", "guide.md", "llms.txt", "assets/goshawk.svg"):
    assert (guide_dir / rel).is_file(), f"打包套件缺少離線指南檔案：{guide_dir / rel}"

proof = {
    "status": "passed",
    "checks": summary,
    "localization": {
        "enInputModeName": en_info[MODE_KEY],
        "zhInputModeName": zh_info[MODE_KEY],
        "translatedStrings": len(en_strings),
    },
    "reading": reading_proof,
    "continuationEvaluation": ranking,
    "benchmark": bench,
    "appSelfTest": app_self,
}
out_path.write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"VERIFIED {len(summary)} CLI scenarios + benchmark + GoshawkIME.app self-test -> {out_path}")
print(
    "VERIFIED reading lookup: 厝 "
    f"{reading_proof['cuoDachen']} / {reading_proof['cuoPinyin']} "
    f"({reading_proof['cuoCandidates']} candidates, "
    f"{reading_proof['zenV5']['nativeCodes'][0]} {reading_proof['zenV5']['radicals'][0]} "
    f"| {reading_proof['zenV3']['nativeCodes'][0]} {reading_proof['zenV3']['radicals'][0]} for 怎)"
)
PY
