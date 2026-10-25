import Foundation
import Network

/// A small HTTP server on the local network that hands `HLSStream`s to the
/// TV. Each stream lives under a random path, so only what's being cast can
/// be fetched, and only by someone who was given its URL.
public final class CastServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacShow.CastServer")
    private let lock = NSLock()
    private var listener: NWListener?
    private var streams: [String: HLSStream] = [:]

    public init() {}

    /// The URL of `stream`'s master playlist, reachable from other devices on
    /// the network. Starts the server the first time.
    public func publish(_ stream: HLSStream) async throws -> URL {
        let port = try await start()
        let token = UUID().uuidString
        lock.withLock { streams[token] = stream }
        return URL(string: "http://\(Self.localAddress() ?? "127.0.0.1"):\(port)/\(token)/master.m3u8")!
    }

    /// Stops serving the stream at `url`.
    public func unpublish(_ url: URL) {
        let token = url.pathComponents.dropFirst().first ?? ""
        _ = lock.withLock { streams.removeValue(forKey: token) }
    }

    private func start() async throws -> UInt16 {
        if let port = lock.withLock({ listener?.port?.rawValue }) { return port }
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .main)
            self?.receive(on: connection, buffer: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    self?.lock.withLock { self?.listener = listener }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Reads requests one after another on a kept-alive connection.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return connection.cancel() }
            var buffer = buffer + (data ?? Data())
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || buffer.count > 65536 { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                return
            }
            let request = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            buffer.removeSubrange(..<end.upperBound)
            // Segments take a moment to make; don't hold up other connections.
            DispatchQueue.global(qos: .userInitiated).async {
                let response = self.respond(to: request)
                connection.send(content: response, completion: .contentProcessed { _ in
                    if isComplete { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                })
            }
        }
    }

    private func respond(to request: String) -> Data {
        let lines = request.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return Self.status("405 Method Not Allowed") }
        let path = parts[1].split(separator: "?")[0].split(separator: "/", maxSplits: 1).map(String.init)
        guard path.count == 2, let stream = lock.withLock({ streams[path[0]] }) else { return Self.status("404 Not Found") }
        let body: Data, contentType: String
        do {
            guard let response = try stream.response(for: path[1]) else { return Self.status("404 Not Found") }
            (body, contentType) = response
        } catch {
            return Self.status("500 Internal Server Error")
        }

        // Byte ranges, in case a player asks for part of a segment.
        var status = "200 OK"
        var range = 0..<body.count
        if let header = lines.first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
            let bounds = header.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            if bounds.count == 2, let start = bounds[0], start < body.count {
                range = start..<min((bounds[1] ?? body.count - 1) + 1, body.count)
                status = "206 Partial Content"
            }
        }
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(range.count)\r\nAccept-Ranges: bytes\r\nConnection: keep-alive\r\n"
        if status.hasPrefix("206") { head += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(body.count)\r\n" }
        let content = parts[0] == "HEAD" ? Data() : body.subdata(in: range)
        return Data((head + "\r\n").utf8) + content
    }

    private static func status(_ status: String) -> Data {
        Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n".utf8)
    }

    /// This Mac's IPv4 address on its network (Wi-Fi or Ethernet), which the TV connects to.
    static func localAddress() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }
        var found: [(name: String, address: String)] = []
        var next = addresses
        while let entry = next?.pointee {
            next = entry.ifa_next
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append((String(cString: entry.ifa_name), String(cString: host)))
        }
        // en0 is usually the Wi-Fi or built-in Ethernet; skip VPN tunnels and bridges.
        return (found.first { $0.name == "en0" } ?? found.first { $0.name.hasPrefix("en") } ?? found.first)?.address
    }
}
