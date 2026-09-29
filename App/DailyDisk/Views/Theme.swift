import AppKit
import DailyDiskCore
import Foundation
import SwiftUI

/// Graphite palette: neutral surfaces with a single indigo accent.
enum Theme {
    static let accent = dynamic(light: (0.231, 0.333, 0.816), dark: (0.482, 0.549, 1.0))
    static let unattributed = dynamic(light: (0.659, 0.706, 0.933), dark: (0.333, 0.388, 0.667))
    static let overhead = dynamic(light: (0.788, 0.800, 0.839), dark: (0.365, 0.376, 0.408))
    static let release = dynamic(light: (0.620, 0.647, 0.706), dark: (0.478, 0.502, 0.553))
    static let track = Color.primary.opacity(0.07)
    static let card = Color.primary.opacity(0.035)
    static let hairline = Color.primary.opacity(0.08)
    static let content = Color(nsColor: .textBackgroundColor)
    static let positive = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)

    private static func dynamic(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
            })
    }
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View { modifier(CardBackground(padding: padding)) }
}

/// Section title with an optional trailing accessory, separated from rows by a hairline.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer(minLength: 12)
                trailing.font(.caption).foregroundStyle(.secondary)
            }
            Divider()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

extension SectionHeader {
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }
}

/// "今天 09:01" / "昨天 09:00" / "2026年9月20日 09:00".
func relativeDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.doesRelativeDateFormatting = true
    return formatter.string(from: date)
}

extension DailyReport {
    var isBaseline: Bool { accounting.physicalUsedDelta == nil }

    /// Only the opening baseline is tagged; ordinary runs stay untagged.
    var tagLabel: String? { isBaseline ? "基线" : nil }
}
