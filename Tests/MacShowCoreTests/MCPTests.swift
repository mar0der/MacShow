import Foundation
import Testing
@testable import MacShowCore

@MainActor
struct MCPServerTests {
    func server() -> MCPServer {
        MCPServer(name: "MacShow", version: "1", instructions: "Plays your media.", tools: [
            MCPTool("echo", "Says it back", input: ["type": "object", "properties": ["text": ["type": "string"]]]) { arguments in
                ["said": arguments["text"] ?? .null]
            },
            MCPTool("rename", "Changes things", changesLibrary: true) { _ in "done" },
            MCPTool("fail", "Refuses") { _ in throw MCPToolError("Nothing playing") },
        ])
    }

    func call(_ server: MCPServer, _ json: String) async throws -> JSONValue {
        let reply = try #require(await server.handle(Data(json.utf8)))
        return try JSONDecoder().decode(JSONValue.self, from: reply)
    }

    @Test func initializeAndList() async throws {
        let server = server()
        let hello = try await call(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        #expect(hello["result"]?["protocolVersion"]?.string == "2025-03-26")
        #expect(hello["result"]?["serverInfo"]?["name"]?.string == "MacShow")
        #expect(await server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
        let list = try await call(server, #"{"jsonrpc":"2.0","id":"2","method":"tools/list"}"#)
        #expect(list["id"]?.string == "2")
        #expect(list["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } == ["echo", "rename", "fail"])
    }

    @Test func callsTools() async throws {
        let server = server()
        let echo = try await call(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        #expect(echo["result"]?["isError"]?.bool == false)
        #expect(echo["result"]?["content"]?.array?.first?["text"]?.string?.contains("\"said\" : \"hi\"") == true)

        let fail = try await call(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fail"}}"#)
        #expect(fail["result"]?["isError"]?.bool == true)
        #expect(fail["result"]?["content"]?.array?.first?["text"]?.string == "Nothing playing")

        let unknown = try await call(server, #"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)
        #expect(unknown["error"]?["code"]?.int == -32601)
    }

    @Test func readOnlyRefusesChanges() async throws {
        let server = server()
        server.readOnly = true
        let rename = try await call(server, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"rename"}}"#)
        #expect(rename["result"]?["isError"]?.bool == true)
        let echo = try await call(server, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        #expect(echo["result"]?["isError"]?.bool == false)
    }
}

struct AgentHTTPServerTests {
    @Test func parsesCompleteRequestsOnly() {
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer abc\r\nContent-Length: 4\r\n\r\n"
        #expect(HTTPRequest(Data((head + "ab").utf8)) == nil)
        let request = HTTPRequest(Data((head + "abcd").utf8))
        #expect(request?.method == "POST" && request?.path == "/mcp")
        #expect(request?.headers["authorization"] == "Bearer abc")
        #expect(request?.body == Data("abcd".utf8))
    }

    @Test func answersOverHTTP() async throws {
        let port = UInt16.random(in: 40000...49000)
        let server = AgentHTTPServer(port: port, token: "secret") { body in body }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))
        func post(token: String?, origin: String? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.httpBody = Data("ping".utf8)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            return ((response as! HTTPURLResponse).statusCode, data)
        }
        let ok = try await post(token: "secret")
        #expect(ok.0 == 200 && ok.1 == Data("ping".utf8))
        #expect(try await post(token: "wrong").0 == 401)
        #expect(try await post(token: "secret", origin: "https://evil.example").0 == 403)
    }
}
