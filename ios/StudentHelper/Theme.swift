import SwiftUI

/// 一步 · 视觉令牌（对应 web/workspace.css :root）。仅浅色。
enum Notebook {
    // 表面
    static let paper = Color(hex: 0xFFFCF6)
    static let side = Color(hex: 0xF6F0E2)
    static let surface = Color.white
    static let sunk = Color(hex: 0xF3ECDC)
    static let paperCard = Color(hex: 0xFBF5E6)
    // 文字
    static let ink = Color(hex: 0x221D14)
    static let secondary = Color(hex: 0x4A4132)     // ink-2
    static let tertiary = Color(hex: 0x6F6450)      // ink-3
    // 线
    static let line = Color(hex: 0xE9DFC9)
    static let lineStrong = Color(hex: 0xD5C7A6)
    static let field = Color(hex: 0x9A8D72)
    // 强调
    static let accent = Color(hex: 0x1D6B55)
    static let accentPress = Color(hex: 0x134A39)
    static let soft = Color(hex: 0xDDEFE6)
    static let softInk = Color(hex: 0x134A39)
    // 荧光笔
    static let marker = Color(hex: 0xFFEFB0)
    static let markerEdge = Color(hex: 0xF2DA7E)
    static let markerInk = Color(hex: 0x2B2200)
    // 状态
    static let amber = Color(hex: 0x8F5200)         // 保留旧名：草稿/警示
    static let danger = Color(hex: 0xB3321F)
    static let dangerSoft = Color(hex: 0xFCE6E0)
    static let disabledBg = Color(hex: 0xEFE7D3)
    static let disabledFg = Color(hex: 0xA79A82)
    static let scrim = Color(red: 34/255, green: 29/255, blue: 20/255).opacity(0.42)

    // 动效
    static func message(_ reduced: Bool) -> Animation { reduced ? .linear(duration: 0.16) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.32) }
    static func unfold(_ reduced: Bool) -> Animation { reduced ? .linear(duration: 0.16) : .timingCurve(0.37, 0, 0.63, 1, duration: 0.24) }
    static func scroll(_ reduced: Bool) -> Animation { reduced ? .linear(duration: 0.16) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.30) }
}

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255, opacity: 1) }
}

/// 用户气泡 / 老师气泡的统一形状：三个 18pt 圆角 + 一个 6pt 尖角。
func bubbleShape(userSide: Bool) -> UnevenRoundedRectangle {
    userSide
    ? UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18)
    : UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 18)
}

struct ReadingStyle: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 16
    func body(content: Content) -> some View { content.font(.system(size: size)).lineSpacing(10).tracking(0.3).foregroundStyle(Notebook.ink) }
}
struct HeadingStyle: ViewModifier {
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 22
    func body(content: Content) -> some View { content.font(.system(size: size, weight: .semibold)).lineSpacing(4).foregroundStyle(Notebook.ink) }
}
extension View {
    func reading() -> some View { modifier(ReadingStyle()) }
    func heading() -> some View { modifier(HeadingStyle()) }
    func notebookCard() -> some View {
        padding(16).background(Notebook.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Notebook.line, lineWidth: 1))
    }
}

struct NotebookButton: ButtonStyle {
    var primary = true
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label.font(.subheadline.weight(.medium)).frame(minHeight: 44).padding(.horizontal, 16)
            .foregroundStyle(!enabled ? Notebook.disabledFg : primary ? .white : Notebook.ink)
            .background(!enabled ? (primary ? Notebook.disabledBg : .clear) : primary ? (pressed ? Notebook.accentPress : Notebook.accent) : (pressed ? Notebook.sunk : Notebook.surface), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(primary ? .clear : (enabled ? Notebook.lineStrong : Notebook.line), lineWidth: 1))
            .animation(.linear(duration: reduced ? 0.01 : 0.12), value: pressed)
    }
}

struct EmptyNotebook: View {
    var symbol: String
    var title: String
    var subtitle: String = ""
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 44, weight: .light)).foregroundStyle(Notebook.tertiary)
            Text(title).heading()
            if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(Notebook.secondary).multilineTextAlignment(.center) }
        }.frame(maxWidth: .infinity).padding(32)
    }
}

struct MessageRow: View {
    let message: LearningMessage
    var onGrow: () -> Void = {}
    @EnvironmentObject private var store: LearningStore
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if message.role == "divider" {
            HStack(spacing: 16) { Rectangle().fill(Notebook.line).frame(height: 1); Text(message.text).font(.footnote).foregroundStyle(Notebook.tertiary); Rectangle().fill(Notebook.line).frame(height: 1) }.padding(.vertical, 4)
        } else if message.role == "paper" {
            VStack(alignment: .leading, spacing: 8) {
                Text("题目").font(.caption).tracking(1).foregroundStyle(Notebook.tertiary)
                MathMessageBody(text: message.text, cards: false)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Notebook.paperCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Notebook.line, lineWidth: 1))
        } else if message.role == "user" {
            HStack(spacing: 0) {
                Spacer(minLength: 32)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(message.images ?? []) { image in
                        ImagePreviewButton(image: image).frame(maxWidth: .infinity).frame(height: min(240, 260 * CGFloat(image.height) / CGFloat(max(image.width, 1))))
                    }
                    if !message.text.isEmpty { Text(message.text).font(.system(size: 16)).lineSpacing(10).tracking(0.3).foregroundStyle(.white).textSelection(.enabled) }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Notebook.accent, in: bubbleShape(userSide: true))
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 328, alignment: .trailing)
            }
        } else {
            HStack(spacing: 0) {
                MathMessageBody(text: message.text, structured: true, paced: store.pacedReplyID == message.id, onGrow: onGrow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 24) }
            }
        }
    }
}

/// 网络等待：老师侧小气泡 + 三点依次明暗；发送后 300ms 才淡入，避免快速回复时一闪。
struct ThinkingRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var visible = false
    private func level(_ t: Double, _ i: Int) -> Double {
        let period = 1.5, p = ((t - Double(i) * 0.2).truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) / period
        func ease(_ x: Double) -> Double { 0.5 - 0.5 * cos(Double.pi * x) }
        if p < 0.3 { return 0.4 + 0.6 * ease(p / 0.3) }
        if p < 0.6 { return 1.0 - 0.6 * ease((p - 0.3) / 0.3) }
        return 0.4
    }
    var body: some View {
        HStack {
            TimelineView(.animation(paused: reduced)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in Circle().fill(Notebook.accent).frame(width: 6, height: 6).opacity(reduced ? 0.7 : level(t, i)) }
                }.padding(.horizontal, 14).frame(height: 32)
                    .background(Notebook.surface, in: bubbleShape(userSide: false))
                    .overlay(bubbleShape(userSide: false).stroke(Notebook.line, lineWidth: 1))
            }
            Spacer()
        }
        .opacity(visible ? 1 : 0).offset(y: visible || reduced ? 0 : 4)
        .task { try? await Task.sleep(for: .milliseconds(300)); withAnimation(reduced ? .linear(duration: 0.2) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.26)) { visible = true } }
        .accessibilityElement(children: .ignore).accessibilityLabel("正在回复")
    }
}
