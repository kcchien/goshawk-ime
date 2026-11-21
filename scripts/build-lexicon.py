#!/usr/bin/env python3
import csv
import hashlib
import io
import math
import pathlib
import shutil
import subprocess
import tempfile
import unicodedata
import urllib.request
import zipfile
from collections import defaultdict

ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
RESOURCES_DIR = ROOT_DIR / "Sources" / "GoshawkCore" / "Resources"

CANGJIE_KEYS = set("abcdefghijklmnopqrstuvwxy")

# 讀音來源：全字庫（CNS11643 中文標準交換碼全字庫，數位發展部）的注音屬性資料，
# 採政府資料開放授權條款第 1 版。以 release.txt 標示的版本加各壓縮檔的內容 SHA-256
# 固定版本：上游不定期更新，雜湊不符就停止而不是默默換資料。
CNS_BASE_URL = "https://data.cns11643.gov.tw/opendata/"
CNS_VERSION = "20261028"
CNS_ARCHIVES = {
    "Properties.zip": "d20fb0ee58a2602b2d9dc1f7a50ef573d33e8fbf52607bc9a30a4fdc3401fb76",
    "MapingTables.zip": "605cadc2074cb5399bf03a268ab1f66a52384f08acb27021178c13d041cb87d2",
}
CNS_PHONETIC_MEMBER = "CNS_phonetic.txt"
# BMP 與第 2 字面就蓋得住倉頡碼表的字（Big5 字集全在 BMP），其餘字面不必解壓。
CNS_UNICODE_MEMBERS = (
    "Unicode/CNS2UNICODE_Unicode BMP.txt",
    "Unicode/CNS2UNICODE_Unicode 2.txt",
)

# 全字庫的輕聲寫成開頭的點，其餘聲調寫成結尾的調號，一聲不加調號。
CNS_TONE_MARKS = {"ˊ": 2, "ˇ": 3, "ˋ": 4}
CNS_NEUTRAL_TONE_MARK = "˙"

# 上游的注音資料錯誤：2-3378（啐）多了一列「˙ㄑ」，ㄑ 不能單獨成音節。
# 同一個字另有正確的「ㄘㄨㄟˋ」，跳過這一列不會少收讀音。
# 列成具名例外而不是放寬自我檢查，上游新增別的壞資料時產生器才會停下來。
CNS_PHONETIC_EXCEPTIONS = {("啐", "˙ㄑ")}

# 倉頡碼表來源：libcangjie 的 data/table.txt，該檔的說明檔聲明資料置於公眾領域。
# 固定在 table.txt 最後一次變更的提交，連說明檔一起比對雜湊：
# 上游若改動資料或改寫授權聲明，產生器停止而不是默默沿用舊的授權結論。
# gitlab.freedesktop.org 的 SSH 主機金鑰無法由公開來源核對，因此以 HTTPS 單檔下載，
# 並以提交雜湊加內容 SHA-256 固定版本。
LIBCANGJIE_PROJECT = "cangjie%2Flibcangjie"
LIBCANGJIE_COMMIT = "1f95d1d56ffb328779d46baaab7431fa31349f1e"
LIBCANGJIE_FILES = {
    "data/table.txt": "86118f2a50591b837e3317a3dab87f96e7188c54046e8ed20dd4a0933877d3ea",
    "data/README.table.md": "5962758f991e9119dddf78391202443731264332ea6b1f013791ba599fcb1b5d",
}

# table.txt 的欄位定義見 data/README.table.md，共 15 欄。只用得到這三欄。
LC_FIELD_COUNT = 15
LC_CHAR = 0
LC_CANGJIE3 = 11
LC_CANGJIE5 = 12

# Big5 三個分區的碼位界線，用來決定候選順位。
BIG5_COMMON_RANGE = (0xA440, 0xC67E)
BIG5_LESS_COMMON_RANGE = (0xC940, 0xF9D5)

# 常用度來源：Unicode Unihan 資料庫的 Unihan_DictionaryLikeData.txt。
# 以版本化網址加內容 SHA-256 固定版本，比照其他來源的做法。
UNIHAN_URL = "https://www.unicode.org/Public/18.0.0/ucd/Unihan.zip"
UNIHAN_VERSION = "18.0.0"
UNIHAN_SHA256 = "4c93ea9c1f636451729a840978f1667a53886af37ba854fdcce109721c63d43e"
UNIHAN_MEMBER = "Unihan_DictionaryLikeData.txt"

# 主要讀音來源：同一份 Unihan 壓縮檔的 Unihan_Readings.txt 的 kMandarin 欄。
# 依 UAX #38，kMandarin 是「the most customary pīnyīn reading for this ideograph」，
# 而且「When there are two values, then the first is preferred for zh-Hans (CN) and
# the second is preferred for zh-Hant (TW)」，所以取最後一個值就是台灣慣用的那個讀音。
UNIHAN_READINGS_MEMBER = "Unihan_Readings.txt"

# 帶調漢語拼音的調號（NFD 分解後的結合字元）。沒有調號的音節是輕聲。
PINYIN_TONE_MARKS = {"̄": 1, "́": 2, "̌": 3, "̀": 4}

