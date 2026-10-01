import AppKit
import Observation

/// One simulator device, from `simctl list devices --json`.
struct SimDevice: Identifiable, Equatable, Sendable {
    let udid: String
    let name: String
    /// "iOS 18.2", from the runtime identifier.
    let runtime: String
    let isBooted: Bool

    var id: String { udid }

    private struct ListDTO: Decodable {
        let devices: [String: [Device]]
        struct Device: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool?
        }
    }

    /// Booted devices first, then the newest runtime's available ones. A UDID
    /// that isn't the expected shape is dropped — it becomes an argument.
    static func parse(_ data: Data) throws -> [SimDevice] {
        let list = try JSONDecoder().decode(ListDTO.self, from: data)
        var devices: [SimDevice] = []
        for (runtime, entries) in list.devices {
            let label = runtimeLabel(runtime)
            for entry in entries where entry.isAvailable != false && isUDID(entry.udid) {
                devices.append(SimDevice(udid: entry.udid, name: entry.name, runtime: label, isBooted: entry.state == "Booted"))
            }
        }
        return devices.sorted {
            if $0.isBooted != $1.isBooted { return $0.isBooted }
            if $0.runtime != $1.runtime { return $0.runtime.compare($1.runtime, options: .numeric) == .orderedDescending }
            return $0.name.compare($1.name, options: .numeric) == .orderedAscending
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-18-2` → "iOS 18.2".
    static func runtimeLabel(_ identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let parts = last.split(separator: "-")
        guard let os = parts.first, parts.count > 1 else { return last }
        return "\(os) " + parts.dropFirst().joined(separator: ".")
    }

    static func isUDID(_ text: String) -> Bool {
        text.range(of: "^[0-9A-Fa-f-]{36}$", options: .regularExpression) != nil
    }
}

/// The Simulators page: what's booted, and one-click jobs on it — a
/// screenshot or recording into the Stash, a deep link, a test push, light
/// or dark appearance, a clean 9:41 status bar, erase.
///
/// Everything goes through `xcrun simctl`, with an argument array and never a
/// shell. The list is read when the page appears and after each action; no
/// polling.
@MainActor
@Observable
final class SimulatorStore {
    private(set) var devices: [SimDevice] = []
    var selectedID: String?
    private(set) var busy: String?
    private(set) var message: String?
    private(set) var isRecording = false
    private(set) var toolsMissing = false
    var confirmingErase = false

    /// A screenshot or recording is ready to go into the Stash.
    @ObservationIgnored var onCapture: ((URL) -> Void)?

    @ObservationIgnored private var recorder: Process?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    static let xcrun = "/usr/bin/xcrun"

    var booted: [SimDevice] { devices.filter(\.isBooted) }
    var selected: SimDevice? { booted.first { $0.udid == selectedID } ?? booted.first }

    /// A handful of devices to boot when none is running.
    var bootable: [SimDevice] {
        let newest = devices.first(where: { !$0.isBooted })?.runtime
        return Array(devices.filter { !$0.isBooted && $0.runtime == newest }.prefix(6))
    }

    func refresh() {
        Task { [weak self] in
            guard await CommandRunner.developerToolsInstalled() else {
                self?.toolsMissing = true
                return
            }
            let out = try? await CommandRunner.run(Self.xcrun, ["simctl", "list", "devices", "--json"])
            guard let self else { return }
            toolsMissing = false
            if let out, out.succeeded, let parsed = try? SimDevice.parse(Data(out.stdout.utf8)) {
                devices = parsed
                if selected == nil { selectedID = booted.first?.udid }
            } else {
                show(out?.failureReason ?? L10n.string("simctl is not available."))
            }
        }
    }

    // MARK: - Actions

    func boot(_ device: SimDevice) {
        run(L10n.string("Booting…"), ["simctl", "boot", device.udid]) { [weak self] in
            self?.selectedID = device.udid
            self?.openSimulatorApp()
        }
    }

    func openSimulatorApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iphonesimulator") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func screenshot() {
        guard let device = selected else { return }
        let url = Self.captureURL(device, ext: "png")
        run(L10n.string("Taking screenshot…"), ["simctl", "io", device.udid, "screenshot", "--type=png", url.path]) { [weak self] in
            self?.onCapture?(url)
            self?.show(L10n.string("Screenshot added to Stash"))
        }
    }

    /// Recording runs until stopped. `simctl` finishes writing the file when
    /// it receives SIGINT, the same as pressing ⌃C in Terminal.
    func toggleRecording() {
        if let recorder {
            recorder.interrupt()
            return
        }
        guard let device = selected else { return }
        let url = Self.captureURL(device, ext: "mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.xcrun)
        process.arguments = ["simctl", "io", device.udid, "recordVideo", "--codec=h264", "--force", url.path]
        process.environment = CommandRunner.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.recordingEnded() }
        }
        do {
            try process.run()
            recorder = process
            recordingURL = url
            isRecording = true
        } catch {
            show(error.localizedDescription)
        }
    }

    private func recordingEnded() {
        isRecording = false
        recorder = nil
        if let url = recordingURL, FileManager.default.fileExists(atPath: url.path) {
            onCapture?(url)
            show(L10n.string("Recording added to Stash"))
        }
        recordingURL = nil
    }

    func setAppearance(dark: Bool) {
        guard let device = selected else { return }
        run(nil, ["simctl", "ui", device.udid, "appearance", dark ? "dark" : "light"])
    }

    /// The status bar from Apple's marketing shots: 9:41, full battery and bars.
    func cleanStatusBar() {
        guard let device = selected else { return }
        run(nil, ["simctl", "status_bar", device.udid, "override", "--time", "9:41", "--dataNetwork", "wifi",
                  "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
                  "--batteryState", "charged", "--batteryLevel", "100"]) { [weak self] in
            self?.show(L10n.string("Status bar set to 9:41"))
        }
    }

    func resetStatusBar() {
        guard let device = selected else { return }
        run(nil, ["simctl", "status_bar", device.udid, "clear"])
    }

    /// Any scheme the app under test registers (`myapp://…`) as well as
    /// web links; refused only when it isn't a URL at all.
    func openURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let device = selected, let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty,
              !trimmed.hasPrefix("-") else {
            show(L10n.string("Enter a full URL, e.g. myapp://path"))
            return false
        }
        run(nil, ["simctl", "openurl", device.udid, trimmed])
        return true
    }

    /// A simple alert push for `bundleID`, written to a private temporary
    /// file that `simctl push` reads.
    func sendPush(bundleID: String, message: String) {
        let bundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let device = selected,
              bundle.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil else {
            show(L10n.string("Enter the app's bundle identifier"))
            return
        }
        let payload: [String: Any] = ["aps": ["alert": ["title": "MyHub", "body": message.isEmpty ? "Test notification" : message], "sound": "default"]]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("myhub-push-\(UUID().uuidString).apns")
        guard let data = try? JSONSerialization.data(withJSONObject: payload), (try? AppPaths.writePrivate(data, to: file)) != nil else { return }
        run(L10n.string("Sending push…"), ["simctl", "push", device.udid, bundle, file.path]) { [weak self] in
            try? FileManager.default.removeItem(at: file)
            self?.show(L10n.string("Push sent"))
        }
    }

    /// Shut down, erase, boot again — a factory-fresh device.
    func erase() {
        confirmingErase = false
        guard let device = selected else { return }
        busy = L10n.string("Erasing…")
        Task { [weak self] in
            _ = try? await CommandRunner.run(Self.xcrun, ["simctl", "shutdown", device.udid], timeout: .seconds(60))
            let erased = try? await CommandRunner.run(Self.xcrun, ["simctl", "erase", device.udid], timeout: .seconds(120))
            _ = try? await CommandRunner.run(Self.xcrun, ["simctl", "boot", device.udid], timeout: .seconds(120))
            guard let self else { return }
            busy = nil
            show(erased?.succeeded == true ? L10n.string("Erased") : (erased?.failureReason ?? L10n.string("Erase failed")))
            refresh()
        }
    }

    // MARK: - Helpers

    private func run(_ status: String?, _ arguments: [String], then: (@MainActor () -> Void)? = nil) {
        busy = status
        Task { [weak self] in
            let out = try? await CommandRunner.run(Self.xcrun, arguments, timeout: .seconds(90))
            guard let self else { return }
            busy = nil
            if let out, out.succeeded {
                then?()
            } else {
                show(out?.failureReason ?? L10n.string("simctl failed"))
            }
            refresh()
        }
    }

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.message = nil }
        }
    }

    /// Captures share the folder with copied screenshots.
    private static func captureURL(_ device: SimDevice, ext: String) -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let name = "\(device.name) \(stamp).\(ext)".replacingOccurrences(of: "/", with: "-")
        return AppPaths.directory("Captures").appendingPathComponent(name)
    }

    func stop() {
        recorder?.interrupt()
    }

    #if DEBUG
    func injectForPreview(_ devices: [SimDevice]) {
        self.devices = devices
        selectedID = devices.first(where: \.isBooted)?.udid
    }
    #endif
}
