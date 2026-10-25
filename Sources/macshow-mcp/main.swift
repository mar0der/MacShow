// macshow-mcp: lets MCP apps that start a program (Claude Desktop, Claude Code)
// talk to MacShow. It passes each JSON-RPC message from stdin to MacShow's
// agent endpoint on 127.0.0.1 and writes the answer to stdout. The token comes
// from MacShow's own settings (or MACSHOW_TOKEN), so no config needs it.
import Foundation

let appID = "io.github.mar0der.MacShow"
/// A value from MacShow's settings (they live in its sandbox container), or the environment.
func setting(_ key: String, environment: String) -> Any? {
    if let value = ProcessInfo.processInfo.environment[environment], !value.isEmpty { return value }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let plist = home.appendingPathComponent("Library/Containers/\(appID)/Data/Library/Preferences/\(appID).plist")
    if let value = NSDictionary(contentsOf: plist)?[key] { return value }
    return CFPreferencesCopyAppValue(key as CFString, appID as CFString)
}

func token() -> String? { setting("agentToken", environment: "MACSHOW_TOKEN") as? String }

/// Read each time: MacShow picks another port if its usual one is taken.
var endpoint: URL {
    let port = (setting("agentPort", environment: "MACSHOW_PORT") as? Int)
        ?? (setting("agentPort", environment: "MACSHOW_PORT") as? String).flatMap(Int.init) ?? 47321
    return URL(string: "http://127.0.0.1:\(port)/mcp")!
}

enum Reply {
    case body(Data)
    case none
    case refused(String)
}

func send(_ message: Data) -> Reply {
    guard let token = token() else { return .refused("MacShow's agent control hasn't been turned on (MacShow › Settings › Agents).") }
    var request = URLRequest(url: endpoint, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.httpBody = message
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var reply = Reply.refused("MacShow isn't running, or agent control is off (MacShow › Settings › Agents).")
    URLSession.shared.dataTask(with: request) { data, response, _ in
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: reply = .body(data ?? Data())
        case 202: reply = .none
        case 401: reply = .refused("MacShow refused the token. Turn agent control off and on in MacShow › Settings › Agents.")
        default: break
        }
        done.signal()
    }.resume()
    done.wait()
    return reply
}

/// Opens MacShow in the background and waits for its endpoint.
func launchMacShow() {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-b", appID]
    try? open.run()
    open.waitUntilExit()
}

var launched = false
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    let message = Data(line.utf8)
    var reply = send(message)
    if case .refused = reply, !launched {
        launched = true
        launchMacShow()
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.5)
            reply = send(message)
            if case .refused = reply { continue }
            break
        }
    }
    switch reply {
    case .body(let data):
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    case .none:
        break
    case .refused(let reason):
        // Answer requests (not notifications) with an error the client can show.
        if let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any], let id = object["id"] {
            let error: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": reason]]
            if let data = try? JSONSerialization.data(withJSONObject: error) {
                FileHandle.standardOutput.write(data + Data("\n".utf8))
            }
        }
    }
}
