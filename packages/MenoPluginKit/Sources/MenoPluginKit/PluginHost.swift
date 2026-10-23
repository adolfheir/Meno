import Foundation
import SwiftUI

@MainActor
public final class PluginHost: ObservableObject {
    public let definitions: [PluginDefinition]
    @Published public private(set) var enabledIDs: Set<String>
    @Published public private(set) var instances: [String: any PluginRuntime] = [:]
    @Published public private(set) var modules: [String: any MenoPlugin] = [:]
    @Published public private(set) var busyIDs: Set<String> = []
    @Published public private(set) var failures: [String: String] = [:]

    private let dataDirectory: URL
    private let persist: (Set<String>) throws -> Void
    private var isShuttingDown = false

    public init(
        definitions: [PluginDefinition],
        enabledIDs: Set<String>,
        dataDirectory: URL,
        persist: @escaping (Set<String>) throws -> Void
    ) {
        precondition(Set(definitions.map(\.descriptor.id)).count == definitions.count, "插件 ID 必须唯一")
        self.definitions = definitions
        self.enabledIDs = enabledIDs.intersection(Set(definitions.map(\.descriptor.id)))
        self.dataDirectory = dataDirectory
        self.persist = persist
    }

    public func restore() async {
        for definition in definitions where enabledIDs.contains(definition.descriptor.id) {
            await setEnabled(true, for: definition.descriptor.id)
        }
    }

    public func isRunning(_ id: String) -> Bool { instances[id] != nil }

    public func module(for id: String) throws -> any MenoPlugin {
        if let module = modules[id] { return module }
        guard let definition = definitions.first(where: { $0.descriptor.id == id }) else {
            throw NSError(domain: "Meno", code: 2, userInfo: [NSLocalizedDescriptionKey: "未安装此子应用。"])
        }
        let module = try definition.makePlugin(PluginContext(dataDirectory: dataDirectory.appendingPathComponent(id, isDirectory: true)))
        modules[id] = module
        return module
    }

    public func setEnabled(_ enabled: Bool, for id: String) async {
        guard !isShuttingDown, !busyIDs.contains(id),
              definitions.contains(where: { $0.descriptor.id == id }) else { return }
        if enabled, instances[id] != nil { return }
        busyIDs.insert(id)
        failures[id] = nil
        defer { busyIDs.remove(id) }

        if enabled {
            var plugin: (any PluginRuntime)?
            do {
                plugin = try module(for: id).makeRuntime()
                try await plugin!.start()
                guard !isShuttingDown else {
                    await plugin!.stop()
                    return
                }
                var candidate = enabledIDs
                candidate.insert(id)
                try persist(candidate)
                enabledIDs = candidate
                instances[id] = plugin
            } catch {
                await plugin?.stop()
                failures[id] = error.localizedDescription
            }
        } else {
            do {
                var candidate = enabledIDs
                candidate.remove(id)
                try persist(candidate)
                await instances[id]?.stop()
                instances[id] = nil
                enabledIDs = candidate
            } catch {
                failures[id] = error.localizedDescription
            }
        }
    }

    /// Quitting preserves the user's enabled selection for the next launch.
    public func shutdown() async {
        isShuttingDown = true
        while !busyIDs.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        for plugin in instances.values { await plugin.stop() }
        instances = [:]
    }
}
