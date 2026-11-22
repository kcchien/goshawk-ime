import AppKit
import Carbon.HIToolbox
import Foundation
import GoshawkCore

/// 只用臨時目錄與人工按鍵，從 IMK 接收按鍵和面板動作的入口重播。
@MainActor
func runStatisticsChecks() throws -> Int {
    let name = "goshawk-statistics-test-" + UUID().uuidString
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    let url = directory.appendingPathComponent("statistics.json")
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: directory)
    }

    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var secure = false
    let store = LocalUsageStatistics(url: url, defaults: defaults, build: "1.2", now: { now })
    defer { store.shutdown() }
    let session = InputSessionCoordinator(configuration: EngineConfiguration(),
        statistics: StatisticsSession(store: store, isSecureInput: { secure }))
    var host = FakeIMKClient()
    var passed = 0
    func check(_ ok: Bool, _ name: String) throws {
        guard ok else { throw SelfTestFailure(message: "本機使用統計：\(name)") }
        passed += 1
    }
    func send(_ text: String, _ code: UInt16 = 0, _ flags: NSEvent.ModifierFlags = []) {
        _ = session.handlePayload(KeyEventPayload(keyCode: code, modifierFlags: flags,
            characters: text, charactersIgnoringModifiers: text), client: host)
    }
    func type(_ letters: String) {
        for letter in letters { send(String(letter)) }
    }
    func fresh(terminal: Bool = false) {
        session.resetForFocusChange()
        host = FakeIMKClient()
        host.reportsCursorAtZero = terminal
        host.allowsReadingText = !terminal
        host.declaresDocumentAccess = !terminal
    }
    func totals() -> StatisticsTotals {
        store.rows().reduce(into: StatisticsTotals()) { $0.merge($1.totals) }
    }
    func dualCommit() { type("my"); send(" ", 49) }
    func swap() { send(" ", 49, .shift) }
    var protection = StatisticsInputProtection()
    protection.set(kTextServiceInputModePassword, forTag: Int(kTextServiceInputModePropertyTag))
    protection.set(nil, forTag: 0)
    let explicitPassword = protection.suspended(secureEventInput: false)
    protection.set(kTextServiceInputModeRoman, forTag: Int(kTextServiceInputModePropertyTag))
    try check(explicitPassword && protection.suspended(secureEventInput: true)
        && !protection.suspended(secureEventInput: false), "密碼欄位與系統安全輸入各自停記")
    dualCommit()
    store.shutdown()
    try check(!store.enabled && store.rows().isEmpty && !FileManager.default.fileExists(atPath: url.path), "預設不建立統計檔")

    store.setEnabled(true)
    fresh()
    dualCommit()
    swap()
    swap()
    try check(host.text == "下" && totals().count(.trackOpportunities) == 1
        && totals().count(.committedTrackSwaps) == 1, "同一次實交送出只算一次修正")
    fresh(terminal: true)
    dualCommit()
    swap()
    try check(session.stagedCommit != nil && totals().count(.trackOpportunities) == 2
        && totals().count(.stagedTrackSwaps) == 1, "暫存對調獨立計數")
    fresh()
    dualCommit()
    host.text = "內容已改"
    swap()
    try check(host.text == "內容已改" && totals().count(.trackOpportunities) == 3
        && totals().count(.refusedTrackSwaps) == 1 && totals().count(.committedTrackSwaps) == 1,
              "宿主拒絕取代單獨計數")
    // 游標前先放一個字：空文件的第一個標點會先暫存，這裡要驗的是立即送出後的取代。
    fresh()
    host.text = "下"
    send(",", 43)
    swap()
    try check(host.text == "下," && totals().count(.punctuationOpportunities) == 1 && totals().count(.committedPunctuationSwaps) == 1,
              "標點與中英對調分開")
    fresh(terminal: true)
    send(",", 43)
    swap()
    fresh()
    host.text = "下"
    send(",", 43)
    host.text = "改過標點"
    swap()
    try check(totals().count(.punctuationOpportunities) == 3 && totals().count(.stagedPunctuationSwaps) == 1
        && totals().count(.refusedPunctuationSwaps) == 1, "標點也區分暫存與宿主拒絕")

    // 成對符號算標點對調：兩個方括號各是一次機會，整對切換只算一次修正，
    // 接著的切換與數字直選是同一次修正的延續。
    fresh()
    let beforePair = totals()
    func pairDelta(_ metric: StatisticsMetric) -> Int { totals().count(metric) - beforePair.count(metric) }
    send("[", 33)
    send("]", 30)
    try check(host.text == "「」" && pairDelta(.punctuationOpportunities) == 2 && pairDelta(.trackOpportunities) == 0,
              "成對符號的機會算在標點，不算中英")
    swap()
    let afterPairSwitch = pairDelta(.committedPunctuationSwaps)
    swap()
    send("4", 21)
    try check(host.text == "《》" && afterPairSwitch == 1 && pairDelta(.committedPunctuationSwaps) == 1
        && pairDelta(.committedTrackSwaps) == 0, "整對切換只算一次標點修正")
    // 引擎自己判定整段換不了（跨行）而吃掉按鍵，算一次被拒。
    fresh()
    host.text = "「日\n月"
    send("]", 30)
    swap()
    try check(host.text == "「日\n月」" && pairDelta(.refusedPunctuationSwaps) == 1
        && pairDelta(.refusedTrackSwaps) == 0, "引擎吃掉的成對切換算被拒的標點對調")
    // 終端機裡結尾還在暫存，外層擋下成對切換，同樣算被拒，不算暫存中的對調。
    fresh(terminal: true)
    type("id")
    send("\t", 48)
    send("[", 33)
    send("a")
    send(" ", 49)
    send("]", 30)
    let stagedBeforePairRefusal = pairDelta(.stagedPunctuationSwaps)
    swap()
    try check(session.stagedCommit == "]" && pairDelta(.refusedPunctuationSwaps) == 2
        && pairDelta(.stagedPunctuationSwaps) == stagedBeforePairRefusal
        && pairDelta(.refusedTrackSwaps) == 0, "暫存中被擋下的成對切換算被拒的標點對調")

    fresh()
    let beforeSelection = totals()
    type("oj")
    send("", 125)
    send(" ", 49)
    try check(host.text == "什" && totals().count(.ambiguousChineseCommits) == beforeSelection.count(.ambiguousChineseCommits) + 1
        && totals().count(.candidateNavigationKeys) == beforeSelection.count(.candidateNavigationKeys) + 1,
              "重碼送出的額外按鍵")
    fresh()
    let beforeEnglish = totals()
    type("is")
    send("@", 19, .shift)
    type("is")
    send("\r", 36)
    try check(totals().englishRanks[1] == beforeEnglish.englishRanks[1] + 1
        && totals().count(.completionsWithEnglishPredictions) == beforeEnglish.count(.completionsWithEnglishPredictions) + 2,
              "英文採用名次與送出分母")

    // 符號面板開著時的按鍵屬於面板：方向鍵不算重碼選字的移動鍵，選符號不算英文候選的送出，
    // 也不借用反查的計數。
    fresh()
    let beforePanel = totals()
    type("no")
    send("", 125)
    session.toggleSymbolPanel(client: host)
    send("", 125)
    send("", 125)
    send("", 53)
    send(" ", 49)
    try check(host.text == "欠"
        && totals().count(.ambiguousChineseCommits) == beforePanel.count(.ambiguousChineseCommits) + 1
        && totals().count(.candidateNavigationKeys) == beforePanel.count(.candidateNavigationKeys) + 1,
              "符號面板裡的方向鍵不算重碼選字的移動鍵")
    fresh()
    let beforePick = totals()
    type("is")
    session.toggleSymbolPanel(client: host)
    send("2", 19)
    let afterPick = totals()
    try check(host.text == "is……" && afterPick.englishRanks == beforePick.englishRanks
        && afterPick.count(.completionsWithEnglishPredictions) == beforePick.count(.completionsWithEnglishPredictions)
        && [StatisticsMetric.lookupOpens, .lookupSelections, .lookupCancellations, .lookupPageTurns]
            .allSatisfy { afterPick.count($0) == beforePanel.count($0) },
              "選符號不算英文候選的送出，也不算反查")

    fresh()
    session.toggleReadingLookup(client: host)
    type("1i")
    send(" ", 49)
    session.pickReadingLookupRow(2, client: host)
    session.toggleReadingLookup(client: host)
    session.toggleReadingScheme(client: host)
    type("yi")
    send("", 121)
    send("", 53)
    session.toggleReadingLookup(client: host)
    session.commitComposition(client: host)
    let reading = totals()
    try check(reading.count(.lookupOpens) == 3 && reading.count(.lookupSelections) == 1
        && reading.count(.lookupCancellations) == 2 && reading.count(.lookupPageTurns) == 1,
              "鍵盤與面板用同一組反查分母")
    try check(StatisticsRoute.allCases.allSatisfy { (reading.latency[$0.rawValue]?.reduce(0,+) ?? 0) > 0 },
              "一般組字、送出與反查各有耗時分桶")
    var histogram = StatisticsTotals()
    for _ in 0..<95 { histogram.sample(.composing, nanoseconds: 1_000_000) }
    for _ in 0..<4 { histogram.sample(.composing, nanoseconds: 2_000_001) }
    histogram.sample(.composing, nanoseconds: 129_000_000)
    let buckets = histogram.latency[StatisticsRoute.composing.rawValue] ?? []
    try check(StatisticsTotals.percentile(95, buckets: buckets) == "≤1.0 ms"
        && StatisticsTotals.percentile(99, buckets: buckets) == "≤4.0 ms"
        && StatisticsTotals.percentile(100, buckets: buckets) == ">128 ms", "按樣本數計算百分位所在的級距")

    fresh()
    dualCommit()
    let swaps = totals().count(.committedTrackSwaps)
    store.setEnabled(false)
    store.setEnabled(true)
    swap()
    try check(totals().count(.committedTrackSwaps) == swaps, "暫停前的反悔機會不帶入下一段記錄")
    secure = true
    session.toggleReadingLookup(client: host)
    secure = false
    session.commitComposition(client: host)
    try check(totals().count(.lookupCancellations) == 2, "受保護欄位開始的反查不產生取消次數")
    passed += try checkCompletionTrialStatistics(store: store)

    fresh()
    let measured = try LocalUsageStatistics.encode(store.rows())
    secure = true
    type("syntheticprivate")
    send("\r", 36)
    session.toggleReadingLookup(client: host)
    session.commitComposition(client: host)
    try check(try LocalUsageStatistics.encode(store.rows()) == measured, "受保護欄位停記")
    secure = false
    store.setEnabled(false)
    fresh()
    dualCommit()
    swap()
    store.shutdown()
    try check(try Data(contentsOf: url) == measured, "暫停保留先前的資料並停止新增")
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "檔案只允許本人讀寫")

    let reopened = LocalUsageStatistics(url: url, defaults: defaults, build: "1.3", now: { now })
    defer { reopened.shutdown() }
    try check(!reopened.enabled && (try LocalUsageStatistics.encode(reopened.rows())) == measured,
              "讀回彙總與暫停狀態")
    guard let document = try JSONSerialization.jsonObject(with: measured) as? [String: Any],
          let rows = document["rows"] as? [[String: Any]] else {
        throw SelfTestFailure(message: "匯出的 JSON 缺少統計列")
    }
    let schemaOK = rows.allSatisfy { row in
        guard let group = row["group"] as? [String: String], let totals = row["totals"] as? [String: Any] else { return false }
        let metrics = totals["counts"] as? [String: Int] ?? [:]
        let latency = totals["latency"] as? [String: [Int]] ?? [:]
        return Set(row.keys) == ["group", "totals"] && Set(group.keys) == ["dateUTC", "build", "cangjie", "mode"]
            && Set(totals.keys) == ["counts", "latency", "englishRanks"]
            && metrics.keys.allSatisfy { StatisticsMetric(rawValue: $0) != nil }
            && latency.allSatisfy { StatisticsRoute(rawValue: $0.key) != nil && $0.value.count == StatisticsTotals.microsecondLimits.count + 1 }
    }
    let exported = String(decoding: measured, as: UTF8.self)
    try check(Set(document.keys) == ["format", "rows", "latencyUpperBoundsMicroseconds"] && schemaOK
        && ["syntheticprivate", "GoshawkIME", "goshaw", "OjPersonal", "資料", "SQL"].allSatisfy { !exported.contains($0) },
              "落地與匯出只有允許的分組、計數與分布")

    reopened.setEnabled(true)
    var configuration = EngineConfiguration()
    configuration.cangjieVersion = .v5
    configuration.mixedModeEnabled = false
    let group = reopened.group(for: InputEngine(configuration: configuration))
    reopened.update(group) { $0.add(.ambiguousChineseCommits) }
    let report = StatisticsSettings.report(rows: reopened.rows())
    try check(group.cangjie == "v5" && group.mode == .chinese && report.contains("1.2") && report.contains("1.3")
        && report.contains("P99"), "依版本檢視觀測數與耗時")
    now.addTimeInterval(29 * 86400)
    try check(reopened.rows().count == 2, "保留今天加前 29 天")
    now.addTimeInterval(86400)
    try check(reopened.rows().isEmpty, "第 30 天刪除過期資料")
    let current = reopened.group(for: InputEngine(configuration: configuration))
    reopened.update(current) { $0.add(.lookupOpens) }
    reopened.setEnabled(false)
    try reopened.clear()
    reopened.shutdown()
    try check(!FileManager.default.fileExists(atPath: url.path) && reopened.rows().isEmpty, "清除後舊的批次寫入不會重建檔案")
    // 以普通檔案占住儲存目錄，穩定重現背景寫入失敗。
    for clearBeforeRetry in [false, true] {
        let blockedDirectory = directory.appendingPathComponent(clearBeforeRetry ? "cleared" : "paused")
        let retryURL = blockedDirectory.appendingPathComponent("statistics.json")
        let retryStore = LocalUsageStatistics(url: retryURL, defaults: defaults, build: "1.3", now: { now })
        try Data().write(to: blockedDirectory)
        retryStore.setEnabled(true)
        retryStore.update(retryStore.group(for: InputEngine())) { $0.add(.lookupOpens) }
        retryStore.setEnabled(false)
        retryStore.shutdown()
        try FileManager.default.removeItem(at: blockedDirectory)
        if clearBeforeRetry { try retryStore.clear() }
        retryStore.shutdown()
        if clearBeforeRetry {
            try check(retryStore.rows().isEmpty && !FileManager.default.fileExists(atPath: retryURL.path),
                      "清除待重試快照後，舊資料不會被寫回")
        } else {
            let recovered = LocalUsageStatistics(url: retryURL, defaults: defaults, build: "1.3", now: { now })
            try check(!recovered.enabled && recovered.rows().first?.totals.count(.lookupOpens) == 1,
                      "儲存恢復後，即使仍暫停且沒有新按鍵，也寫回失敗的批次一次")
            recovered.shutdown()
        }
    }
    passed += try checkStatisticsFileRecovery(directory: directory, defaults: defaults, now: now)
    return passed
}

