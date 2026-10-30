import AppKit
import MenoControlProtocol
import SwiftUI

@MainActor
public struct AIConnectionButton: View {
    @State private var copied = false
    @State private var copySequence = 0
    @State private var copyFailed = false

    public init() {}

    public var body: some View {
        Button {
            let prompt = AIConnectionInfo(bundleURL: Bundle.main.bundleURL).prompt
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(prompt, forType: .string)
            copyFailed = !copied
            copySequence += 1
        } label: {
            HStack(spacing: 7) {
                MenoFeedbackSymbol(name: copied ? "checkmark" : "doc.on.doc")
                Text(copied ? "已复制" : "复制 AI 连接提示词")
            }.font(.callout).frame(minWidth: 150)
                .padding(.horizontal, 13).padding(.vertical, 11).menoGlassPill(interactive: true)
        }
        .buttonStyle(MenoQuietButtonStyle())
        .help("复制后贴给能使用本机工具或 MCP 的 AI，即可验证连接并管理提醒")
        .accessibilityLabel(copied ? "已复制 AI 连接提示词" : "复制 AI 连接提示词")
        .accessibilityIdentifier("ai.copyConnectionPrompt")
        .task(id: copySequence) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
        .alert("未能复制", isPresented: $copyFailed) {
            Button("好", role: .cancel) {}
        } message: { Text("剪贴板暂时不可用，请再试一次。") }
    }
}
