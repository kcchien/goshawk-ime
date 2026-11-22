# 第三方資料來源與授權

蒼鷹輸入法的程式碼依 [MIT 授權](LICENSE) 散布。隨附於 `Sources/GoshawkCore/Resources/`
的資料檔另有來源與授權，逐檔列於下。倉頡、英文預測與讀音索引由
[`scripts/build-lexicon.py`](scripts/build-lexicon.py) 產生，並核對固定版本來源的 SHA-256。
中文接詞的選詞與計數方式見下方「中文接詞詞頻」。

本檔列出的授權結論都來自直接閱讀上游的授權檔、說明檔或檔頭，引文照原文抄錄，含原文的錯字。

---

## `cangjie5.tsv`、`cangjie3.tsv`、`cangjie_native.tsv`

- **來源**：libcangjie 專案的 `data/table.txt`
  <https://gitlab.freedesktop.org/cangjie/libcangjie/-/blob/main/data/table.txt>
- **固定版本**：提交 `1f95d1d56ffb328779d46baaab7431fa31349f1e`
  - `data/table.txt` 內容 SHA-256 `86118f2a50591b837e3317a3dab87f96e7188c54046e8ed20dd4a0933877d3ea`
  - `data/README.table.md` 內容 SHA-256 `5962758f991e9119dddf78391202443731264332ea6b1f013791ba599fcb1b5d`
- **授權**：公眾領域（Public Domain）
- **上游聲明原文**（`data/README.table.md`，Legal 一節）：

  > The data in the ``table.txt`` file is hereby placed under the Public
  > Domain, in the hope that is is useful.

- **適用範圍**：這段聲明只涵蓋 `table.txt` 這一份資料檔。libcangjie 倉庫根目錄的
  `COPYING` 是 GNU Lesser General Public License Version 3，適用於該專案的程式庫程式碼。
  `table.txt` 由上面那段聲明另外置於公眾領域，不在 LGPL-3 的範圍內。本專案只取這一份資料，
  不含 libcangjie 的程式碼。
- **上游自述的資料來源**（同一份說明檔 Sources 一節）：Unicode Consortium 的 Unihan 資料庫、
  Unicode 規格、Wan Leung Wong 原始 libcangjie 的資料，以及 libcangjie 團隊的整理。
- **我們做的處理**：
  1. 只收 Big5 編得出來的字（以 Python 內建 `big5` 編碼器判定）。`table.txt` 涵蓋整個
     Unihan，全收會讓 `in`、`is`、`time`、`file` 這類常用英文詞被罕用字占住倉頡軌。
  2. 取第 12 欄（倉頡三代）與第 13 欄（倉頡五代）的拆碼，過濾掉非 `a` 至 `y` 或長度不在
     1 至 5 的碼，以及私用區字元。
  3. 候選順序依 Big5 分區（常用字區、次常用字區、其餘）、Unihan 常用度分數、Big5 碼位。
     該表沒有頻率欄，第 15 欄雖帶排序值，但標點符號與 286 個 Big5 字為 0，不足以排序全表，
     所以常用度另取 Unihan 的欄位，見下一節。
  4. 補上另一代的相容拆碼，只補主代已收錄的字。補碼與主代原生候選一起依常用度排序。
  5. 完整英文詞的碼有兩種情形不收進正查表：補碼（主代原無此碼）一律不收；主代原生碼則是在
     所有候選字都不是常用字時不收。被擋掉的字仍留在 `cangjie_native.tsv`。
  6. 字一律正規化為 NFC。
  7. `cangjie_native.tsv` 只收讀音索引出現過的字的原生拆碼，不含相容補碼。

## 候選排序用的常用度與主要讀音（影響 `cangjie5.tsv`、`cangjie3.tsv`、`readings.tsv`）

- **來源**：Unicode Unihan 資料庫的 `Unihan_DictionaryLikeData.txt`（常用度）與
  `Unihan_Readings.txt`（主要讀音），同一份壓縮檔
  <https://www.unicode.org/Public/18.0.0/ucd/Unihan.zip>
- **固定版本**：Unicode 18.0.0（檔頭標示 `Date: 2026-07-31`），
  `Unihan.zip` 內容 SHA-256 `4c93ea9c1f636451729a840978f1667a53886af37ba854fdcce109721c63d43e`
