import AppKit
import CryptoKit
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

private struct UpdateManifest: Decodable {
    let version: String
    let build: Int
    let url: URL
    let sha256: String
    let notes: String?

    var versionLabel: String {
        "v\(version.trimmingCharacters(in: CharacterSet(charactersIn: "vV")))"
    }
}

private struct UpdateCheckResult {
    let manifest: UpdateManifest
    let currentVersion: String
    let currentBuild: Int
    let isAvailable: Bool
}

private struct PreparedUpdate {
    let appBundle: URL
    let workDirectory: URL
}

private struct TrafficRates {
    let downloadBitsPerSecond: Double
    let uploadBitsPerSecond: Double
    let connectedDevices: Int

    var menuBarTitle: String {
        "↓ \(Self.compactRate(downloadBitsPerSecond))  ↑ \(Self.compactRate(uploadBitsPerSecond))"
    }

    var menuTitle: String {
        "Traffic: ↓ \(Self.fullRate(downloadBitsPerSecond))  ↑ \(Self.fullRate(uploadBitsPerSecond))"
    }

    var tooltip: String {
        "Download \(Self.fullRate(downloadBitsPerSecond)), upload \(Self.fullRate(uploadBitsPerSecond)) through \(connectedDevices) connected VPN device\(connectedDevices == 1 ? "" : "s")."
    }

    private static func compactRate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000_000 {
            return String(format: "%.1f Gb/s", bitsPerSecond / 1_000_000_000)
        }
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mb/s", bitsPerSecond / 1_000_000)
        }
        if bitsPerSecond >= 1_000 {
            return String(format: "%.0f Kb/s", bitsPerSecond / 1_000)
        }
        return "0 Kb/s"
    }

    private static func fullRate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000_000 {
            return String(format: "%.2f Gb/s", bitsPerSecond / 1_000_000_000)
        }
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.2f Mb/s", bitsPerSecond / 1_000_000)
        }
        if bitsPerSecond >= 1_000 {
            return String(format: "%.1f Kb/s", bitsPerSecond / 1_000)
        }
        return "0 Kb/s"
    }
}

private struct TrafficSnapshot {
    let date: Date
    let uploadBytes: UInt64
    let downloadBytes: UInt64
    let connectedDevices: Int
}

private final class TrafficMonitor {
    var onUpdate: ((TrafficRates) -> Void)?

    private let stateURL: URL
    private var previousSnapshot: TrafficSnapshot?
    private var timer: Timer?
    private var requestInFlight = false

    init(webURL: URL) {
        stateURL = URL(string: "\(webURL.absoluteString)/api/state")!
    }

    func start() {
        stop()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        requestInFlight = false
    }

    private func poll() {
        guard !requestInFlight else {
            return
        }

        requestInFlight = true
        var request = URLRequest(url: stateURL)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            defer {
                self.requestInFlight = false
            }

            guard
                let data,
                let snapshot = self.parseSnapshot(data)
            else {
                return
            }

            let rates = self.rates(from: snapshot)
            self.previousSnapshot = snapshot
            DispatchQueue.main.async { [onUpdate] in
                onUpdate?(rates)
            }
        }.resume()
    }

    private func rates(from snapshot: TrafficSnapshot) -> TrafficRates {
        guard let previousSnapshot else {
            return TrafficRates(downloadBitsPerSecond: 0, uploadBitsPerSecond: 0, connectedDevices: snapshot.connectedDevices)
        }

        let elapsed = snapshot.date.timeIntervalSince(previousSnapshot.date)
        guard elapsed > 0 else {
            return TrafficRates(downloadBitsPerSecond: 0, uploadBitsPerSecond: 0, connectedDevices: snapshot.connectedDevices)
        }

        let uploadDelta = snapshot.uploadBytes >= previousSnapshot.uploadBytes
            ? snapshot.uploadBytes - previousSnapshot.uploadBytes
            : 0
        let downloadDelta = snapshot.downloadBytes >= previousSnapshot.downloadBytes
            ? snapshot.downloadBytes - previousSnapshot.downloadBytes
            : 0

        return TrafficRates(
            downloadBitsPerSecond: Double(downloadDelta) * 8 / elapsed,
            uploadBitsPerSecond: Double(uploadDelta) * 8 / elapsed,
            connectedDevices: snapshot.connectedDevices
        )
    }

    private func parseSnapshot(_ data: Data) -> TrafficSnapshot? {
        guard
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devices = payload["devices"] as? [[String: Any]]
        else {
            return nil
        }

        var uploadBytes: UInt64 = 0
        var downloadBytes: UInt64 = 0
        var connectedDevices = 0

        for device in devices {
            guard
                let wireguard = device["wireguard"] as? [String: Any],
                let live = wireguard["live"] as? [String: Any]
            else {
                continue
            }

            if (live["connected"] as? Bool) == true {
                connectedDevices += 1
            }

            uploadBytes += unsignedValue(live["transferRxBytes"])
            downloadBytes += unsignedValue(live["transferTxBytes"])
        }

        return TrafficSnapshot(
            date: Date(),
            uploadBytes: uploadBytes,
            downloadBytes: downloadBytes,
            connectedDevices: connectedDevices
        )
    }

    private func unsignedValue(_ value: Any?) -> UInt64 {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let string = value as? String, let parsed = UInt64(string) {
            return parsed
        }
        return 0
    }
}

