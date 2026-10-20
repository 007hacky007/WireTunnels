import SwiftUI

struct InventorySettingsView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    let tunnel: Tunnel
    @State private var executable = ""
    @State private var arguments = ""
    @State private var saving = false
    @State private var error: String?

    private var live: Tunnel { tunnelManager.tunnels.first { $0.id == tunnel.id } ?? tunnel }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inventory AllowedIPs").font(.headline)
            Text("After connecting, run a local command as your user and add its IPs/CIDRs to this tunnel's first peer. Static config entries are preserved. Fixed and cached destinations stay blocked outside this VPN, including after disconnect or app quit.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Executable, e.g. /absolute/path/to/python3", text: $executable)
                .textFieldStyle(.roundedBorder)
            Text("Arguments, one per line").font(.caption)
            TextEditor(text: $arguments).font(.system(.caption, design: .monospaced)).frame(height: 90)
                .border(Color.secondary.opacity(0.3))
            Text("Example arguments: /path/to/server_ips.py, your inventory URL, and --merge, each on its own line. Output must be IPs or CIDRs separated by commas or whitespace. The command has a 60-second timeout.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Save Command") { save(disable: false) }
                    .disabled(saving || live.isActive || executable.isEmpty)
                Button("Disable and Remove Protection") { save(disable: true) }
                    .disabled(saving || live.isActive || live.inventoryCommand == nil)
                Button("Refresh Now") { Task { await tunnelManager.refreshInventory(for: live) } }
                    .disabled(!live.isActive || live.inventoryCommand == nil || tunnelManager.refreshingInventories.contains(live.id))
                if saving || tunnelManager.refreshingInventories.contains(live.id) { ProgressView().controlSize(.small) }
            }
            if live.isActive { Text("Disconnect before changing or disabling the command.").font(.caption).foregroundStyle(.secondary) }
            Text("Cached inventory: \(live.inventoryAllowedIPs.count) prefixes").font(.caption)
            if let updated = live.inventoryUpdatedAt { Text("Updated \(updated.formatted())").font(.caption).foregroundStyle(.secondary) }
            if let message = error ?? tunnelManager.inventoryErrors[live.id] {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: tunnel.id) {
            executable = live.inventoryCommand?.executable ?? ""
            arguments = live.inventoryCommand?.arguments.joined(separator: "\n") ?? ""
        }
    }

    private func save(disable: Bool) {
        saving = true; error = nil
        let command = disable ? nil : InventoryCommand(executable: executable.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: arguments.components(separatedBy: "\n").filter { !$0.isEmpty })
        Task {
            defer { saving = false }
            do { try await tunnelManager.updateInventoryCommand(for: live, command: command) }
            catch { self.error = error.localizedDescription }
        }
    }
}
