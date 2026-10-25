import Foundation
import Network

/// Serves MacShow's MCP endpoint (`POST /mcp`, JSON in and out) on
/// 127.0.0.1 only, for agents on this Mac. Every request needs the token
/// (`Authorization: Bearer …`), and requests a web page makes (an `Origin`
/// other than localhost) are turned away.
public final class AgentHTTPServer: @unchecked Sendable {
    public let port: UInt16
    private let token: String
    private let handle: @Sendable (Data) async -> Data?
    private let queue = DispatchQueue(label: "MacShow.AgentHTTPServer")
    private var listener: NWListener?

    public init(port: UInt16, token: String, handle: @escaping @Sendable (Data) async -> Data?) {
        self.port = port
        self.token = token
        self.handle = handle
    }

    /// Returns once it's listening; throws if the port is taken.
    public func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    listener.stateUpdateHandler = nil
                    listener.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return connection.cancel() }
            let buffer = buffer + (data ?? Data())
            guard let request = HTTPRequest(buffer) else {
                if isComplete || buffer.count > 4 << 20 { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                return
            }
            Task {
                let response = await self.respond(to: request)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func respond(to request: HTTPRequest) async -> Data {
        if let origin = request.headers["origin"], let host = URL(string: origin)?.host, !["localhost", "127.0.0.1"].contains(host) {
            return Self.response("403 Forbidden")
        }
        guard request.path.split(separator: "?").first == "/mcp" else { return Self.response("404 Not Found") }
        guard request.headers["authorization"] == "Bearer \(token)" else { return Self.response("401 Unauthorized") }
        guard request.method == "POST" else { return Self.response("405 Method Not Allowed", extra: "Allow: POST\r\n") }
        guard let body = await handle(request.body) else { return Self.response("202 Accepted") }
        return Self.response("200 OK", contentType: "application/json", body: body)
    }

    static func response(_ status: String, contentType: String? = nil, extra: String = "", body: Data = Data()) -> Data {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n" + extra
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

/// A complete HTTP/1.1 request: nil until the headers and the whole body (by
/// Content-Length) have arrived.
struct HTTPRequest {
    let method: String
    let path: String
    /// Lowercased names.
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        self.method = String(start[0])
        self.path = String(start[1])
        self.headers = headers
        self.body = Data(body.prefix(length))
    }
}
