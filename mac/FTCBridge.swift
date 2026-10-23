// FTC Bridge: menu bar app for choosing which robot (Control Hub) the Pi joins.
// Every action is one SSH call over the USB link to /usr/local/bin/ftc-hub on the Pi, which
// stores the saved robots. The `ftc-bridge` terminal command uses the same calls.
import SwiftUI

enum Pi {
    static let login = "ftc@10.12.194.1"
    static let key = NSHomeDirectory() + "/.ssh/ftcpi"

    /// Runs `ftc-hub <args>` on the Pi. `input` goes to its stdin, so the Wi-Fi
    /// password never appears in a command line.
    static func run(_ args: [String], input: String? = nil) async -> (ok: Bool, output: String) {
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let ssh = Process()
                ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                ssh.arguments = [
                    "-i", key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "LogLevel=ERROR",
                    // The Pi gets a new host key each time its card is reflashed, and it's on
                    // a direct USB cable, so don't pin the key.
                    "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                    login, "sudo", "/usr/local/bin/ftc-hub",
                ] + args
                let stdout = Pipe(), stdin = Pipe()
                ssh.standardOutput = stdout
                ssh.standardError = stdout
                ssh.standardInput = stdin
                do { try ssh.run() } catch { return done.resume(returning: (false, "\(error)")) }
                if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
                try? stdin.fileHandleForWriting.close()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                ssh.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                done.resume(returning: (ssh.terminationStatus == 0, text))
            }
        }
    }
}

struct Robot: Hashable {
    let name: String
    let ssid: String
}

/// Robot names become part of the Pi's connection names, so keep them simple.
func robotName(from ssid: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    return String(String(ssid.map { allowed.contains($0) ? $0 : "-" }).prefix(32))
}

@MainActor
final class Bridge: ObservableObject {
    enum Link { case noPi, noHub, connected }

    @Published var link = Link.noPi
    @Published var robot = ""          // robot the Pi is set to
    @Published var ssid = ""           // that robot's Wi-Fi name
    @Published var robots: [Robot] = []
    @Published var nearby: [String] = []
    @Published var message = ""        // shown only while working or after a problem
    @Published var messageIsError = false
    @Published var busy = false

    init() {
        Task { while true { await refresh(); try? await Task.sleep(for: .seconds(5)) } }
    }

    var icon: String {
        switch link {
        case .connected: "antenna.radiowaves.left.and.right"
        case .noHub: "antenna.radiowaves.left.and.right.slash"
        case .noPi: "powerplug"
        }
    }

    var tint: Color {
        switch link {
        case .connected: .green
        case .noHub: .orange
        case .noPi: .secondary
        }
    }

    var title: String {
        switch link {
        case .connected: robot
        case .noHub: robot.isEmpty ? "No robot chosen" : robot
        case .noPi: "Pi not plugged in"
        }
    }

    var subtitle: String {
        switch link {
        case .connected: "Connected · \(ssid)"
        case .noHub: robot.isEmpty ? "Pick or add a robot below" : "Not answering. Is the robot on?"
        case .noPi: "Plug the Pi's middle USB port into this Mac"
        }
    }

    func refresh() async {
        let result = await Pi.run(["status"])
        guard result.ok else { link = .noPi; return }
        var saved: [Robot] = []
        var fields: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...])
            if key == "saved" {
                let parts = value.split(separator: "\t", maxSplits: 1).map(String.init)
                saved.append(Robot(name: parts[0], ssid: parts.count > 1 ? parts[1] : ""))
            } else {
                fields[key] = value
            }
        }
        robots = saved
        robot = fields["robot"] ?? ""
        ssid = fields["ssid"] ?? ""
        link = fields["hub"] == "up" ? .connected : .noHub
    }

    func scan() async {
        busy = true
        messageIsError = false
        message = "Looking for robots…"
        let result = await Pi.run(["scan"])
        nearby = result.ok ? result.output.split(separator: "\n").map(String.init) : []
        messageIsError = !result.ok
        message = !result.ok ? "Couldn't reach the Pi" : nearby.isEmpty ? "No Wi-Fi networks found. Is the robot on?" : ""
        busy = false
    }

    func use(_ name: String) async {
        _ = await perform("Switching to \(name)…") { await Pi.run(["use", name]) }
    }

    func forget(_ name: String) async {
        _ = await perform("Forgetting \(name)…") { await Pi.run(["forget", name]) }
    }

    /// Saves a robot and switches to it. Returns true if both worked.
    func add(name: String, ssid: String, password: String) async -> Bool {
        await perform("Saving \(name)…") {
            let saved = await Pi.run(["add", name], input: ssid + "\n" + password + "\n")
            guard saved.ok else { return saved }
            self.message = "Connecting to \(name)…"
            return await Pi.run(["use", name])
        }
    }

    /// Shows `start` while `work` runs; afterwards shows nothing on success, or what went wrong.
    private func perform(_ start: String, _ work: () async -> (ok: Bool, output: String)) async -> Bool {
        busy = true
        messageIsError = false
        message = start
        let result = await work()
        await refresh()
        messageIsError = !result.ok
        message = result.ok ? "" : (result.output.isEmpty ? "Couldn't reach the Pi" : result.output)
        busy = false
        return result.ok
    }
}

