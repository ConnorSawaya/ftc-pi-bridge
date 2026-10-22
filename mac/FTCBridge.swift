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
    @Published var robots: [Robot] = []
    @Published var nearby: [String] = []
    @Published var message = ""
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

    var status: String {
        switch link {
        case .connected: "Connected to \(robot)"
        case .noHub: robot.isEmpty ? "Pi plugged in · no robot chosen" : "\(robot) isn't answering. Robot on?"
        case .noPi: "Pi not plugged in"
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
        link = fields["hub"] == "up" ? .connected : .noHub
    }

    func scan() async {
        await perform("Looking for robots…") {
            let result = await Pi.run(["scan"])
            self.nearby = result.ok ? result.output.split(separator: "\n").map(String.init) : []
            return !result.ok ? "Couldn't reach the Pi" : self.nearby.isEmpty ? "No networks found" : ""
        }
    }

    func use(_ name: String) async {
        await perform("Switching to \(name)…") { await Pi.run(["use", name]).output }
    }

    func forget(_ name: String) async {
        await perform("") { await Pi.run(["forget", name]).output }
    }

    func add(name: String, ssid: String, password: String) async {
        await perform("Saving \(name)…") {
            let saved = await Pi.run(["add", name], input: ssid + "\n" + password + "\n")
            guard saved.ok else { return saved.output }
            self.message = "Connecting to \(name)…"
            return await Pi.run(["use", name]).output
        }
    }

    /// Shows `start` while `work` runs, then whatever message it returns.
    private func perform(_ start: String, _ work: () async -> String) async {
        busy = true
        message = start
        let result = await work()
        message = result.isEmpty && link == .noPi ? "Couldn't reach the Pi" : result
        await refresh()
        busy = false
    }
}

struct Panel: View {
    @ObservedObject var bridge: Bridge
    @State private var name = ""
    @State private var ssid = ""
    @State private var password = ""

    private var finalName: String { name.isEmpty ? robotName(from: ssid) : name }

    private var canSave: Bool {
        !bridge.busy && bridge.link != .noPi && !ssid.isEmpty && password.count >= 8
            && !finalName.isEmpty && robotName(from: finalName) == finalName
            && !ssid.contains("\n") && !password.contains("\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(bridge.status, systemImage: bridge.icon).font(.headline)

            if !bridge.robots.isEmpty {
                Divider()
                Text("Robots").font(.subheadline).foregroundStyle(.secondary)
                ForEach(bridge.robots, id: \.self) { r in
                    HStack {
                        Image(systemName: r.name == bridge.robot ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(r.name == bridge.robot ? Color.accentColor : .secondary)
                        Button("\(r.name)  ·  \(r.ssid)") { Task { await bridge.use(r.name) } }
                            .buttonStyle(.plain)
                            .disabled(bridge.busy)
                        Spacer()
                        Button { Task { await bridge.forget(r.name) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Forget \(r.name)")
                            .disabled(bridge.busy)
                    }
                }
            }

            Divider()
            HStack {
                Text("Add a robot").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Scan") { Task { await bridge.scan() } }
                    .disabled(bridge.busy || bridge.link == .noPi)
            }
            if !bridge.nearby.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(bridge.nearby, id: \.self) { network in
                            Button(network) { ssid = network }.buttonStyle(.link)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            TextField("Wi-Fi name", text: $ssid)
            SecureField("Wi-Fi password", text: $password)
            TextField("Nickname (optional, e.g. comp)", text: $name)
            HStack {
                Button("Save & Connect") {
                    let n = finalName
                    Task {
                        await bridge.add(name: n, ssid: ssid, password: password)
                        password = ""; name = ""; ssid = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                if bridge.busy { ProgressView().controlSize(.small) }
            }
            if !bridge.message.isEmpty {
                Text(bridge.message).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Button("Quit FTC Bridge") { NSApp.terminate(nil) }
        }
        .padding()
        .frame(width: 300)
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
