import SwiftUI
import UIKit

/// 与网页 Claude 主题共用色值，跟随系统外观。
enum Notebook {
    // 表面
    static let paper = adaptive(0xF6F4EF, 0x1A1917)
    static let side = adaptive(0xEFEDE6, 0x211F1C)
    static let surface = adaptive(0xFFFFFF, 0x262522)
    static let sunk = adaptive(0xECE9E0, 0x2E2C28)
    static let paperCard = surface
    // 文字
    static let ink = adaptive(0x1F1E1B, 0xF2EFE8)
    static let secondary = adaptive(0x3D3B36, 0xD8D4CA)
    static let tertiary = adaptive(0x6B675F, 0xA8A398)
    // 线
    static let line = adaptive(0xE6E2D9, 0x3A3833)
    static let lineStrong = adaptive(0xDAD6C9, 0x4A4741)
    static let field = adaptive(0x8F8D84, 0xA8A398)
    // 强调
    static let accent = adaptive(0xD97757, 0xE08A6C)
    static let accentPress = adaptive(0xB85C38, 0xC9683F)
    static let soft = adaptive(0xF7E6DE, 0x3A2A24)
    static let softInk = adaptive(0x8A3F24, 0xF0B29C)
    static let onAccent = adaptive(0xFFFFFF, 0x1A1917)
    // 荧光笔
    static let marker = Color.clear
    static let markerEdge = Color.clear
    static let markerInk = ink
    // 状态
    static let amber = adaptive(0x8A5A12, 0xE8C27A)
    static let danger = adaptive(0xC8453B, 0xE5645A)
    static let dangerSoft = adaptive(0xFCE6E0, 0x3A2422)
    static let disabledBg = adaptive(0xECE9DF, 0x2E2C28)
    static let disabledFg = adaptive(0xA8A69E, 0x6F6B63)
    static let scrim = Color.black.opacity(0.36)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }

    // 动效
    static func message(_ reduced: Bool) -> Animation { reduced ? .linear(duration: 0.16) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.32) }
    static func unfold(_ reduced: Bool) -> Animation { reduced ? .linear(duration: 0.16) : .timingCurve(0.37, 0, 0.63, 1, duration: 0.24) }
    static func scroll(_ reduced: Bool) -> Animation { reduced ? .linear(duration: 0.16) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.30) }
}

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255, opacity: 1) }
}

/// 中性圆角消息，没有尾角。
func bubbleShape(userSide: Bool) -> UnevenRoundedRectangle {
    UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 16)
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
            .foregroundStyle(!enabled ? Notebook.disabledFg : primary ? Notebook.onAccent : Notebook.ink)
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
                    if !message.text.isEmpty { Text(message.text).font(.system(size: 16)).lineSpacing(6).tracking(0.3).foregroundStyle(Notebook.ink).textSelection(.enabled) }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Notebook.sunk, in: bubbleShape(userSide: true))
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
                    ForEach(0..<3, id: \.self) { i in Circle().fill(Notebook.tertiary).frame(width: 6, height: 6).opacity(reduced ? 0.7 : level(t, i)) }
                }.frame(height: 24)
            }
            Spacer()
        }
        .opacity(visible ? 1 : 0).offset(y: visible || reduced ? 0 : 4)
        .task { try? await Task.sleep(for: .milliseconds(300)); withAnimation(reduced ? .linear(duration: 0.2) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.26)) { visible = true } }
        .accessibilityElement(children: .ignore).accessibilityLabel("正在回复")
    }
}