/// A list row that highlights on hover and runs `action` when clicked.
struct HoverRow<Content: View>: View {
    var enabled = true
    let action: () -> Void
    @ViewBuilder let content: (_ hovering: Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering && enabled ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if enabled { action() } }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8)
    }
}

struct Panel: View {
    @ObservedObject var bridge: Bridge
    @State private var adding: Bool
    @State private var name = ""
    @State private var ssid = ""
    @State private var password = ""

    init(bridge: Bridge, adding: Bool = false) {
        self.bridge = bridge
        _adding = State(initialValue: adding)
    }

    /// Scan results, minus robots already saved.
    private var newNetworks: [String] {
        bridge.nearby.filter { network in !bridge.robots.contains { $0.ssid == network } }
    }

    private var finalName: String { name.isEmpty ? robotName(from: ssid) : name }

    private var canSave: Bool {
        !bridge.busy && !ssid.isEmpty && password.count >= 8
            && !finalName.isEmpty && robotName(from: finalName) == finalName
            && !ssid.contains("\n") && !password.contains("\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if bridge.link != .noPi {
                Divider()
                robotList
                Divider()
                if adding { addForm } else { addButton }
            }
            if !bridge.message.isEmpty { messageLine }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(bridge.tint.opacity(0.18))
                Image(systemName: bridge.icon).foregroundStyle(bridge.tint)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(bridge.title).font(.headline)
                Text(bridge.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if bridge.busy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 4)
    }

    private var robotList: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(text: "ROBOTS")
            if bridge.robots.isEmpty {
                Text("No robots saved yet.").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            ForEach(bridge.robots, id: \.self) { r in
                let active = r.name == bridge.robot
                HoverRow(enabled: !bridge.busy && !active, action: { Task { await bridge.use(r.name) } }) { hovering in
                    HStack(spacing: 8) {
                        Image(systemName: active ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(active ? bridge.tint : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).fontWeight(active ? .semibold : .regular)
                            Text(r.ssid).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if hovering && !bridge.busy {
                            Button { Task { await bridge.forget(r.name) } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Forget \(r.name)")
                        }
                    }
                }
            }
        }
    }

    private var addButton: some View {
        Button {
            adding = true
            if bridge.nearby.isEmpty { Task { await bridge.scan() } }
        } label: {
            Label("Add robot", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .disabled(bridge.busy)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "ADD ROBOT")
                Spacer()
                Button { Task { await bridge.scan() } } label: { Label("Scan", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(bridge.busy)
            }
            if !newNetworks.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(newNetworks, id: \.self) { network in
                            HoverRow(action: { ssid = network }) { _ in
                                HStack(spacing: 8) {
                                    Image(systemName: "wifi").foregroundStyle(.secondary)
                                    Text(network).lineLimit(1)
                                    Spacer()
                                    if network == ssid { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 112)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            Group {
                TextField("Wi-Fi name", text: $ssid)
                SecureField("Wi-Fi password", text: $password)
                TextField("Nickname (optional, e.g. comp)", text: $name)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { closeForm() }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Save & Connect") {
                    let n = finalName, s = ssid, p = password
                    Task { if await bridge.add(name: n, ssid: s, password: p) { closeForm() } else { password = "" } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(.horizontal, 4)
    }

    private var messageLine: some View {
        Label(bridge.message, systemImage: bridge.messageIsError ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.caption)
            .foregroundStyle(bridge.messageIsError ? Color.orange : Color.secondary)
            .padding(.horizontal, 8)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            Text("FTC Bridge").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 8)
    }

    private func closeForm() {
        adding = false
        name = ""; ssid = ""; password = ""
    }
}

@main
struct FTCBridgeApp: App {
    @StateObject private var bridge = Bridge()

    var body: some Scene {
        MenuBarExtra {
            Panel(bridge: bridge)
        } label: {
            Image(systemName: bridge.icon)
        }
        .menuBarExtraStyle(.window)
    }
}
