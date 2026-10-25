import Foundation
import Network
import Testing
@testable import MacShowCore

struct DLNATests {
    private let fixture = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("My.Show.S02E05.720p.mkv")

    static let description = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <device>
            <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
            <friendlyName>[TV] Living Room</friendlyName>
            <UDN>uuid:1234</UDN>
            <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
                <controlURL>/upnp/control/RenderingControl1</controlURL>
              </service>
              <service>
                <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                <controlURL>/upnp/control/AVTransport1</controlURL>
              </service>
            </serviceList>
          </device>
        </root>
        """

    @Test func readsTheSearchResponse() {
        let response = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nlocation: http://192.168.0.20:9197/dmr\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
        #expect(DLNA.location(inSearchResponse: response) == URL(string: "http://192.168.0.20:9197/dmr"))
        #expect(DLNA.location(inSearchResponse: "NOTIFY * HTTP/1.1\r\nLOCATION: http://x/\r\n\r\n") == nil)
        #expect(DLNA.searchRequest(host: "239.255.255.250", port: 1900).contains("\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n"))
    }

    @Test func readsTheDeviceDescription() throws {
        let location = URL(string: "http://192.168.0.20:9197/dmr")!
        let renderer = try #require(DLNA.renderer(inDescription: Data(Self.description.utf8), from: location))
        #expect(renderer.name == "[TV] Living Room")
        #expect(renderer.controlURL == URL(string: "http://192.168.0.20:9197/upnp/control/AVTransport1"))
        #expect(renderer.serviceType == "urn:schemas-upnp-org:service:AVTransport:1")

        // An embedded renderer, with URLBase; and a device without AVTransport.
        let embedded = """
            <root><URLBase>http://10.0.0.5:8080/</URLBase><device><friendlyName>Receiver</friendlyName><deviceList>
            <device><friendlyName>Receiver Renderer</friendlyName><serviceList><service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:2</serviceType><controlURL>av/control</controlURL>
            </service></serviceList></device></deviceList></device></root>
            """
        let inner = try #require(DLNA.renderer(inDescription: Data(embedded.utf8), from: location))
        #expect(inner.name == "Receiver Renderer")
        #expect(inner.controlURL == URL(string: "http://10.0.0.5:8080/av/control"))
        #expect(DLNA.renderer(inDescription: Data(Self.description.replacingOccurrences(of: "AVTransport", with: "ConnectionManager").utf8), from: location) == nil)
    }

    @Test func soapAndDIDLBodies() {
        let play = DLNA.soapBody("Play", serviceType: "urn:schemas-upnp-org:service:AVTransport:1", arguments: [("Speed", "1")])
        #expect(play == #"<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>"#)

        let url = URL(string: "http://192.168.0.2:5000/T/video.mkv")!
        let metadata = DLNA.metadata(title: "Tom & Jerry", url: url, mimeType: "video/x-matroska", duration: 3725)
        #expect(metadata.contains("<dc:title>Tom &amp; Jerry</dc:title>"))
        #expect(metadata.contains(#"<res protocolInfo="http-get:*:video/x-matroska:DLNA.ORG_OP=01;"#))
        #expect(metadata.contains(#"duration="1:02:05.000">http://192.168.0.2:5000/T/video.mkv</res>"#))
        // The metadata travels escaped inside the SOAP body.
        let set = DLNA.soapBody("SetAVTransportURI", serviceType: "urn:schemas-upnp-org:service:AVTransport:1", arguments: [("CurrentURI", url.absoluteString), ("CurrentURIMetaData", metadata)])
        #expect(set.contains("<CurrentURIMetaData>&lt;DIDL-Lite xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;"))
        #expect(set.contains("Tom &amp;amp; Jerry"))
    }

    @Test func readsReplies() {
        let reply = """
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
            <u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
            <Track>1</Track><TrackDuration>1:28:30</TrackDuration><RelTime>0:12:05.5</RelTime><AbsTime>NOT_IMPLEMENTED</AbsTime>
            </u:GetPositionInfoResponse></s:Body></s:Envelope>
            """
        let fields = DLNA.fields(inResponse: Data(reply.utf8))
        #expect(DLNA.seconds(fields["RelTime"]!) == 725.5)
        #expect(DLNA.seconds(fields["TrackDuration"]!) == 5310)
        #expect(DLNA.seconds(fields["AbsTime"]!) == 0)
        #expect(DLNA.time(725.5) == "0:12:05")
    }

    @Test func sendsTheFileItselfOnlyWhenTVsPlayIt() {
        #expect(DLNA.originalMimeType(container: "matroska,webm", video: .copy, audioCodec: "eac3") == "video/x-matroska")
        #expect(DLNA.originalMimeType(container: "mov,mp4,m4a,3gp,3g2,mj2", video: .copy, audioCodec: "aac") == "video/mp4")
        #expect(DLNA.originalMimeType(container: "mpegts", video: .copy, audioCodec: "ac3") == "video/mp2t")
        #expect(DLNA.originalMimeType(container: "matroska,webm", video: .convert, audioCodec: "aac") == nil)  // AV1, XviD…
        #expect(DLNA.originalMimeType(container: "matroska,webm", video: .copy, audioCodec: "dts") == nil)
        #expect(DLNA.originalMimeType(container: "avi", video: .copy, audioCodec: "ac3") == nil)
    }

    /// Discovery, control and file serving against a pretend TV on this Mac.
    @Test func castsToAFakeRenderer() async throws {
        let tv = try await FakeRenderer.start()
        defer { tv.stop() }
        let renderers = await DLNA.discover(timeout: 1, host: "127.0.0.1", port: tv.ssdpPort)
        let renderer = try #require(renderers.first)
        #expect(renderers.count == 1)
        #expect(renderer.name == "[TV] Living Room")

        let server = CastServer()
        let url = try await server.publish(file: fixture, mimeType: "video/x-matroska")
        try await DLNA.play(url, title: "My Show", mimeType: "video/x-matroska", duration: 1, on: renderer)
        try await DLNA.seek(to: 65, on: renderer)
        let status = try await DLNA.status(of: renderer)
        #expect(status.position == 725.5 && status.duration == 5310 && status.state == "PLAYING")
        #expect(tv.actions.map(\.name) == ["SetAVTransportURI", "Play", "Seek", "GetPositionInfo", "GetTransportInfo"])
        #expect(tv.actions[0].body.contains("<CurrentURI>\(url.absoluteString)</CurrentURI>"))
        #expect(tv.actions[2].body.contains("<Unit>REL_TIME</Unit><Target>0:01:05</Target>"))

        // The TV fetches the file in byte ranges, as it does to seek.
        var request = URLRequest(url: url)
        request.setValue("bytes=100-199", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        let file = try Data(contentsOf: fixture)
        #expect(http.statusCode == 206)
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 100-199/\(file.count)")
        #expect(http.value(forHTTPHeaderField: "contentFeatures.dlna.org") == DLNA.contentFeatures)
        #expect(data == file[100..<200])
        let (whole, _) = try await URLSession.shared.data(from: url)
        #expect(whole == file)
        server.unpublish(url)
    }
}

/// A pretend TV: answers SSDP searches on a UDP port and serves a device
/// description and an AVTransport control URL over HTTP, recording each call.
private final class FakeRenderer: @unchecked Sendable {
    let ssdpPort: UInt16
    private let socket: Int32
    private let listener: NWListener
    private let lock = NSLock()
    private var recorded: [(name: String, body: String)] = []
    var actions: [(name: String, body: String)] { lock.withLock { recorded } }

    private init(socket: Int32, ssdpPort: UInt16, listener: NWListener) {
        self.socket = socket
        self.ssdpPort = ssdpPort
        self.listener = listener
    }

    static func start() async throws -> FakeRenderer {
        let listener = try NWListener(using: .tcp)
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        let tv = FakeRenderer(socket: socket, ssdpPort: UInt16(bigEndian: address.sin_port), listener: listener)

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            tv.serve(connection, buffer: Data())
        }
        let httpPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue) }
                if case .failed(let error) = state { listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
            }
            listener.start(queue: .global())
        }
        // Answer every M-SEARCH with where the description is.
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 2048)
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            while true {
                let count = withUnsafeMutablePointer(to: &sender) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socket, &buffer, buffer.count, 0, $0, &senderLength) } }
                guard count > 0 else { return }
                let reply = Array("HTTP/1.1 200 OK\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nLOCATION: http://127.0.0.1:\(httpPort)/description.xml\r\n\r\n".utf8)
                _ = withUnsafePointer(to: &sender) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socket, reply, reply.count, 0, $0, senderLength) } }
            }
        }
        return tv
    }

    func stop() {
        listener.cancel()
        shutdown(socket, SHUT_RDWR)
        close(socket)
    }

    private func serve(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            guard error == nil else { return connection.cancel() }
            let buffer = buffer + (data ?? Data())
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return isComplete ? connection.cancel() : self.serve(connection, buffer: buffer)
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            guard buffer.count - end.upperBound >= length else { return self.serve(connection, buffer: buffer) }
            let body = String(decoding: buffer[end.upperBound..<end.upperBound + length], as: UTF8.self)
            let reply: String
            if head.hasPrefix("GET /description.xml") {
                reply = DLNATests.description
            } else {
                let action = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("soapaction:") }?
                    .split(separator: "#").last.map { $0.replacingOccurrences(of: "\"", with: "") } ?? ""
                self.lock.withLock { self.recorded.append((action, body)) }
                let fields = ["GetPositionInfo": "<TrackDuration>1:28:30</TrackDuration><RelTime>0:12:05.5</RelTime>",
                              "GetTransportInfo": "<CurrentTransportState>PLAYING</CurrentTransportState>"][action] ?? ""
                reply = #"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>"#
                    + "<u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">\(fields)</u:\(action)Response></s:Body></s:Envelope>"
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: \(reply.utf8.count)\r\nConnection: close\r\n\r\n" + reply
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
