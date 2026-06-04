import CryptoKit
import XCTest

final class DeviceIdentityTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziel-identity-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    private var identityURL: URL { tempDir.appendingPathComponent("device-identity.json") }

    // MARK: - Payload format (pinned against OpenClaw 2026.6.1 buildDeviceAuthPayloadV3)

    func testPayloadV3MatchesOpenClawFormat() {
        let payload = DeviceIdentity.buildPayloadV3(
            deviceId: "abc123",
            clientId: "gateway-client",
            clientMode: "ui",
            role: "operator",
            scopes: ["operator.read"],
            signedAtMs: 1_737_264_000_000,
            token: "tok-1",
            nonce: "nonce-1",
            platform: "macos",
            deviceFamily: nil)
        XCTAssertEqual(payload,
            "v3|abc123|gateway-client|ui|operator|operator.read|1737264000000|tok-1|nonce-1|macos|")
    }

    func testPayloadV3LowercasesMetadataAndJoinsScopes() {
        let payload = DeviceIdentity.buildPayloadV3(
            deviceId: "d",
            clientId: "gateway-client",
            clientMode: "ui",
            role: "operator",
            scopes: ["operator.read", "operator.write"],
            signedAtMs: 5,
            token: nil,
            nonce: "n",
            platform: "MacOS",
            deviceFamily: " Mac ")
        XCTAssertEqual(payload,
            "v3|d|gateway-client|ui|operator|operator.read,operator.write|5||n|macos|mac")
    }

    // MARK: - Key material

    func testDeviceIdIsSha256HexOfRawPublicKey() throws {
        let identity = try DeviceIdentity.loadOrCreate(at: identityURL)
        let raw = try XCTUnwrap(Data(base64URLNoPad: identity.publicKeyRawBase64Url))
        XCTAssertEqual(raw.count, 32)
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(identity.deviceId, digest)
    }

    func testPublicKeyAndSignatureAreBase64UrlNoPadding() throws {
        let identity = try DeviceIdentity.loadOrCreate(at: identityURL)
        let signature = identity.sign(payload: "v3|test")
        for value in [identity.publicKeyRawBase64Url, signature] {
            XCTAssertFalse(value.contains("+"), "must be base64url: \(value)")
            XCTAssertFalse(value.contains("/"), "must be base64url: \(value)")
            XCTAssertFalse(value.contains("="), "must be unpadded: \(value)")
        }
    }

    func testSignatureVerifiesAgainstPublicKey() throws {
        let identity = try DeviceIdentity.loadOrCreate(at: identityURL)
        let payload = "v3|abc|gateway-client|ui|operator|operator.read|1|tok|n|macos|"
        let signature = identity.sign(payload: payload)
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: XCTUnwrap(Data(base64URLNoPad: identity.publicKeyRawBase64Url)))
        let signatureData = try XCTUnwrap(Data(base64URLNoPad: signature))
        XCTAssertTrue(publicKey.isValidSignature(signatureData, for: Data(payload.utf8)))
    }

    // MARK: - Persistence

    func testLoadOrCreatePersistsAndReloadsSameIdentity() throws {
        let first = try DeviceIdentity.loadOrCreate(at: identityURL)
        let second = try DeviceIdentity.loadOrCreate(at: identityURL)
        XCTAssertEqual(first.deviceId, second.deviceId)
        XCTAssertEqual(first.publicKeyRawBase64Url, second.publicKeyRawBase64Url)
        // same key: second's signature verifies against first's public key
        // (CryptoKit Ed25519 signatures are randomized, so bytes can't be compared)
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: XCTUnwrap(Data(base64URLNoPad: first.publicKeyRawBase64Url)))
        let signature = try XCTUnwrap(Data(base64URLNoPad: second.sign(payload: "x")))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data("x".utf8)))
    }

    func testIdentityFileIsOwnerOnly() throws {
        _ = try DeviceIdentity.loadOrCreate(at: identityURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: identityURL.path)
        let perms = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perms.intValue & 0o077, 0, "identity file must not be group/world readable")
    }

    func testCorruptIdentityFileRegenerates() throws {
        try Data("not json".utf8).write(to: identityURL)
        let identity = try DeviceIdentity.loadOrCreate(at: identityURL)
        XCTAssertEqual(identity.deviceId.count, 64)
    }
}
