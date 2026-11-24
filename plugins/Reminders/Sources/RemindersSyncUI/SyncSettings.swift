import RemindersCore
import SwiftUI

public struct SyncSettings: View {
    @ObservedObject private var sync: ReminderSync

    public init(sync: ReminderSync) { self.sync = sync }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let endpoint = sync.configuredAddress {
                Text(endpoint).font(.callout).textSelection(.enabled)
                HStack {
                    if sync.isEnabled {
                        Button("立即同步") { Task { await sync.syncNow() } }
                            .accessibilityIdentifier("sync.now")
                        Spacer()
                        Button("暂停同步") { sync.setEnabled(false) }
                    } else {
                        Button("恢复同步") { sync.setEnabled(true) }
                    }
                }.disabled(sync.busy)
                if let date = sync.lastSyncedAt {
                    LabeledContent("最近同步", value: date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                }
            }
            if sync.busy { ProgressView().controlSize(.small) }
            Text(sync.status)
                .font(.caption)
                .foregroundStyle(sync.hasError ? Color.red : Color.secondary)
                .accessibilityIdentifier("sync.status")
        }
    }
}
