import AppKit
import SwiftUI

enum AssistantTheme {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }

    static let background = adaptive(0xF3F3F6, 0x202024)
    static let surface = adaptive(0xFFFFFF, 0x2C2C30)
    static let inset = adaptive(0xF8F8FA, 0x27272B)
    static let line = adaptive(0xE3E3E8, 0x3B3B41)
    static let text = adaptive(0x242428, 0xF0F0F4)
    static let secondary = adaptive(0x878791, 0xA2A2AC)
    static let tertiary = adaptive(0xAAAAB3, 0x777781)
    static let accent = adaptive(0x6269D9, 0x9C9FF2)

    static func color(for status: HealthStatus) -> Color {
        switch status {
        case .healthy: return Color(red: 0.24, green: 0.61, blue: 0.45)
        case .degraded, .error: return Color(red: 0.81, green: 0.51, blue: 0.22)
        case .unreachable, .disconnected: return Color(red: 0.83, green: 0.35, blue: 0.34)
        case .checking: return accent
        case .unknown, .stale: return secondary
        }
    }

    private static func timeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }

    private static let todayTimeFormatter = timeFormatter("HH:mm:ss")
    private static let historicalTimeFormatter = timeFormatter("MM-dd HH:mm")

    static func time(_ date: Date) -> String {
        let formatter = Calendar.autoupdatingCurrent.isDateInToday(date) ? todayTimeFormatter : historicalTimeFormatter
        return formatter.string(from: date)
    }
}

struct SurfaceGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AssistantTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(AssistantTheme.line, lineWidth: 1))
    }
}
