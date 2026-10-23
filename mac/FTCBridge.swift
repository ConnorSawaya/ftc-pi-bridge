// FTC Bridge: menu bar app for choosing which robot (Control Hub) the Pi joins.
// Every action is one SSH call over the USB link to /usr/local/bin/ftc-hub on the Pi, which
// stores the saved robots. The `ftc-bridge` terminal command uses the same calls.
import ServiceManagement
import SwiftUI
import UserNotifications

/// Runs a program and returns whether it succeeded and what it printed. `input` goes to its stdin.
func execute(_ path: String, _ args: [String], input: String? = nil) async -> (ok: Bool, output: String) {
    await withCheckedContinuation { done in
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let stdout = Pipe(), stdin = Pipe()
            process.standardOutput = stdout
            process.standardError = stdout
            process.standardInput = stdin
            do { try process.run() } catch { return done.resume(returning: (false, "\(error)")) }
            if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
            try? stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            done.resume(returning: (process.terminationStatus == 0, text))
        }
    }
}

enum Pi {
    static let login = "ftc@10.12.194.1"
    static let key = NSHomeDirectory() + "/.ssh/ftcpi"

    /// Runs `ftc-hub <args>` on the Pi. `input` goes to its stdin, so the Wi-Fi
    /// password never appears in a command line.
    static func run(_ args: [String], input: String? = nil) async -> (ok: Bool, output: String) {
        await execute("/usr/bin/ssh", [
            "-i", key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "LogLevel=ERROR",
            // The Pi gets a new host key each time its card is reflashed, and it's on
            // a direct USB cable, so don't pin the key.
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            login, "sudo", "/usr/local/bin/ftc-hub",
        ] + args, input: input)
    }
}

/// adb on this Mac, talking to the robot through the Pi's forwarder.
enum ADB {
    static let serial = "10.12.194.1:5555"
    /// Panels: 8001 web page, 8002 live data (the page connects to <its own host>:8002);
    /// 5800/5801/5805/5807: the Limelight, which the Panels Limelight plugin passes through the hub.
    static let panelsPorts = [8001, 8002, 5800, 5801, 5805, 5807]