# kFenn 的尾字母是 Fenn《The Five Thousand Dictionary》的粗略字頻分級：
# 依 UAX #38，A 是最常用的 500 字，B 是接下來五百字，依此類推。資料裡沒有 J，
# 十個字母合計約五千字，所以字母在這個字串裡的位置就是「第幾個五百字」。
# 尾字母 P（Fenn 只因它是其他字的聲符才收的罕用字）與 *（不在該字典裡）不是分級，不採用。
FENN_BAND_LETTERS = "ABCDEFGHIK"

# 英文基礎語料：Google Books Ngram 衍生的英文一元詞頻表，上游標示 CC BY 3.0。
NGRAM_SOURCE_PATH = "ngrams/1grams_english.csv"
NGRAM_SOURCE_COMMIT = "6a72a4d96a2c36717479e9e9bf4e24260b3dbdae"
NGRAM_SOURCE_SHA256 = "f7f63aa08f0bb2f7f654cddff3a7ced4968b27887b2c0e7cd4b4d108221e197d"

# 書籍語料未過濾髒話。原詞表是 no-swears 版，這裡自列排除清單維持同樣性質。
# 只列固定來源裡真的出現、且屬於罵人或猥褻用語的詞；sexual、naked、breast、sperm
# 這類臨床或中性用詞保留，與原詞表一致。
EXCLUDED_WORDS = frozenset(
    """
    fuck fucking shit cock dick bastard bitch damn damned hell ass crap
    penis vaginal anal rape sex sexy erotic breasts nipples queer
    """.split()
)

DEV_TERMS = [
    ("git", 85_500),
    ("github", 84_500),
    # 書籍語料沒有 http，但它原本就在詞表裡，少了會讓 htt 預測不出 HTTP。
    ("http", 84_000),
    ("docker", 83_500),
    ("kubectl", 82_500),
    ("k8s", 81_500),
    ("typescript", 80_500),
    ("postgres", 79_500),
    ("useState", 78_500),
    ("useEffect", 77_500),
    ("useReducer", 76_800),
    ("async", 76_500),
    ("await", 75_500),
    ("localhost", 74_500),
    ("terraform", 73_500),
    ("mp3", 72_500),
    ("h264", 71_500),
    ("es6", 70_500),
    ("nginx", 70_200),
    ("graphql", 69_800),
]

EXTRA_COMMON_WORDS = [
    ("a", 94_000),
    ("i", 69_000),
    ("ok", 71_000),
    ("hi", 70_000),
    ("doc", 60_000),
    ("id", 45_000),
    ("idea", 72_000),
]


def is_valid_cangjie_char(word: str) -> bool:
    if not word or "," in word or "\t" in word:
        return False
    for ch in word:
        cp = ord(ch)
        if 0xE000 <= cp <= 0xF8FF or 0xF0000 <= cp <= 0xFFFFD or 0x100000 <= cp <= 0x10FFFD:
            return False
    return True


def normalize_han_char(word: str) -> str:
    """統一成 NFC。相容漢字（如 U+FA0C 兀）正規化後與統一漢字同形。

    Swift 的 String 以標準等價比較，兩形在查詢端本來就是同一個字。資料端先合併，
    讀音列不會列出看起來重複的字，原生碼也不會被空欄位蓋掉。
    """
    return unicodedata.normalize("NFC", word)


# 注音轉拼音。三張介音表加一張韻母表，取代散落的條件式。
BPMF_INITIALS = {
    "ㄅ": "b", "ㄆ": "p", "ㄇ": "m", "ㄈ": "f",
    "ㄉ": "d", "ㄊ": "t", "ㄋ": "n", "ㄌ": "l",
    "ㄍ": "g", "ㄎ": "k", "ㄏ": "h",
    "ㄐ": "j", "ㄑ": "q", "ㄒ": "x",
    "ㄓ": "zh", "ㄔ": "ch", "ㄕ": "sh", "ㄖ": "r",
    "ㄗ": "z", "ㄘ": "c", "ㄙ": "s",
}
BPMF_MEDIALS = ("ㄧ", "ㄨ", "ㄩ")
BPMF_FINALS = {
    "ㄚ": "a", "ㄛ": "o", "ㄜ": "e", "ㄝ": "ê",
    "ㄞ": "ai", "ㄟ": "ei", "ㄠ": "ao", "ㄡ": "ou",
    "ㄢ": "an", "ㄣ": "en", "ㄤ": "ang", "ㄥ": "eng", "ㄦ": "er",
}
# 捲舌與舌尖聲母單獨成音節時補 i：zhi、chi、shi、ri、zi、ci、si。
BPMF_STANDALONE_I = set("ㄓㄔㄕㄖㄗㄘㄙ")
# 零聲母由介音起頭，寫法與帶聲母時不同。
BPMF_ZERO_ONSET = {
    "ㄧ": {
        None: "yi", "ㄚ": "ya", "ㄛ": "yo", "ㄝ": "ye", "ㄞ": "yai",
        "ㄠ": "yao", "ㄡ": "you", "ㄢ": "yan", "ㄣ": "yin",
        "ㄤ": "yang", "ㄥ": "ying",
    },
    "ㄨ": {
        None: "wu", "ㄚ": "wa", "ㄛ": "wo", "ㄞ": "wai", "ㄟ": "wei",
        "ㄢ": "wan", "ㄣ": "wen", "ㄤ": "wang", "ㄥ": "weng",
    },
    "ㄩ": {None: "yu", "ㄝ": "yue", "ㄢ": "yuan", "ㄣ": "yun", "ㄥ": "yong"},
}
BPMF_MEDIAL_I = {
    None: "i", "ㄚ": "ia", "ㄛ": "io", "ㄝ": "ie", "ㄞ": "iai",
    "ㄠ": "iao", "ㄡ": "iu", "ㄢ": "ian", "ㄣ": "in",
    "ㄤ": "iang", "ㄥ": "ing",
}
BPMF_MEDIAL_U = {
    None: "u", "ㄚ": "ua", "ㄛ": "uo", "ㄞ": "uai", "ㄟ": "ui",
    "ㄢ": "uan", "ㄣ": "un", "ㄤ": "uang", "ㄥ": "ong",
}
# ㄩ 在 ㄐㄑㄒ 後寫 u、在 ㄋㄌ 後寫 ü；ㄩㄥ 兩者都寫 iong。
BPMF_MEDIAL_YU = {None: "{v}", "ㄝ": "{v}e", "ㄢ": "{v}an", "ㄣ": "{v}n", "ㄥ": "iong"}
BPMF_YU_WRITES_U = set("ㄐㄑㄒ")


