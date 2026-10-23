import AppKit
import SwiftUI

public enum MenoMotion {
    public static func feedback(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }

    public static func layout(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.90)
    }

    public static func arrival(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(y: 6))
    }
}

/// Meno's own horizon motif. Only the foreground, visible empty state animates;
/// no timer or animation is attached to the reminder runtime.
struct MenoSunrise: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var applicationActive = NSApp.isActive

    private var paused: Bool { reduceMotion || !visible || !applicationActive }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: paused)) { timeline in
            let wave = paused ? 0 : sin(timeline.date.timeIntervalSinceReferenceDate * .pi / 2.8)
            Canvas { context, size in
                let scale = size.width / 88
                context.scaleBy(x: scale, y: scale)
                context.fill(Path(ellipseIn: CGRect(x: 4, y: 4, width: 80, height: 80)), with: .color(MenoPalette.softAccent.opacity(0.46)))
                let sun = CGPoint(x: 44, y: 37 + wave * 2)
                var sky = context
                sky.clip(to: Path(CGRect(x: 0, y: 0, width: 88, height: 48)))
                sky.fill(Path(ellipseIn: CGRect(x: sun.x - 18, y: sun.y - 18, width: 36, height: 36)), with: .color(MenoPalette.horizonLight.opacity(0.08 + wave * 0.025)))
                sky.fill(Path(ellipseIn: CGRect(x: sun.x - 10, y: sun.y - 10, width: 20, height: 20)), with: .color(MenoPalette.horizonLight))
                var rays = Path()
                for angle in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    let radians = angle * .pi
                    rays.move(to: CGPoint(x: sun.x + cos(radians) * 16, y: sun.y - sin(radians) * 16))
                    rays.addLine(to: CGPoint(x: sun.x + cos(radians) * 20, y: sun.y - sin(radians) * 20))
                }
                sky.stroke(rays, with: .color(MenoPalette.accent.opacity(0.65)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                var horizon = Path()
                horizon.move(to: CGPoint(x: 21, y: 48)); horizon.addLine(to: CGPoint(x: 67, y: 48))
                horizon.move(to: CGPoint(x: 29, y: 54)); horizon.addLine(to: CGPoint(x: 59, y: 54))
                context.stroke(horizon, with: .color(MenoPalette.primary.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }
        .frame(width: 88, height: 88).accessibilityHidden(true)
        .onAppear { visible = true; applicationActive = NSApp.isActive }
        .onDisappear { visible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in applicationActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in applicationActive = false }
    }
}
