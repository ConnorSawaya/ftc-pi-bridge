// FTC Bridge: menu bar app for choosing which robot (Control Hub) the Pi joins.
// Every action is one SSH call over the USB link to /usr/local/bin/ftc-hub on the Pi, which
// stores the saved robots. The `ftc-bridge` terminal command uses the same calls.
import ServiceManagement
import SwiftUI
import UserNotifications

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

/// Settings, saved in the app's preferences.
enum Prefs {
    static let showName = "showRobotNameInMenuBar"
    static let notify = "notifyOnConnectionChange"
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
    private var checkedOnce = false    // no notification for the state the app starts in

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
        let before = link
        let result = await Pi.run(["status"])
        if result.ok {
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
        } else {
            link = .noPi
        }
        if checkedOnce && before != link {
            if link == .connected { notify("Connected to \(robot)", "Ready to upload.") }
            else if before == .connected { notify("Lost the robot", subtitle) }
        }
        checkedOnce = true
    }

    private func notify(_ title: String, _ body: String) {
        guard UserDefaults.standard.bool(forKey: Prefs.notify) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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

    func disconnect() async {
        _ = await perform("Leaving the robot's Wi-Fi…") { await Pi.run(["disconnect"]) }
    }

    func power(_ action: String) async {
        let done = await perform(action == "off" ? "Shutting down…" : "Restarting…") { await Pi.run(["power", action]) }
        if done {
            messageIsError = false
            message = action == "off" ? "Unplug the Pi when its green light stays off." : "The Pi is restarting (about a minute)."
        }
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

    func showError(_ text: String) {
        messageIsError = true
        message = text
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

/// A setting with a small switch on the right.
struct SwitchRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

/// A clickable action row: icon, title, a line of detail.
struct ActionRow: View {
    let icon: String
    let title: String
    let detail: String
    var tint: Color = .primary
    var enabled = true
    let action: () -> Void

    var body: some View {
        HoverRow(enabled: enabled, action: action) { _ in
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(enabled ? tint : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(enabled ? tint : Color.secondary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct Panel: View {
    enum Page { case main, settings }

    @ObservedObject var bridge: Bridge
    @State private var page: Page
    @State private var adding: Bool
    @State private var name = ""
    @State private var ssid = ""
    @State private var password = ""

    @AppStorage(Prefs.showName) private var showName = false
    @AppStorage(Prefs.notify) private var notify = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmShutdown = false

    init(bridge: Bridge, page: Page = .main, adding: Bool = false) {
        self.bridge = bridge
        _page = State(initialValue: page)
        _adding = State(initialValue: adding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch page {
            case .main: mainPage
            case .settings: settingsPage
            }
            if !bridge.message.isEmpty { messageLine }
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: Main page

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

    @ViewBuilder private var mainPage: some View {
        header
        if bridge.link != .noPi {
            Divider()
            robotList
            Divider()
            if adding { addForm } else { addButton }
        }
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
            Button { page = .settings } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Settings")
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

    private func closeForm() {
        adding = false
        name = ""; ssid = ""; password = ""
    }

    // MARK: Settings page

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
    }

    @ViewBuilder private var settingsPage: some View {
        HStack(spacing: 6) {
            Button { page = .main; confirmShutdown = false } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Back")
            Text("Settings").font(.headline)
            Spacer()
            if bridge.busy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 4)

        Divider()
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "GENERAL")
            SwitchRow(title: "Open at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
            SwitchRow(title: "Robot name in menu bar", isOn: $showName)
            SwitchRow(title: "Notifications", detail: "When the robot connects or drops", isOn: Binding(get: { notify }, set: setNotify))
        }

        Divider()
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(text: "PI")
            ActionRow(icon: "wifi.slash", title: "Disconnect from robot", detail: "Before a match (rule R704.C)",
                      enabled: !bridge.busy && !bridge.robot.isEmpty) { Task { await bridge.disconnect() } }
            ActionRow(icon: "arrow.clockwise", title: "Restart Pi", detail: "If it stops answering",
                      enabled: !bridge.busy && bridge.link != .noPi) { Task { await bridge.power("reboot") } }
            ActionRow(icon: "power", title: confirmShutdown ? "Click again to shut down" : "Shut down Pi",
                      detail: "Do this before unplugging it", tint: confirmShutdown ? .red : .primary,
                      enabled: !bridge.busy && bridge.link != .noPi) {
                if confirmShutdown {
                    confirmShutdown = false
                    Task { await bridge.power("off") }
                } else {
                    confirmShutdown = true
                }
            }
        }

        Divider()
        HStack {
            Text("FTC Bridge \(version)").font(.caption).foregroundStyle(.secondary)
            Link("GitHub", destination: URL(string: "https://github.com/ConnorSawaya/ftc-pi-bridge")!)
                .font(.caption)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 8)
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            bridge.showError("Couldn't change Open at login: \(error.localizedDescription)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            bridge.showError("Allow FTC Bridge in System Settings › General › Login Items.")
        }
    }

    private func setNotify(_ on: Bool) {
        notify = on
        guard on else { return }
        Task {
            let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            if !allowed {
                notify = false
                bridge.showError("Notifications are off for FTC Bridge in System Settings › Notifications.")
            }
        }
    }

    // MARK: Shared

    private var messageLine: some View {
        Label(bridge.message, systemImage: bridge.messageIsError ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.caption)
            .foregroundStyle(bridge.messageIsError ? Color.orange : Color.secondary)
            .padding(.horizontal, 8)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The menu bar item: the status icon, plus the robot's name if that setting is on.
struct MenuBarLabel: View {
    @ObservedObject var bridge: Bridge
    @AppStorage(Prefs.showName) private var showName = false

    var body: some View {
        if showName && bridge.link != .noPi && !bridge.robot.isEmpty {
            Label(bridge.robot, systemImage: bridge.icon).labelStyle(.titleAndIcon)
        } else {
            Image(systemName: bridge.icon)
        }
    }
}

@main
struct FTCBridgeApp: App {
    @StateObject private var bridge = Bridge()

    var body: some Scene {
        MenuBarExtra {
            Panel(bridge: bridge)
        } label: {
            MenuBarLabel(bridge: bridge)
        }
        .menuBarExtraStyle(.window)
    }
}
