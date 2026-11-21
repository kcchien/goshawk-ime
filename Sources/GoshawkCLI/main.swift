import Darwin.Mach
import Foundation
import GoshawkCore

struct DoctorReport: Codable {
    let status: String
    let cangjieV5Codes: Int
    let cangjieV3Codes: Int
    let englishWords: Int
    let readingSyllables: Int
    let readingTonedSyllables: Int
    let readingCharacters: Int
    let sampleDualSpace: String
    let sampleDualTab: String
}

struct ReadingCandidateRecord: Codable {
    let character: String
    let nativeCodes: [String]
    let radicals: [String]
}

struct ReadingReport: Codable {
    let status: String
    let keys: String
    let scheme: String
    let version: String
    let bopomofo: String?
    let tone: Int?
    let displayDachen: String?
    let displayPinyin: String?
    let candidateCount: Int
    let candidates: [ReadingCandidateRecord]
}

struct BenchmarkReport: Codable {
    let status: String
    let keyEvents: Int
    let p50Ms: Double
    let p99Ms: Double
    let maxMs: Double
    let rssMB: Double
    let cangjieV5Codes: Int
    let englishWords: Int
}

struct ScriptStepRecord: Codable {
    let step: Int
    let token: String
    let state: String
    let buffer: String
    let committedText: String?
    let committedCore: String?
    let commitKind: String
    let deletedBackwardCount: Int
    let englishPredictions: [String]
    let cangjieRadicals: String?
    let cangjieCandidates: [String]
    /// 反查開啟時面板的完整內容：讀音顯示、狀態、本頁各列、焦點與頁碼。
    let readingLookupPanel: ReadingLookupPanel?
    let documentText: String
    let pendingAutoSpace: Bool
    /// 行內程式片段語境：`none`、`inside`、`inside+zh`（黏中）或 `just-closed`，
    /// 片段內與剛關上時附開啟片段時記下的語境字元。
    let snippet: String
    /// 浮窗要標的那一軌，也就是空白鍵會送出哪一邊。沒有浮窗時為 nil。
    let spaceCommits: String?
    /// 浮窗要不要標出「片段」。沒有浮窗時為 nil。
    let inCodeSnippet: Bool?
    /// 這一步送出的文字可以用 Shift+空白 對調。
    let revertible: Bool
    /// 浮窗提示裡對調後的字詞。不可反悔時為 nil。
    let revertPreview: String?
}

struct ScriptReport: Codable {
    let tokens: [String]
    let finalState: String
    let finalBuffer: String
    let documentText: String
    let steps: [ScriptStepRecord]
}

func currentResidentMemoryMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return -1.0 }
    return Double(info.resident_size) / (1024.0 * 1024.0)
}

