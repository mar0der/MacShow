import AppKit
import MacShowCore
import Observation

/// MacShow's MCP server for AI agents: off until turned on in Settings › Agents,
/// on 127.0.0.1 only, behind a token. Agents see what the library shows and
/// nothing in Adult folders, even while that's unlocked in the app.
@MainActor
@Observable
final class AgentControl {
    static let shared = AgentControl()
    /// The port agents connect to: 47321 unless that was taken, then one picked and remembered.
    static var port: UInt16 {
        UInt16(exactly: UserDefaults.standard.integer(forKey: portKey)).flatMap { $0 > 0 ? $0 : nil } ?? 47321
    }
    static let portKey = "agentPort"
    static let enabledKey = "agentControlOn"
    static let tokenKey = "agentToken"
    static let readOnlyKey = "agentReadOnly"

    @ObservationIgnored private var mcp: MCPServer?
    private var server: AgentHTTPServer?
    private(set) var error: String?

    var token: String {
        if let token = UserDefaults.standard.string(forKey: Self.tokenKey), !token.isEmpty { return token }
        return newToken()
    }

    @discardableResult
    func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        if server != nil { apply() }
        return token
    }

    func configure(library: Library, player: Player) {
        mcp = MCPServer(name: "MacShow", version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                        instructions: AgentTools.instructions, tools: AgentTools.make(library: library, player: player))
        apply()
    }

    /// Starts or stops the server to match the settings.
    func apply() {
        server?.stop()
        server = nil
        error = nil
        let defaults = UserDefaults.standard
        mcp?.readOnly = defaults.bool(forKey: Self.readOnlyKey)
        guard defaults.bool(forKey: Self.enabledKey), let mcp else { return }
        let token = token
        starting?.cancel()
        starting = Task {
            // The usual port, else a few others (another program may hold it); the bridge reads which.
            for port in [Self.port] + (0..<5).map({ _ in UInt16.random(in: 40000...60000) }) {
                let server = AgentHTTPServer(port: port, token: token) { body in await mcp.handle(body) }
                do {
                    try await server.start()
                    guard !Task.isCancelled else { return server.stop() }
                    UserDefaults.standard.set(Int(port), forKey: Self.portKey)
                    self.server = server
                    self.error = nil
                    return
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    @ObservationIgnored private var starting: Task<Void, Never>?
    var isRunning: Bool { server != nil }

    /// For Claude Code: `claude mcp add …`, using the bridge inside the app
    /// (it reads the token from MacShow's settings, so none goes in the config).
    static var bridgePath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/macshow-mcp").path }
}
