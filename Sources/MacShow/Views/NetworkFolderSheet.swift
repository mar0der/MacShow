import MacShowCore
import Network
import SwiftUI

/// File servers on the local network (a NAS, other Macs and PCs sharing folders), found with Bonjour.
@MainActor
@Observable
final class ShareBrowser {
    struct Server: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    private(set) var servers: [Server] = []
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
        let thisMac = Host.current().localizedName
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let servers = results.compactMap { result -> Server? in
                guard case .service(let name, _, _, _) = result.endpoint, name != thisMac else { return nil }
                return Server(name: name, endpoint: result.endpoint)
            }
            DispatchQueue.main.async { self?.servers = Array(Set(servers)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// The server's IPv4 address, for an smb:// address Finder can connect to.
    static func address(of server: Server) async -> String? {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: server.endpoint, using: parameters)
        return await withCheckedContinuation { continuation in
            let finish = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var host: String?
                    if case .hostPort(let address, _) = connection.currentPath?.remoteEndpoint { host = "\(address)" }
                    if finish.set() { continuation.resume(returning: host) }
                    connection.cancel()
                case .failed, .cancelled:
                    if finish.set() { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                if finish.set() { continuation.resume(returning: nil) }
                connection.cancel()
            }
        }
    }
}

/// Settings › Library › Add Network Folder: pick a server (or type its address),
/// macOS connects to it (asking for the password and keeping it in the
/// Keychain), then you choose the folder with your media on the share.
struct NetworkFolderSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var browser = ShareBrowser()
    @State private var address = "smb://"
    @State private var status: String?
    @State private var waitingForMount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Network Folder").font(.headline)
            Text("Media on a NAS, or on a Mac or PC sharing folders in your home. macOS connects to it and asks for its password if needed; then choose the folder with your media.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox("On Your Network") {
                if browser.servers.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Looking for file servers…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    VStack(spacing: 0) {
                        ForEach(browser.servers) { server in
                            HStack {
                                Label(server.name, systemImage: "server.rack")
                                Spacer()
                                Button("Connect") { connect(server) }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            HStack {
                TextField("Address", text: $address, prompt: Text("smb://nas.local/Media"))
                    .onSubmit(connectToAddress)
                Button("Connect", action: connectToAddress)
                    .disabled(URL(string: address)?.host == nil)
            }
            if let status {
                HStack(spacing: 8) {
                    if waitingForMount { ProgressView().controlSize(.small) }
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { note in
            guard waitingForMount, let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                  (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
            else { return }
            waitingForMount = false
            chooseFolder(on: volume)
        }
    }

    private func connect(_ server: ShareBrowser.Server) {
        status = "Finding \(server.name)…"
        Task {
            guard let host = await ShareBrowser.address(of: server), let url = URL(string: "smb://\(host)") else {
                status = "Couldn't reach \(server.name). Try its address below."
                return
            }
            open(url, name: server.name)
        }
    }

    private func connectToAddress() {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.host != nil else { return }
        open(url, name: url.host!)
    }

    /// Finder does the connecting: its password dialog, Keychain and share picker.
    private func open(_ url: URL, name: String) {
        waitingForMount = true
        status = "Connecting to \(name)… Pick the share and enter its password in the window macOS shows."
        NSWorkspace.shared.open(url)
    }

    private func chooseFolder(on volume: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = volume
        panel.prompt = "Add to Library"
        panel.message = "Choose the folders with your media on \(volume.lastPathComponent)."
        guard panel.runModal() == .OK else {
            status = "Connected. Choose a folder to add it."
            return
        }
        panel.urls.forEach(library.addFolder)
        dismiss()
    }
}

/// True only the first time `set()` is called (connection callbacks race the timeout).
private final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func set() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
