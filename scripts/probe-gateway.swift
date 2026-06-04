#!/usr/bin/env swift
// Gateway connect probe with device identity: performs the OpenClaw 2026.6.1
// pairing flow (wait for connect.challenge → sign nonce with a persistent
// Ed25519 device key → connect) and prints every frame plus a plain-English
// verdict on the negotiated scopes.
//
// Uses the same identity file as the app (~/Library/Application Support/
// Ziel van Sebastian/device-identity.json), so approving the probe's device
// on the gateway also approves the locally-run app.
//
// Usage:   GATEWAY_TOKEN=... swift scripts/probe-gateway.swift <ws-url> [mode]
// Normally run via scripts/probe-gateway.sh, which handles tunnel + token.

import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2,
      let url = URL(string: args[1]),
      let token = ProcessInfo.processInfo.environment["GATEWAY_TOKEN"], !token.isEmpty
else {
    print("usage: GATEWAY_TOKEN=<token> swift scripts/probe-gateway.swift <ws-url> [mode=ui]")
    exit(2)
}
let mode = args.count > 2 ? args[2] : "ui"

// MARK: - Device identity (same format as Sources/Gateway/DeviceIdentity.swift)

func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func base64URLDecode(_ input: String) -> Data? {
    var s = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    s += String(repeating: "=", count: (4 - s.count % 4) % 4)
    return Data(base64Encoded: s)
}

struct Identity {
    let key: Curve25519.Signing.PrivateKey
    var publicKeyB64: String { base64URLEncode(key.publicKey.rawRepresentation) }
    var deviceId: String {
        SHA256.hash(data: key.publicKey.rawRepresentation)
            .map { String(format: "%02x", $0) }.joined()
    }
}

func loadOrCreateIdentity(at fileURL: URL) -> Identity {
    if let data = try? Data(contentsOf: fileURL),
       let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let privB64 = obj["privateKey"] as? String,
       let raw = base64URLDecode(privB64),
       let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
        return Identity(key: key)
    }
    let identity = Identity(key: Curve25519.Signing.PrivateKey())
    let stored: [String: Any] = [
        "version": 1,
        "deviceId": identity.deviceId,
        "publicKey": identity.publicKeyB64,
        "privateKey": base64URLEncode(identity.key.rawRepresentation),
    ]
    try? FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: stored) {
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    return identity
}

let identityURL = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Ziel van Sebastian/device-identity.json")
let identity = loadOrCreateIdentity(at: identityURL)
print("device id: \(identity.deviceId)")
print("identity:  \(identityURL.path)\n")

func redact(_ s: String) -> String { s.replacingOccurrences(of: token, with: "<token>") }

func findKey(_ key: String, in value: Any, path: String = "") -> [(path: String, value: Any)] {
    var found: [(String, Any)] = []
    if let dict = value as? [String: Any] {
        for (k, v) in dict {
            let p = path.isEmpty ? k : "\(path).\(k)"
            if k == key { found.append((p, v)) }
            found += findKey(key, in: v, path: p)
        }
    } else if let array = value as? [Any] {
        for (i, v) in array.enumerated() {
            found += findKey(key, in: v, path: "\(path)[\(i)]")
        }
    }
    return found
}

// MARK: - Connect

let session = URLSession(configuration: .ephemeral)
let task = session.webSocketTask(with: url)
task.resume()

func sendConnect(nonce: String) {
    let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
    let payload = [
        "v3", identity.deviceId, "gateway-client", mode, "operator",
        "operator.read", String(signedAtMs), token, nonce, "macos", "",
    ].joined(separator: "|")
    let signature = base64URLEncode(try! identity.key.signature(for: Data(payload.utf8)))
    let frame: [String: Any] = [
        "type": "req", "id": "probe-1", "method": "connect",
        "params": [
            "minProtocol": 3, "maxProtocol": 4,
            "client": ["id": "gateway-client", "version": "1.0.0",
                       "displayName": "Ziel van Sebastian",
                       "platform": "macos", "mode": mode],
            "role": "operator",
            "scopes": ["operator.read"],
            "auth": ["token": token],
            "device": ["id": identity.deviceId, "publicKey": identity.publicKeyB64,
                       "signature": signature, "signedAt": signedAtMs, "nonce": nonce],
        ],
    ]
    let data = try! JSONSerialization.data(withJSONObject: frame)
    let text = String(data: data, encoding: .utf8)!
    print(">> \(redact(text))\n")
    task.send(.string(text)) { error in
        if let error {
            print("send failed: \(error.localizedDescription)")
            print("VERDICT: could not reach gateway at \(url) — is the tunnel up?")
            exit(1)
        }
    }
}

func verdict(for response: [String: Any]) {
    guard response["ok"] as? Bool == true else {
        let error = findKey("error", in: response).first.map { "\($0.value)" } ?? "unknown error"
        let message = redact(error)
        print("\nVERDICT: REJECTED — \(message)")
        if message.lowercased().contains("pairing") || message.lowercased().contains("approval") {
            print("This is the one-time pairing step. On vm-claw run:")
            print("  openclaw devices list      → find request for device \(identity.deviceId.prefix(12))…")
            print("  openclaw devices approve <request-id>")
            print("then re-run this probe. The approval is durable for this device key.")
        }
        exit(1)
    }
    let scopeHits = findKey("scopes", in: response)
    let granted = scopeHits.flatMap { ($0.value as? [String]) ?? [] }
    let role = findKey("role", in: response).first.flatMap { $0.value as? String } ?? "?"
    print("\nhandshake ok — role=\(role)")
    for hit in scopeHits { print("  \(hit.path) = \(hit.value)") }
    if granted.contains("operator.read") {
        print("\nVERDICT: SCOPES GRANTED ✓ — device pairing works; the app can use mode \"\(mode)\".")
        exit(0)
    } else if scopeHits.isEmpty {
        print("\nVERDICT: handshake ok but no scopes field found — paste this output back for analysis.")
        exit(0)
    } else {
        print("\nVERDICT: SCOPES CLEARED — gateway accepted us but stripped operator.read.")
        print("On vm-claw run: openclaw devices list  → approve the pending request → re-run this probe.")
        exit(1)
    }
}

func receiveLoop() {
    task.receive { result in
        switch result {
        case .failure(let error):
            print("socket closed: \(error.localizedDescription)")
            print("VERDICT: could not reach gateway at \(url) — is the tunnel up?")
            exit(1)
        case .success(let message):
            var text = ""
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(data: d, encoding: .utf8) ?? "<binary \(d.count)B>"
            @unknown default: text = "<unknown frame>"
            }
            print("<< \(redact(text))")
            if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                if obj["type"] as? String == "event",
                   obj["event"] as? String == "connect.challenge",
                   let payload = obj["payload"] as? [String: Any],
                   let nonce = payload["nonce"] as? String, !nonce.isEmpty {
                    sendConnect(nonce: nonce)
                } else if obj["id"] as? String == "probe-1" {
                    verdict(for: obj)
                }
            }
            receiveLoop()
        }
    }
}
receiveLoop()

// Give the gateway up to 10s (challenge + response).
RunLoop.main.run(until: Date().addingTimeInterval(10))
print("\nVERDICT: no connect.challenge/response within 10s — paste output back for analysis.")
exit(1)
