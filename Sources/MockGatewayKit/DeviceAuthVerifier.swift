import CryptoKit
import Foundation

/// Server-side verification of the connect `device` block, implemented
/// independently from the client's DeviceIdentity so integration tests
/// cross-check the signing format rather than mirror it.
enum DeviceAuthVerifier {
    /// Returns nil when the device block verifies, otherwise a failure reason.
    static func verify(params: [String: Any], expectedNonce: String) -> String? {
        guard let device = params["device"] as? [String: Any] else { return "missing device block" }
        guard let deviceId = device["id"] as? String,
              let publicKeyB64 = device["publicKey"] as? String,
              let signatureB64 = device["signature"] as? String,
              let signedAtMs = (device["signedAt"] as? NSNumber)?.int64Value,
              let nonce = device["nonce"] as? String
        else { return "incomplete device block" }

        guard nonce == expectedNonce else { return "nonce mismatch" }
        guard let rawKey = decodeBase64URL(publicKeyB64), rawKey.count == 32 else {
            return "publicKey is not 32 raw base64url bytes"
        }
        let fingerprint = SHA256.hash(data: rawKey).map { String(format: "%02x", $0) }.joined()
        guard deviceId == fingerprint else { return "device id is not the public key fingerprint" }

        let client = params["client"] as? [String: Any]
        let auth = params["auth"] as? [String: Any]
        let payload = [
            "v3",
            deviceId,
            client?["id"] as? String ?? "",
            client?["mode"] as? String ?? "",
            params["role"] as? String ?? "",
            (params["scopes"] as? [String] ?? []).joined(separator: ","),
            String(signedAtMs),
            auth?["token"] as? String ?? "",
            nonce,
            lowercasedASCII(client?["platform"] as? String),
            lowercasedASCII(client?["deviceFamily"] as? String),
        ].joined(separator: "|")

        guard let signature = decodeBase64URL(signatureB64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
              publicKey.isValidSignature(signature, for: Data(payload.utf8))
        else { return "signature does not verify" }
        return nil
    }
}

private func decodeBase64URL(_ input: String) -> Data? {
    var normalized = input
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
    return Data(base64Encoded: normalized)
}

private func lowercasedASCII(_ value: String?) -> String {
    guard let value else { return "" }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return String(trimmed.map { $0.isASCII && $0.isUppercase ? Character($0.lowercased()) : $0 })
}
