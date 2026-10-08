import AppKit
import SwiftUI

/// Truncated rows never enter native text-selection mode. Full selection lives in a bounded popover.
struct PathDisclosureView: View {
    let path: String
    var description: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presented = false
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { presented.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if let description {
                    Text(description).font(.callout).foregroundStyle(.primary)
                }
                Text(path)
                    .font(description == nil ? .callout.monospaced() : .caption.monospaced())
                    .foregroundStyle(hovering || presented ? Theme.accent : description == nil ? .primary : .secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.disabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("查看完整路径")
        .accessibilityLabel(path)
        .accessibilityHint("打开完整路径，可选择或复制")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            PathDetailsPopover(path: path) { presented = false }
        }
        .onChange(of: path) { _, _ in presented = false }
        .onDisappear { presented = false }
    }
}

private struct PathDetailsPopover: View {
    let path: String
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var copied = false
    @State private var textHeight: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("完整路径").font(.callout.weight(.semibold))
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.medium)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("关闭完整路径")
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        textHeight = $0
                    }
            }
            .frame(height: min(max(textHeight, 36), 200))
            .padding(10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(path, forType: .string)
                } label: {
                    Label(copied ? "已复制" : "复制路径", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
                .tint(Theme.accent)
            }
        }
        .padding(16)
        .frame(width: 380)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 4)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { appeared = true }
        }
    }
}
