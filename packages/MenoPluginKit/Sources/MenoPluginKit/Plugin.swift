import Foundation
import SwiftUI

public struct PluginDescriptor: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let symbol: String
    public let version: String

    public init(id: String, name: String, summary: String, symbol: String, version: String) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbol = symbol
        self.version = version
    }
}

public struct PluginContext: Sendable {
    public let dataDirectory: URL

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }
}

@MainActor
public protocol PluginRuntime: AnyObject {
    func start() async throws
    func stop() async
}

/// A module can be loaded for editing while disabled; only enable creates a runtime.
@MainActor
public protocol MenoPlugin: AnyObject {
    func makeRuntime() throws -> any PluginRuntime
    func makeView() -> AnyView
}

public struct PluginDefinition {
    public let descriptor: PluginDescriptor
    public let makePlugin: @MainActor (PluginContext) throws -> any MenoPlugin

    public init(
        descriptor: PluginDescriptor,
        makePlugin: @escaping @MainActor (PluginContext) throws -> any MenoPlugin
    ) {
        self.descriptor = descriptor
        self.makePlugin = makePlugin
    }
}