def split_syllable(syllable: str) -> tuple[str | None, str | None, str | None]:
    """把去調注音拆成聲母、介音、韻母。順序或成分不合就丟 ValueError。"""
    initial = medial = final = None
    rest = syllable
    if rest and rest[0] in BPMF_INITIALS:
        initial, rest = rest[0], rest[1:]
    if rest and rest[0] in BPMF_MEDIALS:
        medial, rest = rest[0], rest[1:]
    if rest and rest[0] in BPMF_FINALS:
        final, rest = rest[0], rest[1:]
    if rest or (initial is None and medial is None and final is None):
        raise ValueError(f"無法拆解注音音節：{syllable}")
    return initial, medial, final


def bopomofo_to_pinyin(syllable: str) -> str:
    """去調注音轉去調漢語拼音。ü 寫成 ü，不用 v。"""
    initial, medial, final = split_syllable(syllable)

    if medial is None:
        if initial is None:
            return BPMF_FINALS[final]
        if final is None:
            if initial in BPMF_STANDALONE_I:
                return BPMF_INITIALS[initial] + "i"
            raise ValueError(f"聲母無法單獨成音節：{syllable}")
        return BPMF_INITIALS[initial] + BPMF_FINALS[final]

    if initial is None:
        table = BPMF_ZERO_ONSET[medial]
        if final not in table:
            raise ValueError(f"零聲母找不到寫法：{syllable}")
        return table[final]

    if medial == "ㄧ":
        table, suffix = BPMF_MEDIAL_I, None
    elif medial == "ㄨ":
        table, suffix = BPMF_MEDIAL_U, None
    else:
        table = BPMF_MEDIAL_YU
        suffix = "u" if initial in BPMF_YU_WRITES_U else "ü"

    if final not in table:
        raise ValueError(f"介音與韻母組合找不到寫法：{syllable}")
    tail = table[final]
    if suffix is not None:
        tail = tail.format(v=suffix)
    return BPMF_INITIALS[initial] + tail


def fetch_cns_archives(dest_dir: pathlib.Path) -> dict[str, pathlib.Path]:
    """下載全字庫的壓縮檔，雜湊不符就停止。"""
    paths: dict[str, pathlib.Path] = {}
    for name, expected in CNS_ARCHIVES.items():
        out_path = dest_dir / name
        with urllib.request.urlopen(CNS_BASE_URL + name, timeout=300) as response:
            out_path.write_bytes(response.read())
        digest = hashlib.sha256(out_path.read_bytes()).hexdigest()
        if digest != expected:
            raise SystemExit(
                f"全字庫 {name} 內容雜湊為 {digest}，與固定版本 {expected} 不符，"
                "停止產生讀音索引。上游不定期更新，請重新核對版本與授權聲明後再更新雜湊。"
            )
        paths[name] = out_path
    return paths


def read_zip_member(zip_path: pathlib.Path, member: str) -> list[str]:
    """讀壓縮檔裡的一個 UTF-8 文字檔，回傳去掉空白列的列陣列。"""
    with zipfile.ZipFile(zip_path) as archive:
        raw = archive.read(member)
    text = io.TextIOWrapper(io.BytesIO(raw), encoding="utf-8-sig").read()
    return [line for line in text.splitlines() if line.strip()]


def parse_cns_unicode_map(zip_path: pathlib.Path) -> dict[str, str]:
    """CNS 碼到 Unicode 字元。同一個 CNS 碼在多個字面檔重複出現時取先讀到的。"""
    mapping: dict[str, str] = {}
    for member in CNS_UNICODE_MEMBERS:
        for line in read_zip_member(zip_path, member):
            parts = line.split("\t")
            if len(parts) != 2:
                continue
            mapping.setdefault(parts[0], normalize_han_char(chr(int(parts[1], 16))))
    return mapping


def split_cns_tone(bopomofo: str) -> tuple[str, int]:
    """把全字庫的注音拆成去調注音與聲調 1 至 5。"""
    if bopomofo.startswith(CNS_NEUTRAL_TONE_MARK):
        return bopomofo[len(CNS_NEUTRAL_TONE_MARK):], 5
    if bopomofo[-1] in CNS_TONE_MARKS:
        return bopomofo[:-1], CNS_TONE_MARKS[bopomofo[-1]]
    return bopomofo, 1


