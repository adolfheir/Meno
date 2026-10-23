import AppKit
import SwiftUI

/// Keep related glass controls in one sampling pass without merging them at rest.
public struct MenoGlassGroup<Content: View>: View {
    private let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: 4) { content }
        } else { content }
    }
}

private struct MenoGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content.background(MenoPalette.card, in: shape)
                .overlay(shape.strokeBorder(MenoPalette.border, lineWidth: 1).allowsHitTesting(false))
        }
    }
}

private struct MenoWindowSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency { MenoPalette.background.ignoresSafeArea() }
            else {
                GeometryReader { geometry in
                    ZStack {
                        LinearGradient(colors: [MenoPalette.canvasTop, MenoPalette.canvasBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                        RadialGradient(colors: [MenoPalette.canvasGlow.opacity(0.50), .clear], center: .topTrailing,
                                       startRadius: 0, endRadius: max(geometry.size.width, geometry.size.height) * 0.8)
                        RadialGradient(colors: [MenoPalette.canvasLight.opacity(0.45), .clear], center: .bottomLeading,
                                       startRadius: 0, endRadius: max(geometry.size.width, geometry.size.height) * 0.9)
                    }
                }.ignoresSafeArea().allowsHitTesting(false)
            }
        }
    }
}

public extension View {
    func menoGlassPill(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(MenoGlassSurface(shape: Capsule(), tint: tint, interactive: interactive))
    }

    func menoWindowSurface() -> some View { modifier(MenoWindowSurface()) }
}

public struct MenoPrimaryButtonStyle: PrimitiveButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    public init() {}

    @ViewBuilder public func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            Button(configuration).buttonStyle(.glass)
                .buttonBorderShape(.capsule).controlSize(.large)
                .tint(.clear).foregroundStyle(MenoPalette.ink)
        } else {
            Button(configuration).buttonStyle(.borderedProminent)
                .controlSize(.large).tint(MenoPalette.primary)
        }
    }
}

struct MenoTimeButtonStyle: PrimitiveButtonStyle {
    let selected: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            Button(configuration).buttonStyle(.glass)
                .buttonBorderShape(.capsule).controlSize(.large)
                .tint(selected ? MenoPalette.controlTint.opacity(0.22) : .clear)
                .foregroundStyle(MenoPalette.ink)
                .fontWeight(selected ? .semibold : .regular)
                .animation(MenoMotion.feedback(reduceMotion: reduceMotion), value: selected)
        } else {
            Button(configuration).buttonStyle(.bordered)
                .controlSize(.large).tint(selected ? MenoPalette.accent : MenoPalette.secondary)
        }
    }
}

struct ReminderTabs: View {
    @Binding var selection: Int
    @Namespace private var glassSelection
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let titles = ["待提醒", "已暂停", "历史"]

    @ViewBuilder var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 3) {
                    ForEach(titles.indices, id: \.self) { index in
                        Button {
                            withAnimation(MenoMotion.layout(reduceMotion: reduceMotion)) { selection = index }
                        } label: {
                            Text(titles[index]).font(.system(size: 13, weight: selection == index ? .medium : .regular))
                                .frame(width: 74).padding(.vertical, 9)
                                .background {
                                    if selection == index {
                                        Capsule().fill(.clear)
                                            .glassEffect(.regular, in: Capsule())
                                            .glassEffectID("reminder-tab", in: glassSelection)
                                    }
                                }
                        }.buttonStyle(.plain)
                            .accessibilityValue(selection == index ? "已选择" : "未选择")
                            .accessibilityAddTraits(selection == index ? .isSelected : [])
                    }
                }.padding(4).menoGlassPill()
            }
        } else {
            Picker("事项状态", selection: $selection) {
                ForEach(titles.indices, id: \.self) { Text(titles[$0]).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
        }
    }
}

private struct MenoCardSurface: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content.background(MenoPalette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(MenoPalette.border, lineWidth: 1).allowsHitTesting(false))
        }
    }
}

public extension View {
    func menoCard(cornerRadius: CGFloat = 22) -> some View {
        modifier(MenoCardSurface(radius: cornerRadius))
    }
}
