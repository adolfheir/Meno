import AppKit
import RemindersCore
import SwiftUI

@MainActor
final class ReminderPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
@MainActor
protocol ReminderPresenting: AnyObject {
    var onAction: ((String, Bool) -> Void)? { get set }
    var count: Int { get }
    var contentScreenID: UInt32? { get }
    func show(_ queue: [Occurrence])
    func close()
    @discardableResult func focus(screenID: UInt32?) -> Bool
}

@MainActor
final class FullscreenPresenter: ReminderPresenting {
    private var panels: [ReminderPanel] = []
    private var signature = ""
    var onAction: ((String, Bool) -> Void)?
    var count: Int { panels.count }
    var contentScreenID: UInt32?
    func show(_ queue: [Occurrence]) {
        guard let first = queue.first else { close(); return }
        let screens = NSScreen.screens
        let primary = screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? screens.first
        let key = queue.map(\.id).joined(separator: ",") + screens.map { NSStringFromRect($0.frame) }.joined() + String(describing: primary?.frame)
        guard key != signature else { return }; close(); signature = key
        contentScreenID = (primary?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        for screen in screens {
            let panel = ReminderPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.hidesOnDeactivate = false; panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true
            panel.isReleasedWhenClosed = false; panel.isMovable = false
            panel.title = screen == primary ? "Meno 全屏提醒" : "Meno 提醒蒙层"
            panel.onEscape = { [weak self] in self?.onAction?(first.id, true) }
            panel.contentView = NSHostingView(rootView: OverlayContent(item: first, remaining: queue.count - 1, showsContent: screen == primary) { [weak self] snooze in self?.onAction?(first.id, snooze) })
            panel.setFrame(screen.frame, display: true); panel.orderFrontRegardless(); panels.append(panel)
        }
    }
    func close() { for panel in panels { panel.orderOut(nil); panel.close() }; panels = []; signature = ""; contentScreenID = nil }
    /// Explicit navigation may take focus; merely showing a due item never does.
    @discardableResult func focus(screenID: UInt32? = nil) -> Bool {
        let panel = screenID.flatMap { id in panels.first { ($0.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id } }
            ?? panels.first { $0.title == "Meno 全屏提醒" }
        panel?.makeKeyAndOrderFront(nil)
        return panel != nil
    }
}
private struct OverlayContent: View {
    let item: Occurrence
    let remaining: Int
    let showsContent: Bool
    let action: (Bool) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if reduceTransparency { MenoPalette.overlayBase }
            else { Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.43)) }
            if showsContent {
                VStack(spacing: 24) {
                    Image(systemName: "leaf").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(.white.opacity(0.7))
                    Text(item.title).font(.system(size: 54, weight: .light, design: .rounded)).multilineTextAlignment(.center)
                        .lineLimit(5).minimumScaleFactor(0.5).frame(maxWidth: 900).accessibilityIdentifier("overlay.title")
                    if !item.note.isEmpty { Text(item.note).font(.title3).foregroundStyle(.white.opacity(0.8)).lineLimit(6).frame(maxWidth: 700) }
                    Text("原定时间 \(item.scheduledAt.formatted(date: .abbreviated, time: .shortened))").font(.callout).foregroundStyle(.white.opacity(0.65))
                    HStack(spacing: 16) {
                        Button { action(false) } label: { Text("知道了").frame(width: 120).padding(.vertical, 8) }
                            .buttonStyle(.borderedProminent).tint(MenoPalette.overlayAction).accessibilityIdentifier("overlay.acknowledge")
                        Button { action(true) } label: { Text("5 分钟后提醒").frame(width: 140).padding(.vertical, 8) }
                            .buttonStyle(.bordered).accessibilityIdentifier("overlay.snooze")
                    }.controlSize(.large).padding(.top, 14)
                    if remaining > 0 { Text("还有 \(remaining) 条提醒").font(.callout).foregroundStyle(.white.opacity(0.65)) }
                    Text("点击后可用 Esc 延后 5 分钟").font(.caption).foregroundStyle(.white.opacity(0.45))
                }.padding(60).foregroundStyle(.white)
            }
        }.ignoresSafeArea().preferredColorScheme(.dark)
    }
}
