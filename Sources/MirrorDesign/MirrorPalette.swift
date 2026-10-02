import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 앱과 채택한 SwiftPieces에서 사용하는 플랫폼별 동적 색상.
func mirrorAdaptiveColor(light: UInt32, dark: UInt32) -> Color {
    #if os(macOS)
    return Color(nsColor: NSColor(name: nil) { appearance in
        let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                       green: CGFloat((hex >> 8) & 255) / 255,
                       blue: CGFloat(hex & 255) / 255, alpha: 1)
    })
    #else
    return Color(uiColor: UIColor { traits in
        let hex = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                       green: CGFloat((hex >> 8) & 255) / 255,
                       blue: CGFloat(hex & 255) / 255, alpha: 1)
    })
    #endif
}

public enum MirrorPalette {
    public static var surface: Color { mirrorAdaptiveColor(light: 0xF3F2EE, dark: 0x121212) }
    public static var canvas: Color { mirrorAdaptiveColor(light: 0xF7F8F6, dark: 0x191C1A) }
    public static var card: Color { mirrorAdaptiveColor(light: 0xFFFFFF, dark: 0x252925) }
    public static var border: Color { mirrorAdaptiveColor(light: 0xE4E8E3, dark: 0x373E38) }
    public static var accent: Color { mirrorAdaptiveColor(light: 0x28663C, dark: 0xA9DCB7) }
    /// 채움 강조색 위에 표시하는 주요 동작 문구.
    public static var onAccent: Color { mirrorAdaptiveColor(light: 0xFFFFFF, dark: 0x16301E) }
    /// 설정 설명처럼 읽을 수 있어야 하는 보조 문구.
    public static var supportingText: Color { mirrorAdaptiveColor(light: 0x526155, dark: 0xAEBCAF) }
    /// 비어 있는 편집 입력란의 안내 문구.
    public static var inputPrompt: Color { supportingText }
}
