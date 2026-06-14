import AppKit
import Darwin
import Foundation

private let tunnelPort = 4173

private enum BackendState: Equatable {
    case stopped
    case preparing
    case starting
    case running
    case failed(String)

    var label: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .preparing:
            return "Preparing"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }
}

private struct LauncherError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private final class HomeAgentManager {
    let supportRoot: URL
    let stateDir: URL
    let logsDir: URL
    let wireguardDir: URL
    let pythonRoot: URL
    let managedPythonDir: URL
    let sourceRoot: URL
    let webURL = URL(string: "http://127.0.0.1:\(tunnelPort)")!

    var onStateChange: ((BackendState) -> Void)?

    private(set) var state: BackendState = .stopped {
        didSet {
            DispatchQueue.main.async { [state, onStateChange] in
                onStateChange?(state)
            }
        }
    }

    private var process: Process?
    private var logHandle: FileHandle?
    private var outputPipe: Pipe?
    private var selectedPythonPath: String?
    private var expectedStop = false

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        supportRoot = home.appendingPathComponent(".tatertunnel", isDirectory: true)
        stateDir = supportRoot.appendingPathComponent("state", isDirectory: true)
        logsDir = supportRoot.appendingPathComponent("logs", isDirectory: true)
        wireguardDir = supportRoot.appendingPathComponent("wireguard", isDirectory: true)
        pythonRoot = supportRoot.appendingPathComponent("python", isDirectory: true)
        managedPythonDir = pythonRoot.appendingPathComponent("cpython-3.11", isDirectory: true)
        sourceRoot = HomeAgentManager.resolveSourceRoot(supportRoot: supportRoot)
    }

    func start() {
        if process?.isRunning == true {
            state = .running
            return
        }

        appendLauncherLog("Start requested.\n")
        state = .preparing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.ensureFolders()
                try self.ensurePythonRuntime()

                if self.isWebReady() {
                    self.appendLauncherLog("Home Agent already answered on \(self.webURL.absoluteString).\n")
                    self.state = .running
                    return
                }

                try self.launchHomeAgent()
            } catch {
                self.appendLauncherLog("Start failed: \(error.localizedDescription)\n")
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func stop(waitForExit: Bool = false) {
        guard let process else {
            state = .stopped
            return
        }

        appendLauncherLog("Stop requested.\n")
        if process.isRunning {
            expectedStop = true
            process.terminate()
            if waitForExit {
                let deadline = Date().addingTimeInterval(8)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
            }
        }

        closeLogHandle()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        self.process = nil
        state = .stopped
    }

    func restart() {
        stop(waitForExit: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.start()
        }
    }

    func openUI() {
        NSWorkspace.shared.open(webURL)
    }

    func openLogsFolder() {
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([logsDir])
    }

    private static func resolveSourceRoot(supportRoot: URL) -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["TATER_TUNNEL_SOURCE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath, isDirectory: true)
        }

        if let bundledSource = Bundle.main.resourceURL?.appendingPathComponent("TaterTunnelSource", isDirectory: true),
           FileManager.default.fileExists(atPath: bundledSource.appendingPathComponent("tater_tunnel/home_agent.py").path) {
            return bundledSource
        }

        let installedSource = supportRoot
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
        if FileManager.default.fileExists(atPath: installedSource.appendingPathComponent("tater_tunnel/home_agent.py").path) {
            return installedSource
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    private func ensureFolders() throws {
        for folder in [supportRoot, stateDir, logsDir, wireguardDir, pythonRoot] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        guard FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("tater_tunnel/home_agent.py").path) else {
            throw LauncherError("Could not find the bundled Tater Tunnel Home Agent source.")
        }
    }

    private func ensurePythonRuntime() throws {
        let managedPython = managedPythonDir.appendingPathComponent("bin/python3.11").path
        if isUsablePython(managedPython) {
            selectedPythonPath = managedPython
            appendLauncherLog("Using managed Python: \(managedPython)\n")
            return
        }

        for candidate in systemPythonCandidates() where isUsablePython(candidate) {
            selectedPythonPath = candidate
            appendLauncherLog("Using local Python: \(candidate)\n")
            return
        }

        try installManagedPython()
    }

    private func systemPythonCandidates() -> [String] {
        [
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/opt/python@3.11/bin/python3.11",
            "/opt/homebrew/bin/python3.11",
            "/usr/local/bin/python3.13",
            "/usr/local/bin/python3.12",
            "/usr/local/opt/python@3.11/bin/python3.11",
            "/usr/local/bin/python3.11",
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3.13",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11",
            "/usr/bin/python3"
        ]
    }

    private func isUsablePython(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-c", "import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func installManagedPython() throws {
        try FileManager.default.createDirectory(at: pythonRoot, withIntermediateDirectories: true)

        let assetURL = try findStandalonePythonAssetURL()
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tater-tunnel-python-\(UUID().uuidString).tar.gz")
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tater-tunnel-python-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: extractDir)
        }

        appendLauncherLog("Downloading managed Python from \(assetURL.absoluteString)\n")
        try downloadFile(from: assetURL, to: archiveURL)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try runCheckedProcess(
            executable: "/usr/bin/tar",
            arguments: ["-xzf", archiveURL.path, "-C", extractDir.path],
            currentDirectory: nil
        )

        let extractedRoot = try findExtractedPythonRoot(in: extractDir)
        if FileManager.default.fileExists(atPath: managedPythonDir.path) {
            try FileManager.default.removeItem(at: managedPythonDir)
        }
        try FileManager.default.moveItem(at: extractedRoot, to: managedPythonDir)

        let python = managedPythonDir.appendingPathComponent("bin/python3.11").path
        guard isUsablePython(python) else {
            throw LauncherError("Managed Python installed, but \(python) did not run.")
        }
        selectedPythonPath = python
        appendLauncherLog("Managed Python ready: \(python)\n")
    }

    private func findStandalonePythonAssetURL() throws -> URL {
        let releasesURL = URL(string: "https://api.github.com/repos/astral-sh/python-build-standalone/releases?per_page=20")!
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TaterTunnel", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let data = try loadData(from: request)
        guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LauncherError("Could not read python-build-standalone releases.")
        }

        let targetArch = standalonePythonArch()
        for release in releases {
            guard let assets = release["assets"] as? [[String: Any]] else {
                continue
            }
            for asset in assets {
                guard
                    let name = asset["name"] as? String,
                    let rawURL = asset["browser_download_url"] as? String,
                    name.hasPrefix("cpython-3.11."),
                    name.contains("-\(targetArch)-apple-darwin-install_only.tar.gz"),
                    !name.contains("stripped"),
                    let url = URL(string: rawURL)
                else {
                    continue
                }
                return url
            }
        }

        throw LauncherError("Could not find a standalone Python 3.11 build for \(targetArch)-apple-darwin.")
    }

    private func standalonePythonArch() -> String {
        #if arch(arm64)
        return "aarch64"
        #else
        return "x86_64"
        #endif
    }

    private func loadData(from request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(LauncherError("Request failed with HTTP \(http.statusCode)."))
            } else {
                result = .success(data ?? Data())
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        guard let result else {
            throw LauncherError("Request did not complete.")
        }
        return try result.get()
    }

    private func downloadFile(from url: URL, to destination: URL) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URL, Error>?
        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(LauncherError("Download failed with HTTP \(http.statusCode)."))
            } else if let location {
                result = .success(location)
            } else {
                result = .failure(LauncherError("Download finished without a file."))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        guard let result else {
            throw LauncherError("Download did not complete.")
        }
        let tempURL = try result.get()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: tempURL, to: destination)
    }

    private func findExtractedPythonRoot(in directory: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw LauncherError("Could not inspect extracted Python archive.")
        }

        for case let url as URL in enumerator {
            if url.lastPathComponent == "python3.11",
               url.deletingLastPathComponent().lastPathComponent == "bin" {
                return url.deletingLastPathComponent().deletingLastPathComponent()
            }
        }
        throw LauncherError("Downloaded Python archive did not contain bin/python3.11.")
    }

    private func launchHomeAgent() throws {
        guard let selectedPythonPath else {
            throw LauncherError("No usable Python runtime is selected.")
        }

        state = .starting

        let process = Process()
        process.executableURL = URL(fileURLWithPath: selectedPythonPath)
        process.arguments = [
            "-B",
            "-m",
            "tater_tunnel.home_agent",
            "--host",
            "127.0.0.1",
            "--port",
            "\(tunnelPort)",
            "--state-file",
            stateDir.appendingPathComponent("home-agent.json").path,
            "--static-root",
            sourceRoot.path,
            "--wireguard-backend",
            "config",
            "--wireguard-config",
            wireguardDir.appendingPathComponent("tater-home.conf").path,
            "--wireguard-interface",
            "tater-home",
            "--relay-target",
            "http://127.0.0.1:\(tunnelPort)"
        ]
        process.currentDirectoryURL = sourceRoot
        process.environment = backendEnvironment()

        let handle = try openLog(named: "home-agent.log", append: true)
        logHandle = handle
        outputPipe = streamProcessOutput(process, to: handle)
        expectedStop = false
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasExpectedStop = self.expectedStop
                self.expectedStop = false
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.outputPipe = nil
                self.closeLogHandle()
                self.process = nil
                if wasExpectedStop || proc.terminationStatus == 0 {
                    self.state = .stopped
                } else {
                    self.state = .failed("Home Agent exited with status \(proc.terminationStatus)")
                }
            }
        }

        appendLauncherLog("Starting Home Agent on \(webURL.absoluteString).\n")
        try process.run()
        self.process = process
        appendLauncherLog("Home Agent process started with pid \(process.processIdentifier).\n")

        if waitForWebReady(timeout: 25) {
            state = .running
        } else if process.isRunning {
            state = .starting
        } else {
            throw LauncherError("Home Agent exited before the web UI became ready.")
        }
    }

    private func backendEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let pathPrefix = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = (pathPrefix + [existingPath]).filter { !$0.isEmpty }.joined(separator: ":")
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONPATH"] = sourceRoot.path
        return environment
    }

    private func waitForWebReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isWebReady() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func isWebReady() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--fail",
            "--silent",
            "--show-error",
            "--max-time",
            "1.5",
            "--output",
            "/dev/null",
            webURL.absoluteString
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func openLog(named name: String, append: Bool) throws -> FileHandle {
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let url = logsDir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        if append {
            try handle.seekToEnd()
            let header = "\n\n=== \(Date()) ===\n".data(using: .utf8) ?? Data()
            try handle.write(contentsOf: header)
        } else {
            try handle.truncate(atOffset: 0)
        }
        return handle
    }

    private func streamProcessOutput(_ process: Process, to handle: FileHandle) -> Pipe {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { reader in
            let data = reader.availableData
            guard !data.isEmpty else { return }
            try? handle.write(contentsOf: data)
        }
        return pipe
    }

    private func appendLauncherLog(_ text: String) {
        guard !text.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            let url = logsDir.appendingPathComponent("launcher.log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            let stamp = ISO8601DateFormatter().string(from: Date())
            let data = "[\(stamp)] \(text)".data(using: .utf8) ?? Data()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            NSLog("Tater Tunnel launcher log write failed: \(error.localizedDescription)")
        }
    }

    private func closeLogHandle() {
        try? logHandle?.close()
        logHandle = nil
    }

    private func runCheckedProcess(executable: String, arguments: [String], currentDirectory: URL?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LauncherError("\(executable) exited with status \(process.terminationStatus).")
        }
    }
}