- **授權**：Unicode License v3 <https://www.unicode.org/license.txt>
- **上游聲明原文**（授權條款的許可段，本專案依其中 (b) 的方式在本檔保留聲明）：

  > Copyright © 1991-2026 Unicode, Inc.
  >
  > Permission is hereby granted, free of charge, to any person obtaining a
  > copy of data files and any associated documentation (the "Data Files") or
  > software and any associated documentation (the "Software") to deal in the
  > Data Files or Software without restriction, including without limitation
  > the rights to use, copy, modify, merge, publish, distribute, and/or sell
  > copies of the Data Files or Software, and to permit persons to whom the
  > Data Files or Software are furnished to do so, provided that either (a)
  > this copyright and permission notice appear with all copies of the Data
  > Files or Software, or (b) this copyright and permission notice appear in
  > associated Documentation.

  > THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
  > KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
  > MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
  > THIRD PARTY RIGHTS.
  >
  > IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
  > BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
  > OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
  > WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
  > ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
  > FILES OR SOFTWARE.
  >
  > Except as contained in this notice, the name of a copyright holder shall
  > not be used in advertising or otherwise to promote the sale, use or other
  > dealings in these Data Files or Software without prior written
  > authorization of the copyright holder.

- **用到的欄位**（欄位定義見 [UAX #38](https://www.unicode.org/reports/tr38/)）：
  - `kGradeLevel`：香港學制中學生應學會該字的年級，值 1 至 6，取自《朗文初級中文詞典》
    （2001）。這份資料覆蓋 2,632 個字。
  - `kFenn`：取值尾端的字母當字頻分級。依 UAX #38，「A indicating the 500 most common
    ideographs, B the next five hundred, and so on」，資料裡出現的字母是 A 至 K（沒有 J），
    共十級約五千字。尾端的 `P`（Fenn 只因它是其他字的聲符才收的罕用字）與 `*`
    （不在該字典裡）不是分級，不採用。這份資料覆蓋 5,012 個字。
  - 兩欄都沒有的字不計分，排序時排在同一個 Big5 分區的最後。
  - `kMandarin`（在 `Unihan_Readings.txt`）：該字最慣用的帶調漢語拼音讀音，覆蓋 44,353 個字。
    依 UAX #38，「The most customary pīnyīn reading for this ideograph」，而且「When there
    are two values, then the first is preferred for zh-Hans (CN) and the second is
    preferred for zh-Hant (TW)」，所以取最後一個值就是台灣慣用的讀音。只用於 `readings.tsv`。
- **沒有採用的欄位**：`kFrequency` 在 Unicode 18.0.0 已不存在。`kHanyuPinlu`（《現代漢語
  頻率詞典》字頻）來自大陸的簡體語料，偏大陸用字，只在差異報告裡當獨立參照，不參與排序。
  `kTGH`（《通用規範漢字表》序號）量過當第三個常用度欄位，各項指標都沒有改善，見
  `.scratch/licensed-data/report/readings-diff-v3.md`。
- **我們做的處理**：
  1. 兩個常用度欄位都是「這個字大約落在前幾個五百常用字」的估計值，尺度本來就對得上：
     有年級的字依年級累積為 460、970、1513、2111、2370、2632，第 g 年級以前學到的字大致
     落在前 500g 個常用字內，正好是 Fenn 第 g 級的位置。
  2. 兩欄都有時取平均，只有一欄時用那一欄，當作該字的常用度分數（越小越常用）。
  3. 倉頡正查表的排序鍵是「Big5 分區、常用度分數、Big5 碼位」。Big5 常用字區是一份獨立的
     常用度資料，放在第一層可以補 Unihan 對繁體字的缺口（「查」、「汞」、「屐」兩欄都查不到）。
  4. 讀音索引多一層鍵，排在常用度之前：「這個讀音是不是該字的主要讀音」。同一個字在
     `kMandarin` 指出的那個讀音之外的讀音，在它那一列往後排。沒有 `kMandarin`、或該字的
     讀音全都對不上時不標記，讓那個字只依常用度排。按讀音找字的人要的是讀這個音的字，
     所以「雨」不該因為比「遇」常用就占住 ㄩˋ 的第一名。
  5. 兩岸讀音常只差聲調（夕 `xī` 對 ㄒㄧˋ、拙 `zhuō` 對 ㄓㄨㄛˊ），聲調對不上時再用去調
     音節比一次，音節不同的讀音往後排。`kMandarin` 的讀音不是台灣慣用讀音的少數常用字
     （例如「圾」是 `jī`、「期」是 `qī`），產生器裡有兩份具名的覆寫表補上台灣慣用的音節
     與聲調，另一份具名表讓少數台灣常用的第二讀音（例如「樂」的 ㄩㄝˋ）不往後排；表的
     內容是本專案自己整理的，不取自 Unihan。每一筆的讀音在 2026-11-22 逐字對照過教育部
     《重編國語辭典修訂本》的線上版，表裡只有字與讀音，不含辭典的釋義或其他內容。
  6. 完整英文詞保護規則的「常用字」＝在 Big5 常用字區，且常用度分數沒有明確落在最罕用的
     一級（沒有年級且 Fenn 分級是最後一級 K）。缺資料不當罕用。
  7. 只讀這兩個檔案，不散布 Unihan 的原始檔；產出的 TSV 只含候選字的排列順序。

## `english_freq.tsv`

- **來源**：orgtre/google-books-ngram-frequency 的 `ngrams/1grams_english.csv`
  <https://github.com/orgtre/google-books-ngram-frequency>
- **固定版本**：提交 `6a72a4d96a2c36717479e9e9bf4e24260b3dbdae`，
  內容 SHA-256 `f7f63aa08f0bb2f7f654cddff3a7ced4968b27887b2c0e7cd4b4d108221e197d`
- **授權**：Creative Commons Attribution 3.0 Unported（CC BY 3.0）
- **上游聲明原文**（該倉庫 `README.md`）：

  > The content of this repository is licensed under the [Creative Commons Attribution 3.0 Unported License](https://creativecommons.org/licenses/by/3.0/). Issue reports and pull requests are most welcome!

- **原始語料**：Google Books Ngram Corpus Version 3（版本識別碼 20200217），由 Google 發布。
  Google 的資料集頁面 <https://storage.googleapis.com/books/ngrams/books/datasetsv3.html>
  在 Usage 一節寫明：

  > **Usage**: This compilation is licensed under a
  > [Creative Commons Attribution 3.0 Unported License](http://creativecommons.org/licenses/by/3.0/).

- **CC BY 3.0 要求的標示**：本檔衍生自 orgtre 的 google-books-ngram-frequency
  （作者 orgtre，CC BY 3.0），該清單衍生自 Google 的 Google Books Ngram Corpus
  Version 3（20200217，CC BY 3.0）。兩者皆經本專案修改，修改內容列於下。
- **我們做的處理**：
  1. 只收純 ASCII 英文字母的詞，排除帶標點的項目（`o'clock`、`ma'am`）。
  2. 合併大小寫變體並相加語料次數，輸出一律小寫；重新排名後才換成本專案的詞頻權重。
  3. 排除髒話，維持原詞表的 no-swears 性質。排除清單由本專案自行列出，寫在產生器的
     `EXCLUDED_WORDS`；臨床或中性用詞（如 `sexual`、`naked`、`breast`、`sperm`）保留。
  4. 追加本專案自行整理的工程用語（`DEV_TERMS`）與常用短詞（`EXTRA_COMMON_WORDS`），
     兩份清單都是本專案的原創內容，依 MIT 授權。

## `readings.tsv`

- **來源**：CNS11643 中文標準交換碼全字庫（簡稱全字庫）的注音屬性資料
  `Properties.zip` 內的 `CNS_phonetic.txt`，以及 `MapingTables.zip` 內的
  `Unicode/CNS2UNICODE_Unicode BMP.txt` 與 `Unicode/CNS2UNICODE_Unicode 2.txt`
  <https://data.gov.tw/dataset/5961> ・ <https://www.cns11643.gov.tw>
- **固定版本**：`release.txt` 標示的版本 `20261028`
  - `Properties.zip` 內容 SHA-256 `d20fb0ee58a2602b2d9dc1f7a50ef573d33e8fbf52607bc9a30a4fdc3401fb76`
  - `MapingTables.zip` 內容 SHA-256 `605cadc2074cb5399bf03a268ab1f66a52384f08acb27021178c13d041cb87d2`
- **授權**：政府資料開放授權條款－第 1 版
- **授權選擇**：該資料集的授權說明寫明：

  > 1.本資料集授權使用者可依使用目的需求選擇『政府資料開放授權條款-第一版』或『開源字型授權1.1版(OFL 1.1) 』單一授權使用(非以上二種授權同時兼具)。有關授權說明網址：https://data.gov.tw/license。

  本專案只取注音屬性資料與中文碼對照表，不含字型檔，因此選擇政府資料開放授權條款第 1 版。
- **顯名聲明**：該條款「三、課予義務」第（二）項規定：

  > 使用者利用依本條款提供之開放資料，及後續之衍生物，應以符合附件所示「顯名聲明」要求之方式，明確標示原資料提供機關之相關聲明；未盡顯名標示義務者，視為自始未取得開放資料之授權。

  依附件「顯名聲明」的格式標示如下：

  > 數位發展部 2026 CNS11643中文標準交換碼全字庫(簡稱全字庫) 20261028
  >
  > 此開放資料依政府資料開放授權條款 (Open Government Data License) 進行公眾釋出，使用者於遵守本條款各項規定之前提下，得利用之。
  >
  > 政府資料開放授權條款：
  > https://data.gov.tw/license

- **我們做的處理**：
  1. 以 CNS 碼對照表把注音列對應到 Unicode 字元（只解壓 BMP 與第 2 字面，Big5 字集全在 BMP）。
  2. 只收出現在本專案倉頡碼表裡的字：查得到讀音卻沒有任何倉頡碼的字，這個輸入法打不出來。
     因此捨棄了 62,914 個有讀音但無倉頡碼的字。
  3. 一字多音全收。輕聲（開頭的點）與一至四聲（結尾的調號，一聲不加）轉成聲調 1 至 5。
  4. 候選依 Big5 分區、是否為該字的罕用讀音、Unihan 常用度分數、Big5 碼位排序。全字庫本身
     沒有常用度欄位，主要讀音也不能由它判斷：同一個字的多個讀音是照注音符號順序排的
     （逐一核對 15,528 個有多個讀音的 CNS 碼位，100% 符合），所以「行」的第一個讀音是 ㄏㄤˊ、
     「紅」的第一個是 ㄍㄨㄥ。主要讀音改用 Unihan 的 `kMandarin`，見前面的常用度一節。
  5. 跳過一列上游資料錯誤：`2-3378`（啐）多出的「˙ㄑ」，ㄑ 不能單獨成音節；同一個字另有
     正確的「ㄘㄨㄟˋ」。例外寫成產生器裡的具名清單，上游新增別的壞資料時產生器會停下來。
  6. 字一律正規化為 NFC，注音轉拼音的全覆蓋與一對一自我檢查沿用原版。
  7. 有兩個以上聲調的音節另寫一列聲調欄為 `0` 的列，是不指定聲調時的候選順序：同音節
     各聲調候選依字去重的聯集，用第 4 點的排序鍵跨聲調重排，一個字在這個音節的每個聲調
     都是罕用讀音才算罕用讀音。這一列沒有新增任何字或讀音。

---

## 中文接詞詞頻

`chinese_continuations.tsv` 收錄 22 個技術詞的完整詞出現次數。逐檔以原文完整字串計數，不斷詞、不分詞義。索引取每個詞的前兩字；前文線索由專案編寫。檔案與固定版本如下。

- Rust 程式設計語言正體中文版，`src/` 下的 Markdown，MIT 或 Apache-2.0。[rust-tw/book-tw](https://github.com/rust-tw/book-tw/tree/f3d99ccfe8e8ae85586c122eb0035dadd82e32ba/src)
- Twtrubiks 的 Docker 教學，全倉庫的 Markdown，MIT。[twtrubiks/docker-tutorial](https://github.com/twtrubiks/docker-tutorial/tree/bdd20d8a61c09a80e65c339ff6ccabc5ddcaca0e)
- Twtrubiks 的 Git 教學，全倉庫的 Markdown，MIT。[twtrubiks/Git-Tutorials](https://github.com/twtrubiks/Git-Tutorials/tree/bb4593e20c9a029f0c87a2314add069607d377d3)

---

## `symbols.tsv`

符號面板的符號表，由本專案自行編列，與程式碼同樣依 [MIT 授權](LICENSE) 散布。收哪些符號、怎麼分組與排序都是本專案的選擇，內容不是從作業系統或其他輸入法的符號資料檔複製來的。「標點」分頁的十五種標點與它們的順序、名稱依教育部《重訂標點符號手冊》，每種列出全形與半形的寫法；「符號」分頁其餘符號的名稱採通用稱呼。

---

## `artwork/` 的圖片

- **圖示**（`Goshawk.svg`、`Goshawk.icns`、`GoshawkTemplate` 各檔）：
  由作者以 OpenAI Codex 生成，不含第三方素材，與程式碼同樣依 [MIT 授權](LICENSE) 散布。
- **操作示意圖**（`mixed-input.png`、`mixed-input-guide.png`、`reading-lookup.png`、`switch-my.gif`）：
  以本輸入法實際執行時的畫面製作。

---

## 未隨倉庫散布的來源

`scripts/build-lexicon.py` 會在執行時取得上述來源，但上游的原始檔不進版控，倉庫裡只有
產生器與產生出的 TSV。
