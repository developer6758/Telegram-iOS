import Foundation
import XCTest
import CryptoKit
@testable import TimeCapsuleCore

final class CapsuleCoreTests: XCTestCase {
    private func fixture() throws -> [String: String] {
        let raw = try JSONSerialization.jsonObject(with: capsuleGoFixtureJSON) as! [String: Any]
        return raw.compactMapValues { $0 as? String }
    }
    private func configuration(_ vector: [String: String]) throws -> CapsuleConfiguration {
        let der = try CapsuleWire.decode(vector["public_key_spki_der_b64url"]!, maximum: 256)
        return try CapsuleConfiguration(service: "time-capsule-test", baseURL: URL(string: "https://capsule.example.invalid")!, verificationKeys: [vector["kid"]!: der.base64EncodedString()])
    }
    private var context: CapsuleMessageContext {
        return CapsuleMessageContext(accountId: "987654321", senderId: "123456789", peerId: "123456789", isOutgoing: false, isForwarded: false, isDirectCloudChat: true)
    }
    private func release(_ vector: [String: String]) -> CapsuleReleaseResponse {
        return CapsuleReleaseResponse(bindingB64URL: vector["binding_b64url"]!, nonce: vector["nonce"]!, ciphertext: vector["ciphertext"]!, tag: vector["tag"]!, contentKey: vector["content_key"]!, serverMs: 1792782075000, revision: 1)
    }
    private func changed(_ value: String) throws -> String {
        var bytes = try CapsuleWire.decode(value, maximum: 65536)
        bytes[bytes.startIndex] ^= 1
        return CapsuleWire.encode(bytes)
    }

    func testGoSignedDescriptorAndEncryptedUnicodePayload() throws {
        let vector = try fixture()
        let envelope = try CapsuleEnvelopeCodec.verify(vector["carrier"]!, configuration: configuration(vector), context: context)
        let plaintext = try CapsuleCrypto.decrypt(release(vector), envelope: envelope)
        XCTAssertEqual(plaintext.text, vector["text"])
        XCTAssertEqual(envelope.descriptor.unlockMs - envelope.descriptor.createdMs, 75000)
        XCTAssertEqual(envelope.descriptor.recipientId, context.accountId)
        XCTAssertEqual(CapsuleCrypto.digest(try CapsuleWire.decode(vector["binding_b64url"]!, maximum: 4096)), envelope.descriptor.bindingSHA256)
    }

    func testDescriptorSignatureAndKeyTamperingFailClosed() throws {
        let vector = try fixture(), config = try configuration(vector)
        let signatureChanged = CapsuleEnvelopeCodec.prefix + vector["kid"]! + "." + vector["descriptor_b64url"]! + "." + (try changed(vector["signature_der_b64url"]!))
        let descriptorChanged = CapsuleEnvelopeCodec.prefix + vector["kid"]! + "." + (try changed(vector["descriptor_b64url"]!)) + "." + vector["signature_der_b64url"]!
        XCTAssertThrowsError(try CapsuleEnvelopeCodec.verify(signatureChanged, configuration: config, context: context))
        XCTAssertThrowsError(try CapsuleEnvelopeCodec.verify(descriptorChanged, configuration: config, context: context))
        let unknownKey = vector["carrier"]!.replacingOccurrences(of: "TCAP1." + vector["kid"]!, with: "TCAP1.unknown")
        XCTAssertThrowsError(try CapsuleEnvelopeCodec.verify(unknownKey, configuration: config, context: context))
        XCTAssertThrowsError(try CapsuleEnvelopeCodec.verify(vector["carrier"]! + ".extra", configuration: config))
        XCTAssertThrowsError(try CapsuleEnvelopeCodec.verify(vector["carrier"]! + String(repeating: "a", count: 3500), configuration: config))
    }

