import Foundation

/// Casting to smart TVs over DLNA/UPnP: find renderers with SSDP, read their
/// device description, and drive their AVTransport service with SOAP.
public enum DLNA {
    /// A TV (or other MediaRenderer) that can be told to play a URL.
    public struct Renderer: Hashable, Sendable, Identifiable {
        public var id: String { controlURL.absoluteString }
        public let name: String
        /// Where AVTransport actions are POSTed.
        public let controlURL: URL
        /// e.g. "urn:schemas-upnp-org:service:AVTransport:1"
        public let serviceType: String
    }

    /// The MIME type to send the file itself as, when TVs commonly play its
    /// container and codecs (H.264/HEVC with AAC, AC-3 or E-AC-3 in MKV, MP4
    /// or MPEG-TS); nil if it should go as HLS, repackaged.
    public static func originalMimeType(container: String, video: CastPlan.Action, audioCodec: String?) -> String? {
        guard video == .copy, audioCodec.map({ ["aac", "ac3", "eac3"].contains($0) }) ?? true else { return nil }
        switch container {
        case "matroska,webm": return "video/x-matroska"
        case "mov,mp4,m4a,3gp,3g2,mj2": return "video/mp4"
        case "mpegts": return "video/mp2t"
        default: return nil
        }
    }

    // MARK: Discovery

    static let searchTarget = "urn:schemas-upnp-org:device:MediaRenderer:1"

    static func searchRequest(host: String, port: UInt16) -> String {
        ["M-SEARCH * HTTP/1.1", "HOST: \(host):\(port)", "MAN: \"ssdp:discover\"", "MX: 2", "ST: \(searchTarget)", "", ""]
            .joined(separator: "\r\n")
    }

