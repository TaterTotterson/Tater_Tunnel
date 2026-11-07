import Foundation
import NetworkExtension
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter = WireGuardAdapter(with: self) { level, message in
        switch level {
        case .verbose:
            NSLog("Tater Tunnel: %@", message)
        case .error:
            NSLog("Tater Tunnel error: %@", message)
        }
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            guard let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
                  let rawConfiguration = tunnelProtocol.providerConfiguration?["WgQuickConfig"] as? String else {
                throw ProviderError.missingConfiguration
            }
            let configuration = try TaterWireGuardConfiguration.parse(rawConfiguration)
            adapter.start(tunnelConfiguration: configuration) { error in
                completionHandler(error)
            }
        } catch {
            completionHandler(error)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        adapter.stop { _ in
            completionHandler()
        }
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        guard messageData == Data([0]) else {
            completionHandler?(nil)
            return
        }
        adapter.getRuntimeConfiguration { configuration in
            completionHandler?(configuration?.data(using: .utf8))
        }
    }
}

private enum ProviderError: LocalizedError {
    case missingConfiguration
    case invalidLine(String)
    case missingValue(String)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "The Tater Tunnel WireGuard configuration is missing."
        case .invalidLine(let line):
            return "Invalid WireGuard configuration line: \(line)"
        case .missingValue(let name):
            return "WireGuard configuration is missing \(name)."
        case .invalidValue(let name):
            return "WireGuard configuration contains an invalid \(name)."
        }
    }
}

private enum TaterWireGuardConfiguration {
    static func parse(_ text: String) throws -> TunnelConfiguration {
        var section = ""
        var interfaceValues: [String: String] = [:]
        var peerValues: [String: String] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line == "[Interface]" || line == "[Peer]" {
                section = line
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2 else { throw ProviderError.invalidLine(line) }
            switch section {
            case "[Interface]":
                interfaceValues[parts[0].lowercased()] = parts[1]
            case "[Peer]":
                peerValues[parts[0].lowercased()] = parts[1]
            default:
                throw ProviderError.invalidLine(line)
            }
        }

        guard let privateKeyValue = interfaceValues["privatekey"] else {
            throw ProviderError.missingValue("private key")
        }
        guard let privateKey = PrivateKey(base64Key: privateKeyValue) else {
            throw ProviderError.invalidValue("private key")
        }
        var interface = InterfaceConfiguration(privateKey: privateKey)
        interface.addresses = try ranges(interfaceValues["address"], name: "interface address")
        if let mtu = interfaceValues["mtu"] {
            guard let parsed = UInt16(mtu) else { throw ProviderError.invalidValue("MTU") }
            interface.mtu = parsed
        }

        guard let publicKeyValue = peerValues["publickey"] else {
            throw ProviderError.missingValue("VPS public key")
        }
        guard let publicKey = PublicKey(base64Key: publicKeyValue) else {
            throw ProviderError.invalidValue("VPS public key")
        }
        var peer = PeerConfiguration(publicKey: publicKey)
        peer.allowedIPs = try ranges(peerValues["allowedips"], name: "allowed IPs")
        guard let endpointValue = peerValues["endpoint"] else {
            throw ProviderError.missingValue("VPS endpoint")
        }
        guard let endpoint = Endpoint(from: endpointValue) else {
            throw ProviderError.invalidValue("VPS endpoint")
        }
        peer.endpoint = endpoint
        if let keepAlive = peerValues["persistentkeepalive"] {
            guard let parsed = UInt16(keepAlive) else {
                throw ProviderError.invalidValue("persistent keepalive")
            }
            peer.persistentKeepAlive = parsed
        }

        return TunnelConfiguration(name: "Tater Tunnel", interface: interface, peers: [peer])
    }

    private static func ranges(_ value: String?, name: String) throws -> [IPAddressRange] {
        guard let value else { throw ProviderError.missingValue(name) }
        let parsed = value.split(separator: ",").compactMap {
            IPAddressRange(from: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !parsed.isEmpty, parsed.count == value.split(separator: ",").count else {
            throw ProviderError.invalidValue(name)
        }
        return parsed
    }
}
