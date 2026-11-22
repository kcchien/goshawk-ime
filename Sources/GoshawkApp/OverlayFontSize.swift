import CoreGraphics

/// 浮窗上四種角色的字體點數。
struct OverlayFontMetrics: Equatable, Sendable {
    /// 候選字、反查的單字與符號。
    let primary: CGFloat
    /// 拆碼、英文軌、字母碼、名稱與面板標題。
    let secondary: CGFloat
    /// 送出後那一行提示（反悔、接詞、成對切換被擋下）。
    let hint: CGFloat
    /// 編號、焦點標記、按鍵提示、分段按鈕與頁尾。
    let caption: CGFloat
}

/// 候選浮窗的字體大小。只影響顯示，屬於外層的偏好，不進引擎設定。
/// 浮窗的每個點數都從這張表取，新增一檔只要加一個成員與一列數字。
enum OverlayFontSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    var metrics: OverlayFontMetrics {
        switch self {
        case .small: OverlayFontMetrics(primary: 15, secondary: 11, hint: 11, caption: 10)
        case .medium: OverlayFontMetrics(primary: 17, secondary: 13, hint: 12, caption: 11)
        case .large: OverlayFontMetrics(primary: 20, secondary: 15, hint: 14, caption: 12)
        }
    }

    var title: UIText {
        switch self {
        case .small: .overlayFontSizeSmall
        case .medium: .overlayFontSizeMedium
        case .large: .overlayFontSizeLarge
        }
    }

    /// 面板裡固定寬度的欄位跟著那一欄的字級等比例縮放。`mediumWidth` 是標準檔的寬度。
    func columnWidth(_ mediumWidth: CGFloat, following role: KeyPath<OverlayFontMetrics, CGFloat>) -> CGFloat {
        (mediumWidth * metrics[keyPath: role] / OverlayFontSize.medium.metrics[keyPath: role]).rounded(.up)
    }
}
