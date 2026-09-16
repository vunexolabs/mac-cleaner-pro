import XCTest
import CryptoKit
@testable import Core

final class RulePackVerifierTests: XCTestCase {

    func testValidSignatureDecodes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pack = sampleRulePackJSON()
        let sig = try key.signature(for: pack)
        let publicB64 = key.publicKey.rawRepresentation.base64EncodedString()

        // Stamp the public key into the verifier for this test by injecting a swizzle
        // … but trustedPublicKeyB64 is a static let. So we test the underlying logic directly.
        // Path 1: round-trip via raw CryptoKit (sanity that our format is correct).
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: pack))
        XCTAssertEqual(Data(base64Encoded: publicB64)?.count, 32)
        XCTAssertEqual(sig.count, 64)
    }

    func testTamperedPayloadRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pack = sampleRulePackJSON()
        let sig = try key.signature(for: pack)

        var tampered = pack
        tampered.append(contentsOf: [0x20])  // append a space

        XCTAssertFalse(key.publicKey.isValidSignature(sig, for: tampered))
    }

    /// The verifier refuses to run at all when the pinned key is empty, which is
    /// how it shipped before — signing infrastructure present, trust root blank.
    /// This is the regression guard.
    func testTrustedPublicKeyIsConfigured() throws {
        let b64 = RulePackVerifier.trustedPublicKeyB64
        XCTAssertFalse(b64.isEmpty, "trustedPublicKeyB64 must be pinned — see docs/rule-pack-signing.md")

        let raw = try XCTUnwrap(Data(base64Encoded: b64), "key must be valid base64")
        XCTAssertEqual(raw.count, 32, "Ed25519 public keys are 32 raw bytes")
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: raw))
    }

    /// Matches `keys/rulepack_public.b64`, the committed copy operators sign against.
    func testPinnedKeyMatchesCommittedPublicKeyFile() throws {
        let committed = "dHX3NcnyD9ku9USgN4Kz1CMhIIgsGR7wTnc174+1gwk="
        XCTAssertEqual(RulePackVerifier.trustedPublicKeyB64, committed,
                       "rotating this key is a security event — update keys/ and docs together")
    }

    /// With the key wired up, a bogus signature must fail on the *signature*,
    /// not bail out early with `publicKeyNotConfigured`.
    func testGarbageSignatureFailsVerificationNotConfiguration() throws {
        let verifier = RulePackVerifier()
        let bogus = Data(repeating: 0xAB, count: 64).base64EncodedString()

        XCTAssertThrowsError(
            try verifier.verify(packData: sampleRulePackJSON(),
                                signatureB64: bogus,
                                currentAppVersion: "1.0.3")
        ) { error in
            guard case RulePackVerifierError.signatureInvalid = error else {
                return XCTFail("expected signatureInvalid, got \(error)")
            }
        }
    }

    func testRulePackDecodesFromBundleJSON() throws {
        let pack = sampleRulePackJSON()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RulePack.self, from: pack)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertGreaterThan(decoded.rules.count, 0)
    }

    private func sampleRulePackJSON() -> Data {
        let json = #"""
        {
            "schemaVersion": 1,
            "packVersion": "1.0.0",
            "issuedAt": "2026-04-25T00:00:00Z",
            "minAppVersion": "1.0.0",
            "rules": [
                {
                    "id": "test.rule",
                    "category": "caches",
                    "displayName": "Test",
                    "description": "Test rule",
                    "safety": "safe",
                    "requiresHelper": false,
                    "paths": ["~/Library/Caches/test"]
                }
            ]
        }
        """#
        return Data(json.utf8)
    }
}