    /// Apps opened from Finder don't get the shell's PATH, so look in the usual places.
    static let path: String? = [
        NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    static func run(_ args: [String]) async -> (ok: Bool, output: String) {
        guard let path else { return (false, "adb not found. Install Android Studio (it includes adb).") }
        return await execute(path, args)
    }

    /// Fresh connection to whichever robot the Pi is on now (drops a stale one to the last robot).
    static func connect() async -> Bool {
        _ = await run(["disconnect", serial])
        return await run(["connect", serial]).output.contains("connected to")
    }

    static func isConnected() async -> Bool {
        await run(["-s", serial, "get-state"]).output == "device"
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
    static let autoADB = "connectAndroidStudioAutomatically"
    static let crashAlerts = "crashAlerts"

    static func register() {
        UserDefaults.standard.register(defaults: [autoADB: true, crashAlerts: true])
    }
}

/// The `ftc-bridge` command, bundled inside the app (build.sh copies it in).
enum BridgeCLI {
    static let path = Bundle.main.path(forResource: "ftc-bridge", ofType: nil)
    static let backupsFolder = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/ftc-pi-bridge/backups")

    static func run(_ args: [String]) async -> (ok: Bool, output: String) {
        guard let path else { return (false, "ftc-bridge is missing from the app. Rebuild it with mac/build.sh.") }
        return await execute("/bin/bash", [path] + args)
    }
}

/// What `ftc-hub health` and adb say about the connection to the robot.
struct Health {
    var signal: Int?           // 0-100
    var freq = ""              // e.g. "2437 MHz"
    var channel = ""
    var rate = ""              // e.g. "65 Mbit/s"
    var robotApp = false
    var sdk = ""
    var hubSerial = ""
    var sameHub = ""           // yes, first_time or no
    var adb = false
    var adbSerial = ""

    var band: String { freq.hasPrefix("5") ? "5 GHz" : freq.hasPrefix("2") ? "2.4 GHz" : "" }
    var rightRobot: Bool { sameHub != "no" && (adbSerial.isEmpty || hubSerial.isEmpty || adbSerial == hubSerial) }
}

/// A crash or exception found in the robot's log.
struct Crash: Equatable {
    let id: String             // the log line that reported it (it includes the time)
    let summary: String        // e.g. "NullPointerException: Attempt to invoke ... on a null object reference"
    let location: String       // e.g. "MyTeleOp.java:212", or "" if not in team code
    let time: String
    let text: String           // the whole block, to copy for an AI or a teammate

    /// What the FTC SDK and Android log when robot code throws, freezes or crashes the app.
    static let triggers = ["User code threw an uncaught exception", "User OpMode was stuck in", "FATAL EXCEPTION"]

    /// Finds crashes in `logcat -v time` output.
    static func find(in log: String) -> [Crash] {
        let lines = log.components(separatedBy: "\n")
        func message(_ line: String) -> String {
            guard let r = line.range(of: "): ") else { return line }
            return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return lines.indices.compactMap { i in
            let line = lines[i]
            guard triggers.contains(where: line.contains) else { return nil }
            let block = Array(lines[i..<min(i + 15, lines.count)])
            let exception = block.dropFirst().map(message).first { $0.contains("Exception") || $0.contains("Error") }
            var location = ""
            if let frame = block.first(where: { $0.contains("at org.firstinspires.ftc.teamcode.") }),
               let open = frame.lastIndex(of: "("), let close = frame.lastIndex(of: ")"), open < close {
                location = String(frame[frame.index(after: open)..<close])
            }
            // "10-22 18:01:02.200 E/..." -> "18:01:02"
            let time = line.split(separator: " ").dropFirst().first.map { String($0.prefix(8)) } ?? ""
            return Crash(id: line, summary: exception ?? message(line), location: location, time: time,
                         text: block.joined(separator: "\n"))
        }
    }
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
    @Published var scanning = false
    @Published var health: Health?
    @Published var speed = ""          // last speed test, e.g. "3.2 MB/s"
    @Published var lastCrash: Crash?
    @Published var piOutdated = false  // the Pi's software is older than the copy in this app
    private var checkPiVersionSoon = true
    private var checkedOnce = false    // no notification for the state the app starts in
    private var adbRobot = ""          // robot adb is connected to, so a switch reconnects it
    private var seenCrashes: Set<String> = []
    private var crashBaselineRobot = ""  // crashes already in the log when we connected aren't alerted

    init() {
        Task {
            var tick = 0
            while true {
                await refresh()
                if checkPiVersionSoon || tick % 12 == 0 { await checkPiVersion() }  // every minute
                if tick % 2 == 0 { await checkCrashes() }    // every 10 s
                if tick % 3 == 0 { await refreshHealth() }   // every 15 s
                tick += 1
                try? await Task.sleep(for: .seconds(5))
            }
        }
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
        if before == .noPi && link != .noPi { checkPiVersionSoon = true }  // just plugged in
        // Keep adb connected to the robot so it shows up in Android Studio by itself.
        if link == .connected && UserDefaults.standard.bool(forKey: Prefs.autoADB) && ADB.path != nil {
            let stillConnected = adbRobot == robot ? await ADB.isConnected() : false
            if !stillConnected {
                adbRobot = await ADB.connect() ? robot : ""
            }
        } else if link != .connected {
            adbRobot = ""
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
        scanning = true
        message = ""
        let result = await Pi.run(["scan"])
        if result.ok { nearby = result.output.split(separator: "\n").map(String.init) } else { showError("Couldn't reach the Pi") }
        scanning = false
        busy = false
    }

    func use(_ name: String) async {
        speed = ""
        health = nil
        _ = await perform("Switching to \(name)…") { await Pi.run(["use", name]) }
        await refreshHealth()
    }

    func forget(_ name: String) async {
        _ = await perform("Forgetting \(name)…") { await Pi.run(["forget", name]) }
    }

    func refreshHealth() async {
        guard link != .noPi, !robot.isEmpty else { health = nil; return }
        let result = await Pi.run(["health"])
        guard result.ok else { return }
        var f: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            if let eq = line.firstIndex(of: "=") { f[String(line[..<eq])] = String(line[line.index(after: eq)...]) }
        }
        var h = Health()
        h.signal = f["signal"].flatMap { Int($0) }
        h.freq = f["freq"] ?? ""
        h.channel = f["channel"] ?? ""
        h.rate = f["rate"] ?? ""
        h.robotApp = f["rc_app"] == "up"
        h.sdk = f["sdkVersion"] ?? ""
        h.hubSerial = f["serialNumber"] ?? ""
        h.sameHub = f["same_hub"] ?? ""
        if f["adb_port"] == "open" && ADB.path != nil, await ADB.isConnected() {
            h.adb = true
            h.adbSerial = await ADB.run(["-s", ADB.serial, "shell", "getprop", "ro.serialno"]).output
        }
        health = h
    }

    /// Looks for new crashes in the robot's log and alerts once per crash.
    func checkCrashes() async {
        guard UserDefaults.standard.bool(forKey: Prefs.crashAlerts), link == .connected, !adbRobot.isEmpty else { return }
        let result = await ADB.run(["-s", ADB.serial, "logcat", "-d", "-v", "time", "-t", "1500"])
        guard result.ok else { return }
        let crashes = Crash.find(in: result.output)
        if crashBaselineRobot != adbRobot {
            seenCrashes = Set(crashes.map(\.id))
            crashBaselineRobot = adbRobot
            return
        }
        for crash in crashes where !seenCrashes.contains(crash.id) {
            seenCrashes.insert(crash.id)
            lastCrash = crash
            let content = UNMutableNotificationContent()
            content.title = "Robot code crashed on \(robot)"
            content.body = crash.location.isEmpty ? crash.summary : "\(crash.summary)\nat \(crash.location)"
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: crash.id, content: content, trigger: nil))
        }
    }

    func checkPiVersion() async {
        guard link != .noPi else { return }
        checkPiVersionSoon = false
        let result = await BridgeCLI.run(["pi-version"])
        var f: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            if let eq = line.firstIndex(of: "=") { f[String(line[..<eq])] = String(line[line.index(after: eq)...]) }
        }
        if let installed = f["installed"], let latest = f["latest"] { piOutdated = installed != latest }
    }

