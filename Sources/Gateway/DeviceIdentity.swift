import CryptoKit
import Foundation

/// Persistent Ed25519 device identity for OpenClaw gateway device pairing.
/// Field formats are pinned to OpenClaw 2026.6.1 `device-identity` (see plan doc
/// "Verified OpenClaw protocol facts").
public struct DeviceIdentity {
    public let deviceId: String
    public let publicKeyRawBase64Url: String
    private let privateKey: Curve25519.Signing.PrivateKey

    private struct Stored: Codable {
        var version: Int
        var deviceId: String
        var publicKey: String
        var privateKey: String
    }

    private init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        let raw = privateKey.publicKey.rawRepresentation
        publicKeyRawBase64Url = raw.base64URLNoPad
        deviceId = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }

    /// Load the identity stored at `url`, or generate a new one and persist it
    /// (owner-only permissions). Corrupt/unreadable files are regenerated.
    public static func loadOrCreate(at url: URL) throws -> DeviceIdentity {
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           let rawPrivate = Data(base64URLNoPad: stored.privateKey),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivate) {
            return DeviceIdentity(privateKey: key)
        }
        let identity = DeviceIdentity(privateKey: Curve25519.Signing.PrivateKey())
        let stored = Stored(
            version: 1,
            deviceId: identity.deviceId,
            publicKey: identity.publicKeyRawBase64Url,
            privateKey: identity.privateKey.rawRepresentation.base64URLNoPad)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return identity
    }

    /// Ed25519 signature over the UTF-8 payload, base64url without padding.
    public func sign(payload: String) -> String {
        // CryptoKit's Ed25519 signing only throws on internal failure.
        let signature = try! privateKey.signature(for: Data(payload.utf8))
        return signature.base64URLNoPad
    }

    /// OpenClaw `buildDeviceAuthPayloadV3`:
    /// v3|deviceId|clientId|clientMode|role|scopes,…|signedAtMs|token|nonce|platform|deviceFamily
    public static func buildPayloadV3(
        deviceId: String, clientId: String, clientMode: String, role: String,
        scopes: [String], signedAtMs: Int64, token: String?, nonce: String,
        platform: String?, deviceFamily: String?
    ) -> String {
        [
            "v3", deviceId, clientId, clientMode, role,
            scopes.joined(separator: ","),
            String(signedAtMs),
            token ?? "",
            nonce,
            normalizeMetadata(platform),
            normalizeMetadata(deviceFamily),
        ].joined(separator: "|")
    }

    // OpenClaw lowercases only ASCII A-Z after trimming.
    private static func normalizeMetadata(_ value: String?) -> String {
        guard let value else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.map { $0.isASCII && $0.isUppercase ? Character($0.lowercased()) : $0 })
    }
}

extension Data {
    init?(base64URLNoPad input: String) {
        var normalized = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }

    var base64URLNoPad: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
