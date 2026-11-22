import Foundation
import Testing
@testable import GoshawkApp

@Test("版本號依數值逐段比較，帶其他字樣的標籤不算發行版本")
func releaseVersionOrdering() throws {
    let current = try #require(ReleaseVersion("0.1.0"))
    #expect(try #require(ReleaseVersion("v0.2.0")) > current)
    #expect(try #require(ReleaseVersion("0.10.0")) > #require(ReleaseVersion("0.9.9")))
    #expect(try #require(ReleaseVersion("0.1")) == current)
    #expect(try #require(ReleaseVersion("v0.2.0")).description == "0.2.0")
    for tag in ["", "v", "0.2.0-beta", "0..1", "latest", "0.2.x"] {
        #expect(ReleaseVersion(tag) == nil, "\(tag) 不該被當成版本號")
    }
}

@Test("從 GitHub 最新發行版的回應取出版本號")
func latestVersionFromReleaseJSON() {
    let body = Data(#"{"tag_name":"v0.2.0","name":"蒼鷹輸入法 0.2.0","draft":false}"#.utf8)
    #expect(UpdateChecker.latestVersion(fromReleaseJSON: body)?.description == "0.2.0")
    #expect(UpdateChecker.latestVersion(fromReleaseJSON: Data(#"{"message":"Not Found"}"#.utf8)) == nil)
    #expect(UpdateChecker.latestVersion(fromReleaseJSON: Data("<html>".utf8)) == nil)
}

/// 測試用的時鐘與假的查詢：記下被呼叫幾次，回應由測試決定何時送回。
@MainActor
private final class Harness {
    let defaults: UserDefaults
    private let suiteName = "goshawk-update-tests-\(UUID().uuidString)"
    var time = Date(timeIntervalSince1970: 1_800_000_000)
    var fetchCount = 0
    var pending: (@Sendable (Data?) -> Void)?

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func checker(current: String? = "0.1.0") -> UpdateChecker {
        UpdateChecker(
            defaults: defaults,
            currentVersion: current.flatMap(ReleaseVersion.init),
            fetch: { completion in
                self.fetchCount += 1
                self.pending = completion
            },
            now: { self.time }
        )
    }

    /// 送回查詢結果，並等檢查器在主執行緒處理完。
    func respond(tag: String?) async {
        pending?(tag.map { Data(#"{"tag_name":"\#($0)"}"#.utf8) })
        pending = nil
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Test("一天最多查一次，查到較新的版本才提示")
func checksOncePerDayAndReportsNewerVersion() async {
    let harness = Harness()
    let checker = harness.checker()
    #expect(checker.availableVersion == nil)

    checker.checkIfDue()
    checker.checkIfDue()
    #expect(harness.fetchCount == 1, "查詢還沒回來時不重複送出")
    await harness.respond(tag: "v0.2.0")
    #expect(checker.availableVersion?.description == "0.2.0")

    harness.time += UpdateChecker.interval - 1
    checker.checkIfDue()
    #expect(harness.fetchCount == 1, "未滿一天不再查")

    harness.time += 1
    checker.checkIfDue()
    #expect(harness.fetchCount == 2)
    // 查詢失敗時保留上次查到的結果。
    await harness.respond(tag: nil)
    #expect(checker.availableVersion?.description == "0.2.0")

    // 使用者裝了新版之後，同一份偏好不再提示。
    #expect(harness.checker(current: "0.2.0").availableVersion == nil)
}

@MainActor
@Test("已是最新、關閉檢查或不是打包的 App 時不提示")
func staysQuietWhenThereIsNothingToOffer() async {
    let harness = Harness()
    let checker = harness.checker()
    checker.checkIfDue()
    await harness.respond(tag: "v0.1.0")
    #expect(checker.availableVersion == nil)

    harness.time += UpdateChecker.interval
    checker.checkIfDue()
    await harness.respond(tag: "v0.3.0")
    #expect(checker.availableVersion?.description == "0.3.0")

    checker.isEnabled = false
    #expect(checker.availableVersion == nil)
    harness.time += UpdateChecker.interval
    checker.checkIfDue()
    #expect(harness.fetchCount == 2, "關閉後不連網")

    let unbundled = Harness()
    unbundled.checker(current: nil).checkIfDue()
    #expect(unbundled.fetchCount == 0, "不是打包的 App 不連網")
}

@MainActor
@Test("時鐘被往回調之後仍會再查")
func checksAgainAfterClockMovesBackwards() async {
    let harness = Harness()
    let checker = harness.checker()
    checker.checkIfDue()
    await harness.respond(tag: "v0.1.0")

    harness.time -= 30 * UpdateChecker.interval
    checker.checkIfDue()
    #expect(harness.fetchCount == 2)
}
