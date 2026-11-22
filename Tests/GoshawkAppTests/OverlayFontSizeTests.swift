import Foundation
import Testing
@testable import GoshawkApp

/// 每個測試用自己的偏好網域，測完清掉，不碰使用者真正的偏好。
private func withPreferences(_ body: (PreferencesStore, UserDefaults) throws -> Void) rethrows {
    let suiteName = "goshawk-font-size-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(PreferencesStore(defaults: defaults), defaults)
}

@Test("沒存過偏好時浮窗字級是標準，而且標準檔就是原本寫死的點數")
func overlayFontSizeDefaultsToMedium() {
    withPreferences { preferences, _ in
        #expect(preferences.loadOverlayFontSize() == .medium)
    }
    #expect(OverlayFontSize.medium.metrics == OverlayFontMetrics(primary: 17, secondary: 13, hint: 12, caption: 11))
    #expect(OverlayFontSize.allCases == [.small, .medium, .large])
}

@Test("三檔字級表逐一角色由小到大，同一檔內主字最大、編號最小")
func overlayFontMetricsAreMonotonic() {
    let roles: [KeyPath<OverlayFontMetrics, CGFloat>] = [\.primary, \.secondary, \.hint, \.caption]
    let small = OverlayFontSize.small.metrics
    let medium = OverlayFontSize.medium.metrics
    let large = OverlayFontSize.large.metrics
    for role in roles {
        // 小檔的單行提示與次要文字同為 11 點，所以相鄰兩檔只要求不變小，頭尾兩檔要求確實變大。
        #expect(small[keyPath: role] <= medium[keyPath: role])
        #expect(medium[keyPath: role] < large[keyPath: role])
        #expect(small[keyPath: role] < large[keyPath: role])
    }
    #expect(small.primary < medium.primary)
    #expect(small.secondary < medium.secondary)
    #expect(small.caption < medium.caption)
    for size in OverlayFontSize.allCases {
        let metrics = size.metrics
        #expect(metrics.primary > metrics.secondary)
        #expect(metrics.secondary >= metrics.hint)
        #expect(metrics.hint >= metrics.caption)
    }
    #expect(small == OverlayFontMetrics(primary: 15, secondary: 11, hint: 11, caption: 10))
    #expect(large == OverlayFontMetrics(primary: 20, secondary: 15, hint: 14, caption: 12))
}

@Test("欄寬跟著字級等比例縮放，標準檔維持原寬")
func overlayColumnWidthScalesWithFontSize() {
    #expect(OverlayFontSize.medium.columnWidth(24, following: \.primary) == 24)
    #expect(OverlayFontSize.medium.columnWidth(62, following: \.secondary) == 62)
    #expect(OverlayFontSize.large.columnWidth(24, following: \.primary) > 24)
    #expect(OverlayFontSize.small.columnWidth(24, following: \.primary) < 24)
    // 縮小後仍放得下一個該字級的全形字。
    #expect(OverlayFontSize.small.columnWidth(24, following: \.primary) >= OverlayFontSize.small.metrics.primary)
}

@Test("浮窗字級寫入後讀得回來，新建的偏好物件也讀到同一個值")
func overlayFontSizeRoundTrips() {
    withPreferences { preferences, defaults in
        for size in OverlayFontSize.allCases {
            preferences.saveOverlayFontSize(size)
            #expect(preferences.loadOverlayFontSize() == size)
            #expect(PreferencesStore(defaults: defaults).loadOverlayFontSize() == size)
            #expect(defaults.string(forKey: "goshawk.overlayFontSize") == size.rawValue)
        }
    }
}

@Test("偏好裡是不認得的字串或別種型別時退回標準")
func overlayFontSizeFallsBackOnUnknownValue() {
    withPreferences { preferences, defaults in
        for junk in ["huge", "", "Medium", "17"] {
            defaults.set(junk, forKey: "goshawk.overlayFontSize")
            #expect(preferences.loadOverlayFontSize() == .medium, "「\(junk)」應該退回標準")
        }
        defaults.set(20, forKey: "goshawk.overlayFontSize")
        #expect(preferences.loadOverlayFontSize() == .medium)
    }
}

@Test("存字級不動其他偏好，存其他偏好也不動字級")
func overlayFontSizeIsIndependentOfEngineConfiguration() {
    withPreferences { preferences, _ in
        let before = preferences.loadConfiguration()
        preferences.saveOverlayFontSize(.large)
        #expect(preferences.loadConfiguration() == before)
        preferences.save(before)
        #expect(preferences.loadOverlayFontSize() == .large)
    }
}
