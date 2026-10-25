import Foundation

/// One thing an agent can do, described the way MCP lists it.
public struct MCPTool: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema of the arguments.
    public let inputSchema: JSONValue
    /// Changes the library (refused in read-only mode). Playback doesn't count.
    public let changesLibrary: Bool
    public let run: @MainActor @Sendable (JSONValue) async throws -> JSONValue

    public init(_ name: String, _ description: String, input: JSONValue = ["type": "object", "properties": [:]],
                changesLibrary: Bool = false, run: @escaping @MainActor @Sendable (JSONValue) async throws -> JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = input
        self.changesLibrary = changesLibrary
        self.run = run
    }
}

/// A tool refusing a call, with a message the agent can act on.
public struct MCPToolError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// The Model Context Protocol (JSON-RPC 2.0) side of MacShow's agent control:
/// initialize, list tools, call them. Transport-agnostic: `handle` takes one
/// request body and returns the response body (nil for notifications).
@MainActor
public final class MCPServer {
    public static let protocolVersion = "2025-06-18"
    public let name: String
    public let version: String
    public let instructions: String
    public var tools: [MCPTool]
    /// Agents can look and play, not change the library.
    public var readOnly = false

    public init(name: String, version: String, instructions: String, tools: [MCPTool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    public func handle(_ body: Data) async -> Data? {
        guard let request = try? JSONDecoder().decode(JSONValue.self, from: body), let method = request["method"]?.string else {
            return Self.encode(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Not a JSON-RPC request"]])
        }
        let id = request["id"]
        // Notifications (no id) get no answer.
        guard let id else { return nil }
        let result: JSONValue
        switch method {
        case "initialize":
            result = [
                "protocolVersion": request["params"]?["protocolVersion"] ?? .string(Self.protocolVersion),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "version": .string(version)],
                "instructions": .string(instructions),
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": .array(tools.map { tool in
                ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema]
            })]
        case "tools/call":
            result = await call(request["params"]?["name"]?.string, arguments: request["params"]?["arguments"] ?? [:])
        default:
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("Unknown method \(method)")]])
        }
        return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func call(_ name: String?, arguments: JSONValue) async -> JSONValue {
        func answer(_ text: String, error: Bool) -> JSONValue {
            ["content": [["type": "text", "text": .string(text)]], "isError": .bool(error)]
        }
        guard let tool = tools.first(where: { $0.name == name }) else { return answer("No tool named \(name ?? "")", error: true) }
        if tool.changesLibrary, readOnly {
            return answer("MacShow is set to read-only for agents (Settings › Agents), so \(tool.name) isn't allowed.", error: true)
        }
        do {
            let value = try await tool.run(arguments)
            // Compact: agents pay for every character.
            return answer(String(decoding: Self.encode(value) ?? Data(), as: UTF8.self), error: false)
        } catch let error as MCPToolError {
            return answer(error.message, error: true)
        } catch {
            return answer(error.localizedDescription, error: true)
        }
    }

    static func encode(_ value: JSONValue, pretty: Bool = false) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(value)
    }
}