func runDoctor() throws -> Int32 {
    var dualSpaceEngine = InputEngine()
    _ = dualSpaceEngine.handle(.character("m"))
    _ = dualSpaceEngine.handle(.character("y"))
    let spaceEffect = dualSpaceEngine.handle(.space)

    var dualTabEngine = InputEngine()
    _ = dualTabEngine.handle(.character("m"))
    _ = dualTabEngine.handle(.character("y"))
    let tabEffect = dualTabEngine.handle(.tab)

    let cj5Codes = CangjieDictionary.sharedV5.codeCount
    let cj3Codes = CangjieDictionary.sharedV3.codeCount
    let enWords = EnglishPredictor.shared.wordCount
    let readings = ReadingIndex.shared

    let ok = spaceEffect.documentText == "下"
        && tabEffect.documentText == "my "
        && cj5Codes > 10_000
        && cj3Codes > 10_000
        && enWords > 9_000
        && readings.syllableCount > 400
        && readings.tonedSyllableCount > 1_200
        && readings.characterCount > 10_000

    let report = DoctorReport(
        status: ok ? "ok" : "error",
        cangjieV5Codes: cj5Codes,
        cangjieV3Codes: cj3Codes,
        englishWords: enWords,
        readingSyllables: readings.syllableCount,
        readingTonedSyllables: readings.tonedSyllableCount,
        readingCharacters: readings.characterCount,
        sampleDualSpace: spaceEffect.documentText,
        sampleDualTab: tabEffect.documentText
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    print(String(decoding: data, as: UTF8.self))
    return ok ? 0 : 1
}

func runBenchmark() throws -> Int32 {
    let sampleTokens = [
        "o", "n", "f", "SPACE",
        "v", "n", "d", "SPACE",
        "h", "e", "l", "l", "o", "TAB",
        "COMMA", "SPACE",
        "w", "o", "r", "l", "d", "TAB",
        "BANG",
        "m", "y", "SPACE",
        "m", "y", "TAB",
        "n", "o", "t", "BKSP", "SPACE",
        "d", "o", "c", "k", "e", "r", "SPACE",
        "i", "s", "SHIFT_2",
        "ESC"
    ]
    let sampleKeys = sampleTokens.compactMap(KeyInput.parse(token:))
    precondition(sampleKeys.count == sampleTokens.count)

    let totalEvents = 10_000
    var latenciesMs: [Double] = []
    latenciesMs.reserveCapacity(totalEvents)

    var engine = InputEngine()
    // Warm up shared singletons once before timing keystrokes.
    _ = engine.handle(.character("a"))
    _ = engine.handle(.escape)

    for i in 0..<totalEvents {
        if i % 200 == 0 {
            engine.resetContext()
        }
        let key = sampleKeys[i % sampleKeys.count]
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = engine.handle(key)
        let t1 = DispatchTime.now().uptimeNanoseconds
        latenciesMs.append(Double(t1 - t0) / 1_000_000.0)
    }

    latenciesMs.sort()
    let p50 = latenciesMs[totalEvents / 2]
    let p99 = latenciesMs[Int(Double(totalEvents) * 0.99)]
    let maxVal = latenciesMs.last ?? 0.0
    let rssMB = currentResidentMemoryMB()

    let passed = p99 < 2.0 && rssMB > 0 && rssMB < 50.0
    let report = BenchmarkReport(
        status: passed ? "ok" : "failed",
        keyEvents: totalEvents,
        p50Ms: (p50 * 10_000).rounded() / 10_000,
        p99Ms: (p99 * 10_000).rounded() / 10_000,
        maxMs: (maxVal * 10_000).rounded() / 10_000,
        rssMB: (rssMB * 100).rounded() / 100,
        cangjieV5Codes: CangjieDictionary.sharedV5.codeCount,
        englishWords: EnglishPredictor.shared.wordCount
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    print(String(decoding: data, as: UTF8.self))
    return passed ? 0 : 1
}

/// 唯讀查詢：把一段讀音鍵序交給索引，印出面板會顯示的讀音、候選字、原生碼與字根。
func runReading(keys: String, scheme: PhoneticScheme, version: CangjieVersion) throws -> Int32 {
    let index = ReadingIndex.shared
    let input = index.interpret(keys, scheme: scheme)

    var status = "unknown"
    var query: ReadingQuery?
    switch input {
    case .empty:
        status = "empty"
    case .partial:
        status = "partial"
    case .unknown:
        status = "unknown"
    case .syllable(let parsed):
        status = "syllable"
        query = parsed
    }

    let candidates = query.map { index.candidates(for: $0, version: version) } ?? []
    let report = ReadingReport(
        status: status,
        keys: keys,
        scheme: scheme.rawValue,
        version: version.rawValue,
        bopomofo: query?.bopomofo,
        tone: query?.tone?.rawValue,
        displayDachen: query.map { index.display($0, scheme: .dachen) },
        displayPinyin: query.map { index.display($0, scheme: .pinyin) },
        candidateCount: candidates.count,
        candidates: candidates.map { candidate in
            ReadingCandidateRecord(
                character: candidate.character,
                nativeCodes: candidate.nativeCodes,
                radicals: candidate.nativeCodes.map(
                    CangjieDictionary.shared(version: version).radicals(for:)
                )
            )
        }
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(report)
    print(String(decoding: data, as: UTF8.self))
    return 0
}

/// 片段語境的逐步輸出。開啟片段時記下的語境字元接在後面，沒有字元時寫 `-`。
func snippetLabel(_ context: SnippetContext) -> String {
    func suffix(_ ch: Character?) -> String {
        ":" + (ch.map(String.init) ?? "-")
    }
    switch context {
    case .none:
        return "none"
    case .inside(let inside):
        return (inside.stickyChinese ? "inside+zh" : "inside") + suffix(inside.characterBefore)
    case .justClosed(let characterBefore):
        return "just-closed" + suffix(characterBefore)
    }
}

func runScript(rawTokens: String, evidenceOut: String?) throws -> Int32 {
    let tokens = rawTokens.split(whereSeparator: \.isWhitespace).map(String.init)
    var engine = InputEngine()
    var steps: [ScriptStepRecord] = []

    for (idx, token) in tokens.enumerated() {
        guard let key = KeyInput.parse(token: token) else {
            fputs("Error: unknown key token '\(token)' at index \(idx)\n", stderr)
            return 2
        }
        let effect = engine.handle(key)
        steps.append(ScriptStepRecord(
            step: idx + 1,
            token: token,
            state: effect.state.rawValue,
            buffer: effect.buffer,
            committedText: effect.committedText,
            committedCore: effect.committedCore,
            commitKind: effect.commitKind.rawValue,
            deletedBackwardCount: effect.deletedBackwardCount,
            englishPredictions: effect.overlay?.englishTrack.predictions ?? [],
            cangjieRadicals: effect.overlay?.cangjieTrack?.radicals,
            cangjieCandidates: effect.overlay?.cangjieTrack?.candidates ?? [],
            readingLookupPanel: effect.readingLookupPanel,
            documentText: effect.documentText,
            pendingAutoSpace: effect.pendingAutoSpace,
            snippet: snippetLabel(engine.snippet),
            spaceCommits: effect.overlay?.spaceCommits.rawValue,
            inCodeSnippet: effect.overlay?.inCodeSnippet,
            revertible: effect.revertible,
            revertPreview: effect.revertPreview
        ))
    }

    let report = ScriptReport(
        tokens: tokens,
        finalState: engine.state.rawValue,
        finalBuffer: engine.buffer,
        documentText: engine.documentText,
        steps: steps
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    let json = String(decoding: data, as: UTF8.self)

    if let path = evidenceOut {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    print(json)
    return 0
}

// MARK: - 常駐模式

// 離線模擬要在引擎副本上預演，所以需要便宜的「存下狀態、還原狀態」。
// `--serve` 把引擎留在同一個行程裡：標準輸入一行一個指令，標準輸出回一行結果。
// 欄位以 Tab 分隔，文字欄位把反斜線、Tab 與換行轉義，所以回應固定一行。
//
// 指令（<h> 是引擎編號）：
//   new                     建一個預設設定的引擎        → ok <h>
//   clone <h>               複製成另一個引擎（快照）    → ok <h2>
//   free <h>...             釋放引擎編號                → ok
//   key <h> <按鍵代號>      送一個按鍵                  → ok <狀態> <緩衝> <送出> <回刪> <已處理> <送出類別> <可反悔>
//   cands <h> <倉頡碼>      那個碼在這份學習紀錄下的候選 → ok <候選>...
//   reset <h> [前文]        清掉組字與前文鏡像，改成指定前文 → ok
//   config <h> <鍵> <值>    改一項設定                  → ok
//   dump <h>                讀回狀態、緩衝、前文鏡像    → ok <狀態> <緩衝> <前文> <待收合空格> <有反悔紀錄>
//   quit                    結束
// 失敗一律回 `err <原因>`，引擎不動。
// <送出> 的 `0` 是沒有送出，`1` 後面接送出的文字。

private func serveEscape(_ text: String) -> String {
    guard text.contains(where: { $0 == "\\" || $0 == "\t" || $0 == "\n" }) else { return text }
    var out = ""
    out.reserveCapacity(text.count + 8)
    for ch in text {
        switch ch {
        case "\\": out += "\\\\"
        case "\t": out += "\\t"
        case "\n": out += "\\n"
        default: out.append(ch)
        }
    }
    return out
}

private func serveUnescape(_ field: String) -> String {
    guard field.contains("\\") else { return field }
    var out = ""
    out.reserveCapacity(field.count)
    var pendingEscape = false
    for ch in field {
        if pendingEscape {
            switch ch {
            case "t": out.append("\t")
            case "n": out.append("\n")
            default: out.append(ch)
            }
            pendingEscape = false
        } else if ch == "\\" {
            pendingEscape = true
        } else {
            out.append(ch)
        }
    }
    return out
}

private func serveOptional(_ text: String?) -> String {
    guard let text else { return "0" }
    return "1" + serveEscape(text)
}

private func serveKeyResponse(_ effect: StepEffect) -> String {
    [
        "ok",
        effect.state.rawValue,
        serveEscape(effect.buffer),
        serveOptional(effect.committedText),
        String(effect.deletedBackwardCount),
        effect.handled ? "1" : "0",
        effect.commitKind.rawValue,
        effect.revertible ? "1" : "0"
    ].joined(separator: "\t")
}

func runServe() -> Int32 {
    var engines: [InputEngine?] = []
    var freeSlots: [Int] = []

    func allocate(_ engine: InputEngine) -> Int {
        if let slot = freeSlots.popLast() {
            engines[slot] = engine
            return slot
        }
        engines.append(engine)
        return engines.count - 1
    }

    func slot(_ field: String) -> Int? {
        guard let index = Int(field), index >= 0, index < engines.count, engines[index] != nil else {
            return nil
        }
        return index
    }

    func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }

    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { continue }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        switch fields[0] {
        case "quit":
            return 0
        case "new":
            emit("ok\t\(allocate(InputEngine()))")
        case "clone":
            guard fields.count == 2, let source = slot(fields[1]) else {
                emit("err\tclone needs one live handle")
                continue
            }
            emit("ok\t\(allocate(engines[source]!))")
        case "free":
            guard fields.count >= 2 else {
                emit("err\tfree needs at least one handle")
                continue
            }
            for field in fields.dropFirst() {
                guard let index = slot(field) else { continue }
                engines[index] = nil
                freeSlots.append(index)
            }
            emit("ok")
        case "key":
            guard fields.count == 3, let index = slot(fields[1]),
                  let key = KeyInput.parse(token: serveUnescape(fields[2])) else {
                emit("err\tkey needs a live handle and a known key token")
                continue
            }
            emit(serveKeyResponse(engines[index]!.handle(key)))
        case "cands":
            guard fields.count == 3, let index = slot(fields[1]) else {
                emit("err\tcands needs a live handle and a code")
                continue
            }
            // 候選順序只看碼與學習紀錄，所以在副本上打出那個碼再讀浮窗，原引擎不動。
            var probe = engines[index]!
            probe.resetContext()
            for ch in serveUnescape(fields[2]) {
                _ = probe.handle(.character(ch))
            }
            let candidates = probe.currentOverlay?.cangjieTrack?.candidates ?? []
            emit((["ok"] + candidates.map(serveEscape)).joined(separator: "\t"))
        case "reset":
            guard fields.count >= 2, let index = slot(fields[1]) else {
                emit("err\treset needs a live handle")
                continue
            }
            engines[index]!.resetContext()
            if fields.count >= 3 {
                engines[index]!.syncExternalContext(serveUnescape(fields[2]))
            }
            emit("ok")
        case "config":
            guard fields.count == 4, let index = slot(fields[1]) else {
                emit("err\tconfig needs a live handle, a key and a value")
                continue
            }
            var configuration = engines[index]!.configuration
            let on = fields[3] == "1"
            switch fields[2] {
            case "mixedMode":
                configuration.mixedModeEnabled = on
            case "cangjieVersion":
                guard let parsed = CangjieVersion(rawValue: fields[3]) else {
                    emit("err\tcangjieVersion takes v3 or v5")
                    continue
                }
                configuration.cangjieVersion = parsed
            case "autoSpace":
                configuration.autoSpaceEnabled = on
            case "autoPunctuation":
                configuration.autoPunctuationEnabled = on
            case "ctrlBracketsQuotes":
                configuration.ctrlBracketsQuotesEnabled = on
            case "developerVocabulary":
                configuration.developerVocabularyEnabled = on
            case "learnsEnglishPredictions":
                configuration.learnsEnglishPredictions = on
            case "learnsCangjieOrder":
                configuration.learnsCangjieOrder = on
            case "revert":
                configuration.revertEnabled = on
            default:
                emit("err\tunknown configuration key \(fields[2])")
                continue
            }
            engines[index]!.configuration = configuration
            emit("ok")
        case "dump":
            guard fields.count == 2, let index = slot(fields[1]) else {
                emit("err\tdump needs a live handle")
                continue
            }
            let engine = engines[index]!
            emit([
                "ok",
                engine.state.rawValue,
                serveEscape(engine.buffer),
                serveEscape(engine.documentText),
                engine.pendingAutoSpace ? "1" : "0",
                engine.revertRecord != nil ? "1" : "0"
            ].joined(separator: "\t"))
        default:
            emit("err\tunknown command \(fields[0])")
        }
    }
    return 0
}

func main() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--serve") {
        return runServe()
    }

    if args.contains("--doctor") {
        do {
            return try runDoctor()
        } catch {
            fputs("Doctor failed: \(error)\n", stderr)
            return 1
        }
    }

    if args.contains("--benchmark") {
        do {
            return try runBenchmark()
        } catch {
            fputs("Benchmark failed: \(error)\n", stderr)
            return 1
        }
    }

    var scriptArg: String?
    var evidenceOut: String?
    var readingArg: String?
    var scheme: PhoneticScheme = .dachen
    var version: CangjieVersion = .v5
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--reading":
            i += 1
            guard i < args.count else {
                fputs("Missing value for --reading\n", stderr)
                return 2
            }
            readingArg = args[i]
        case "--scheme":
            i += 1
            guard i < args.count, let parsed = PhoneticScheme(rawValue: args[i]) else {
                fputs("Missing or unknown value for --scheme (dachen | pinyin)\n", stderr)
                return 2
            }
            scheme = parsed
        case "--version":
            i += 1
            guard i < args.count, let parsed = CangjieVersion(rawValue: args[i]) else {
                fputs("Missing or unknown value for --version (v5 | v3)\n", stderr)
                return 2
            }
            version = parsed
        case "--script":
            i += 1
            guard i < args.count else {
                fputs("Missing value for --script\n", stderr)
                return 2
            }
            scriptArg = args[i]
        case "--evidence-out":
            i += 1
            guard i < args.count else {
                fputs("Missing value for --evidence-out\n", stderr)
                return 2
            }
            evidenceOut = args[i]
        default:
            fputs("Unknown argument: \(args[i])\n", stderr)
            return 2
        }
        i += 1
    }

    if let keys = readingArg {
        do {
            return try runReading(keys: keys, scheme: scheme, version: version)
        } catch {
            fputs("Reading query failed: \(error)\n", stderr)
            return 1
        }
    }

    guard let rawTokens = scriptArg else {
        fputs("Usage: GoshawkCLI --doctor | --benchmark | --serve | --reading \"<keys>\" [--scheme dachen|pinyin] [--version v5|v3] | --script \"<tokens>\" [--evidence-out <path>]\n", stderr)
        return 2
    }

    do {
        return try runScript(rawTokens: rawTokens, evidenceOut: evidenceOut)
    } catch {
        fputs("Script execution failed: \(error)\n", stderr)
        return 1
    }
}

exit(main())