def parse_cns_phonetic_table(
    properties_zip: pathlib.Path,
    mapping_zip: pathlib.Path,
    cangjie_chars: set[str],
    commonness: dict[str, float],
    mandarin: dict[str, tuple[str, int]],
) -> tuple[dict[tuple[str, int], list[str]], int]:
    """得到（去調注音、聲調）到候選字的對照。

    只收能對應到 Unicode、且出現在倉頡碼表裡的字：查得到讀音卻沒有任何倉頡碼的字，
    這個輸入法打不出來，列進面板只會占位置。一字多音全收。

    每一列各自排序：全字庫沒有常用度欄位，常用度來自 Unihan，主要讀音的判定也來自
    Unihan 的 kMandarin，見 reading_sort_key 與 find_demoted_readings。
    """
    unicode_map = parse_cns_unicode_map(mapping_zip)
    table: dict[tuple[str, int], list[str]] = {}
    seen: dict[tuple[str, int], set[str]] = defaultdict(set)
    skipped_without_cangjie: set[str] = set()

    for line in read_zip_member(properties_zip, CNS_PHONETIC_MEMBER):
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        cns_code, bopomofo = parts[0].strip(), parts[1].strip()
        word = unicode_map.get(cns_code)
        if word is None or not is_valid_cangjie_char(word):
            continue
        if word not in cangjie_chars:
            skipped_without_cangjie.add(word)
            continue
        if (word, bopomofo) in CNS_PHONETIC_EXCEPTIONS:
            continue
        stripped, tone = split_cns_tone(bopomofo)
        # 自我檢查：音節必須拆得開也轉得出拼音，否則是沒見過的新資料，停下來。
        try:
            bopomofo_to_pinyin(stripped)
        except (ValueError, KeyError) as error:
            raise SystemExit(
                f"全字庫 {CNS_PHONETIC_MEMBER} 的 {cns_code}（{word}）注音 {bopomofo!r} "
                f"無法轉成拼音：{error}。請確認是上游資料錯誤還是轉換表缺音節。"
            )
        key = (stripped, tone)
        if word in seen[key]:
            continue
        seen[key].add(word)
        table.setdefault(key, []).append(word)

    demoted = find_demoted_readings(table, mandarin)
    for key in table:
        table[key].sort(key=reading_sort_key(commonness, demoted, key))

    return table, len(skipped_without_cangjie)


def write_readings_tsv(
    table: dict[tuple[str, int], list[str]], out_path: pathlib.Path
) -> tuple[int, int, int]:
    """寫出讀音索引，並自我檢查注音轉拼音為全覆蓋且一對一。"""
    syllables = sorted({bopomofo for bopomofo, _ in table})
    pinyin_of: dict[str, str] = {}
    for bopomofo in syllables:
        pinyin = bopomofo_to_pinyin(bopomofo)
        owner = next((b for b, p in pinyin_of.items() if p == pinyin), None)
        if owner is not None:
            raise SystemExit(f"拼音 {pinyin} 同時對應 {owner} 與 {bopomofo}，轉換不是一對一。")
        pinyin_of[bopomofo] = pinyin

    lines = [
        f"# 來源 全字庫（CNS11643）注音屬性資料 {CNS_PHONETIC_MEMBER}，版本 {CNS_VERSION}",
        "# 提供機關 數位發展部，政府資料開放授權條款第 1 版，顯名聲明見 THIRD_PARTY_NOTICES.md",
        "# 欄位：去調注音、去調漢語拼音（ü 寫 ü）、聲調 1-5（5 為輕聲）、候選字",
        f"# 候選依 Big5 分區、是否為該字的罕用讀音（Unihan {UNIHAN_VERSION} kMandarin）、"
        "常用度分數、Big5 碼位排序。",
        "# 候選字直接相連，每字一個字元。",
        "# 列序固定為注音碼序再聲調，重跑可得位元組相同的結果。",
    ]
    chars: set[str] = set()
    for key in sorted(table, key=lambda k: (k[0], k[1])):
        bopomofo, tone = key
        candidates = table[key]
        # 候選字直接相連，所以每個值必須是單一且已正規化的字元。
        for word in candidates:
            if len(word) != 1 or normalize_han_char(word) != word:
                raise SystemExit(f"候選字 {word!r} 不是單一正規化字元，無法無分隔符寫出。")
        chars.update(candidates)
        lines.append(f"{bopomofo}\t{pinyin_of[bopomofo]}\t{tone}\t{''.join(candidates)}")

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(syllables), len(table), len(chars)


def write_native_codes_tsv(
    chars: set[str],
    native5: dict[str, list[str]],
    native3: dict[str, list[str]],
    out_path: pathlib.Path,
) -> tuple[int, int]:
    """寫出讀音索引用到的字在各代的原生拆碼，兩代皆缺碼的字不列。"""
    lines = [
        "# 來源 libcangjie data/table.txt（公眾領域），提交 " + LIBCANGJIE_COMMIT,
        "# 欄位：字、倉頡五代原生碼、倉頡三代原生碼，皆依來源順序以逗號分隔。",
        "# 只收讀音索引出現過的字；兩代皆無碼的字不列，查詢時視為本代未收錄。",
        "# 讀音索引已先濾掉沒有倉頡碼的字，所以目前每個字都列得出至少一代的碼。",
    ]
    missing = 0
    written = 0
    for char in sorted(chars):
        codes5 = native5.get(char, [])
        codes3 = native3.get(char, [])
        if not codes5 and not codes3:
            missing += 1
            continue
        lines.append(f"{char}\t{','.join(codes5)}\t{','.join(codes3)}")
        written += 1

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return written, missing