    func testCopiedForwardedAndWrongAccountEnvelopesCannotBecomeInteractive() throws {
        let vector = try fixture(), config = try configuration(vector)
        let invalidContexts = [
            CapsuleMessageContext(accountId: "987654321", senderId: "123456789", peerId: "123456789", isOutgoing: false, isForwarded: true, isDirectCloudChat: true),
            CapsuleMessageContext(accountId: "987654321", senderId: "123456789", peerId: "555", isOutgoing: false, isForwarded: false, isDirectCloudChat: true),
            CapsuleMessageContext(accountId: "555", senderId: "123456789", peerId: "123456789", isOutgoing: false, isForwarded: false, isDirectCloudChat: true),
            CapsuleMessageContext(accountId: "987654321", senderId: "555", peerId: "123456789", isOutgoing: false, isForwarded: false, isDirectCloudChat: true),
            CapsuleMessageContext(accountId: "987654321", senderId: "123456789", peerId: "123456789", isOutgoing: false, isForwarded: false, isDirectCloudChat: false)
        ]
        for invalid in invalidContexts { XCTAssertThrowsError(try CapsuleEnvelopeCodec.verify(vector["carrier"]!, configuration: config, context: invalid)) }
    }

    func testBindingCiphertextNonceTagAndKeyTamperingNeverReturnsText() throws {
        let vector = try fixture(), envelope = try CapsuleEnvelopeCodec.verify(vector["carrier"]!, configuration: configuration(vector), context: context)
        for field in ["binding_b64url", "nonce", "ciphertext", "tag", "content_key"] {
            var tampered = vector; tampered[field] = try changed(vector[field]!)
            XCTAssertThrowsError(try CapsuleCrypto.decrypt(release(tampered), envelope: envelope), field)
        }
    }