    func updatePi() async {
        busy = true
        messageIsError = false
        message = "Updating the Pi…"
        let result = await BridgeCLI.run(["update-pi"])
        busy = false
        await checkPiVersion()
        if result.ok && !piOutdated { message = "The Pi is up to date." }
        else { showError(result.output.split(separator: "\n").last.map(String.init) ?? "Updating the Pi failed") }
        await refreshHealth()
    }

    func speedTest() async {
        busy = true
        messageIsError = false
        message = "Sending 8 MB to the robot…"
        let result = await BridgeCLI.run(["speedtest"])
        busy = false
        if result.ok, let r = result.output.range(of: #"[0-9.]+ MB/s"#, options: .regularExpression) {
            speed = String(result.output[r])
            message = ""
        } else {
            showError(result.output.split(separator: "\n").last.map(String.init) ?? "Speed test failed")
        }
    }

    func backupNow() async {
        busy = true
        messageIsError = false
        message = "Backing up \(robot)…"
        let result = await BridgeCLI.run(["backup"])
        busy = false
        if result.ok { message = result.output.split(separator: "\n").last.map(String.init) ?? "Backed up." }
        else { showError(result.output.split(separator: "\n").last.map(String.init) ?? "Backup failed") }
    }

    /// Tunnels the robot's Panels dashboard to this Mac and opens it in the browser.
    func openPanels() async {
        busy = true
        messageIsError = false
        message = "Opening Panels…"
        defer { busy = false }
        if !(await ADB.isConnected()) {
            guard await ADB.connect() else {
                return showError(ADB.path == nil ? "adb not found. Install Android Studio (it includes adb)." : "Couldn't reach the robot. Is it on?")
            }
            adbRobot = robot
        }
        for port in ADB.panelsPorts {
            let result = await ADB.run(["-s", ADB.serial, "forward", "tcp:\(port)", "tcp:\(port)"])
            if !result.ok { return showError("Port \(port) is busy on this Mac. Close what's using it and try again.") }
        }
        message = ""
        NSWorkspace.shared.open(URL(string: "http://localhost:8001")!)
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

/// One line of the health card: icon, label, value, and a green/orange dot (none if `good` is nil).
struct HealthRow: View {
    let icon: String
    let label: String
    let value: String
    let good: Bool?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1)
            if let good {
                Circle().fill(good ? Color.green : Color.orange).frame(width: 7, height: 7)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
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
    @AppStorage(Prefs.autoADB) private var autoADB = true
    @AppStorage(Prefs.crashAlerts) private var crashAlerts = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmShutdown = false

    init(bridge: Bridge, page: Page = .main, adding: Bool = false, picked: String = "") {
        self.bridge = bridge
        _page = State(initialValue: page)
        _adding = State(initialValue: adding)
        _ssid = State(initialValue: picked)
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

    /// Scan results, minus robots already saved; ones that look like robots first.
    private var newNetworks: [String] {
        let unsaved = bridge.nearby.filter { network in !bridge.robots.contains { $0.ssid == network } }
        return unsaved.filter(looksLikeRobot) + unsaved.filter { !looksLikeRobot($0) }
    }

    /// FTC robot Wi-Fi names: FTC-xxxx (Control Hub default), 12345-RC, DIRECT-xx (phone RCs), "Control Hub".
    private func looksLikeRobot(_ network: String) -> Bool {
        network.range(of: #"ftc|-rc$|^[0-9]{3,5}-|^direct-|control ?hub"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private var finalName: String { name.isEmpty ? robotName(from: ssid) : name }

    private var canSave: Bool {
        !bridge.busy && !ssid.isEmpty && password.count >= 8
            && !finalName.isEmpty && robotName(from: finalName) == finalName
            && !ssid.contains("\n") && !password.contains("\n")
    }

    @ViewBuilder private var mainPage: some View {
        header
        if bridge.piOutdated && bridge.link != .noPi {
            ActionRow(icon: "arrow.down.circle.fill", title: "Update the Pi", detail: "New Pi software from this Mac (about 10 s)",
                      tint: .accentColor, enabled: !bridge.busy) { Task { await bridge.updatePi() } }
        }
        if bridge.link == .connected {
            ActionRow(icon: "chart.xyaxis.line", title: "Open Panels", detail: "Telemetry, graphs, OpMode control",
                      enabled: !bridge.busy) { Task { await bridge.openPanels() } }
        }
        if let crash = bridge.lastCrash { crashCard(crash) }
        if bridge.link != .noPi {
            if !bridge.robot.isEmpty {
                Divider()
                healthCard
            }
            Divider()
            robotList
            Divider()
            if adding { addForm } else { addButton }
        }
    }

    private func crashCard(_ crash: Crash) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Robot code crashed", systemImage: "exclamationmark.octagon.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.red)
                Spacer()
                Text(crash.time).font(.caption2).foregroundStyle(.secondary)
                Button { bridge.lastCrash = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Dismiss")
            }
            Text(crash.summary).font(.caption).lineLimit(3)
            if !crash.location.isEmpty {
                Text("at \(crash.location)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(crash.text, forType: .string)
            } label: { Label("Copy error", systemImage: "doc.on.doc") }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
    }

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionTitle(text: "HEALTH")
            if let h = bridge.health {
                HealthRow(icon: "wifi", label: "Wi-Fi",
                          value: h.signal.map { "\($0)%" + (h.band.isEmpty ? "" : " · \(h.band)") + (h.channel.isEmpty ? "" : " ch \(h.channel)") } ?? "Not connected",
                          good: (h.signal ?? 0) >= 40)
                HealthRow(icon: "app.badge.checkmark", label: "Robot app",
                          value: h.robotApp ? "Running" + (h.sdk.isEmpty ? "" : " · SDK \(h.sdk)") : "Not answering",
                          good: h.robotApp)
                HealthRow(icon: "cable.connector", label: "adb",
                          value: h.adb ? "Connected" : "Not connected", good: h.adb)
                HealthRow(icon: "checkmark.shield", label: "Right robot",
                          value: !h.rightRobot ? "Different hub!" : h.sameHub == "first_time" ? "Hub saved" : h.hubSerial.isEmpty ? "Unknown" : "Same hub",
                          good: h.rightRobot && !h.hubSerial.isEmpty)
                HStack {
                    HealthRow(icon: "speedometer", label: "Upload speed", value: bridge.speed.isEmpty ? "–" : bridge.speed, good: nil)
                    Button("Test") { Task { await bridge.speedTest() } }
                        .buttonStyle(.borderless).font(.caption)
                        .disabled(bridge.busy || !h.adb)
                }
            } else {
                Text("Checking…").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
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
            Task { await bridge.scan() }
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
                Button { Task { await bridge.scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(bridge.busy)
            }
            networkPicker
            if !ssid.isEmpty {
                Group {
                    SecureField("Password for \(ssid)", text: $password)
                    TextField("Nickname (optional, e.g. comp)", text: $name)
                }
                .textFieldStyle(.roundedBorder)
            }
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

    /// The list of nearby Wi-Fi to pick the robot from. Always shown while adding a robot.
    private var networkPicker: some View {
        Group {
            if newNetworks.isEmpty {
                HStack(spacing: 8) {
                    if bridge.scanning {
                        ProgressView().controlSize(.small)
                        Text("Looking for robots…")
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        Text("No new robots found. Is the robot on?")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(newNetworks, id: \.self) { network in
                            let robotLike = looksLikeRobot(network)
                            let picked = network == ssid
                            HoverRow(action: { ssid = network }) { _ in
                                HStack(spacing: 8) {
                                    Image(systemName: robotLike ? "antenna.radiowaves.left.and.right" : "wifi")
                                        .frame(width: 18)
                                        .foregroundStyle(robotLike ? Color.accentColor : Color.secondary)
                                    Text(network).lineLimit(1)
                                        .foregroundStyle(robotLike ? Color.primary : Color.secondary)
                                    Spacer()
                                    if picked { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 6).fill(picked ? Color.accentColor.opacity(0.15) : .clear))
                        }
                    }
                    .padding(2)
                }
                .frame(height: min(CGFloat(newNetworks.count) * 30 + 6, 160))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func closeForm() {
        adding = false
        name = ""; ssid = ""; password = ""
    }

    // MARK: Settings page

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.4"
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
            SwitchRow(title: "Connect Android Studio", detail: "The robot shows up in Android Studio by itself", isOn: $autoADB)
            SwitchRow(title: "Notifications", detail: "When the robot connects or drops", isOn: Binding(get: { notify }, set: setNotify))
            SwitchRow(title: "Crash alerts", detail: "When robot code throws or freezes", isOn: Binding(get: { crashAlerts }, set: setCrashAlerts))
        }

        Divider()
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(text: "ROBOT")
            ActionRow(icon: "externaldrive.badge.timemachine", title: "Back up robot", detail: "Its configs and app, to this Mac",
                      enabled: !bridge.busy && bridge.link == .connected) { Task { await bridge.backupNow() } }
            ActionRow(icon: "folder", title: "Show backups", detail: "Restore with ftc-bridge restore") {
                try? FileManager.default.createDirectory(at: BridgeCLI.backupsFolder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(BridgeCLI.backupsFolder)
            }
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

    private func setCrashAlerts(_ on: Bool) {
        crashAlerts = on
        if on { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) } }
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

    init() {
        Prefs.register()
        if UserDefaults.standard.bool(forKey: Prefs.crashAlerts) {
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel(bridge: bridge)
        } label: {
            MenuBarLabel(bridge: bridge)
        }
        .menuBarExtraStyle(.window)
    }
}