def fetch_libcangjie(dest_dir: pathlib.Path) -> dict[str, pathlib.Path]:
    """下載固定提交的 libcangjie 資料檔，雜湊不符就停止。"""
    paths: dict[str, pathlib.Path] = {}
    for rel_path, expected in LIBCANGJIE_FILES.items():
        quoted = rel_path.replace("/", "%2F")
        url = (
            f"https://gitlab.freedesktop.org/api/v4/projects/{LIBCANGJIE_PROJECT}"
            f"/repository/files/{quoted}/raw?ref={LIBCANGJIE_COMMIT}"
        )
        out_path = dest_dir / rel_path.replace("/", "_")
        with urllib.request.urlopen(url, timeout=120) as response:
            out_path.write_bytes(response.read())
        digest = hashlib.sha256(out_path.read_bytes()).hexdigest()
        if digest != expected:
            raise SystemExit(
                f"libcangjie {rel_path} 內容雜湊為 {digest}，與固定版本 {expected} 不符，停止產生碼表。"
            )
        paths[rel_path] = out_path
    return paths


def fetch_unihan(dest_dir: pathlib.Path) -> pathlib.Path:
    """下載固定版本的 Unihan 壓縮檔，雜湊不符就停止。"""
    out_path = dest_dir / "Unihan.zip"
    with urllib.request.urlopen(UNIHAN_URL, timeout=300) as response:
        out_path.write_bytes(response.read())
    digest = hashlib.sha256(out_path.read_bytes()).hexdigest()
    if digest != UNIHAN_SHA256:
        raise SystemExit(
            f"Unihan.zip 內容雜湊為 {digest}，與固定版本 {UNIHAN_SHA256} 不符，停止產生碼表。"
            "上游每年改版，請重新核對版本與授權聲明後再更新雜湊。"
        )
    return out_path


def parse_unihan_commonness(zip_path: pathlib.Path) -> dict[str, float]:
    """得到字到常用度分數的對照，分數越小越常用，缺資料的字不列。

    kGradeLevel（香港小學學到該字的年級 1 至 6）與 kFenn 的字頻分級（每級五百字，
    第 1 至 10 級）是同一件事的兩個估計值，而且尺度已經對得上：有年級的 2,632 個字
    依年級累積為 460、970、1513、2111、2370、2632，第 g 年級以前學到的字大致落在前
    500g 個常用字內，正好是 Fenn 第 g 級的位置。

    兩個估計值都有雜訊，所以兩欄都有時取平均，只有一欄時就用那一欄。
    取平均在獨立參照（Unihan 的 kHanyuPinlu 字頻）上的排序正確率比取較常用者高，
    理由是單一欄位偏樂觀時會直接決定順序，平均會把它拉回來。
    """
    with zipfile.ZipFile(zip_path) as archive:
        raw = archive.read(UNIHAN_MEMBER)
    grades: dict[str, int] = {}
    bands: dict[str, int] = {}
    for line in io.TextIOWrapper(io.BytesIO(raw), encoding="utf-8").read().splitlines():
        if not line or line.startswith("#"):
            continue
        code_point, field, value = line.split("\t", 2)
        word = normalize_han_char(chr(int(code_point[2:], 16)))
        if field == "kGradeLevel":
            grades[word] = int(value)
        elif field == "kFenn":
            # 一個字可能有多個 kFenn 值，取最常用的那一級。
            graded = [
                FENN_BAND_LETTERS.index(token[-1]) + 1
                for token in value.split()
                if token[-1] in FENN_BAND_LETTERS
            ]
            if graded:
                bands[word] = min(graded)
    if not grades or not bands:
        raise SystemExit(
            f"Unihan {UNIHAN_MEMBER} 解不出 kGradeLevel 或 kFenn 分級"
            f"（{len(grades)} 與 {len(bands)} 筆），欄位格式可能已變，停止產生碼表。"
        )

    commonness: dict[str, float] = {}
    for word in grades.keys() | bands.keys():
        values = [v for v in (grades.get(word), bands.get(word)) if v is not None]
        commonness[word] = sum(values) / len(values)
    return commonness


def split_pinyin_tone(reading: str) -> tuple[str, int]:
    """帶調漢語拼音拆成去調拼音與聲調 1 至 5。ü 的分音符不是調號，要留著。"""
    tone = 5
    letters = []
    for ch in unicodedata.normalize("NFD", reading):
        if ch in PINYIN_TONE_MARKS:
            tone = PINYIN_TONE_MARKS[ch]
        else:
            letters.append(ch)
    return unicodedata.normalize("NFC", "".join(letters)), tone


def parse_unihan_mandarin(zip_path: pathlib.Path) -> dict[str, tuple[str, int]]:
    """得到字到台灣慣用讀音（去調拼音、聲調）的對照，缺資料的字不列。"""
    with zipfile.ZipFile(zip_path) as archive:
        raw = archive.read(UNIHAN_READINGS_MEMBER)
    out: dict[str, tuple[str, int]] = {}
    for line in io.TextIOWrapper(io.BytesIO(raw), encoding="utf-8").read().splitlines():
        if not line or line.startswith("#"):
            continue
        code_point, field, value = line.split("\t", 2)
        if field != "kMandarin":
            continue
        word = normalize_han_char(chr(int(code_point[2:], 16)))
        out[word] = split_pinyin_tone(value.split()[-1])
    if not out:
        raise SystemExit(
            f"Unihan {UNIHAN_READINGS_MEMBER} 解不出 kMandarin 欄，"
            "欄位格式可能已變，停止產生讀音索引。"
        )
    return out


