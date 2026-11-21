# 給 AI 代理的安裝說明

這份文件寫給代替使用者操作電腦的 AI 代理。照順序做，每一步都有可以讀回的結果。人類使用者請看 [README.md](README.md) 的「安裝」。

蒼鷹輸入法 (Goshawk) 是 macOS 的倉頡與英文混打輸入法。安裝只動目前使用者的家目錄，不需要 `sudo`，不需要 Xcode。

## 1. 確認環境

```sh
sw_vers -productVersion
```

主版本要是 14 以上。不是就停下來告訴使用者，不要繼續。

## 2. 安裝

```sh
curl -fsSL https://raw.githubusercontent.com/kcchien/goshawk-ime/main/scripts/install.sh | bash
```

腳本做的事：

1. 下載最新發行版的 `GoshawkIME.dmg` 到暫存目錄並掛載。
2. 用 `codesign` 驗證 App，並確認簽章的 Team ID 是 `DPNCSH8U5S`。不符就以非零結束碼停止，沒有安裝任何東西。
3. 執行 App 裡的 `GoshawkApp --install`，把 App 複製到 `~/Library/Input Methods/GoshawkIME.app`，註冊並啟用輸入來源。
4. 卸載 dmg，刪掉暫存目錄。

重複執行是安全的，結果與執行一次相同。想先看腳本內容再執行，把它下載成檔案讀過，再用 `bash <檔案>` 執行。

使用者已經有 dmg 檔時，改用這個檔案安裝：

```sh
GOSHAWK_DMG_URL="file:///絕對路徑/GoshawkIME.dmg" bash install.sh
```

## 3. 確認裝好了

三項都要通過：

```sh
test -x ~/Library/Input\ Methods/GoshawkIME.app/Contents/MacOS/GoshawkApp && echo "App 已安裝"
codesign -dv ~/Library/Input\ Methods/GoshawkIME.app 2>&1 | grep TeamIdentifier
defaults read com.apple.inputsources AppleEnabledThirdPartyInputSources | grep com.kc.inputmethod.Goshawk
```

第二行要印出 `TeamIdentifier=DPNCSH8U5S`。第三行要印出至少一行。不同版本的 macOS 把啟用的輸入來源存在不同地方，第三行沒有輸出時改查：

```sh
defaults read com.apple.HIToolbox AppleEnabledInputSources | grep com.kc.inputmethod.Goshawk
```

## 4. 交給使用者做的事

下面這些不要用模擬按鍵或點擊代做，請告訴使用者：

- 從選單列的輸入法選單選「蒼鷹輸入法」（系統語言是英文時顯示 `Goshawk`）。
- 在任何文字欄位打 `my` 再按空白鍵，應該出現「下」。
- 選單裡沒有蒼鷹時，開啟「系統設定」→「鍵盤」→「文字輸入」→「編輯」，按「＋」，在「繁體中文」裡加入。
- 切換到蒼鷹時前景程式卡住，登出再登入一次。

## 5. 出問題時

| 現象 | 處理 |
|---|---|
| `curl` 回 404 | 找不到下載檔案。也可以[從原始碼建置](README.md#從原始碼建置)，需要 Swift 6 開發工具。 |
| 「簽章的開發者不符」 | 下載到的不是本專案發行的檔案。停止，把訊息原文告訴使用者，不要想辦法繞過檢查。 |
| 「註冊後找不到輸入來源」 | 請使用者登出再登入，然後重跑第 2 步。 |
| 第 3 步的第三項沒有輸出 | 重跑第 2 步。仍然沒有就請使用者照第 4 步手動加入。 |

## 6. 移除

```sh
~/Library/Input\ Methods/GoshawkIME.app/Contents/MacOS/GoshawkApp --uninstall
```

這會停用輸入來源並刪掉 App，設定與學習紀錄留著。使用者明確要求清除個人資料時才執行：

```sh
rm -rf ~/Library/Application\ Support/GoshawkIME
defaults delete com.kc.inputmethod.Goshawk
```

## 隱私

蒼鷹沒有任何網路連線。學習紀錄存在 `~/Library/Application Support/GoshawkIME/usage-history.json`，只記選過的字詞與次數，不記時間、程式名稱或按鍵。