private final class AppUpdater {
    func checkForUpdates() throws -> UpdateCheckResult {
        let manifestURL = try updateManifestURL()
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TaterTunnel", forHTTPHeaderField: "User-Agent")

        let data = try loadData(from: request)
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        let currentVersion = currentAppVersion()
        let currentBuild = currentAppBuild()
        return UpdateCheckResult(
            manifest: manifest,
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            isAvailable: isManifest(manifest, newerThanVersion: currentVersion, build: currentBuild)
        )
    }

    func prepareUpdate(_ manifest: UpdateManifest) throws -> PreparedUpdate {
        guard manifest.url.scheme == "https" else {
            throw LauncherError("Update downloads must use HTTPS.")
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tater-tunnel-update-\(UUID().uuidString)", isDirectory: true)
        let zipURL = workDirectory.appendingPathComponent("TaterTunnel-\(manifest.versionLabel).zip")
        let extractDirectory = workDirectory.appendingPathComponent("extract", isDirectory: true)

        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        do {
            try downloadFile(from: manifest.url, to: zipURL)
            try verifySHA256(zipURL, expected: manifest.sha256)
            try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
            try runCheckedProcess(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", zipURL.path, extractDirectory.path],
                currentDirectory: nil
            )

            let appBundle = try findAppBundle(in: extractDirectory)
            return PreparedUpdate(appBundle: appBundle, workDirectory: workDirectory)
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            throw error
        }
    }

    func launchInstaller(for preparedUpdate: PreparedUpdate) throws {
        let currentApp = Bundle.main.bundleURL
        guard currentApp.pathExtension == "app" else {
            throw LauncherError("Updates can only be installed from the Tater Tunnel app bundle.")
        }

        let installParent = currentApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: installParent.path) else {
            throw LauncherError("Tater Tunnel cannot update itself in \(installParent.path). Move it to a writable folder or install manually from the DMG.")
        }

        let scriptURL = preparedUpdate.workDirectory.appendingPathComponent("install-update.sh")
        let script = """
        #!/bin/sh
        set -eu

        APP_PATH="$1"
        NEW_APP="$2"
        WORK_DIR="$3"
        APP_PID="$4"
        BACKUP_PATH="${APP_PATH}.previous"

        while kill -0 "$APP_PID" 2>/dev/null; do
          sleep 0.2
        done

        rm -rf "$BACKUP_PATH"
        if [ -d "$APP_PATH" ]; then
          mv "$APP_PATH" "$BACKUP_PATH"
        fi

        if ! cp -R "$NEW_APP" "$APP_PATH"; then
          rm -rf "$APP_PATH"
          if [ -d "$BACKUP_PATH" ]; then
            mv "$BACKUP_PATH" "$APP_PATH"
          fi
          exit 1
        fi

        xattr -dr com.apple.quarantine "$APP_PATH" >/dev/null 2>&1 || true
        open "$APP_PATH"
        rm -rf "$BACKUP_PATH"
        rm -rf "$WORK_DIR"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            currentApp.path,
            preparedUpdate.appBundle.path,
            preparedUpdate.workDirectory.path,
            "\(getpid())"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
    }

    private func updateManifestURL() throws -> URL {
        guard
            let rawValue = Bundle.main.object(forInfoDictionaryKey: "TaterTunnelUpdateManifestURL") as? String,
            let url = URL(string: rawValue)
        else {
            throw LauncherError("The update manifest URL is missing from the app.")
        }
        return url
    }

    private func currentAppVersion() -> String {
        let rawVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return (rawVersion ?? "0.0.0").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    private func currentAppBuild() -> Int {
        let rawBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return Int(rawBuild ?? "") ?? 0
    }

    private func isManifest(_ manifest: UpdateManifest, newerThanVersion currentVersion: String, build currentBuild: Int) -> Bool {
        let versionComparison = compareVersions(manifest.version, currentVersion)
        if versionComparison == .orderedDescending {
            return true
        }
        if versionComparison == .orderedSame && manifest.build > currentBuild {
            return true
        }
        return false
    }

    private func compareVersions(_ left: String, _ right: String) -> ComparisonResult {
        let leftParts = numericVersionParts(left)
        let rightParts = numericVersionParts(right)
        let count = max(leftParts.count, rightParts.count)
        for index in 0..<count {
            let leftValue = index < leftParts.count ? leftParts[index] : 0
            let rightValue = index < rightParts.count ? rightParts[index] : 0
            if leftValue > rightValue {
                return .orderedDescending
            }
            if leftValue < rightValue {
                return .orderedAscending
            }
        }
        return .orderedSame
    }

    private func numericVersionParts(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split { !$0.isNumber }
            .map { Int($0) ?? 0 }
    }

    private func verifySHA256(_ fileURL: URL, expected: String) throws {
        let expectedHash = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !expectedHash.isEmpty else {
            throw LauncherError("Update manifest did not include a SHA-256 checksum.")
        }

        let actualHash = try sha256Hex(of: fileURL)
        guard actualHash == expectedHash else {
            throw LauncherError("Downloaded update checksum did not match the manifest.")
        }
    }

    private func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func findAppBundle(in directory: URL) throws -> URL {
        let expected = directory.appendingPathComponent("Tater Tunnel.app", isDirectory: true)
        if isTaterTunnelApp(expected) {
            return expected
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw LauncherError("Could not inspect downloaded update.")
        }

        for case let url as URL in enumerator where url.pathExtension == "app" {
            if isTaterTunnelApp(url) {
                return url
            }
        }

        throw LauncherError("Downloaded update did not contain Tater Tunnel.app.")
    }

    private func isTaterTunnelApp(_ url: URL) -> Bool {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard
            let info = NSDictionary(contentsOf: infoURL),
            let bundleID = info["CFBundleIdentifier"] as? String
        else {
            return false
        }
        return bundleID == "com.tatertotterson.tatertunnel"
    }

    private func loadData(from request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(LauncherError("Update check failed with HTTP \(http.statusCode)."))
            } else {
                result = .success(data ?? Data())
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        guard let result else {
            throw LauncherError("Update check did not complete.")
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
                result = .failure(LauncherError("Update download failed with HTTP \(http.statusCode)."))
            } else if let location {
                result = .success(location)
            } else {
                result = .failure(LauncherError("Update download finished without a file."))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        guard let result else {
            throw LauncherError("Update download did not complete.")
        }
        let tempURL = try result.get()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: tempURL, to: destination)
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

        let downArrow = NSBezierPath()
        downArrow.move(to: NSPoint(x: 5.5, y: 14.2))
        downArrow.line(to: NSPoint(x: 5.5, y: 5.0))
        downArrow.move(to: NSPoint(x: 2.9, y: 7.4))
        downArrow.line(to: NSPoint(x: 5.5, y: 4.8))
        downArrow.line(to: NSPoint(x: 8.1, y: 7.4))
        downArrow.lineWidth = 1.55
        downArrow.lineCapStyle = .round
        downArrow.lineJoinStyle = .round
        downArrow.stroke()

        let upArrow = NSBezierPath()
        upArrow.move(to: NSPoint(x: 12.5, y: 3.8))
        upArrow.line(to: NSPoint(x: 12.5, y: 13.0))
        upArrow.move(to: NSPoint(x: 9.9, y: 10.6))
        upArrow.line(to: NSPoint(x: 12.5, y: 13.2))
        upArrow.line(to: NSPoint(x: 15.1, y: 10.6))
        upArrow.lineWidth = 1.55
        upArrow.lineCapStyle = .round
        upArrow.lineJoinStyle = .round
        upArrow.stroke()

        let tunnel = NSBezierPath()
        tunnel.move(to: NSPoint(x: 3.3, y: 2.6))
        tunnel.curve(
            to: NSPoint(x: 14.7, y: 2.6),
            controlPoint1: NSPoint(x: 6.0, y: 1.1),
            controlPoint2: NSPoint(x: 12.0, y: 1.1)
        )
        tunnel.lineWidth = 1.2
        tunnel.lineCapStyle = .round
        tunnel.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = HomeAgentManager()
    private let updater = AppUpdater()
    private lazy var trafficMonitor = TrafficMonitor(webURL: manager.webURL)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private let statusMenuItem = NSMenuItem(title: "Status: Stopped", action: nil, keyEquivalent: "")
    private let trafficMenuItem = NSMenuItem(title: "Traffic: Waiting for tunnel data", action: nil, keyEquivalent: "")
    private let startMenuItem = NSMenuItem(title: "Start Home Agent", action: #selector(startHomeAgent), keyEquivalent: "s")
    private let stopMenuItem = NSMenuItem(title: "Stop Home Agent", action: #selector(stopHomeAgent), keyEquivalent: "")
    private let restartMenuItem = NSMenuItem(title: "Restart Home Agent", action: #selector(restartHomeAgent), keyEquivalent: "r")
    private let openMenuItem = NSMenuItem(title: "Open Tater Tunnel", action: #selector(openTaterTunnel), keyEquivalent: "o")
    private let updateMenuItem = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "u")

    private var updateInProgress = false
    private var latestTrafficRates: TrafficRates?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        manager.onStateChange = { [weak self] state in
            self?.refreshMenu(for: state)
        }
        trafficMonitor.onUpdate = { [weak self] rates in
            self?.latestTrafficRates = rates
            self?.refreshTrafficDisplay()
        }
        trafficMonitor.start()
        manager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        trafficMonitor.stop()
        manager.stop(waitForExit: true)
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = MenuBarIcon.make()
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleProportionallyDown
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            button.toolTip = "Tater Tunnel"
        }

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        trafficMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(trafficMenuItem)
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

        updateMenuItem.target = self
        menu.addItem(updateMenuItem)
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
        refreshTrafficDisplay()
    }

    private func refreshTrafficDisplay() {
        guard let button = statusItem.button else {
            return
        }

        guard case .running = manager.state, let rates = latestTrafficRates else {
            button.title = ""
            button.toolTip = "Tater Tunnel"
            trafficMenuItem.title = "Traffic: Waiting for tunnel data"
            return
        }

        button.title = " \(rates.menuBarTitle)"
        button.toolTip = rates.tooltip
        trafficMenuItem.title = rates.menuTitle
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

    @objc private func checkForUpdates() {
        guard !updateInProgress else {
            return
        }

        setUpdateMenuBusy("Checking for Updates...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result {
                try self.updater.checkForUpdates()
            }
            DispatchQueue.main.async {
                self.clearUpdateMenuBusy()
                self.handleUpdateCheck(result)
            }
        }
    }

    private func handleUpdateCheck(_ result: Result<UpdateCheckResult, Error>) {
        switch result {
        case .success(let check):
            if check.isAvailable {
                promptToInstallUpdate(check)
            } else {
                showAlert(
                    title: "Tater Tunnel is up to date",
                    message: "You are running version \(check.currentVersion) build \(check.currentBuild)."
                )
            }
        case .failure(let error):
            showAlert(title: "Could not check for updates", message: error.localizedDescription)
        }
    }

    private func promptToInstallUpdate(_ check: UpdateCheckResult) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Tater Tunnel \(check.manifest.versionLabel) is available"
        let notes = check.manifest.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        alert.informativeText = [
            "Current: v\(check.currentVersion) build \(check.currentBuild)",
            "Available: \(check.manifest.versionLabel) build \(check.manifest.build)",
            notes
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            installUpdate(check.manifest)
        }
    }

    private func installUpdate(_ manifest: UpdateManifest) {
        setUpdateMenuBusy("Downloading Update...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result {
                try self.updater.prepareUpdate(manifest)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let preparedUpdate):
                    self.finishInstallingUpdate(preparedUpdate)
                case .failure(let error):
                    self.clearUpdateMenuBusy()
                    self.showAlert(title: "Could not install update", message: error.localizedDescription)
                }
            }
        }
    }

    private func finishInstallingUpdate(_ preparedUpdate: PreparedUpdate) {
        setUpdateMenuBusy("Installing Update...")
        do {
            manager.stop(waitForExit: true)
            try updater.launchInstaller(for: preparedUpdate)
            NSApp.terminate(nil)
        } catch {
            clearUpdateMenuBusy()
            showAlert(title: "Could not finish update", message: error.localizedDescription)
        }
    }

    private func setUpdateMenuBusy(_ title: String) {
        updateInProgress = true
        updateMenuItem.title = title
        updateMenuItem.isEnabled = false
    }

    private func clearUpdateMenuBusy() {
        updateInProgress = false
        updateMenuItem.title = "Check for Updates"
        updateMenuItem.isEnabled = true
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