@MainActor
private func checkStatisticsFileRecovery(directory: URL, defaults: UserDefaults, now: Date) throws -> Int {
    let fm = FileManager.default
    let url = directory.appendingPathComponent("future.json")
    let future = Data(#"{"format":42,"latencyUpperBoundsMicroseconds":[],"rows":[]}"#.utf8)
    try future.write(to: url)
    let store = LocalUsageStatistics(url: url, defaults: defaults, build: "1.3", now: { now })
    store.setEnabled(true)
    let group = store.group(for: InputEngine())
    store.update(group) { $0.add(.lookupOpens) }
    store.shutdown()
    let controls = StatisticsSettings(store: store, note: NSTextField(labelWithString: ""))
    guard try Data(contentsOf: url) == future, !store.enabled,
          controls.toggle.state == .on, !controls.inspect.isEnabled,
          controls.note.stringValue == UIText.statisticsFileUnavailable.text else {
        throw SelfTestFailure(message: "無法解讀的統計檔保持原樣，設定顯示暫停原因")
    }
    controls.toggle.performClick(nil)
    try store.clear()
    controls.reload()
    guard !store.enabled, !fm.fileExists(atPath: url.path), controls.inspect.isEnabled,
          controls.toggle.state == .off else {
        throw SelfTestFailure(message: "清除未支援的統計格式後，沿用使用者最新的記錄選擇")
    }

    controls.toggle.performClick(nil)
    store.update(group) { $0.add(.lookupOpens) }
    store.shutdown()
    guard store.enabled, store.rows().first?.totals.count(.lookupOpens) == 1,
          try Data(contentsOf: url) == LocalUsageStatistics.encode(store.rows()) else {
        throw SelfTestFailure(message: "清除後重新同意時可以開始記錄並存檔")
    }
    try store.clear()

    // 目錄與裡面的檔案都不是使用者授權清除的統計檔。
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    let otherFile = url.appendingPathComponent("unrelated")
    try Data([1]).write(to: otherFile)
    let unreadable = LocalUsageStatistics(url: url, defaults: defaults, build: "1.3", now: { now })
    unreadable.setEnabled(true)
    let blocked = StatisticsSettings(store: unreadable, note: NSTextField(labelWithString: ""))
    do {
        try unreadable.clear()
        throw SelfTestFailure(message: "清除統計不應刪除目錄")
    } catch is POSIXError {}
    guard !unreadable.enabled, !blocked.inspect.isEnabled, try Data(contentsOf: otherFile) == Data([1]) else {
        throw SelfTestFailure(message: "清除失敗須保留原目錄與暫停狀態")
    }
    try fm.moveItem(at: url, to: directory.appendingPathComponent("original-directory"))
    var totals = StatisticsTotals()
    totals.add(.lookupOpens)
    let old = StatisticsGroup(dateUTC: "2000-01-01", build: group.build, cangjie: group.cangjie, mode: group.mode)
    try LocalUsageStatistics.encode([StatisticsRow(group: old, totals: totals),
                                    StatisticsRow(group: group, totals: totals)]).write(to: url)
    blocked.reload()
    let rows = unreadable.rows()
    unreadable.shutdown()
    guard unreadable.enabled, blocked.inspect.isEnabled, rows.map(\.group) == [group],
          rows.first?.totals.count(.lookupOpens) == 1,
          try Data(contentsOf: url) == LocalUsageStatistics.encode(rows) else {
        throw SelfTestFailure(message: "重新開啟設定能恢復讀取，並刪除過期統計")
    }
    return 5
}

@MainActor
private func checkCompletionTrialStatistics(store: LocalUsageStatistics) throws -> Int {
    var configuration = EngineConfiguration()
    configuration.personalTermsEnabled = true
    configuration.chineseContinuationEnabled = true
    configuration.personalTerms = PersonalTerms(["GoshawkIME", "IdentifierLab", "OjPersonal"])
    var secure = false
    let session = InputSessionCoordinator(configuration: configuration,
        statistics: StatisticsSession(store: store, isSecureInput: { secure }))
    var host = FakeIMKClient()
    let panel = CandidateOverlayPanel.shared
    defer { panel.orderOut(nil) }
    var checks = 0
    func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw SelfTestFailure(message: "補完統計：\(name)") }
        checks += 1
    }
    func send(_ text: String, _ code: UInt16 = 0, _ flags: NSEvent.ModifierFlags = []) {
        _ = session.handlePayload(KeyEventPayload(keyCode: code, modifierFlags: flags, characters: text,
            charactersIgnoringModifiers: text), client: host) { overlay, reading, rect in
            panel.update(overlay: overlay, layerPanel: reading, cursorRect: rect,
                         showsEnglishActions: session.englishActionsAvailable, revertHint: session.revertHint,
                         continuation: session.engine.chineseContinuation)
        }
    }
    func start(_ letters: String, after prefix: String = "") {
        session.resetForFocusChange()
        host = FakeIMKClient()
        host.text = prefix
        for ch in letters { send(String(ch)) }
    }
    func count(_ metric: StatisticsMetric) -> Int { store.rows().reduce(0) { $0 + $1.totals.count(metric) } }
    func offerChinese() { start("fdyj", after: "用 SQL 查詢資"); send(" ", 49) }
    func english(_ offered: Int, _ accepted: Int) -> Bool {
        count(.compositionsWithPersonalTermOffer) == offered && count(.personalTermAcceptances) == accepted
    }

    offerChinese()
    try check(panel.shownCommitHint?.contains("庫") == true && count(.chineseContinuationOffers) == 1, "中文浮窗顯示一次")
    send("\r", 36, .option)
    send("\r", 36, .option)
    offerChinese()
    send("x")
    send("", 53)
    try check(count(.chineseContinuationOffers) == 2 && count(.chineseContinuationAcceptances) == 1, "採用一次、略過一次")

    start("goshaw")
    send("\t", 48)
    try check(host.text == "GoshawkIME " && english(1, 1), "多個前綴顯示同一術語只算一次")
    start("goshawxx")
    send("\r", 36)
    start("goshaw")
    send("", 53)
    try check(english(2, 1), "較早出現術語的送出保留在分母，取消組字排除")
    start("id")
    send("\t", 48)
    try check(host.text == "id " && english(3, 1), "完整短詞排在個人術語之前")
    start("oj")
    send(" ", 49)
    send(" ", 49, .shift)
    try check(host.text == "OjPersonal " && english(4, 1), "中英反悔不會新增採用或重算分母")
    start("goshaw")
    session.commitComposition(client: host)
    try check(host.text == "goshaw" && english(5, 1), "宿主結束組字也會送出")
    session.engine.configuration.personalTerms = PersonalTerms(["ID", "GoshA", "GoshB", "GoshC", "GoshD", "GoshE"])
    start("id")
    send("\t", 48)
    try check(host.text == "id " && english(6, 2), "短詞本身是個人詞表成員")
    start("gosh")
    send("%", 23, .shift)
    try check(host.text == "GoshE " && english(7, 2), "第五名可用快捷鍵但未出現在浮窗")
    start("zzzz")
    send("\r", 36)
    try check(english(7, 2), "從未顯示個人術語的組字排除")
    let report = StatisticsSettings.report(rows: store.rows())
    try check(report.contains(UIText.statisticsContinuations.text(1, 2))
        && report.contains(UIText.statisticsPersonalTerms.text(2, 7)), "設定列出兩種採用分母")

    for paused in [true, false] {
        store.setEnabled(!paused)
        secure = !paused
        offerChinese()
        send("\r", 36, .option)
        start("id")
        send("\t", 48)
    }
    try check(english(7, 2) && count(.chineseContinuationOffers) == 2 && count(.chineseContinuationAcceptances) == 1,
              "暫停與受保護輸入都不增加任何補完計數")
    return checks
}