def find_demoted_readings(
    table: dict[tuple[str, int], list[str]], mandarin: dict[str, tuple[str, int]]
) -> set[tuple[str, tuple[str, int]]]:
    """標出「這個讀音不是這個字的主要讀音」的（字、讀音）配對。

    一字多音全收後只依常用度排序，常用字的罕用讀音就會占住第一頁：ㄩˋ 的第一名變成
    「雨」、ㄍㄨㄥ 的第二名變成「紅」。kMandarin 指出該字最慣用的那個讀音，用它把同一個
    字的其餘讀音往後排。全字庫的注音屬性資料不能當依據：它同一個字的多個讀音是照注音
    符號順序排的（15,528 個多音字碼位逐一核對全部符合），沒有主次資訊。

    兩岸讀音常只差聲調（夕 xī 對 ㄒㄧˋ、拙 zhuō 對 ㄓㄨㄛˊ），所以聲調對不上時再用去調
    音節比一次，而且該音節在這個字的讀音裡唯一才算。一個字的讀音全都對不上時不標任何
    配對：寧可讓它不參與這一層排序，也不要把它每一個讀音都當罕用讀音壓下去。
    """
    readings_of: dict[str, list[tuple[str, int]]] = defaultdict(list)
    for key, words in table.items():
        for word in words:
            readings_of[word].append(key)

    demoted: set[tuple[str, tuple[str, int]]] = set()
    for word, keys in readings_of.items():
        # 只有一個讀音的字沒有主次問題。
        if len(keys) < 2:
            continue
        wanted = mandarin.get(word)
        if wanted is None:
            continue
        spelled = {key: (bopomofo_to_pinyin(key[0]), key[1]) for key in keys}
        primary = next((key for key in keys if spelled[key] == wanted), None)
        if primary is None:
            same_syllable = [key for key in keys if spelled[key][0] == wanted[0]]
            if len(same_syllable) != 1:
                continue
            primary = same_syllable[0]
        demoted.update((word, key) for key in keys if key != primary)
    return demoted


def big5_tier(word: str) -> int:
    """Big5 分區。常用字區在前、次常用字區其次、符號等其餘墊底。

    Big5 的常用字區是 1984 年依台灣的使用頻率挑出的 5,401 字，本身就是一份常用度資料，
    而且與 Unihan 的兩個欄位獨立，所以放在排序的第一層：Unihan 對繁體字有缺口
    （例如「查」兩個欄位都沒有），只靠分數會把這類字排到罕用字後面。
    """
    code_point = int.from_bytes(word.encode("big5"), "big")
    if BIG5_COMMON_RANGE[0] <= code_point <= BIG5_COMMON_RANGE[1]:
        return 0
    if BIG5_LESS_COMMON_RANGE[0] <= code_point <= BIG5_LESS_COMMON_RANGE[1]:
        return 1
    return 2


def candidate_sort_key(commonness: dict[str, float]):
    """候選排序鍵：Big5 分區、常用度分數、Big5 碼位。

    第三層的碼位只是讓兩個都查不到常用度的字有固定順序，重跑才能得到相同結果。
    """
    def key(word: str) -> tuple[int, float, int]:
        return (
            big5_tier(word),
            commonness.get(word, math.inf),
            int.from_bytes(word.encode("big5"), "big"),
        )

    return key


def reading_sort_key(
    commonness: dict[str, float],
    demoted: set[tuple[str, tuple[str, int]]],
    key: tuple[str, int],
):
    """某一個帶調讀音的候選排序鍵：Big5 分區、是否為該字的罕用讀音、常用度、碼位。

    罕用讀音排在常用度之前：按讀音找字的人要的是讀這個音的字，所以「雨」不該因為比
    「遇」常用就占住 ㄩˋ 的第一名。放在 Big5 分區之後，才不會為了把罕用字的主要讀音
    提前而把 Big5 常用字擠出第一頁。倉頡正查表沒有讀音，仍用 candidate_sort_key。
    """
    base = candidate_sort_key(commonness)

    def sort_key(word: str) -> tuple[int, int, float, int]:
        tier, score, code_point = base(word)
        return (tier, int((word, key) in demoted), score, code_point)

    return sort_key


def is_common_char(word: str, commonness: dict[str, float]) -> bool:
    """常用字：在 Big5 常用字區，且常用度資料沒有明確把它列在最罕用的一級。

    缺資料不當罕用。Unihan 的兩個欄位對繁體字有缺口，「查」、「汞」、「屐」這類字
    兩欄都查不到，但它們在 Big5 常用字區。只有資料明確說它落在 Fenn 最後一級
    （K，約第 4,501 至 5,000 常用）而香港小學字表也沒收時，才判定為罕用字。

    這裡與 candidate_sort_key 對缺資料的處理刻意相反：排序需要一個全序，查不到資料的字
    只能排在同分區的最後；這條規則要決定「可不可以把這個碼整個藏起來」，不能只因為
    查不到資料就藏。兩邊各取保守的那一側。
    """
    return (
        big5_tier(word) == 0
        and commonness.get(word, 0.0) < len(FENN_BAND_LETTERS)
    )