private enum MenuBarIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.setStroke()
        NSColor.black.setFill()

        let body = NSBezierPath(ovalIn: NSRect(x: 3.1, y: 2.1, width: 11.8, height: 13.7))
        body.lineWidth = 1.45
        body.stroke()

        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: 9, y: 14.3))
        stem.curve(to: NSPoint(x: 11.2, y: 16.1), controlPoint1: NSPoint(x: 9.3, y: 15.4), controlPoint2: NSPoint(x: 10.2, y: 16.1))
        stem.lineWidth = 1.25
        stem.lineCapStyle = .round
        stem.stroke()

        let cable = NSBezierPath()
        cable.move(to: NSPoint(x: 5.1, y: 7.2))
        cable.curve(to: NSPoint(x: 12.9, y: 7.2), controlPoint1: NSPoint(x: 7.0, y: 10.0), controlPoint2: NSPoint(x: 11.0, y: 10.0))
        cable.lineWidth = 1.55
        cable.lineCapStyle = .round
        cable.stroke()

        for point in [NSPoint(x: 5.1, y: 7.2), NSPoint(x: 9, y: 9.2), NSPoint(x: 12.9, y: 7.2)] {
            NSBezierPath(ovalIn: NSRect(x: point.x - 1.05, y: point.y - 1.05, width: 2.1, height: 2.1)).fill()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = HomeAgentManager()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    private let statusMenuItem = NSMenuItem(title: "Status: Stopped", action: nil, keyEquivalent: "")
    private let startMenuItem = NSMenuItem(title: "Start Home Agent", action: #selector(startHomeAgent), keyEquivalent: "s")
    private let stopMenuItem = NSMenuItem(title: "Stop Home Agent", action: #selector(stopHomeAgent), keyEquivalent: "")
    private let restartMenuItem = NSMenuItem(title: "Restart Home Agent", action: #selector(restartHomeAgent), keyEquivalent: "r")
    private let openMenuItem = NSMenuItem(title: "Open Tater Tunnel", action: #selector(openTaterTunnel), keyEquivalent: "o")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        manager.onStateChange = { [weak self] state in
            self?.refreshMenu(for: state)
        }
        manager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stop(waitForExit: true)
    }

    private func configureStatusItem() {
        statusItem.button?.image = MenuBarIcon.make()
        statusItem.button?.toolTip = "Tater Tunnel"

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        openMenuItem.target = self
        startMenuItem.target = self
        stopMenuItem.target = self
        restartMenuItem.target = self
        menu.addItem(openMenuItem)
        menu.addItem(startMenuItem)
        menu.addItem(stopMenuItem)
        menu.addItem(restartMenuItem)
        menu.addItem(.separator())

        let copyURL = NSMenuItem(title: "Copy Local URL", action: #selector(copyLocalURL), keyEquivalent: "c")
        copyURL.target = self
        menu.addItem(copyURL)

        let logs = NSMenuItem(title: "Open Logs Folder", action: #selector(openLogsFolder), keyEquivalent: "l")
        logs.target = self
        menu.addItem(logs)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Tater Tunnel", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        refreshMenu(for: manager.state)
    }

    private func refreshMenu(for state: BackendState) {
        statusMenuItem.title = "Status: \(state.label)"
        switch state {
        case .stopped, .failed:
            startMenuItem.isEnabled = true
            stopMenuItem.isEnabled = false
            restartMenuItem.isEnabled = true
            openMenuItem.isEnabled = false
        case .preparing, .starting:
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
            restartMenuItem.isEnabled = false
            openMenuItem.isEnabled = true
        case .running:
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
            restartMenuItem.isEnabled = true
            openMenuItem.isEnabled = true
        }
    }

    @objc private func startHomeAgent() {
        manager.start()
    }

    @objc private func stopHomeAgent() {
        manager.stop()
    }

    @objc private func restartHomeAgent() {
        manager.restart()
    }

    @objc private func openTaterTunnel() {
        manager.openUI()
    }

    @objc private func copyLocalURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(manager.webURL.absoluteString, forType: .string)
    }

    @objc private func openLogsFolder() {
        manager.openLogsFolder()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
