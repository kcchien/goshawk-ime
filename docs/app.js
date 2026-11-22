/* 蒼鷹輸入法（Goshawk IME）互動教學與雙模式練習場引擎
   純原生 JavaScript，零外部依賴，離線可用 */

(() => {
  "use strict";

  // === 1. 精選示範詞庫（完全對應真實倉頡碼表與產品規格） ===
  const RADICALS = {
    a: "日", b: "月", c: "金", d: "木", e: "水", f: "火", g: "土",
    h: "竹", i: "戈", j: "十", k: "大", l: "中", m: "一", n: "弓",
    o: "人", p: "心", q: "手", r: "口", s: "尸", t: "廿", u: "山",
    v: "女", w: "田", x: "難", y: "卜", z: "重"
  };

  const CANGJIE_TABLE = {
    my: ["下"],
    id: ["床"],
    oj: ["午", "什"],
    bq: ["用"],
    anmt: ["開"],
    omwa: ["會"],
    ym: ["上"],
    dam: ["查", "柦"],
    ci: ["公"],
    hgr: ["告"],
    mta: ["厝"],
    cta: ["錯"],
    osp: ["怎"],
    hsp: ["怎"],
    ab: ["明"],
    am: ["旦", "且"],
    vnd: ["好"],
    l: ["中"],
    yk: ["文"],
    dd: ["林"],
    ddd: ["森"],
    yrhmy: ["訴"],
    opd: ["他"],
    onf: ["你"],
    hqi: ["我"],
    klg: ["在"],
    amyo: ["是"],
    hapi: ["的"],
    m: ["一"],
    i: ["戈"],
    o: ["人"],
    a: ["日", "曰"],
    b: ["月"],
    c: ["金"],
    d: ["木"],
    e: ["水"],
    f: ["火"],
    g: ["土"],
    h: ["竹"],
    j: ["十"],
    k: ["大"],
    n: ["弓"],
    p: ["心"],
    q: ["手"],
    r: ["口"],
    s: ["尸"],
    t: ["廿"],
    u: ["山"],
    v: ["女"],
    w: ["田"],
    y: ["卜"]
  };

  const CANGJIE_KEYS = Object.keys(CANGJIE_TABLE);

  const ENGLISH_DICT = [
    "id", "idea", "ideas", "identity",
    "my", "myself", "my_id",
    "GitHub", "git", "macOS", "Zoom", "useState", "k8s",
    "file", "folder", "hello", "world", "code", "api", "json",
    "npm", "order", "order_id", "path", "name", "test", "swift",
    "brew", "ssh", "docker", "linux", "type", "text", "tab", "space"
  ];

  const PAIR_STYLES = [
    { id: "corner", opener: "「", closer: "」" },
    { id: "square", opener: "[", closer: "]" },
    { id: "whiteCorner", opener: "『", closer: "』" },
    { id: "doubleAngle", opener: "《", closer: "》" },
    { id: "singleAngle", opener: "〈", closer: "〉" },
    { id: "lenticular", opener: "【", closer: "】" },
    { id: "doubleCurly", opener: "“", closer: "”" },
    { id: "singleCurly", opener: "‘", closer: "’" }
  ];

  const PUNCT_PAIRS = {
    ",": { full: "，", half: ",", closing: true },
    ".": { full: "。", half: ".", closing: true },
    "!": { full: "！", half: "!", closing: true },
    "?": { full: "？", half: "?", closing: true },
    ";": { full: "；", half: ";", closing: true },
    ":": { full: "：", half: ":", closing: true },
    "(": { full: "（", half: "(", closing: false },
    ")": { full: "）", half: ")", closing: true },
    "\\": { full: "、", half: "\\", closing: false }
  };

  const READING_ENTRIES = [
    { ch: "錯", code: "cta", radicals: "金廿日", pinyin: "cuo4", zhuyin: "hji4", displayZy: "ㄘㄨㄛˋ" },
    { ch: "挫", code: "qoog", radicals: "手人人土", pinyin: "cuo4", zhuyin: "hji4", displayZy: "ㄘㄨㄛˋ" },
    { ch: "銼", code: "coog", radicals: "金人人土", pinyin: "cuo4", zhuyin: "hji4", displayZy: "ㄘㄨㄛˋ" },
    { ch: "措", code: "qta", radicals: "手廿日", pinyin: "cuo4", zhuyin: "hji4", displayZy: "ㄘㄨㄛˋ" },
    { ch: "厝", code: "mta", radicals: "一廿日", pinyin: "cuo4", zhuyin: "hji4", displayZy: "ㄘㄨㄛˋ" }
  ];

  const SYMBOL_TABS = {
    recent: [
      { sym: "——", name: "破折號", en: "Two-em dash" },
      { sym: "……", name: "刪節號", en: "Six-dot ellipsis" },
      { sym: "‧", name: "間隔號", en: "Hyphenation point" },
      { sym: "〔", name: "左六角括號", en: "Left tortoise shell bracket" },
      { sym: "〕", name: "右六角括號", en: "Right tortoise shell bracket" },
      { sym: "※", name: "參考符號", en: "Reference mark" },
      { sym: "→", name: "右箭頭", en: "Rightwards arrow" },
      { sym: "×", name: "乘號", en: "Multiplication sign" },
      { sym: "±", name: "正負號", en: "Plus-minus sign" }
    ],
    punctuation: [
      { sym: "。", name: "句號", en: "Ideographic full stop" },
      { sym: "，", name: "逗號", en: "Fullwidth comma" },
      { sym: "、", name: "頓號", en: "Ideographic comma" },
      { sym: "；", name: "分號", en: "Fullwidth semicolon" },
      { sym: "：", name: "冒號", en: "Fullwidth colon" },
      { sym: "？", name: "問號", en: "Fullwidth question mark" },
      { sym: "！", name: "驚嘆號", en: "Fullwidth exclamation mark" },
      { sym: "——", name: "破折號", en: "Two-em dash" },
      { sym: "……", name: "刪節號", en: "Six-dot ellipsis" }
    ],
    symbols: [
      { sym: "〔", name: "左六角括號", en: "Left tortoise shell bracket" },
      { sym: "〕", name: "右六角括號", en: "Right tortoise shell bracket" },
      { sym: "※", name: "參考符號", en: "Reference mark" },
      { sym: "→", name: "右箭頭", en: "Rightwards arrow" },
      { sym: "←", name: "左箭頭", en: "Leftwards arrow" },
      { sym: "×", name: "乘號", en: "Multiplication sign" },
      { sym: "±", name: "正負號", en: "Plus-minus sign" },
      { sym: "°", name: "度", en: "Degree sign" },
      { sym: "‧", name: "間隔號", en: "Hyphenation point" }
    ]
  };

  function isCJK(ch) {
    return /[\u3400-\u9FFF\u3000-\u303F\uFF01-\uFF60]/.test(ch);
  }

  function isLatinOrDigit(ch) {
    return /[A-Za-z0-9]/.test(ch);
  }

  function hasCangjiePrefix(buf) {
    const lower = buf.toLowerCase();
    return CANGJIE_KEYS.some((k) => k.startsWith(lower));
  }

  function cangjieCandidates(buf) {
    return CANGJIE_TABLE[buf.toLowerCase()] || [];
  }

  function cangjieRadicals(buf) {
    return buf.toLowerCase().split("").map((c) => RADICALS[c] || c).join("");
  }

  function englishPredictions(buf) {
    const lower = buf.toLowerCase();
    const exact = ENGLISH_DICT.filter((w) => w.toLowerCase() === lower);
    const prefixed = ENGLISH_DICT.filter((w) => w.toLowerCase().startsWith(lower) && w.toLowerCase() !== lower);
    const list = [...exact, ...prefixed];
    if (list.length === 0) return [buf];
    // 保留使用者打出的原大小寫短詞（如 Zoom、GitHub）
    if (buf !== lower && list[0].toLowerCase() === lower) {
      list[0] = buf;
    }
    return list.slice(0, 4);
  }

  function findUnclosedPairOpener(text, snippetStart) {
    const start = snippetStart !== null ? snippetStart : 0;
    const stack = [];
    for (let i = start; i < text.length; i++) {
      const ch = text[i];
      const openIdx = PAIR_STYLES.findIndex((p) => p.opener === ch);
      if (openIdx >= 0) {
        stack.push({ index: i, styleIdx: openIdx });
        continue;
      }
      const closeIdx = PAIR_STYLES.findIndex((p) => p.closer === ch);
      if (closeIdx >= 0 && stack.length > 0 && stack[stack.length - 1].styleIdx === closeIdx) {
        stack.pop();
      }
    }
    return stack.length > 0 ? stack[stack.length - 1] : null;
  }

  function shouldUseFullwidthContext(text, { isPeriod = false } = {}) {
    if (!text) return !isPeriod;
    const last = text[text.length - 1];
    if (isCJK(last)) return true;
    if (isLatinOrDigit(last)) return false;
    if (last === " ") {
      return false;
    }
    return !isPeriod;
  }

  // === 2. 蒼鷹瀏覽器模擬狀態機 ===
  class GoshawkSim {
    constructor(onChange) {
      this.onChange = onChange;
      this.recentSymbols = SYMBOL_TABS.recent.map((x) => ({ ...x }));
      this.reset();
    }

    reset() {
      this.doc = "";
      this.buffer = "";
      this.pendingAutoSpace = false;
      this.snippet = false;
      this.snippetStart = null;
      this.snippetStickyZh = false;
      this.snippetContextBefore = null;
      this.afterSnippetPunctContext = null;
      this.pureEnglish = false;
      this.selectingCangjie = false;
      this.cjIndex = 0;
      this.revertRecord = null;
      this.pairChoice = null;
      this.layer = null; // null | { type: "reading", scheme, query, focus } | { type: "symbol", tab, focus }
      this.lastShiftTap = 0;
      this.feed = "";
      this.emit();
    }

    emit() {
      if (this.onChange) this.onChange(this);
    }

    snapshot() {
      return {
        doc: this.doc,
        pendingAutoSpace: this.pendingAutoSpace,
        snippet: this.snippet,
        snippetStart: this.snippetStart,
        snippetStickyZh: this.snippetStickyZh
      };
    }

    restoreSnapshot(snap) {
      this.doc = snap.doc;
      this.pendingAutoSpace = snap.pendingAutoSpace;
      this.snippet = snap.snippet;
      this.snippetStart = snap.snippetStart;
      this.snippetStickyZh = snap.snippetStickyZh;
    }

    commitText(str, { kind = "other", addAutoSpaceAfterEn = false } = {}) {
      this.afterSnippetPunctContext = null;
      if (!this.snippet && this.doc.length > 0) {
        const last = this.doc[this.doc.length - 1];
        if (kind === "zh" && isLatinOrDigit(last) && !this.pendingAutoSpace) {
          this.doc += " ";
        } else if (kind === "en" && isCJK(last) && !this.pendingAutoSpace) {
          this.doc += " ";
        }
      }
      this.doc += str;
      if (addAutoSpaceAfterEn && !this.snippet) {
        this.doc += " ";
        this.pendingAutoSpace = true;
      } else {
        this.pendingAutoSpace = false;
      }
    }

    openReadingLookup() {
      this.revertRecord = null;
      this.pairChoice = null;
      this.layer = { type: "reading", scheme: "zhuyin", query: "", focus: 0, selecting: false };
      this.feed = "開啟注音／拼音查拆碼：輸入 hji4（注音）或按 Tab 切拼音打 cuo4。";
      this.emit();
    }

    openSymbolPanel() {
      this.revertRecord = null;
      this.pairChoice = null;
      this.layer = { type: "symbol", tab: "recent", focus: 0 };
      this.feed = "開啟符號面板：按 1–9 選取，Tab 切換分頁，Esc 關閉。";
      this.emit();
    }

    getReadingRows() {
      if (!this.layer || this.layer.type !== "reading") return [];
      const q = this.layer.query.toLowerCase();
      if (!q) return [];
      const matches = READING_ENTRIES.filter((e) =>
        this.layer.scheme === "zhuyin"
          ? e.zhuyin.startsWith(q)
          : e.pinyin.startsWith(q)
      );
      return matches;
    }

    getSymbolRows() {
      if (!this.layer || this.layer.type !== "symbol") return [];
      if (this.layer.tab === "recent") return this.recentSymbols;
      return SYMBOL_TABS[this.layer.tab] || [];
    }

    pickReadingRow(index) {
      const rows = this.getReadingRows();
      const row = rows[index];
      if (!row) return;
      this.buffer = "";
      this.selectingCangjie = false;
      this.layer = null;
      this.commitText(row.ch, { kind: "zh" });
      this.feed = `反查選字「${row.ch}」（倉頡碼 ${row.code} · ${row.radicals}）`;
      this.emit();
    }

    pickSymbolRow(index) {
      const rows = this.getSymbolRows();
      const item = rows[index];
      if (!item) return;
      if (this.buffer) {
        this.settleBufferForPunctuation();
      }
      this.layer = null;
      if (this.pendingAutoSpace && [",", ".", ";", ":", "!", "?", ")", "，", "。", "；", "：", "！", "？", "）"].includes(item.sym)) {
        this.doc = this.doc.slice(0, -1);
        this.pendingAutoSpace = false;
      }
      this.doc += item.sym;
      if (this.snippet) this.snippetStickyZh = false;
      // 更新最近使用
      this.recentSymbols = [item, ...this.recentSymbols.filter((x) => x.sym !== item.sym)].slice(0, 9);
      this.feed = `從符號面板送出「${item.sym}」（${item.name}）`;
      this.emit();
    }

    selectPairStyleDirect(styleIdx) {
      if (!this.revertRecord || this.revertRecord.kind !== "pair") return;
      const rec = this.revertRecord;
      const style = PAIR_STYLES[styleIdx];
      if (!style) return;
      if (rec.side === "open") {
        this.doc = this.doc.slice(0, rec.startIndex) + style.opener;
      } else {
        const inner = this.doc.slice(rec.startIndex + 1, this.doc.length - 1);
        this.doc = this.doc.slice(0, rec.startIndex) + style.opener + inner + style.closer;
      }
      rec.styleIdx = styleIdx;
      rec.digitsPick = false;
      this.pairChoice = { currentIdx: styleIdx, digitsPick: false };
      this.feed = `成對符號切換為 ${style.opener}${style.closer}`;
      this.emit();
    }

    settleBufferForPunctuation() {
      if (!this.buffer) return;
      const cands = cangjieCandidates(this.buffer);
      if (this.snippet && !this.snippetStickyZh) {
        this.commitText(this.buffer, { kind: "en" });
      } else if (cands.length > 0) {
        this.commitText(cands[this.cjIndex] || cands[0], { kind: "zh" });
      } else {
        this.commitText(this.buffer, { kind: "en" });
      }
      this.buffer = "";
      this.selectingCangjie = false;
      this.cjIndex = 0;
    }

    handleKey(e) {
      const key = e.key;
      const code = e.code || "";

      // 純 Shift 鍵用於偵測雙擊 Shift
      if (key === "Shift") {
        const now = Date.now();
        if (!this.buffer && !this.layer && now - this.lastShiftTap < 360) {
          this.pureEnglish = !this.pureEnglish;
          this.lastShiftTap = 0;
          this.feed = this.pureEnglish ? "已進入純英文模式（再雙擊 Shift 切回混打）" : "已切回中英混打模式";
          this.emit();
        } else {
          this.lastShiftTap = now;
        }
        return true;
      }

      // 快捷鍵：Ctrl+Shift+; 讀音反查
      if (e.ctrlKey && e.shiftKey && (code === "Semicolon" || key === ";" || key === ":")) {
        if (this.layer && this.layer.type === "reading") {
          this.layer = null;
          this.feed = "已關閉讀音反查，還原原本組字。";
        } else if (!this.layer) {
          this.openReadingLookup();
        }
        this.emit();
        return true;
      }

      // 快捷鍵：Option+Shift+B 符號面板
      if (e.altKey && e.shiftKey && (code === "KeyB" || key.toLowerCase() === "b")) {
        if (this.layer && this.layer.type === "symbol") {
          this.layer = null;
          this.feed = "已關閉符號面板，還原原本組字。";
        } else if (!this.layer && !this.pureEnglish) {
          this.openSymbolPanel();
        }
        this.emit();
        return true;
      }

      // 疊加層處理：讀音反查
      if (this.layer && this.layer.type === "reading") {
        if (key === "Escape") {
          this.layer = null;
          this.feed = "已取消讀音反查，保留原本緩衝。";
          this.emit();
          return true;
        }
        if (key === "Tab") {
          this.layer.scheme = this.layer.scheme === "zhuyin" ? "pinyin" : "zhuyin";
          this.layer.query = "";
          this.layer.focus = 0;
          this.layer.selecting = false;
          this.feed = this.layer.scheme === "zhuyin" ? "反查方案切換為注音（試打 hji4）" : "反查方案切換為漢語拼音（試打 cuo4）";
          this.emit();
          return true;
        }
        if (key === "Backspace") {
          this.layer.query = this.layer.query.slice(0, -1);
          this.layer.focus = 0;
          this.layer.selecting = false;
          this.emit();
          return true;
        }
        if (key === "ArrowDown") {
          const rows = this.getReadingRows();
          if (rows.length) {
            this.layer.selecting = true;
            this.layer.focus = (this.layer.focus + 1) % rows.length;
          }
          this.emit();
          return true;
        }
        if (key === "ArrowUp") {
          const rows = this.getReadingRows();
          if (rows.length) {
            this.layer.selecting = true;
            this.layer.focus = (this.layer.focus - 1 + rows.length) % rows.length;
          }
          this.emit();
          return true;
        }
        if (key === "Enter" || (key === " " && this.getReadingRows().length > 0)) {
          this.pickReadingRow(this.layer.focus);
          return true;
        }
        const hasTone = /[1-7]$/.test(this.layer.query);
        const isToneKey = this.layer.scheme === "zhuyin" ? /^[3467]$/.test(key) : /^[1-5]$/.test(key);
        if (/^[1-9]$/.test(key)) {
          if ((this.layer.selecting || hasTone || !isToneKey) && this.getReadingRows().length >= Number(key)) {
            this.pickReadingRow(Number(key) - 1);
            return true;
          }
        }
        if (/^[a-zA-Z0-9]$/.test(key)) {
          this.layer.query += key.toLowerCase();
          this.layer.focus = 0;
          this.emit();
          return true;
        }
        return true;
      }

      // 疊加層處理：符號面板
      if (this.layer && this.layer.type === "symbol") {
        const tabs = ["recent", "punctuation", "symbols"];
        if (key === "Escape") {
          this.layer = null;
          this.feed = "已關閉符號面板。";
          this.emit();
          return true;
        }
        if (key === "Tab") {
          const idx = (tabs.indexOf(this.layer.tab) + 1) % tabs.length;
          this.layer.tab = tabs[idx];
          this.layer.focus = 0;
          this.emit();
          return true;
        }
        if (key === "ArrowDown") {
          const rows = this.getSymbolRows();
          if (rows.length) this.layer.focus = (this.layer.focus + 1) % rows.length;
          this.emit();
          return true;
        }
        if (key === "ArrowUp") {
          const rows = this.getSymbolRows();
          if (rows.length) this.layer.focus = (this.layer.focus - 1 + rows.length) % rows.length;
          this.emit();
          return true;
        }
        if (key === "Enter" || key === " ") {
          this.pickSymbolRow(this.layer.focus);
          return true;
        }
        if (/^[1-9]$/.test(key) && this.getSymbolRows().length >= Number(key)) {
          this.pickSymbolRow(Number(key) - 1);
          return true;
        }
        return true;
      }

      // 純英文模式
      if (this.pureEnglish) {
        if (key === "Backspace") {
          this.doc = this.doc.slice(0, -1);
          this.emit();
          return true;
        }
        if (key.length === 1 && !e.metaKey && !e.ctrlKey) {
          this.doc += key;
          this.emit();
          return true;
        }
        return false;
      }

      // 檢查成對切換數字直選（緊接在 Shift+空白 之後）
      if (this.revertRecord && this.revertRecord.kind === "pair" && this.revertRecord.digitsPick && /^[1-8]$/.test(key)) {
        this.selectPairStyleDirect(Number(key) - 1);
        return true;
      }

      // Shift+Space 處理：反悔 / 標點寬度對調 / 成對切換 / 展開候選
      if (key === " " && e.shiftKey) {
        if (this.buffer) {
          const cands = cangjieCandidates(this.buffer);
          if (cands.length > 0) {
            this.selectingCangjie = true;
            this.feed = "已聚焦倉頡候選列：可用方向鍵或數字選字，空白鍵送出。";
            this.emit();
            return true;
          }
        }
        if (this.revertRecord) {
          return this.applyRevert();
        }
        this.doc += " ";
        this.pendingAutoSpace = false;
        this.pairChoice = null;
        this.feed = "插入空格。";
        this.emit();
        return true;
      }

      // 任何其他鍵進來先清掉舊反悔與成對選項列
      this.revertRecord = null;
      this.pairChoice = null;

      // Backspace
      if (key === "Backspace") {
        if (this.buffer) {
          this.buffer = this.buffer.slice(0, -1);
          this.selectingCangjie = false;
          this.cjIndex = 0;
          this.feed = this.buffer ? `退格，目前緩衝「${this.buffer}」` : "已清空組字緩衝。";
        } else {
          const removed = this.doc.slice(-1);
          this.doc = this.doc.slice(0, -1);
          if (removed === "`") {
            this.snippet = !this.snippet;
            this.snippetStart = this.snippet ? this.doc.length : null;
          }
          this.pendingAutoSpace = false;
          this.feed = "回刪一個字元。";
        }
        this.emit();
        return true;
      }

      // Escape
      if (key === "Escape") {
        if (this.selectingCangjie) {
          this.selectingCangjie = false;
          this.feed = "回到輸入狀態。";
        } else if (this.buffer) {
          this.buffer = "";
          this.feed = "已取消組字。";
        }
        this.emit();
        return true;
      }

      // 方向鍵在選字時移動
      if (this.buffer && (key === "ArrowRight" || key === "ArrowLeft")) {
        const cands = cangjieCandidates(this.buffer);
        if (cands.length > 1) {
          this.selectingCangjie = true;
          this.cjIndex = (this.cjIndex + (key === "ArrowRight" ? 1 : -1) + cands.length) % cands.length;
          this.emit();
          return true;
        }
      }

      // 反引號 `：行內程式片段開關
      if (key === "`") {
        if (this.buffer) {
          this.settleBufferForPunctuation();
        }
        const entering = !this.snippet;
        if (entering) {
          this.snippetContextBefore = this.doc;
          this.afterSnippetPunctContext = null;
        } else {
          this.afterSnippetPunctContext = this.snippetContextBefore;
          this.snippetContextBefore = null;
        }
        this.doc += "`";
        this.pendingAutoSpace = false;
        this.snippet = entering;
        this.snippetStart = this.snippet ? this.doc.length : null;
        this.snippetStickyZh = false;
        this.feed = this.snippet
          ? "進入行內程式片段：英文優先、標點半形、Tab 不附尾空格。"
          : "離開行內程式片段，恢復中英混打語境。";
        this.emit();
        return true;
      }

      // Tab：送出英文預測（並記錄可反悔）
      if (key === "Tab") {
        if (!this.buffer) return false;
        const preds = englishPredictions(this.buffer);
        const word = preds[0] || this.buffer;
        const cands = cangjieCandidates(this.buffer);
        const snap = this.snapshot();
        const rawBuf = this.buffer;
        this.buffer = "";
        this.selectingCangjie = false;
        this.cjIndex = 0;

        if (this.snippet) {
          this.commitText(word, { kind: "en", addAutoSpaceAfterEn: false });
          this.snippetStickyZh = false;
          this.feed = `片段內 Tab 補完「${word}」（不附尾空格）`;
        } else {
          this.commitText(word, { kind: "en", addAutoSpaceAfterEn: true });
          if (cands.length > 0) {
            this.revertRecord = {
              kind: "dual",
              snapshot: snap,
              buffer: rawBuf,
              currentSide: "en",
              altLabel: cands[0]
            };
          }
          this.feed = `Tab 接受英文「${word} 」並補上一格空格`;
        }
        this.emit();
        return true;
      }

      // Enter：原樣送出字母（保留大小寫、不補空格）
      if (key === "Enter") {
        if (this.buffer) {
          const text = this.buffer;
          this.buffer = "";
          this.selectingCangjie = false;
          this.cjIndex = 0;
          this.commitText(text, { kind: "en", addAutoSpaceAfterEn: false });
          if (this.snippet) this.snippetStickyZh = false;
          this.feed = `Enter 原樣送出「${text}」（保留大小寫、不加尾空格）`;
          this.emit();
          return true;
        }
        if (this.snippet) {
          this.snippet = false;
          this.snippetStart = null;
          this.snippetStickyZh = false;
        }
        this.doc += "\n";
        this.pendingAutoSpace = false;
        this.emit();
        return true;
      }

      // Space：倉頡首選（或片段內英文優先）
      if (key === " ") {
        if (!this.buffer) {
          this.doc += " ";
          this.pendingAutoSpace = false;
          this.feed = "輸入手動空格。";
          this.emit();
          return true;
        }
        const cands = cangjieCandidates(this.buffer);
        const preds = englishPredictions(this.buffer);
        const snap = this.snapshot();
        const rawBuf = this.buffer;
        const chosenZh = cands[this.cjIndex] || cands[0];
        this.buffer = "";
        this.cjIndex = 0;

        if (this.snippet && !this.snippetStickyZh && !this.selectingCangjie) {
          this.selectingCangjie = false;
          this.doc += rawBuf + " ";
          this.pendingAutoSpace = false;
          this.feed = `片段內英文優先，空白鍵送出「${rawBuf} 」`;
          this.emit();
          return true;
        }

        const wasSelecting = this.selectingCangjie;
        this.selectingCangjie = false;

        if (chosenZh) {
          this.commitText(chosenZh, { kind: "zh" });
          if (this.snippet) this.snippetStickyZh = true;
          if (!wasSelecting && preds.length > 0 && !this.snippet) {
            this.revertRecord = {
              kind: "dual",
              snapshot: snap,
              buffer: rawBuf,
              currentSide: "zh",
              altLabel: `${preds[0]} `
            };
          }
          this.feed = `空白鍵送出倉頡首選「${chosenZh}」${this.revertRecord ? "（可按 Shift+空白 換回英文）" : ""}`;
        } else {
          this.commitText(rawBuf, { kind: "en", addAutoSpaceAfterEn: true });
          this.feed = `無精確漢字，送出原字母與空格「${rawBuf} 」`;
        }
        this.emit();
        return true;
      }

      // 數字鍵：視條件選字或當字元
      if (/^[0-9]$/.test(key) && !e.shiftKey && !e.ctrlKey && !e.altKey) {
        if (this.buffer) {
          const cands = cangjieCandidates(this.buffer);
          const digitsSelect = this.selectingCangjie || (this.buffer.length >= 2 && cands.length >= 2 && !this.snippet);
          const idx = Number(key) - 1;
          if (digitsSelect && idx >= 0 && idx < cands.length) {
            const chosen = cands[idx];
            this.buffer = "";
            this.selectingCangjie = false;
            this.cjIndex = 0;
            this.commitText(chosen, { kind: "zh" });
            this.feed = `按數字 ${key} 選出「${chosen}」`;
            this.emit();
            return true;
          }
          this.buffer += key;
          this.feed = `候選無編號，數字直接併入「${this.buffer}」`;
          this.emit();
          return true;
        }
        this.commitText(key, { kind: "en" });
        this.emit();
        return true;
      }

      // Shift+2..4 選英文預測
      if (this.buffer && e.shiftKey && ["Digit2", "Digit3", "Digit4"].includes(code)) {
        const idx = Number(code.replace("Digit", "")) - 1;
        const preds = englishPredictions(this.buffer);
        if (preds[idx]) {
          this.buffer = "";
          this.selectingCangjie = false;
          this.commitText(preds[idx], { kind: "en", addAutoSpaceAfterEn: !this.snippet });
          this.feed = `Shift+${idx + 1} 選取英文預測「${preds[idx]}」`;
          this.emit();
          return true;
        }
      }

      // 方括號 [ 與 ]：八種成對符號
      if (key === "[" || key === "]") {
        if (this.buffer) this.settleBufferForPunctuation();
        if (this.snippet) this.snippetStickyZh = false;

        if (key === "[") {
          const defaultFull = !this.snippet && shouldUseFullwidthContext(this.doc);
          const styleIdx = defaultFull ? 0 : 1; // 「 或 [
          const startIndex = this.doc.length;
          this.doc += PAIR_STYLES[styleIdx].opener;
          this.pendingAutoSpace = false;
          this.revertRecord = {
            kind: "pair",
            side: "open",
            startIndex,
            styleIdx,
            digitsPick: false
          };
          this.feed = `輸入開頭「${PAIR_STYLES[styleIdx].opener}」（可立刻按 Shift+空白 換種類）`;
          this.emit();
          return true;
        }

        // key === "]"
        const opener = findUnclosedPairOpener(this.doc, this.snippet ? this.snippetStart : 0);
        if (opener) {
          const style = PAIR_STYLES[opener.styleIdx];
          this.doc += style.closer;
          this.pendingAutoSpace = false;
          this.revertRecord = {
            kind: "pair",
            side: "close",
            startIndex: opener.index,
            styleIdx: opener.styleIdx,
            digitsPick: false
          };
          this.feed = `自動配對結尾「${style.closer}」（立刻按 Shift+空白 可整對切換八種符號）`;
          this.emit();
          return true;
        }
        const defaultFull = !this.snippet && shouldUseFullwidthContext(this.doc);
        const ch = defaultFull ? "」" : "]";
        this.doc += ch;
        this.pendingAutoSpace = false;
        this.feed = `輸入「${ch}」`;
        this.emit();
        return true;
      }

      // 標點符號（含混打組字按句點直接出 my.）
      if (PUNCT_PAIRS[key]) {
        const meta = PUNCT_PAIRS[key];
        if (key === "." && this.buffer && !this.selectingCangjie) {
          const literal = this.buffer + ".";
          this.buffer = "";
          this.commitText(literal, { kind: "en" });
          this.feed = `組字中按句點，直接保留檔名格式「${literal}」`;
          this.emit();
          return true;
        }

        if (this.buffer) this.settleBufferForPunctuation();
        if (this.snippet) this.snippetStickyZh = false;

        if (meta.closing && this.pendingAutoSpace) {
          this.doc = this.doc.slice(0, -1);
          this.pendingAutoSpace = false;
        }

        const punctCtxText = this.afterSnippetPunctContext !== null ? this.afterSnippetPunctContext : this.doc;
        this.afterSnippetPunctContext = null;
        let isFull = !this.snippet && shouldUseFullwidthContext(punctCtxText, { isPeriod: key === "." });
        let forced = false;
        if (e.ctrlKey) {
          isFull = true;
          forced = true;
        } else if (e.altKey) {
          isFull = false;
          forced = true;
        }

        const out = isFull ? meta.full : meta.half;
        const pos = this.doc.length;
        this.doc += out;
        if (!forced) {
          this.revertRecord = {
            kind: "punct",
            pos,
            punctKey: key,
            isFull
          };
        }
        this.feed = `輸出標點「${out}」${!forced ? "（立刻按 Shift+空白 可對調全半形）" : ""}`;
        this.emit();
        return true;
      }

      // 字母鍵進入中英混打組字
      if (/^[a-zA-Z]$/.test(key) && !e.metaKey && !e.ctrlKey && !e.altKey) {
        this.buffer += key;
        this.selectingCangjie = false;
        this.cjIndex = 0;
        this.feed = hasCangjiePrefix(this.buffer)
          ? `同時列出中英文候選「${this.buffer}」：空白出中文、Tab 出英文、Enter 保留大小寫`
          : `英文候選「${this.buffer}」：按 Tab 補完或 Enter 原樣打出`;
        this.emit();
        return true;
      }

      // 其他一般可印字元（例如底線 _）
      if (key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey) {
        if (this.buffer) this.settleBufferForPunctuation();
        this.doc += key;
        this.pendingAutoSpace = false;
        this.emit();
        return true;
      }

      return false;
    }

    applyRevert() {
      const rec = this.revertRecord;
      if (!rec) return false;

      if (rec.kind === "dual") {
        this.restoreSnapshot(rec.snapshot);
        const cands = cangjieCandidates(rec.buffer);
        const preds = englishPredictions(rec.buffer);
        if (rec.currentSide === "zh") {
          this.commitText(preds[0] || rec.buffer, { kind: "en", addAutoSpaceAfterEn: true });
          rec.currentSide = "en";
          rec.altLabel = cands[0];
          this.feed = `一鍵反悔：換成英文「${preds[0] || rec.buffer} 」（再按可換回）`;
        } else {
          this.commitText(cands[0], { kind: "zh" });
          rec.currentSide = "zh";
          rec.altLabel = `${preds[0] || rec.buffer} `;
          this.feed = `一鍵反悔：換回中文「${cands[0]}」`;
        }
        this.emit();
        return true;
      }

      if (rec.kind === "punct") {
        const meta = PUNCT_PAIRS[rec.punctKey];
        rec.isFull = !rec.isFull;
        const replacement = rec.isFull ? meta.full : meta.half;
        this.doc = this.doc.slice(0, rec.pos) + replacement;
        this.feed = `標點寬度對調為「${replacement}」`;
        this.emit();
        return true;
      }

      if (rec.kind === "pair") {
        const nextIdx = (rec.styleIdx + 1) % PAIR_STYLES.length;
        const style = PAIR_STYLES[nextIdx];
        if (rec.side === "open") {
          this.doc = this.doc.slice(0, rec.startIndex) + style.opener;
          rec.styleIdx = nextIdx;
          rec.digitsPick = false;
          this.pairChoice = { currentIdx: nextIdx, digitsPick: false };
          this.feed = `開頭已切換為 ${style.opener}`;
        } else {
          const inner = this.doc.slice(rec.startIndex + 1, this.doc.length - 1);
          this.doc = this.doc.slice(0, rec.startIndex) + style.opener + inner + style.closer;
          rec.styleIdx = nextIdx;
          rec.digitsPick = true;
          this.pairChoice = { currentIdx: nextIdx, digitsPick: true };
          this.feed = `整對切換為 ${style.opener}${inner}${style.closer}（現在可直接按 1–8 跳選種類）`;
        }
        this.emit();
        return true;
      }

      return false;
    }
  }

  // === 3. 繪製真實比例的蒼鷹浮窗（供教學與自由練習場共用） ===
  function renderOverlay(sim, container) {
    container.innerHTML = "";

    // 疊加層：讀音反查
    if (sim.layer && sim.layer.type === "reading") {
      const pop = document.createElement("div");
      pop.className = "goshawk-popover";
      const rows = sim.getReadingRows();
      const queryDisplay = sim.layer.query
        ? (sim.layer.scheme === "zhuyin" && sim.layer.query === "hji4" ? "ㄘㄨㄛˋ" : sim.layer.query)
        : (sim.layer.scheme === "zhuyin" ? "打注音（試打 hji4）" : "打拼音（試打 cuo4）");

      const header = document.createElement("div");
      header.className = "panel-header";
      header.innerHTML = `
        <span class="panel-title">${escapeHtml(queryDisplay)} · 倉頡三代</span>
        <span class="panel-tabs">
          <button type="button" class="panel-tab ${sim.layer.scheme === "zhuyin" ? "is-active" : ""}" data-scheme="zhuyin">注音</button>
          <button type="button" class="panel-tab ${sim.layer.scheme === "pinyin" ? "is-active" : ""}" data-scheme="pinyin">拼音</button>
        </span>
      `;
      header.querySelectorAll(".panel-tab").forEach((btn) => {
        btn.addEventListener("click", (ev) => {
          ev.stopPropagation();
          sim.layer.scheme = btn.dataset.scheme;
          sim.layer.query = "";
          sim.layer.focus = 0;
          sim.emit();
        });
      });
      pop.appendChild(header);

      const list = document.createElement("div");
      list.className = "panel-rows";
      if (rows.length === 0) {
        const empty = document.createElement("div");
        empty.className = "pop-hint";
        empty.style.padding = "8px 4px";
        empty.textContent = sim.layer.query ? "查無此示範讀音（本網頁示範收錄 ㄘㄨㄛˋ / cuo4）" : "請輸入 hji4（注音）或點右上方「拼音」打 cuo4";
        list.appendChild(empty);
      } else {
        rows.forEach((r, idx) => {
          const el = document.createElement("div");
          el.className = `panel-row ${idx === sim.layer.focus ? "is-focused" : ""}`;
          el.innerHTML = `<span class="pr-tri">▸</span><span class="pr-num">${idx + 1}</span><span class="pr-main">${r.ch}</span><span class="pr-code">${r.code}</span><span class="pr-sub">${r.radicals}</span>`;
          el.addEventListener("click", (ev) => {
            ev.stopPropagation();
            sim.pickReadingRow(idx);
          });
          list.appendChild(el);
        });
      }
      pop.appendChild(list);

      const footer = document.createElement("div");
      footer.className = "panel-footer";
      footer.innerHTML = `${renderKeyExpr("1", { small: true })}–${renderKeyExpr("5", { small: true })} 選字 &nbsp; ${renderKeyExpr("Tab", { small: true })} 切方案 &nbsp; ${renderKeyExpr("Esc", { small: true })} 關閉`;
      pop.appendChild(footer);
      container.appendChild(pop);
      return;
    }

    // 疊加層：符號面板
    if (sim.layer && sim.layer.type === "symbol") {
      const pop = document.createElement("div");
      pop.className = "goshawk-popover";
      const rows = sim.getSymbolRows();
      const header = document.createElement("div");
      header.className = "panel-header";
      header.innerHTML = `
        <span class="panel-tabs">
          <button type="button" class="panel-tab ${sim.layer.tab === "recent" ? "is-active" : ""}" data-tab="recent">最近使用</button>
          <button type="button" class="panel-tab ${sim.layer.tab === "punctuation" ? "is-active" : ""}" data-tab="punctuation">標點</button>
          <button type="button" class="panel-tab ${sim.layer.tab === "symbols" ? "is-active" : ""}" data-tab="symbols">符號</button>
        </span>
      `;
      header.querySelectorAll(".panel-tab").forEach((btn) => {
        btn.addEventListener("click", (ev) => {
          ev.stopPropagation();
          sim.layer.tab = btn.dataset.tab;
          sim.layer.focus = 0;
          sim.emit();
        });
      });
      pop.appendChild(header);

      const list = document.createElement("div");
      list.className = "panel-rows";
      rows.slice(0, 9).forEach((item, idx) => {
        const el = document.createElement("div");
        el.className = `panel-row is-symbol ${idx === sim.layer.focus ? "is-focused" : ""}`;
        el.innerHTML = `<span class="pr-tri">▸</span><span class="pr-num">${idx + 1}</span><span class="pr-main">${escapeHtml(item.sym)}</span><span class="pr-sub">${escapeHtml(item.name)}</span>`;
        el.addEventListener("click", (ev) => {
          ev.stopPropagation();
          sim.pickSymbolRow(idx);
        });
        list.appendChild(el);
      });
      pop.appendChild(list);

      const footer = document.createElement("div");
      footer.className = "panel-footer";
      footer.innerHTML = `${renderKeyExpr("1", { small: true })}–${renderKeyExpr("9", { small: true })} 選取 &nbsp; ${renderKeyExpr("Tab", { small: true })} 切分頁 &nbsp; ${renderKeyExpr("Esc", { small: true })} 關閉`;
      pop.appendChild(footer);
      container.appendChild(pop);
      return;
    }

    // 成對符號選項列
    if (sim.pairChoice) {
      const pop = document.createElement("div");
      pop.className = "goshawk-popover";
      const bar = document.createElement("div");
      bar.className = "pair-bar";
      PAIR_STYLES.forEach((style, idx) => {
        const span = document.createElement("span");
        span.className = `pair-item ${idx === sim.pairChoice.currentIdx ? "is-focused" : ""}`;
        const numHtml = sim.pairChoice.digitsPick ? `<span class="pair-num">${idx + 1}</span>` : "";
        span.innerHTML = `${numHtml}${escapeHtml(style.opener + style.closer)}`;
        span.addEventListener("click", (ev) => {
          ev.stopPropagation();
          sim.selectPairStyleDirect(idx);
        });
        bar.appendChild(span);
      });
      pop.appendChild(bar);
      container.appendChild(pop);
      return;
    }

    // 組字中英候選浮窗
    if (sim.buffer) {
      const pop = document.createElement("div");
      pop.className = "goshawk-popover";
      const preds = englishPredictions(sim.buffer);
      const hasPrefix = hasCangjiePrefix(sim.buffer);
      const cands = cangjieCandidates(sim.buffer);
      const enFocused = sim.snippet && !sim.snippetStickyZh && !sim.selectingCangjie;

      const enRow = document.createElement("div");
      enRow.className = "pop-row";
      let enHtml = "";
      if (sim.snippet) enHtml += `<span class="pop-badge">片段</span>`;
      enHtml += `<span class="pop-en-main ${enFocused ? "is-focused" : ""}">${escapeHtml(preds[0] || sim.buffer)}</span>`;
      enHtml += renderKeyExpr(enFocused ? "Space" : "Tab", { small: true });
      if (preds.length > 1) {
        enHtml += `<span class="pop-sep">|</span>`;
        preds.slice(1, 4).forEach((w, i) => {
          enHtml += `<span class="pop-en-alt">${renderKeyExpr(`Shift+${i + 2}`, { small: true })} ${escapeHtml(w)}</span>`;
        });
      }
      enRow.innerHTML = enHtml;
      pop.appendChild(enRow);

      if (hasPrefix) {
        const div = document.createElement("div");
        div.className = "pop-divider";
        pop.appendChild(div);

        const cjRow = document.createElement("div");
        cjRow.className = "pop-row";
        const showNums = sim.selectingCangjie || (sim.buffer.length >= 2 && cands.length >= 2 && !sim.snippet);
        let cjHtml = `<span class="pop-radicals">${escapeHtml(cangjieRadicals(sim.buffer))}</span>`;
        if (cands.length === 0) {
          cjHtml += `<span class="pop-hint">（前綴，續打或按 ${renderKeyExpr("Space", { small: true })} 出英文）</span>`;
        } else {
          cands.forEach((ch, idx) => {
            const focused = !enFocused && idx === sim.cjIndex;
            const numHtml = showNums ? `<span class="cand-num">${idx + 1}</span>` : "";
            const triHtml = focused ? `<span class="focus-tri">▸</span>` : "";
            cjHtml += `<span class="pop-cand ${focused ? "is-focused" : ""}">${triHtml}${numHtml}${ch}</span>`;
          });
        }
        cjRow.innerHTML = cjHtml;
        pop.appendChild(cjRow);
      }

      container.appendChild(pop);
      return;
    }

    // 中英對調提示條（兩顆獨立實體鍵帽 Shift + 空白）
    if (sim.revertRecord && sim.revertRecord.kind === "dual") {
      const pop = document.createElement("div");
      pop.className = "goshawk-popover";
      const swapVerb = lang === "en" ? "swap to" : "改成";
      pop.innerHTML = `<div class="pop-single-hint">${renderKeyExpr("Shift+Space", { small: true })}<span>${swapVerb}</span><strong>${escapeHtml(sim.revertRecord.altLabel)}</strong></div>`;
      container.appendChild(pop);
    }
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  // === 2.5 全站統一實體鍵帽 SVG 繪製系統 ===
  const KEY_SVGS = {
    Shift: '<svg class="keycap-svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 2.2 2.6 8.3h3.2v5.2h4.4V8.3h3.2L8 2.2Z"/></svg>',
    Ctrl: '<svg class="keycap-svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 10.5 8 4.8l5 5.7"/></svg>',
    Option: '<svg class="keycap-svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 4.2h3.4l5.2 7.6H14M9.4 4.2H14"/></svg>',
    Tab: '<svg class="keycap-svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 8h9.2M8.2 4.6 11.6 8l-3.4 3.4M13.5 3.6v8.8"/></svg>',
    Enter: '<svg class="keycap-svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M13 3.5V9H3.4M6.4 6 3.2 9l3.2 3"/></svg>',
    Space: '<svg class="keycap-svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2.2 8.5v3h11.6v-3"/></svg>',
    CapsLock: '<svg class="keycap-svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 2 3 7.5h2.8V10h4.4V7.5H13L8 2ZM5.8 12.6h4.4"/></svg>',
    ArrowUp: '<svg class="keycap-svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 13V3M4.2 6.8 8 3l3.8 3.8"/></svg>',
    ArrowDown: '<svg class="keycap-svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 3v10M4.2 9.2 8 13l3.8-3.8"/></svg>',
    ArrowLeft: '<svg class="keycap-svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M13 8H3M6.8 4.2 3 8l3.8 3.8"/></svg>',
    ArrowRight: '<svg class="keycap-svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 8h10M9.2 4.2 13 8l-3.8 3.8"/></svg>'
  };

  function renderSingleKeycap(rawToken, { small = false } = {}) {
    const t = rawToken.trim();
    const smClass = small ? " keycap-sm" : "";
    if (t === "Space") {
      const label = lang === "en" ? "Space" : "空白";
      return `<kbd class="keycap keycap-wide${smClass}">${KEY_SVGS.Space}<span>${label}</span></kbd>`;
    }
    if (t === "Shift") {
      return `<kbd class="keycap${smClass}">${KEY_SVGS.Shift}<span>Shift</span></kbd>`;
    }
    if (t === "Ctrl") {
      return `<kbd class="keycap${smClass}">${KEY_SVGS.Ctrl}<span>Ctrl</span></kbd>`;
    }
    if (t === "Option") {
      return `<kbd class="keycap${smClass}">${KEY_SVGS.Option}<span>Option</span></kbd>`;
    }
    if (t === "Tab") {
      return `<kbd class="keycap${smClass}">${KEY_SVGS.Tab}<span>Tab</span></kbd>`;
    }
    if (t === "Enter") {
      return `<kbd class="keycap${smClass}">${KEY_SVGS.Enter}<span>Enter</span></kbd>`;
    }
    if (t === "CapsLock") {
      return `<kbd class="keycap${smClass}">${KEY_SVGS.CapsLock}<span>Caps Lock</span></kbd>`;
    }
    if (t === "Esc") {
      return `<kbd class="keycap${smClass}"><span>Esc</span></kbd>`;
    }
    if (KEY_SVGS[t]) {
      return `<kbd class="keycap${smClass}" aria-label="${t}">${KEY_SVGS[t]}</kbd>`;
    }
    const isSingleSym = t.length === 1;
    return `<kbd class="keycap${isSingleSym ? " keycap-sym" : ""}${smClass}">${escapeHtml(t)}</kbd>`;
  }

  function renderKeyExpr(expr, { small = false } = {}) {
    // expr 可為 "Shift+Space"（組合鍵用 + 串接）或 "m,y,Space"（逗號分隔連續單鍵；若鍵本身是逗號則處理空項）
    const tokens = [];
    let i = 0;
    while (i < expr.length) {
      if (expr[i] === ",") {
        // 兩個連續逗號或尾端逗號代表按鍵本身是逗號 ","
        if (i === expr.length - 1 || expr[i + 1] === ",") {
          tokens.push(",");
          i += (expr[i + 1] === ",") ? 2 : 1;
          continue;
        }
        i += 1;
        continue;
      }
      const nextComma = expr.indexOf(",", i);
      if (nextComma === -1) {
        tokens.push(expr.slice(i));
        break;
      }
      // 處理 Ctrl+, 這類結尾為 +, 的組合鍵
      if (nextComma > i && expr[nextComma - 1] === "+") {
        tokens.push(expr.slice(i, nextComma + 1));
        i = nextComma + 1;
        if (expr[i] === ",") i += 1;
      } else {
        tokens.push(expr.slice(i, nextComma));
        i = nextComma + 1;
      }
    }

    return tokens.map((tok) => {
      if (tok.includes("+") && tok.length > 1) {
        const parts = tok.split("+");
        // 若原字串結尾為 "+"（不會發生）則過濾空項
        const cleaned = parts.filter((p) => p.length > 0);
        return `<span class="kchord">${cleaned.map((p) => renderSingleKeycap(p, { small })).join('<span class="kplus">+</span>')}</span>`;
      }
      return renderSingleKeycap(tok, { small });
    }).join("");
  }

  function hydrateKeycaps(root = document) {
    root.querySelectorAll(".kseq[data-keys]").forEach((el) => {
      const small = el.classList.contains("kseq-sm");
      el.innerHTML = renderKeyExpr(el.getAttribute("data-keys"), { small });
    });
  }

  // === 4. 30 秒五關教學定義（全部改用分段步驟與實體鍵帽，零歧義箭頭） ===
  const MISSIONS = [
    {
      id: "split",
      pillZh: "1. 中英混打",
      pillEn: "1. Mix Chinese & EN",
      timeZh: "約 6 秒",
      timeEn: "~6 sec",
      titleZh: "不切輸入法：空白出中文，Tab 出英文",
      titleEn: "One IME: Space for Chinese, Tab for English",
      goalZh: "先打出中文「用」，再緊接著打出英文 id 並自動補空格，完成「用 id 」。",
      goalEn: "Type Chinese 用 first, then accept English id with automatic spacing: 「用 id 」.",
      steps: [
        { tagZh: "步驟 1 · 打出「用」", tagEn: "Step 1 · Type 用", keys: "b,q,Space" },
        { tagZh: "接著 · 接上英文 id", tagEn: "Then · Accept id", keys: "i,d,Tab" }
      ],
      targetDisplay: "用 id ",
      check: (text) => text.trim() === "用 id" && text.startsWith("用 id"),
      demo: [
        { key: "b" }, { key: "q" }, { key: " " },
        { key: "i" }, { key: "d" }, { key: "Tab" }
      ]
    },
    {
      id: "revert",
      pillZh: "2. 按錯換回",
      pillEn: "2. Instant Swap",
      timeZh: "約 5 秒",
      timeEn: "~5 sec",
      titleZh: "按錯空白鍵？立刻互換中英文",
      titleEn: "Pressed Space by mistake? Swap immediately",
      goalZh: "先打出「下」，不用按退格刪除，直接同時按下 Shift 與空白鍵換成英文「my 」。",
      goalEn: "Type 下 first, then without backspacing press Shift and Space together to swap to \"my \".",
      steps: [
        { tagZh: "步驟 1 · 先打出「下」", tagEn: "Step 1 · Type 下", keys: "m,y,Space" },
        { tagZh: "接著 · 立刻互換成英文", tagEn: "Then · Swap to English", keys: "Shift+Space" }
      ],
      targetDisplay: "my ",
      check: (text) => text.trim() === "my",
      demo: [
        { key: "m" }, { key: "y" }, { key: " " },
        { key: " ", shiftKey: true }
      ]
    },
    {
      id: "punct",
      pillZh: "3. 標點換全形",
      pillEn: "3. Punctuation Swap",
      timeZh: "約 6 秒",
      timeEn: "~6 sec",
      titleZh: "英文後接中文全形標點",
      titleEn: "Fullwidth Chinese punctuation after English",
      goalZh: "先打出保留大小寫的 GitHub 與半形逗號，立刻同時按 Shift 與空白鍵換成全形「GitHub，」。",
      goalEn: "Type GitHub and a halfwidth comma, then immediately press Shift and Space for 「GitHub，」.",
      steps: [
        { tagZh: "步驟 1 · 打出 GitHub,", tagEn: "Step 1 · Type GitHub,", keys: "G,i,t,H,u,b,Enter,," },
        { tagZh: "接著 · 逗號換全形", tagEn: "Then · Make comma fullwidth", keys: "Shift+Space" }
      ],
      targetDisplay: "GitHub，",
      check: (text) => text.trim() === "GitHub，",
      demo: [
        { key: "G" }, { key: "i" }, { key: "t" }, { key: "H" }, { key: "u" }, { key: "b" },
        { key: "Enter" }, { key: "," }, { key: " ", shiftKey: true }
      ]
    },
    {
      id: "pair",
      pillZh: "4. 八種引號括號",
      pillEn: "4. Paired Brackets",
      timeZh: "約 7 秒",
      timeEn: "~7 sec",
      titleZh: "用方括號切換八種引號與括號",
      titleEn: "Switch 8 paired quotes & brackets in one tap",
      goalZh: "先用左右方括號打出「明日」，立刻按 Shift 與空白鍵叫出選項列，再按數字 4 整對換成《明日》。",
      goalEn: "Type 「明日」 with square brackets, then press Shift and Space followed by 4 to switch to 《明日》.",
      steps: [
        { tagZh: "步驟 1 · 先打出「明日」", tagEn: "Step 1 · Type 「明日」", keys: "[,a,b,Space,a,Space,]" },
        { tagZh: "接著 · 整對換成《明日》", tagEn: "Then · Switch to 《明日》", keys: "Shift+Space,4" }
      ],
      targetDisplay: "《明日》",
      check: (text) => text.trim() === "《明日》",
      demo: [
        { key: "[" }, { key: "a" }, { key: "b" }, { key: " " }, { key: "a" }, { key: " " }, { key: "]" },
        { key: " ", shiftKey: true }, { key: "4" }
      ]
    },
    {
      id: "rescue",
      pillZh: "5. 查拆碼與符號",
      pillEn: "5. Lookup & Symbols",
      timeZh: "約 6 秒",
      timeEn: "~6 sec",
      titleZh: "忘了倉頡怎麼拆？用注音或拼音查，也能開符號面板",
      titleEn: "Forgot a Cangjie code? Look it up or open symbols",
      goalZh: "任選下方一種方式完成：用注音／拼音查字選出「厝」，或開符號面板選出刪節號「……」。",
      goalEn: "Choose either path: look up 「厝」 by Zhuyin/Pinyin, or insert 「……」 from the Symbol Panel.",
      steps: [
        { tagZh: "方式 A · 注音查「厝」", tagEn: "Option A · Lookup 「厝」", keys: "Ctrl+Shift+;,h,j,i,4,5" },
        { orSeparator: true },
        { tagZh: "方式 B · 符號面板「……」", tagEn: "Option B · Symbol 「……」", keys: "Option+Shift+B,2" }
      ],
      targetDisplay: "厝 或 ……",
      check: (text) => text.includes("厝") || text.includes("……"),
      hasChordAssist: true,
      demo: [
        { trigger: "reading" },
        { key: "h" }, { key: "j" }, { key: "i" }, { key: "4" }, { key: "5" }
      ]
    }
  ];

  // === 5. 介面多語字典 ===
  const I18N = {
    zh: {
      brandName: "蒼鷹輸入法",
      navOnboarding: "30 秒上手",
      navPlayground: "自由練習場",
      navManual: "使用指南",
      navCheatsheet: "快捷鍵",
      navFaq: "常見問答",
      copyPageBtn: "複製頁面",
      menuCopyMdTitle: "複製本頁為 Markdown",
      menuCopyMdDesc: "含安裝、快捷鍵與常見問答，直接貼給 AI",
      menuViewMdTitle: "檢視純 Markdown ↗",
      menuViewMdDesc: "開啟 guide.md 純文字版本",
      menuLlmsTitle: "開啟 llms.txt ↗",
      menuLlmsDesc: "AI 代理與爬蟲專用結構化索引",
      menuAiInstallTitle: "複製 AI 代理安裝指令",
      menuAiInstallDesc: "貼給能操作 Mac 的 AI 代理自動安裝",
      faqEyebrow: "FAQ · 常見問答",
      faqTitle: "常見問題與解答",
      faqDesc: "針對倉頡使用者最常問的系統支援、學習門檻、隱私安全與終端機相容性，一次回答清楚。",
      downloadMac: "下載 Mac 版",
      pillMac: "macOS 14+",
      pillCangjie: "倉頡三代 / 五代",
      pillPrivacy: "純離線 · 零追蹤",
      heroTitle: "倉頡拆碼，英文直打，<br>不再來回切換輸入法。",
      heroLead: "中文照常按空白鍵送出，英文直接拼按 Tab 補完並自動留空格。花 30 秒在底下完成五個手勢，馬上建立肌肉記憶。",
      ctaStart: "開始 30 秒互動練習",
      ctaDownload: "下載 GoshawkIME.dmg",
      heroWindowTitle: "工作筆記.rtf",
      keySpace: "空白鍵",
      keyShiftSpace: "Shift+空白",
      legendRevert: "隨時反悔",
      onboardingEyebrow: "INTERACTIVE ONBOARDING · 30 SECONDS",
      onboardingTitle: "30 秒建立核心肌肉記憶",
      onboardingDesc: "未安裝可直接用「線上模擬」試打；已安裝可切到「本機蒼鷹」用真實輸入法驗收。",
      modeSim: "線上模擬",
      modeLive: "本機蒼鷹",
      btnAutoDemo: "▶ 自動示範",
      btnResetStep: "重試本關",
      btnNextStep: "下一關",
      chordAssistLabel: "若瀏覽器攔截組合鍵，可直接點下方按鈕開啟面板：",
      btnOpenLookup: "開啟注音／拼音查拆碼",
      btnOpenSymbol: "開啟符號面板",
      btnOpenLookupShort: "注音／拼音查拆碼",
      btnOpenSymbolShort: "符號面板",
      liveNote: "請先從右上角 macOS 選單列切換到「蒼鷹輸入法」，再點進下方輸入框直接照關卡實打。",
      liveExpectLabel: "預期結果：",
      completeTitle: "30 秒核心手勢全部完成。",
      completeDesc: "你已經掌握蒼鷹日常最常用的操作：空白出中文、Tab 出英文、Shift 加空白立刻互換，以及忘記拆碼時用注音或拼音查字。",
      btnRestartAll: "再練一次",
      playgroundEyebrow: "FREE PLAYGROUND",
      playgroundTitle: "自由練習場",
      playgroundDesc: "照右側日常句子試打，體驗中英混打、反引號寫程式碼與八種引號括號。「線上模擬」內建精選常用字；已安裝可切到「本機蒼鷹」任意輸入。",
      btnClear: "清空",
      pgTryTitle: "日常句子試打",
      pgTryNote: "點任一句即可聚焦輸入區並查看按法提示：",
      pgLexiconTitle: "線上模擬內建常用字",
      pgLexiconSub: "本機蒼鷹完整版收錄超過 14,000 筆倉頡三／五代碼與近萬英文詞彙。",
      manualEyebrow: "USER GUIDE",
      manualTitle: "重點使用指南",
      manualDesc: "點選下方主題快速查看，每次只呈現最相關的重點。",
      catMixed: "中英混打",
      catPunct: "標點與引號",
      catCode: "寫程式與終端機",
      catLookup: "查拆碼與符號",
      catSetup: "安裝與隱私",
      manualEmpty: "找不到符合的指南內容，試試其他關鍵字。",
      cheatEyebrow: "QUICK REFERENCE",
      cheatTitle: "單頁快捷鍵速查表",
      cheatDesc: "把這張表記住，就能流暢駕馭蒼鷹全部功能。",
      btnPrint: "列印速查表",
      thKey: "按鍵",
      thAction: "作用",
      ckSpace: "打出倉頡首選字（反引號裡優先出英文）",
      ckTab: "接受英文建議並補一格空格（反引號裡不加空格）",
      ckEnter: "保留原本大小寫打出字母，字尾不加空格",
      ckShiftSpace: "打完立刻互換中英文、標點全半形或八種引號括號；打字中展開候選列",
      ckDoubleShift: "切換純英文模式，再連按兩下回到混打",
      ckCaps: "亮燈期間直出小寫英數與半形標點（加 Shift 出大寫）",
      ckBrackets: "打出八種成對引號括號；結尾自動配對，緊接 Shift 加空白與數字 1 至 8 換種類",
      ckBacktick: "用反引號寫程式與指令：優先出英文、標點半形、不自動補空格",
      ckCtrlPunct: "按住 Ctrl 加標點，單次強制輸出全形標點（支援 , . \\ ; ! ? ( )）",
      ckOptPunct: "按住 Option 加標點，單次強制輸出半形標點",
      ckHalfPunct: "切換「使用半形標點符號」",
      ckReading: "忘了倉頡怎麼拆？開啟注音／拼音查拆碼",
      ckSymbol: "開啟符號面板（最近使用、標點、符號三分頁）",
      cardMixedTitle: "中英直接混打與自動空格",
      cardRevertTitle: "按錯不用重打：立刻互換",
      cardPunctTitle: "中英文標點自動判斷與切換",
      cardPairTitle: "方括號打出八種常用引號與括號",
      cardSnippetTitle: "用反引號寫指令與程式碼",
      cardTerminalTitle: "終端機相容速查",
      cardReadingTitle: "忘了倉頡怎麼拆？用注音或拼音查字",
      cardSymbolTitle: "符號面板（151 個標準標點與符號）",
      cardInstallTitle: "安裝、升級與移除",
      cardPrivacyTitle: "設定與隱私承諾",
      footerTag: "蒼鷹輸入法（Goshawk IME）· MIT 開源授權 · 本頁面零追蹤、可完全離線開啟",
      footerReleases: "發行版本",
      footerIssues: "回報問題"
    },
    en: {
      brandName: "Goshawk IME",
      navOnboarding: "30s Onboarding",
      navPlayground: "Playground",
      navManual: "Guide",
      navCheatsheet: "Shortcuts",
      navFaq: "FAQ",
      copyPageBtn: "Copy page",
      menuCopyMdTitle: "Copy page as Markdown",
      menuCopyMdDesc: "Full guide, shortcuts, and FAQ ready to paste into an LLM",
      menuViewMdTitle: "View as Markdown ↗",
      menuViewMdDesc: "Open raw guide.md in a new tab",
      menuLlmsTitle: "Open llms.txt ↗",
      menuLlmsDesc: "Structured index for AI agents and crawlers",
      menuAiInstallTitle: "Copy AI install prompt",
      menuAiInstallDesc: "Paste to a Mac-capable AI agent to install Goshawk",
      faqEyebrow: "FAQ",
      faqTitle: "Frequently Asked Questions",
      faqDesc: "Direct answers on compatibility, learning curve, privacy, and terminal support.",
      downloadMac: "Download for Mac",
      pillMac: "macOS 14+",
      pillCangjie: "Cangjie 3 & 5",
      pillPrivacy: "Offline · Zero Tracking",
      heroTitle: "Type Cangjie and English<br>in one unbroken flow.",
      heroLead: "Space commits Chinese, Tab accepts English with smart spacing, and Shift+Space reverses a slip instantly. Spend 30 seconds on five exercises below to build muscle memory.",
      ctaStart: "Start 30s Interactive Guide",
      ctaDownload: "Download GoshawkIME.dmg",
      heroWindowTitle: "Notes.rtf",
      keySpace: "Space",
      keyShiftSpace: "Shift+Space",
      legendRevert: "Instant swap",
      onboardingEyebrow: "INTERACTIVE ONBOARDING · 30 SECONDS",
      onboardingTitle: "Build Muscle Memory in 30 Seconds",
      onboardingDesc: "Try right away in Web Simulator, or switch to Installed Goshawk after installing on your Mac.",
      modeSim: "Web Simulator",
      modeLive: "Installed Goshawk",
      btnAutoDemo: "▶ Watch Demo",
      btnResetStep: "Reset Step",
      btnNextStep: "Next Step",
      chordAssistLabel: "If your browser intercepts shortcuts, open the panel directly:",
      btnOpenLookup: "Open Zhuyin / Pinyin Lookup",
      btnOpenSymbol: "Open Symbol Panel",
      btnOpenLookupShort: "Code Lookup",
      btnOpenSymbolShort: "Symbols",
      liveNote: "Switch macOS input source to Goshawk from the menu bar, then type directly in the box below.",
      liveExpectLabel: "Expected output:",
      completeTitle: "All 5 core gestures complete.",
      completeDesc: "You now have the muscle memory for Space/Tab split, Shift+Space swap, paired brackets, and lookup tools.",
      btnRestartAll: "Practice Again",
      playgroundEyebrow: "FREE PLAYGROUND",
      playgroundTitle: "Interactive Playground",
      playgroundDesc: "Try the real-world sentences on the right in Web Simulator, or switch to Installed Goshawk to type anything freely.",
      btnClear: "Clear",
      pgTryTitle: "Real-World Sentences",
      pgTryNote: "Click any sentence to focus the input area and view key tips:",
      pgLexiconTitle: "Web Simulator Sample Words",
      pgLexiconSub: "Installed Goshawk ships with 14,000+ Cangjie entries and ~10,000 English words.",
      manualEyebrow: "USER GUIDE",
      manualTitle: "Focused User Guide",
      manualDesc: "Pick a topic tab to scan key points without wall-of-text clutter.",
      catMixed: "Mixed Typing",
      catPunct: "Punctuation & Pairs",
      catCode: "Code & Terminals",
      catLookup: "Lookup & Symbols",
      catSetup: "Install & Privacy",
      manualEmpty: "No matching guide entries found.",
      cheatEyebrow: "QUICK REFERENCE",
      cheatTitle: "Shortcut Cheat Sheet",
      cheatDesc: "One printable reference covering every Goshawk gesture.",
      btnPrint: "Print Cheat Sheet",
      thKey: "Shortcut",
      thAction: "Action",
      ckSpace: "Commit top Cangjie candidate (English-first inside backticks)",
      ckTab: "Accept English prediction + space (no trailing space inside snippets)",
      ckEnter: "Commit literal buffer with original casing, no trailing space",
      ckShiftSpace: "Swap last Chinese/English, punctuation width, or paired brackets; focus candidates while composing",
      ckDoubleShift: "Toggle Pure English mode; double-tap again to return",
      ckCaps: "Type lowercase ASCII and halfwidth punctuation while Caps Lock is on",
      ckBrackets: "Type paired brackets; ] matches unclosed opener, Shift+Space and 1–8 switch all 8 styles",
      ckBacktick: "Inline code snippet context: English-first, halfwidth punctuation, no auto spacing",
      ckCtrlPunct: "Force fullwidth punctuation once (, . \\ ; ! ? ( ))",
      ckOptPunct: "Force halfwidth punctuation once (e.g. Option+., Option+])",
      ckHalfPunct: "Toggle halfwidth punctuation mode",
      ckReading: "Open Reading Lookup panel (Zhuyin and Hanyu Pinyin)",
      ckSymbol: "Open Symbol Panel (Recent, Punctuation, Symbols)",
      cardMixedTitle: "Mixed Typing & Automatic Spacing",
      cardRevertTitle: "Instant Swap (Shift+Space)",
      cardPunctTitle: "Smart Punctuation & Width Overrides",
      cardPairTitle: "8 Paired Brackets with [ and ]",
      cardSnippetTitle: "Inline Code Snippets (` ... `)",
      cardTerminalTitle: "Terminals & Editor Compatibility",
      cardReadingTitle: "Reading Lookup (Zhuyin & Pinyin)",
      cardSymbolTitle: "Symbol Panel (151 Symbols)",
      cardInstallTitle: "Install, Upgrade & Uninstall",
      cardPrivacyTitle: "Settings, Learning & Privacy",
      footerTag: "Goshawk IME · MIT License · Zero tracking, works completely offline",
      footerReleases: "Releases",
      footerIssues: "Report Issue"
    }
  };

  // === 6. 狀態管理與初始化 ===
  const params = new URLSearchParams(window.location.search);
  let lang = params.get("lang") === "en" ? "en" : (params.get("lang") === "zh" ? "zh" : (safeGet("goshawk.guide.lang") || "zh"));
  let theme = safeGet("goshawk.guide.theme") || "auto";
  let onboardingMode = "sim";
  let currentStep = 0;
  const completedSteps = new Set();
  let demoTimer = null;

  function safeGet(key) {
    try { return localStorage.getItem(key); } catch (_) { return null; }
  }
  function safeSet(key, val) {
    try { localStorage.setItem(key, val); } catch (_) {}
  }

  // DOM 參考
  const $ = (id) => document.getElementById(id);

  const simStage = $("simStage");
  const simText = $("simText");
  const simMarked = $("simMarked");
  const simPlaceholder = $("simPlaceholder");
  const simOverlaySlot = $("simOverlaySlot");
  const simFeed = $("simFeed");
  const stageStatus = $("stageStatus");
  const liveStage = $("liveStage");
  const liveInput = $("liveInput");
  const liveExpectValue = $("liveExpectValue");
  const chordAssist = $("chordAssist");

  const pgSimStage = $("pgSimStage");
  const pgText = $("pgText");
  const pgMarked = $("pgMarked");
  const pgPlaceholder = $("pgPlaceholder");
  const pgOverlaySlot = $("pgOverlaySlot");
  const pgFeed = $("pgFeed");
  const pgBadges = $("pgBadges");
  const pgLiveStage = $("pgLiveStage");
  const pgLiveTextarea = $("pgLiveTextarea");

  // 建立兩個獨立的模擬器實體（教學用 / 自由練習場用）
  const onboardingSim = new GoshawkSim((sim) => {
    simText.textContent = sim.doc;
    simMarked.textContent = sim.buffer;
    simPlaceholder.classList.toggle("is-hidden", Boolean(sim.doc || sim.buffer || sim.layer));
    renderOverlay(sim, simOverlaySlot);
    if (sim.feed) simFeed.textContent = sim.feed;
    evaluateStep(sim.doc);
  });

  const playgroundSim = new GoshawkSim((sim) => {
    pgText.textContent = sim.doc;
    pgMarked.textContent = sim.buffer;
    pgPlaceholder.classList.toggle("is-hidden", Boolean(sim.doc || sim.buffer || sim.layer));
    renderOverlay(sim, pgOverlaySlot);
    if (sim.feed) pgFeed.textContent = sim.feed;

    pgBadges.innerHTML = "";
    if (sim.snippet) pgBadges.innerHTML += `<span class="pg-badge">片段</span>`;
    if (sim.pureEnglish) pgBadges.innerHTML += `<span class="pg-badge">純英文</span>`;
  });

  function stopDemo() {
    if (demoTimer) {
      clearTimeout(demoTimer);
      demoTimer = null;
    }
  }

  function applyTheme() {
    if (theme === "dark" || theme === "light") {
      document.documentElement.setAttribute("data-theme", theme);
    } else {
      document.documentElement.removeAttribute("data-theme");
    }
    $("themeToggle").textContent = theme === "dark" ? "☀" : (theme === "light" ? "☾" : "◐");
  }

  function applyLang() {
    document.documentElement.lang = lang === "en" ? "en" : "zh-Hant";
    $("langToggle").textContent = lang === "en" ? "繁中" : "EN";
    const dict = I18N[lang];
    document.querySelectorAll("[data-i18n]").forEach((el) => {
      const key = el.getAttribute("data-i18n");
      if (dict[key]) {
        if (key === "heroTitle") el.innerHTML = dict[key];
        else el.textContent = dict[key];
      }
    });
    renderStepPills();
    renderMission();
    hydrateKeycaps();
    onboardingSim.emit();
    playgroundSim.emit();
  }

  function renderStepPills() {
    const wrap = $("stepPills");
    wrap.innerHTML = "";
    MISSIONS.forEach((m, idx) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "step-pill";
      if (idx === currentStep) btn.classList.add("is-current");
      if (completedSteps.has(m.id)) btn.classList.add("is-done");
      const mark = completedSteps.has(m.id) ? "✓ " : "";
      btn.textContent = mark + (lang === "en" ? m.pillEn : m.pillZh);
      btn.addEventListener("click", () => selectStep(idx));
      wrap.appendChild(btn);
    });
    const pct = Math.round((completedSteps.size / MISSIONS.length) * 100);
    $("progressText").textContent = `${completedSteps.size} / ${MISSIONS.length}`;
    $("progressFill").style.width = `${pct}%`;
    $("completeBanner").classList.toggle("is-hidden", completedSteps.size < MISSIONS.length);
  }

  function renderMission() {
    const m = MISSIONS[currentStep];
    $("missionBadge").textContent = lang === "en" ? `Step ${currentStep + 1}` : `第 ${currentStep + 1} 關`;
    $("missionTime").textContent = lang === "en" ? m.timeEn : m.timeZh;
    $("missionTitle").textContent = lang === "en" ? m.titleEn : m.titleZh;
    $("missionGoal").textContent = lang === "en" ? m.goalEn : m.goalZh;
    $("missionTargetChip").textContent = `${lang === "en" ? "Goal:" : "目標："} ${m.targetDisplay}`;
    liveExpectValue.textContent = m.targetDisplay;

    const keysWrap = $("missionKeys");
    keysWrap.innerHTML = "";
    const stepsContainer = document.createElement("div");
    stepsContainer.className = "key-steps";
    m.steps.forEach((step) => {
      if (step.orSeparator) {
        const orEl = document.createElement("div");
        orEl.className = "key-step-or";
        orEl.textContent = lang === "en" ? "OR" : "或者";
        stepsContainer.appendChild(orEl);
        return;
      }
      const row = document.createElement("div");
      row.className = "key-step-row";
      const tag = document.createElement("span");
      tag.className = "key-step-tag";
      tag.textContent = lang === "en" ? step.tagEn : step.tagZh;
      const seq = document.createElement("span");
      seq.className = "kseq";
      seq.innerHTML = renderKeyExpr(step.keys, { small: false });
      row.appendChild(tag);
      row.appendChild(seq);
      stepsContainer.appendChild(row);
    });
    keysWrap.appendChild(stepsContainer);

    chordAssist.classList.toggle("is-hidden", !(m.hasChordAssist && onboardingMode === "sim"));
    $("stageModeLabel").textContent = onboardingMode === "sim"
      ? (lang === "en" ? "Practice · Web Simulator" : "練習區 · 線上模擬")
      : (lang === "en" ? "Practice · Installed Goshawk" : "練習區 · 本機蒼鷹");

    stageStatus.textContent = completedSteps.has(m.id) ? (lang === "en" ? "✓ Passed" : "✓ 過關") : "";
    stageStatus.classList.toggle("is-pass", completedSteps.has(m.id));
  }

  function selectStep(idx) {
    stopDemo();
    currentStep = (idx + MISSIONS.length) % MISSIONS.length;
    onboardingSim.reset();
    liveInput.value = "";
    renderStepPills();
    renderMission();
    if (onboardingMode === "sim") simStage.focus();
    else liveInput.focus();
  }

  function evaluateStep(text) {
    const m = MISSIONS[currentStep];
    if (!completedSteps.has(m.id) && m.check(text)) {
      completedSteps.add(m.id);
      renderStepPills();
      renderMission();
      simFeed.textContent = lang === "en"
        ? "Passed! Click Next Step or press Enter to continue."
        : "過關！點「下一關」繼續，或直接點上方關卡切換。";
    }
  }

  function runAutoDemo() {
    stopDemo();
    if (onboardingMode !== "sim") {
      setGlobalInputMode("sim");
    }
    const m = MISSIONS[currentStep];
    onboardingSim.reset();
    simStage.focus();
    const steps = m.demo;
    let i = 0;

    function tick() {
      if (i >= steps.length) {
        demoTimer = null;
        return;
      }
      const act = steps[i++];
      if (act.trigger === "reading") {
        onboardingSim.openReadingLookup();
      } else if (act.trigger === "symbol") {
        onboardingSim.openSymbolPanel();
      } else {
        onboardingSim.handleKey({
          key: act.key,
          code: act.code || "",
          shiftKey: Boolean(act.shiftKey),
          ctrlKey: Boolean(act.ctrlKey),
          altKey: Boolean(act.altKey),
          metaKey: false
        });
      }
      demoTimer = setTimeout(tick, 420);
    }
    tick();
  }

  function setGlobalInputMode(mode) {
    onboardingMode = mode;
    // 上下兩區模式與術語完全同步（「線上模擬」／「本機蒼鷹」）
    $("modeSimBtn").classList.toggle("is-active", mode === "sim");
    $("modeSimBtn").setAttribute("aria-selected", String(mode === "sim"));
    $("modeLiveBtn").classList.toggle("is-active", mode === "live");
    $("modeLiveBtn").setAttribute("aria-selected", String(mode === "live"));
    simStage.classList.toggle("is-hidden", mode !== "sim");
    liveStage.classList.toggle("is-hidden", mode !== "live");

    $("pgModeSim").classList.toggle("is-active", mode === "sim");
    $("pgModeSim").setAttribute("aria-selected", String(mode === "sim"));
    $("pgModeLive").classList.toggle("is-active", mode === "live");
    $("pgModeLive").setAttribute("aria-selected", String(mode === "live"));
    pgSimStage.classList.toggle("is-hidden", mode !== "sim");
    pgLiveStage.classList.toggle("is-hidden", mode !== "live");
    $("pgTriggers").classList.toggle("is-hidden", mode !== "sim");
    $("pgWinTitle").textContent = mode === "sim"
      ? (lang === "en" ? "Playground · Web Simulator" : "自由練習場 · 線上模擬")
      : (lang === "en" ? "Playground · Installed Goshawk" : "自由練習場 · 本機蒼鷹");
    renderMission();
  }

  // 事件綁定：教學區
  simStage.addEventListener("keydown", (e) => {
    if (e.metaKey) return; // 放行瀏覽器 Cmd 快捷鍵
    stopDemo();
    const handled = onboardingSim.handleKey(e);
    if (handled) e.preventDefault();
  });

  liveInput.addEventListener("input", () => {
    evaluateStep(liveInput.value);
  });

  $("modeSimBtn").addEventListener("click", () => setGlobalInputMode("sim"));
  $("modeLiveBtn").addEventListener("click", () => setGlobalInputMode("live"));
  $("btnAutoDemo").addEventListener("click", runAutoDemo);
  $("btnResetStep").addEventListener("click", () => {
    stopDemo();
    onboardingSim.reset();
    liveInput.value = "";
    if (onboardingMode === "sim") simStage.focus();
    else liveInput.focus();
  });
  $("btnNextStep").addEventListener("click", () => selectStep(currentStep + 1));
  $("btnRestartAll").addEventListener("click", () => {
    completedSteps.clear();
    selectStep(0);
  });
  $("btnTriggerReading").addEventListener("click", () => {
    simStage.focus();
    onboardingSim.openReadingLookup();
  });
  $("btnTriggerSymbol").addEventListener("click", () => {
    simStage.focus();
    onboardingSim.openSymbolPanel();
  });

  // 事件綁定：自由練習場
  pgSimStage.addEventListener("keydown", (e) => {
    if (e.metaKey) return;
    const handled = playgroundSim.handleKey(e);
    if (handled) e.preventDefault();
  });

  $("pgModeSim").addEventListener("click", () => setGlobalInputMode("sim"));
  $("pgModeLive").addEventListener("click", () => setGlobalInputMode("live"));
  $("pgClearBtn").addEventListener("click", () => {
    playgroundSim.reset();
    pgLiveTextarea.value = "";
    pgFeed.textContent = "已清空，點輸入框即可重新開始。";
  });
  $("pgBtnReading").addEventListener("click", () => {
    pgSimStage.focus();
    playgroundSim.openReadingLookup();
  });
  $("pgBtnSymbol").addEventListener("click", () => {
    pgSimStage.focus();
    playgroundSim.openSymbolPanel();
  });

  document.querySelectorAll(".sample-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      pgFeed.textContent = btn.dataset.hint;
      pgSimStage.focus();
    });
  });

  // 事件綁定：使用指南分頁切換（極簡 5 分頁，不需搜尋框）
  let activeCategory = "mixed";
  const manualCards = Array.from(document.querySelectorAll("#manualGrid .guide-card"));

  function filterManual() {
    manualCards.forEach((card) => {
      card.classList.toggle("is-hidden", card.dataset.cat !== activeCategory);
    });
  }

  $("manualFilters").querySelectorAll(".filter-pill").forEach((pill) => {
    pill.addEventListener("click", () => {
      activeCategory = pill.dataset.cat;
      $("manualFilters").querySelectorAll(".filter-pill").forEach((p) => p.classList.toggle("is-active", p === pill));
      filterManual();
    });
  });

  // === Copy page as Markdown（支援線上 fetch 與本機離線退路） ===
  const AI_INSTALL_PROMPT = "請依照 https://raw.githubusercontent.com/kcchien/goshawk-ime/main/INSTALL.md 的步驟，在這台 Mac 安裝蒼鷹輸入法。";

  function buildFallbackMarkdown() {
    const lines = [
      "# 蒼鷹輸入法（Goshawk IME）完整使用指南與常見問答",
      "",
      "> 網址：https://goshawk.kcchien.com/",
      "> 下載：https://github.com/kcchien/goshawk-ime/releases/latest/download/GoshawkIME.dmg",
      "> 原始碼：https://github.com/kcchien/goshawk-ime",
      "> 系統需求：macOS 14+（Apple Silicon & Intel 通用執行檔，Apple Developer ID 簽章與公證）",
      "> 授權：MIT License · 純離線運作 · 零追蹤",
      "",
      "## 安裝指令",
      "",
      "```sh",
      "curl -fsSL https://raw.githubusercontent.com/kcchien/goshawk-ime/main/scripts/install.sh | bash",
      "```",
      "",
      "## 重點使用指南",
      ""
    ];
    manualCards.forEach((card) => {
      const title = card.querySelector("h3")?.textContent.trim() || "";
      lines.push(`### ${title}`);
      card.querySelectorAll(".guide-item").forEach((item) => {
        const t = item.querySelector(".guide-item-title")?.textContent.trim() || "";
        const d = (item.querySelector(".guide-item-desc")?.textContent || item.querySelector(".guide-example")?.textContent || "").replace(/\s+/g, " ").trim();
        lines.push(`- **${t}**：${d}`);
      });
      lines.push("");
    });
    lines.push("## 常見問答（FAQ）", "");
    document.querySelectorAll("#faq .faq-card").forEach((card) => {
      const q = card.querySelector("h3")?.textContent.trim() || "";
      const a = (card.querySelector("p")?.textContent || "").replace(/\s+/g, " ").trim();
      lines.push(`### ${q}`, a, "");
    });
    return lines.join("\n");
  }

  async function copyTextToClipboard(text) {
    if (navigator.clipboard && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(text);
        return true;
      } catch (_) {}
    }
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch (_) {}
    document.body.removeChild(ta);
    return ok;
  }

  let copyFeedbackTimer = null;
  function flashCopyLabel(msgZh, msgEn) {
    const btn = $("copyPageBtn");
    const label = $("copyPageLabel");
    btn.classList.add("is-copied");
    label.textContent = lang === "en" ? msgEn : msgZh;
    clearTimeout(copyFeedbackTimer);
    copyFeedbackTimer = setTimeout(() => {
      btn.classList.remove("is-copied");
      label.textContent = I18N[lang].copyPageBtn;
    }, 1800);
  }

  async function copyPageAsMarkdown() {
    let md = "";
    if (window.location.protocol === "http:" || window.location.protocol === "https:") {
      try {
        const res = await fetch("./guide.md");
        if (res.ok) md = await res.text();
      } catch (_) {}
    }
    if (!md) md = buildFallbackMarkdown();
    await copyTextToClipboard(md);
    closeCopyMenu();
    flashCopyLabel("已複製 Markdown", "Copied Markdown");
  }

  function closeCopyMenu() {
    $("copyDropdown").classList.add("is-hidden");
    $("copyMenuToggle").setAttribute("aria-expanded", "false");
  }

  $("copyPageBtn").addEventListener("click", copyPageAsMarkdown);
  $("menuCopyMd").addEventListener("click", copyPageAsMarkdown);
  $("menuCopyAiInstall").addEventListener("click", async () => {
    await copyTextToClipboard(AI_INSTALL_PROMPT);
    closeCopyMenu();
    flashCopyLabel("已複製安裝指令", "Copied prompt");
  });

  $("copyMenuToggle").addEventListener("click", (e) => {
    e.stopPropagation();
    const dd = $("copyDropdown");
    const willOpen = dd.classList.contains("is-hidden");
    dd.classList.toggle("is-hidden", !willOpen);
    $("copyMenuToggle").setAttribute("aria-expanded", String(willOpen));
  });

  document.addEventListener("click", (e) => {
    if (!$("copySplit").contains(e.target)) closeCopyMenu();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeCopyMenu();
  });

  // 主題、語言與列印
  $("themeToggle").addEventListener("click", () => {
    theme = theme === "dark" ? "light" : "dark";
    safeSet("goshawk.guide.theme", theme);
    applyTheme();
  });

  $("langToggle").addEventListener("click", () => {
    lang = lang === "zh" ? "en" : "zh";
    safeSet("goshawk.guide.lang", lang);
    applyLang();
  });

  $("printCheatBtn").addEventListener("click", () => window.print());

  // 初始繪製
  applyTheme();
  applyLang();
  filterManual();
  onboardingSim.emit();
  playgroundSim.emit();
})();