def parse_libcangjie_table(
    table_path: pathlib.Path,
) -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    """讀 table.txt，回傳兩代的字到原生碼對照。

    只收 Big5 編得出來的字。table.txt 涵蓋整個 Unihan，連 CJK 擴充 B 區的罕用字都有
    拆碼；全收會讓 `in`、`is`、`time`、`file` 這類常用英文詞被罕用字占住倉頡軌，
    空白鍵就送不出英文。Big5 字集與本輸入法的繁體中文定位相符，也涵蓋全部標點符號。
    該表自己的 Big5 欄位漏掉標點符號與注音符號，所以改用 Python 的 big5 編碼器判定。
    """
    codes3: dict[str, list[str]] = defaultdict(list)
    codes5: dict[str, list[str]] = defaultdict(list)

    for raw_line in table_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != LC_FIELD_COUNT:
            continue
        word = normalize_han_char(parts[LC_CHAR])
        if not is_valid_cangjie_char(word):
            continue
        try:
            word.encode("big5")
        except UnicodeEncodeError:
            continue
        for field, target in ((LC_CANGJIE3, codes3), (LC_CANGJIE5, codes5)):
            if parts[field] == "NA":
                continue
            for code in parts[field].split(","):
                code = code.lower()
                if not (1 <= len(code) <= 5) or not all(c in CANGJIE_KEYS for c in code):
                    continue
                if code not in target[word]:
                    target[word].append(code)

    return dict(codes3), dict(codes5)


def build_code_entries(
    native_codes: dict[str, list[str]], commonness: dict[str, float]
) -> dict[str, list[str]]:
    """把字到碼的對照反轉成碼到候選字，候選依常用度排序。"""
    entries: dict[str, list[str]] = defaultdict(list)
    for word, codes in native_codes.items():
        for code in codes:
            if word not in entries[code]:
                entries[code].append(word)
    sort_key = candidate_sort_key(commonness)
    for code in entries:
        entries[code].sort(key=sort_key)
    return dict(entries)


def merge_compatible_codes(
    primary: dict[str, list[str]],
    secondary: dict[str, list[str]],
    english_words: set[str],
    commonness: dict[str, float],
) -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    """為主碼表已有的字補上另一代拆碼，並讓完整英文詞避開只有罕用字的碼。

    完整英文詞的碼有兩種情形不放進正查表：補碼（主代原無此碼）一律不收；
    主代原生碼則是在所有候選字都不是常用字時不收。`like`、`risk`、`bike` 這類
    高頻英文詞原本會讓空白鍵送出「袚」、「唳」、「胈」，打不出英文詞。
    被擋掉的字仍留在 cangjie_native.tsv，讀音反查面板查得到也顯示拆碼。

    補碼與主代原生候選一起依常用度排序，不接在後面。同一個碼下，使用者要的是常用字，
    那個字的拆碼屬於哪一代不影響他按空白鍵的期待：倉頡五代的 `ahs` 原生只有「昈」，
    「昨」要靠三代補碼才進得來，但按 `ahs` 的人想要的是「昨」。

    回傳合併後的碼表，以及被擋掉的碼與它原本的候選字。
    """
    primary_chars = {word for words in primary.values() for word in words}
    merged = {code: list(words) for code, words in primary.items()}
    for code, words in secondary.items():
        if code not in primary and code in english_words:
            continue
        for word in words:
            if word in primary_chars and word not in merged.get(code, []):
                merged.setdefault(code, []).append(word)
    sort_key = candidate_sort_key(commonness)
    for words in merged.values():
        words.sort(key=sort_key)
    blocked = {
        code: list(words)
        for code, words in primary.items()
        if code in english_words
        and not any(is_common_char(word, commonness) for word in words)
    }
    for code in blocked:
        del merged[code]
    return merged, blocked


def write_cangjie_tsv(
    entries: dict[str, list[str]], generation: str, out_path: pathlib.Path
) -> tuple[int, int]:
    lines = [
        f"# 來源 libcangjie data/table.txt（公眾領域），提交 {LIBCANGJIE_COMMIT}",
        f"# 只收 Big5 編得出來的字，取倉頡{generation}欄並補另一代的相容拆碼。",
        "# 欄位：碼、候選字（逗號分隔）。",
        "# 候選依 Big5 分區（常用、次常用、其餘）、Unihan 常用度分數、Big5 碼位排序。",
        f"# 常用度來自 Unihan {UNIHAN_VERSION} 的 kGradeLevel 與 kFenn，詳見 THIRD_PARTY_NOTICES.md。",
    ]
    total_chars = 0
    for code in sorted(entries.keys()):
        cands = entries[code]
        total_chars += len(cands)
        lines.append(f"{code}\t{','.join(cands)}")
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(entries), total_chars


