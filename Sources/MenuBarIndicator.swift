import AppKit

enum MenuBarIndicator {
    static func symbol(for status: HealthStatus) -> String {
        switch status {
        case .healthy: return "checkmark.shield.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .unreachable: return "xmark.octagon.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .disconnected: return "wifi.slash"
        case .error: return "exclamationmark.circle.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .unknown: return "questionmark.circle"
        }
    }

    static func color(for status: HealthStatus) -> NSColor {
        switch status {
        case .healthy: return NSColor(srgbRed: 0.12, green: 0.68, blue: 0.30, alpha: 1)
        case .degraded, .error: return NSColor(srgbRed: 0.86, green: 0.65, blue: 0.04, alpha: 1)
        case .unreachable: return NSColor(srgbRed: 0.92, green: 0.22, blue: 0.24, alpha: 1)
        case .checking, .disconnected, .stale, .unknown: return .secondaryLabelColor
        }
    }

    static func image(for status: HealthStatus) -> NSImage? {
        guard let source = NSImage(systemSymbolName: symbol(for: status),
                                   accessibilityDescription: status.title) else { return nil }
        let tint = color(for: status)
        let image = NSImage(size: NSSize(width: 17, height: 17), flipped: false) { bounds in
            source.draw(in: bounds)
            tint.setFill()
            bounds.fill(using: .sourceIn)
            return true
        }
        // Menu bar template rendering would discard the semantic colors.
        image.isTemplate = false
        image.accessibilityDescription = "稳连，" + status.title
        return image
    }
}
