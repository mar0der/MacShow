import MacShowCore
import SwiftUI

/// Settings › Agents: let AI agents (Claude and others, over MCP) control MacShow.
struct AgentSettings: View {
    @AppStorage(AgentControl.enabledKey) private var enabled = false
    @AppStorage(AgentControl.readOnlyKey) private var readOnly = false
    @State private var copied: String?

    var body: some View {
        Form {
            Section {
                Toggle("Let AI agents control MacShow", isOn: $enabled)
                Toggle("Read-only: agents can search and play, not change the library", isOn: $readOnly)
                    .disabled(!enabled)
                if enabled {
                    if AgentControl.shared.isRunning {
                        Label("Running on this Mac only (127.0.0.1:\(String(AgentControl.port)))", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else if let error = AgentControl.shared.error {
                        Label("Couldn't start: \(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Label("Starting…", systemImage: "hourglass").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Agents can search your library, play and queue things, make playlists, move items between categories and edit details. Nothing in Adult folders is visible to them. Only programs on this Mac with the token can connect.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Connect Claude Code") {
                copyable(claudeCode)
            }
            Section {
                copyable(desktopConfig)
            } header: {
                Text("Connect Claude Desktop or another MCP app")
            } footer: {
                Text("Add this to the app's MCP servers (in Claude Desktop: Settings › Developer › Edit Config). The bridge reads the token from MacShow's settings and opens MacShow when it isn't running.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Button("New Token") { AgentControl.shared.newToken() }
            } footer: {
                Text("Disconnects anything that used the old token directly. Connections through the bridge keep working.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onChange(of: enabled) { AgentControl.shared.apply() }
        .onChange(of: readOnly) { AgentControl.shared.apply() }
    }

    private var claudeCode: String { "claude mcp add macshow -- \"\(AgentControl.bridgePath)\"" }

    private var desktopConfig: String {
        """
        "macshow": {
          "command": "\(AgentControl.bridgePath)"
        }
        """
    }

    private func copyable(_ text: String) -> some View {
        HStack(alignment: .top) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied == text ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = text
            }
        }
    }
}