def build_english_tsv(csv_path: pathlib.Path, out_path: pathlib.Path) -> set[str]:
    """由 Google Books Ngram 英文一元詞頻表產出預測詞庫。

    書籍語料帶大小寫變體、專有名詞與帶標點的項目。只收純英文字母的詞，大小寫合併後
    把語料次數相加，重新排名後才換成詞頻權重，權重公式與欄位格式沿用原版，
    英文預測與跨代撞碼判斷的既有門檻才不會跟著資料一起變動。
    """
    digest = hashlib.sha256(csv_path.read_bytes()).hexdigest()
    if digest != NGRAM_SOURCE_SHA256:
        raise SystemExit(
            f"{NGRAM_SOURCE_PATH} 內容雜湊為 {digest}，"
            f"與固定版本 {NGRAM_SOURCE_SHA256} 不符，停止產生英文詞庫。"
        )

    corpus_freq: dict[str, int] = defaultdict(int)
    with csv_path.open("r", encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            word = row["ngram"]
            if not word.isascii() or not word.isalpha():
                continue
            lower = word.lower()
            if lower in EXCLUDED_WORDS:
                continue
            corpus_freq[lower] += int(row["freq"])

    word_map: dict[str, tuple[str, int, int]] = {}
    ranked = sorted(corpus_freq.items(), key=lambda item: (-item[1], item[0]))
    for rank, (lower, _) in enumerate(ranked):
        word_map[lower] = (lower, max(1_000, 100_000 - rank * 8), 0)

    for word, freq in EXTRA_COMMON_WORDS:
        lower = word.lower()
        existing = word_map.get(lower)
        if existing is None or lower == "id":
            word_map[lower] = (word, freq, 0)

    for word, freq in DEV_TERMS:
        lower = word.lower()
        word_map[lower] = (word, freq, 1)

    ordered = sorted(word_map.values(), key=lambda item: (-item[1], len(item[0]), item[0].lower()))
    # 載入端只收得到至少兩欄且第二欄為整數的列，不含定位字元的說明列會被跳過。
    lines = [
        f"# 來源 orgtre/google-books-ngram-frequency {NGRAM_SOURCE_PATH}（CC BY 3.0）",
        f"# 提交 {NGRAM_SOURCE_COMMIT}",
        f"# 內容 SHA-256 {NGRAM_SOURCE_SHA256}",
        "# 另加入工程用語與常用短詞，並排除髒話；詳見 scripts/build-lexicon.py。",
        "# 欄位：詞、詞頻權重、是否為工程用語。",
    ]
    lines += [f"{w}\t{freq}\t{is_dev}" for w, freq, is_dev in ordered]
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return set(word_map)


def main() -> None:
    RESOURCES_DIR.mkdir(parents=True, exist_ok=True)
    tmpdir = pathlib.Path(tempfile.mkdtemp(prefix="goshawk-lexicon-"))
    try:
        en_dir = tmpdir / "google-books-ngram-frequency"
        subprocess.run(
            ["git", "clone", "--depth", "1", "--filter=blob:none", "--sparse", "https://github.com/orgtre/google-books-ngram-frequency.git", str(en_dir)],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(en_dir), "sparse-checkout", "set", "--no-cone", NGRAM_SOURCE_PATH],
            check=True,
        )

        unihan_zip = fetch_unihan(tmpdir)
        commonness = parse_unihan_commonness(unihan_zip)
        mandarin = parse_unihan_mandarin(unihan_zip)

        lc_files = fetch_libcangjie(tmpdir)
        native3, native5 = parse_libcangjie_table(lc_files["data/table.txt"])
        cj5 = build_code_entries(native5, commonness)
        cj3 = build_code_entries(native3, commonness)

        english_words = build_english_tsv(
            en_dir / NGRAM_SOURCE_PATH,
            RESOURCES_DIR / "english_freq.tsv",
        )
        merged5, blocked5 = merge_compatible_codes(cj5, cj3, english_words, commonness)
        merged3, blocked3 = merge_compatible_codes(cj3, cj5, english_words, commonness)
        c5_codes, c5_chars = write_cangjie_tsv(merged5, "五代", RESOURCES_DIR / "cangjie5.tsv")
        c3_codes, c3_chars = write_cangjie_tsv(merged3, "三代", RESOURCES_DIR / "cangjie3.tsv")

        cns_files = fetch_cns_archives(tmpdir)
        # 用原生碼而不是正查表：被英文詞保護規則擋掉的碼，它的字仍該留在讀音索引，
        # 反查面板查得到也顯示拆碼。
        cangjie_chars = set(native5) | set(native3)
        readings, readings_without_cangjie = parse_cns_phonetic_table(
            cns_files["Properties.zip"],
            cns_files["MapingTables.zip"],
            cangjie_chars,
            commonness,
            mandarin,
        )
        syllable_count, row_count, reading_chars = write_readings_tsv(
            readings, RESOURCES_DIR / "readings.tsv"
        )
        char_set = {word for words in readings.values() for word in words}
        native_rows, native_missing = write_native_codes_tsv(
            char_set,
            native5,
            native3,
            RESOURCES_DIR / "cangjie_native.tsv",
        )

        print(f"Built cangjie5.tsv: {c5_codes} codes, {c5_chars} chars")
        print(f"Built cangjie3.tsv: {c3_codes} codes, {c3_chars} chars")
        for generation, blocked in (("五代", blocked5), ("三代", blocked3)):
            listing = " ".join(
                f"{code}->{''.join(words)}" for code, words in sorted(blocked.items())
            )
            print(f"English words kept out of the {generation} table ({len(blocked)}): {listing}")
        print(f"Built english_freq.tsv: {len(english_words)} words")
        print(
            f"Built readings.tsv: {syllable_count} syllables, "
            f"{row_count} toned rows, {reading_chars} chars "
            f"({readings_without_cangjie} characters with a reading but no Cangjie code were dropped)"
        )
        print(
            f"Built cangjie_native.tsv: {native_rows} chars, "
            f"{native_missing} reading chars have no native code in either version"
        )
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
