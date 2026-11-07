import CryptoKit
import Foundation
import NetworkExtension
import SystemExtensions

enum TunnelState: Equatable {
    case waitingForPair
    case installing
    case needsApproval
    case connecting
    case connected
    case disconnected
    case failed(String)

    var label: String {
        switch self {
        case .waitingForPair:
            return "Waiting for VPS pairing"
        case .installing:
            return "Preparing private tunnel"
        case .needsApproval:
            return "Approval needed in System Settings"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }
}

final class TunnelController: NSObject, OSSystemExtensionRequestDelegate {
    static let providerBundleIdentifier = "com.tatertotterson.tatertunnel.network-extension"

    var onStateChange: ((TunnelState) -> Void)?

    private(set) var state: TunnelState = .waitingForPair {
        didSet {
            guard state != oldValue else { return }
            DispatchQueue.main.async { [state, onStateChange] in
                onStateChange?(state)
            }
        }
    }

    private let configURL: URL
    private var timer: Timer?
    private var manager: NETunnelProviderManager?
    private var pendingConfiguration: String?
    private var appliedDigest = ""
    private var activationInFlight = false
    private var activationFinished = false
    private var cleanedMissingConfiguration = false

    override init() {
        configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tatertunnel/wireguard/tater-home.conf")
        super.init()
    }

    func start() {
        guard timer == nil else {
            refresh()
            return
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusDidChange),
            name: .NEVPNStatusDidChange,
            object: nil
        )
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
        stopTunnel()
    }

    func stopTunnel() {
        manager?.connection.stopVPNTunnel()
        if manager != nil {
            state = .disconnected
        }
    }

    private func refresh() {
        guard let configuration = try? String(contentsOf: configURL, encoding: .utf8),
              !configuration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingConfiguration = nil
            appliedDigest = ""
            state = .waitingForPair
            if !cleanedMissingConfiguration {
                cleanedMissingConfiguration = true
                removeStaleTunnelConfiguration()
            }
            return
        }

        cleanedMissingConfiguration = false
        pendingConfiguration = configuration
        let digest = SHA256.hash(data: Data(configuration.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        if digest == appliedDigest, manager?.connection.status == .connected {
            state = .connected
            return
        }

        if activationFinished {
            configureAndStartTunnel(configuration, digest: digest)
        } else {
            activateSystemExtension()
        }
    }

    private func activateSystemExtension() {
        guard !activationInFlight else { return }
        activationInFlight = true
        state = .installing
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.providerBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func configureAndStartTunnel(_ configuration: String, digest: String) {
        if manager?.connection.status == .connecting || manager?.connection.status == .reasserting {
            return
        }
        state = .connecting
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.state = .failed(error.localizedDescription)
                    return
                }

                let selected = managers?.first(where: { manager in
                    (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                        .providerBundleIdentifier == Self.providerBundleIdentifier
                }) ?? NETunnelProviderManager()
                self.manager = selected

                let tunnelProtocol = NETunnelProviderProtocol()
                tunnelProtocol.providerBundleIdentifier = Self.providerBundleIdentifier
                tunnelProtocol.providerConfiguration = [
                    "WgQuickConfig": configuration,
                    "ConfigurationDigest": digest,
                ]
                tunnelProtocol.serverAddress = Self.endpoint(from: configuration) ?? "Tater VPS"
                tunnelProtocol.disconnectOnSleep = false
                tunnelProtocol.includeAllNetworks = false

                selected.localizedDescription = "Tater Tunnel"
                selected.protocolConfiguration = tunnelProtocol
                selected.isEnabled = true
                selected.isOnDemandEnabled = false
                selected.saveToPreferences { [weak self] saveError in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let saveError {
                            self.state = .failed(saveError.localizedDescription)
                            return
                        }
                        selected.loadFromPreferences { [weak self] loadError in
                            DispatchQueue.main.async {
                                guard let self else { return }
                                if let loadError {
                                    self.state = .failed(loadError.localizedDescription)
                                    return
                                }
                                do {
                                    try selected.connection.startVPNTunnel()
                                    self.appliedDigest = digest
                                    self.state = .connecting
                                } catch {
                                    self.state = .failed(error.localizedDescription)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func removeStaleTunnelConfiguration() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                for manager in managers ?? [] where
                    (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                        .providerBundleIdentifier == Self.providerBundleIdentifier {
                    manager.connection.stopVPNTunnel()
                    manager.removeFromPreferences(completionHandler: nil)
                }
                self.manager = nil
            }
        }
    }

    @objc private func vpnStatusDidChange(_ notification: Notification) {
        guard let connection = notification.object as? NEVPNConnection,
              connection === manager?.connection else { return }
        switch connection.status {
        case .connected:
            state = .connected
        case .connecting, .reasserting:
            state = .connecting
        case .disconnecting:
            state = .disconnected
        case .disconnected, .invalid:
            state = pendingConfiguration == nil ? .waitingForPair : .disconnected
        @unknown default:
            state = .disconnected
        }
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        state = .needsApproval
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension extension: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        activationInFlight = false
        activationFinished = true
        guard let configuration = pendingConfiguration else {
            state = .waitingForPair
            return
        }
        let digest = SHA256.hash(data: Data(configuration.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        configureAndStartTunnel(configuration, digest: digest)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        activationInFlight = false
        activationFinished = false
        state = .failed(error.localizedDescription)
    }

    private static func endpoint(from configuration: String) -> String? {
        for line in configuration.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if parts.count == 2, parts[0].caseInsensitiveCompare("Endpoint") == .orderedSame {
                return parts[1]
            }
        }
        return nil
    }
}