    /// The description URL in an SSDP search response (its LOCATION header).
    public static func location(inSearchResponse response: String) -> URL? {
        let lines = response.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }
        guard lines.first?.uppercased().hasPrefix("HTTP/1.1 200") == true else { return nil }
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "location" {
                return URL(string: parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// The renderer in a device description, if it has an AVTransport service.
    public static func renderer(inDescription data: Data, from location: URL) -> Renderer? {
        let parser = XMLParser(data: data)
        let reader = DescriptionReader()
        parser.delegate = reader
        guard parser.parse(), let control = reader.controlURL, let serviceType = reader.serviceType else { return nil }
        let base = reader.urlBase.flatMap { URL(string: $0) } ?? location
        guard let url = URL(string: control, relativeTo: base)?.absoluteURL else { return nil }
        return Renderer(name: reader.name ?? location.host ?? "TV", controlURL: url, serviceType: serviceType)
    }

    /// Asks the network for MediaRenderers and returns those that answer within
    /// `timeout`. SSDP goes to the multicast group unless `host` names one device.
    public static func discover(timeout: TimeInterval = 3, host: String = "239.255.255.250", port: UInt16 = 1900) async -> [Renderer] {
        let locations = await Task.detached { search(host: host, port: port, timeout: timeout) }.value
        return await withTaskGroup(of: Renderer?.self) { group in
            for location in locations {
                group.addTask {
                    var request = URLRequest(url: location, timeoutInterval: 3)
                    request.setValue("MacShow", forHTTPHeaderField: "User-Agent")
                    guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
                    return renderer(inDescription: data, from: location)
                }
            }
            var renderers: [Renderer] = []
            for await renderer in group { if let renderer, !renderers.contains(renderer) { renderers.append(renderer) } }
            return renderers.sorted { $0.name < $1.name }
        }
    }

    /// Sends M-SEARCH from a UDP socket and collects the LOCATION of every reply.
    private static func search(host: String, port: UInt16, timeout: TimeInterval) -> [URL] {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { return [] }
        defer { close(socket) }
        var ttl: UInt8 = 2
        setsockopt(socket, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var wait = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        let request = Array(searchRequest(host: host, port: port).utf8)
        // UDP can drop a packet; ask twice.
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socket, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }

        var locations: [URL] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = recv(socket, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            if let location = location(inSearchResponse: String(decoding: buffer[..<count], as: UTF8.self)), !locations.contains(location) {
                locations.append(location)
            }
        }
        return locations
    }

    // MARK: Control

    /// A SOAP call to the renderer's AVTransport, e.g. ("Play", [("Speed", "1")]).
    static func soapBody(_ action: String, serviceType: String, arguments: [(String, String)]) -> String {
        let fields = ([("InstanceID", "0")] + arguments).map { "<\($0)>\(escape($1))</\($0)>" }.joined()
        return #"<?xml version="1.0" encoding="utf-8"?>"#
            + #"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">"#
            + "<s:Body><u:\(action) xmlns:u=\"\(serviceType)\">\(fields)</u:\(action)></s:Body></s:Envelope>"
    }

    /// DIDL-Lite describing what's being played, which many TVs require with the URL.
    static func metadata(title: String, url: URL, mimeType: String, duration: Double) -> String {
        #"<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">"#
            + #"<item id="0" parentID="-1" restricted="1">"#
            + "<dc:title>\(escape(title))</dc:title><upnp:class>object.item.videoItem</upnp:class>"
            + "<res protocolInfo=\"http-get:*:\(mimeType):\(contentFeatures)\" duration=\"\(time(duration)).000\">\(escape(url.absoluteString))</res>"
            + "</item></DIDL-Lite>"
    }

    /// DLNA flags for a file the TV may seek in by byte range and stream.
    public static let contentFeatures = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"

    /// Calls `action` on the renderer and returns the reply's fields.
    @discardableResult
    public static func send(_ action: String, _ arguments: [(String, String)] = [], to renderer: Renderer) async throws -> [String: String] {
        var request = URLRequest(url: renderer.controlURL, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(renderer.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(soapBody(action, serviceType: renderer.serviceType, arguments: arguments).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return fields(inResponse: data)
    }

    public static func play(_ url: URL, title: String, mimeType: String, duration: Double, on renderer: Renderer) async throws {
        try await send("SetAVTransportURI", [("CurrentURI", url.absoluteString), ("CurrentURIMetaData", metadata(title: title, url: url, mimeType: mimeType, duration: duration))], to: renderer)
        try await send("Play", [("Speed", "1")], to: renderer)
    }

    public static func seek(to seconds: Double, on renderer: Renderer) async throws {
        try await send("Seek", [("Unit", "REL_TIME"), ("Target", time(seconds))], to: renderer)
    }

    /// Where the TV is, its length, and whether it's playing, paused or stopped.
    public static func status(of renderer: Renderer) async throws -> (position: Double, duration: Double, state: String) {
        let position = try await send("GetPositionInfo", to: renderer)
        let transport = try await send("GetTransportInfo", to: renderer)
        return (seconds(position["RelTime"] ?? ""), seconds(position["TrackDuration"] ?? ""), transport["CurrentTransportState"] ?? "")
    }

    /// The elements of the action response inside a SOAP reply, by name.
    static func fields(inResponse data: Data) -> [String: String] {
        let parser = XMLParser(data: data)
        let reader = ResponseReader()
        parser.delegate = reader
        parser.parse()
        return reader.fields
    }

    /// "1:02:03" for 3723 seconds.
    static func time(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    /// 3723.5 for "1:02:03.5"; 0 for "NOT_IMPLEMENTED" and the like.
    static func seconds(_ time: String) -> Double {
        let parts = time.split(separator: ":").map { Double($0) }
        guard parts.count == 3, let hours = parts[0], let minutes = parts[1], let seconds = parts[2] else { return 0 }
        return hours * 3600 + minutes * 60 + seconds
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Reads the friendly name and AVTransport control URL from a UPnP device description.
private final class DescriptionReader: NSObject, XMLParserDelegate {
    var urlBase: String?
    var name: String?
    var controlURL: String?
    var serviceType: String?
    private var text = ""
    /// Each open <device>'s friendlyName, innermost last.
    private var deviceNames: [String?] = []
    private var service: (type: String?, control: String?)?

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if element == "device" { deviceNames.append(nil) }
        if element == "service" { service = (nil, nil) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "URLBase": urlBase = value
        case "friendlyName" where !deviceNames.isEmpty: deviceNames[deviceNames.count - 1] = value
        case "serviceType": service?.type = value
        case "controlURL": service?.control = value
        case "service":
            if controlURL == nil, let type = service?.type, type.contains(":service:AVTransport:"), let control = service?.control {
                (controlURL, serviceType) = (control, type)
                name = deviceNames.last ?? nil
            }
            service = nil
        case "device": deviceNames.removeLast()
        default: break
        }
        text = ""
    }
}

/// Collects the child elements of a SOAP action response (RelTime, CurrentTransportState…).
private final class ResponseReader: NSObject, XMLParserDelegate {
    var fields: [String: String] = [:]
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        // Leaf elements only; strip any namespace prefix.
        let name = String(element.split(separator: ":").last ?? "")
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if fields[name] == nil, !value.isEmpty { fields[name] = value }
        text = ""
    }
}