    func testDuplicateEscapedMembersAndDeepJSONRejected() throws {
        struct Value: Decodable { let v: Int }
        for source in [#"{"v":1,"v":2}"#, #"{"v":1,"\u0076":2}"#, #"{"v":1,"nested":{"x":0,"x":1}}"#] {
            XCTAssertThrowsError(try CapsuleStrictJSON.decode(Value.self, from: Data(source.utf8)))
        }
        let deep = String(repeating: "[", count: 25) + "0" + String(repeating: "]", count: 25)
        XCTAssertThrowsError(try CapsuleStrictJSON.decode([Int].self, from: Data(deep.utf8)))
        XCTAssertThrowsError(try CapsuleStrictJSON.decode(Value.self, from: Data([0xff, 0xfe])))
        XCTAssertThrowsError(try CapsuleStrictJSON.decode(Value.self, from: Data(#"{"v":1} trailing"#.utf8)))
    }

    func testPayloadValidatesUTF16EntityBoundariesAndCrossingRanges() throws {
        let text = "A😀e\u{301}שלום العربية"
        XCTAssertNoThrow(try CapsulePayload(text: text, entities: [CapsuleEntity(type: "bold", offset: 1, length: 2)]).validate())
        XCTAssertThrowsError(try CapsulePayload(text: text, entities: [CapsuleEntity(type: "bold", offset: 2, length: 1)]).validate())
        XCTAssertThrowsError(try CapsulePayload(text: text, entities: [CapsuleEntity(type: "bold", offset: 1, length: Int.max)]).validate())
        XCTAssertThrowsError(try CapsulePayload(text: "123456789", entities: [CapsuleEntity(type: "bold", offset: 0, length: 5), CapsuleEntity(type: "italic", offset: 4, length: 4)]).validate())
        XCTAssertThrowsError(try CapsulePayload(text: "secret", entities: [CapsuleEntity(type: "custom_emoji", offset: 0, length: 6)]).validate())
        XCTAssertThrowsError(try CapsulePayload(text: "link", entities: [CapsuleEntity(type: "text_url", offset: 0, length: 4, url: "javascript:alert(1)")]).validate())
        XCTAssertThrowsError(try CapsulePayload(text: String(repeating: "😀", count: 2049)).validate())
    }

    func testLayoutAndConfigurationBounds() throws {
        let valid = CapsuleLayout(samples: [CapsuleLayoutSample(constraintEm: 14, widthEm: 5, heightEm: 1.25), CapsuleLayoutSample(constraintEm: 20, widthEm: 5, heightEm: 1.25), CapsuleLayoutSample(constraintEm: 28, widthEm: 5, heightEm: 1.25)])
        XCTAssertNoThrow(try valid.validate())
        XCTAssertThrowsError(try CapsuleLayout(samples: [CapsuleLayoutSample(constraintEm: 14, widthEm: .infinity, heightEm: -1)]).validate())
        XCTAssertThrowsError(try CapsuleLayout(samples: [CapsuleLayoutSample(constraintEm: 14, widthEm: 15, heightEm: 1), valid.samples[1], valid.samples[2]]).validate())
        let vector = try fixture(), config = try configuration(vector)
        XCTAssertThrowsError(try CapsuleConfiguration(service: config.service, baseURL: URL(string: "http://localhost")!, verificationKeys: config.verificationKeys))
        XCTAssertThrowsError(try CapsuleConfiguration(service: config.service, baseURL: URL(string: "https://user:pass@capsule.example.invalid")!, verificationKeys: config.verificationKeys))
        for invalid in ["0", "01", "-1", "9223372036854775808", "1.5", "123e4"] { XCTAssertFalse(CapsuleWire.validUserId(invalid)) }
        for invalid in ["YQ==", "YQ+", "YQ/", "Y", "YR"] { XCTAssertThrowsError(try CapsuleWire.decode(invalid, maximum: 32)) }
    }

    func testCountdownBoundaryTransitionsAndCeiling() {
        let values: [(Int64, String)] = [(1, "00:00:01"), (8, "00:00:08"), (59, "00:00:59"), (60, "00:01:00"), (3599, "00:59:59"), (3600, "01:00:00"), (86399, "23:59:59"), (86400, "1d 00:00:00"), (95415, "1d 02:30:15"), (1239123, "14d 08:12:03"), (31536000, "365d 00:00:00"), (0, "Tap to open")]
        for (seconds, expected) in values { XCTAssertEqual(CapsuleCountdown.label(remainingSeconds: seconds), expected) }
        XCTAssertEqual(CapsuleCountdown.remainingSeconds(unlockMs: 1001, estimatedServerMs: 1000), 1)
        XCTAssertEqual(CapsuleCountdown.remainingSeconds(unlockMs: 1000, estimatedServerMs: 1000), 0)
        XCTAssertEqual(CapsuleCountdown.remainingSeconds(unlockMs: 999, estimatedServerMs: 1000), 0)
        XCTAssertEqual(CapsuleCountdown.label(remainingSeconds: CapsuleCountdown.remainingSeconds(unlockMs: 86_400_000, estimatedServerMs: 0)), "1d 00:00:00")
        XCTAssertEqual(CapsuleCountdown.label(remainingSeconds: CapsuleCountdown.remainingSeconds(unlockMs: 86_400_000, estimatedServerMs: 1000)), "23:59:59")
    }

    func testFreshEncryptionUsesBucketAndDistinctRandomness() throws {
        let vector = try fixture(), binding = try CapsuleWire.decode(vector["binding_b64url"]!, maximum: 4096)
        let payload = CapsulePayload(text: vector["text"]!)
        let first = try CapsuleCrypto.encrypt(payload, binding: binding)
        let second = try CapsuleCrypto.encrypt(payload, binding: binding)
        XCTAssertNotEqual(first.contentKey, second.contentKey)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotEqual(first.ciphertext, second.ciphertext)
        XCTAssertTrue(CapsuleCrypto.buckets.contains(try CapsuleWire.decode(first.ciphertext, maximum: 65536).count))
        XCTAssertEqual(first.bindingSHA256, second.bindingSHA256)
    }

    func testProtectedStoreSurvivesRestartAndNeverWritesSentinelPlaintext() throws {
        let account = "123456789", service = "unit-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try CapsuleStore(accountId: account, service: service, directory: directory)
        defer { try? first.destroy() }
        let sentinel = "private-test-" + UUID().uuidString
        try first.update { state in state.releases["opaque-test-capsule"] = CapsuleCachedRelease(descriptorSHA256: "test", payload: CapsulePayload(text: sentinel), locallyOpened: true) }
        let encrypted = try Data(contentsOf: directory.appendingPathComponent("capsules-v1.aesgcm"))
        XCTAssertNil(encrypted.range(of: Data(sentinel.utf8)))
        let restarted = try CapsuleStore(accountId: account, service: service, directory: directory)
        XCTAssertEqual(try restarted.read().releases["opaque-test-capsule"]?.payload.text, sentinel)
        XCTAssertEqual(try restarted.read().releases["opaque-test-capsule"]?.locallyOpened, true)
        XCTAssertThrowsError(try CapsuleStore(accountId: "222222222", service: service, directory: directory))
    }
}
