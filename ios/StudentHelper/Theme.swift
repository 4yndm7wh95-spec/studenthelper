import SwiftUI

enum Notebook {
    static let paper = Color(hex: 0xF7F5F0)
    static let side = Color(hex: 0xEFECE4)
    static let ink = Color(hex: 0x1D2129)
    static let secondary = Color(hex: 0x565D69)
    static let accent = Color(hex: 0x2A57C4)
    static let soft = Color(hex: 0xE7EDFA)
    static let line = Color(hex: 0xE2DED4)
    static let amber = Color(hex: 0xA86A12)
    static func message(_ reduced: Bool) -> Animation { reduced ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.86) }
    static func unfold(_ reduced: Bool) -> Animation { reduced ? .easeInOut(duration: 0.15) : .timingCurve(0.2, 0, 0, 1, duration: 0.24) }
    static func scroll(_ reduced: Bool) -> Animation { reduced ? .easeInOut(duration: 0.15) : .timingCurve(0.2, 0, 0, 1, duration: 0.30) }
}

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255, opacity: 1) }
}

struct ReadingStyle: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 16
    func body(content: Content) -> some View { content.font(.system(size: size)).lineSpacing(7).foregroundStyle(Notebook.ink) }
}
struct HeadingStyle: ViewModifier {
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 22
    func body(content: Content) -> some View { content.font(.system(size: size, weight: .semibold)).lineSpacing(2).foregroundStyle(Notebook.ink) }
}
extension View {
    func reading() -> some View { modifier(ReadingStyle()) }
    func heading() -> some View { modifier(HeadingStyle()) }
    func notebookCard() -> some View { padding(16).background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Notebook.line, lineWidth: 1)) }
}

struct NotebookButton: ButtonStyle {
    var primary = true
    @Environment(\.accessibilityReduceMotion) private var reduced
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium)).frame(minHeight: 44).padding(.horizontal, 16)
            .foregroundStyle(primary ? .white : Notebook.accent)
            .background(primary ? Notebook.accent : Notebook.soft, in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduced ? 0.97 : 1)
            .animation(reduced ? .linear(duration: 0.15) : .easeOut(duration: configuration.isPressed ? 0.08 : 0.12), value: configuration.isPressed)
    }
}

struct EmptyNotebook: View {
    var symbol: String
    var title: String
    var subtitle: String = ""
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 44, weight: .light)).foregroundStyle(Notebook.secondary)
            Text(title).heading()
            if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(Notebook.secondary).multilineTextAlignment(.center) }
        }.frame(maxWidth: .infinity).padding(32)
    }
}

struct MessageRow: View {
    let message: LearningMessage
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if message.role == "divider" {
            HStack { Rectangle().fill(Notebook.line).frame(height: 1); Text(message.text).font(.footnote).foregroundStyle(Notebook.accent); Rectangle().fill(Notebook.line).frame(height: 1) }.padding(.vertical, 20)
        } else if message.role == "paper" {
            VStack(alignment: .leading, spacing: 8) {
                Text("题目").font(.caption).foregroundStyle(Notebook.secondary)
                Text(message.text).reading().textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Notebook.side, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Notebook.line, lineWidth: 1))
        } else {
            HStack(alignment: .top, spacing: 0) {
                if message.role == "user" { Spacer(minLength: 32) }
                Text(message.text).reading().textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : message.role == "user" ? 300 : 318, alignment: .leading)
                    .background(message.role == "user" ? Notebook.soft : Notebook.side, in: RoundedRectangle(cornerRadius: 14))
                if message.role != "user" { Spacer(minLength: 0) }
            }
        }
    }
}

struct ThinkingRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var glow = false
    var body: some View {
        HStack(spacing: 5) {
            if reduced { Text("正在回复…").font(.footnote).foregroundStyle(Notebook.secondary) }
            else { ForEach(0..<3) { index in Circle().fill(Notebook.secondary).frame(width: 5, height: 5).opacity(glow ? 1 : 0.3).animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(index)*0.15), value: glow) } }
        }.frame(height: 28).onAppear { glow = true }.accessibilityLabel("正在回复")
    }
}
