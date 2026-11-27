import AppKit

/// Visual state of the toolbar's activity button.
public enum OperationsIndicatorState: Sendable, Equatable {
    /// No active operations and no unacknowledged failures.
    case idle
    /// At least one operation is active; `progress` is `0...1` when known, or `nil` when
    /// indeterminate.
    case running(progress: Double?)
    /// No active operations, and at least one recent operation failed.
    case failed
}

/// Renders the toolbar button's icon and tooltip for each `OperationsIndicatorState`.
@MainActor
enum OperationsToolbarIcon {
    static func image(for state: OperationsIndicatorState) -> NSImage? {
        switch state {
        case .idle:
            return NSImage(
                systemSymbolName: "arrow.up.arrow.down.circle",
                accessibilityDescription: "Activity")
        case .failed:
            let config = NSImage.SymbolConfiguration(hierarchicalColor: .systemRed)
            return NSImage(
                systemSymbolName: "exclamationmark.circle.fill",
                accessibilityDescription: "Activity — Errors"
            )?.withSymbolConfiguration(config)
        case .running(let progress):
            return progressRing(progress: progress)
        }
    }

    static func toolTip(for state: OperationsIndicatorState) -> String {
        switch state {
        case .idle: "Show Activity"
        case .running: "Show Activity (Running)"
        case .failed: "Show Activity (Errors)"
        }
    }

    private static func progressRing(progress: Double?) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset: CGFloat = 2
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2 - inset
            let lineWidth: CGFloat = 2

            let track = NSBezierPath()
            track.appendArc(
                withCenter: center, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
            track.lineWidth = lineWidth
            NSColor.labelColor.withAlphaComponent(0.22).setStroke()
            track.stroke()

            let fraction: Double
            if let progress {
                fraction = min(max(progress, 0.06), 1)
            } else {
                fraction = 0.72
            }
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center, radius: radius,
                startAngle: 90, endAngle: 90 - CGFloat(fraction * 360),
                clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            NSColor.controlAccentColor.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Activity — Running"
        return image
    }
}
