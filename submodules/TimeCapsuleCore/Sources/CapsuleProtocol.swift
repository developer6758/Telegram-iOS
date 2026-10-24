import Foundation
import CryptoKit

public enum CapsuleError: Error, LocalizedError {
    case invalidData, integrity, unavailable, notAuthenticated, accountMismatch, cancelled
    case server(code: String, retryable: Bool, unlockMs: Int64?)

    public var errorDescription: String? {
        switch self {
        case .invalidData, .integrity: return "This time capsule could not be verified."
        case .unavailable: return "This time capsule is unavailable."
        case .notAuthenticated: return "Sign in to open time capsules."
        case .accountMismatch: return "Select the Telegram account used for this chat."
        case .cancelled: return "The operation was cancelled."
        case let .server(code, _, _):
            switch code {
            case "not_ready": return "This time capsule is still locked."
            case "revoked", "hidden", "unavailable": return "This time capsule is unavailable."
            default: return "Could not connect. Tap to try again."
            }
        }
    }
}

public struct CapsuleLayoutSample: Codable, Equatable {
    public let constraintEm: Double
    public let widthEm: Double
    public let heightEm: Double
    public init(constraintEm: Double, widthEm: Double, heightEm: Double) {
        self.constraintEm = constraintEm; self.widthEm = widthEm; self.heightEm = heightEm
    }
    enum CodingKeys: String, CodingKey { case constraintEm = "constraint_em", widthEm = "width_em", heightEm = "height_em" }
}

public struct CapsuleLayout: Codable, Equatable {
    public let v: Int
    public let samples: [CapsuleLayoutSample]
    public init(samples: [CapsuleLayoutSample]) { self.v = 1; self.samples = samples }
    public func validate() throws {
        guard v == 1, samples.count == 3 else { throw CapsuleError.invalidData }
        for (index, sample) in samples.enumerated() {
            guard sample.constraintEm == [14.0, 20.0, 28.0][index],
                sample.widthEm.isFinite, sample.heightEm.isFinite,
                sample.widthEm > 0, sample.widthEm <= sample.constraintEm,
                sample.heightEm > 0, sample.heightEm <= 512,
                (sample.widthEm * 4).rounded() == sample.widthEm * 4,
                (sample.heightEm * 4).rounded() == sample.heightEm * 4 else { throw CapsuleError.invalidData }
        }
    }
}

public struct CapsuleEntity: Codable, Equatable {
    public let type: String
    public let offset: Int
    public let length: Int
    public let url: String?
    public let language: String?
    public init(type: String, offset: Int, length: Int, url: String? = nil, language: String? = nil) {
        self.type = type; self.offset = offset; self.length = length; self.url = url; self.language = language
    }
}

public struct CapsulePayload: Codable, Equatable {
    public let v: Int
    public let text: String
    public let entities: [CapsuleEntity]
    public init(text: String, entities: [CapsuleEntity] = []) { self.v = 1; self.text = text; self.entities = entities }
    public func validate() throws {
        let units = Array(text.utf16)
        guard v == 1, !text.isEmpty, units.count <= 4096, text.utf8.count <= 16384, entities.count <= 128 else { throw CapsuleError.invalidData }
        let allowed = Set(["bold", "italic", "underline", "strike", "code", "pre", "spoiler", "text_url", "url"])
        func isBoundary(_ offset: Int) -> Bool {
            return offset == 0 || offset == units.count || !(0xDC00...0xDFFF).contains(units[offset])
        }
        for entity in entities {
            guard allowed.contains(entity.type), entity.offset >= 0, entity.length > 0,
                entity.offset <= units.count, entity.length <= units.count - entity.offset,
                isBoundary(entity.offset), isBoundary(entity.offset + entity.length),
                (entity.language?.utf8.count ?? 0) <= 64, (entity.url?.utf8.count ?? 0) <= 2048 else { throw CapsuleError.invalidData }
            if entity.type == "text_url" {
                guard let url = entity.url, let parsed = URL(string: url),
                    ["https", "http", "mailto", "tg"].contains(parsed.scheme?.lowercased() ?? ""),
                    !url.unicodeScalars.contains(where: { $0.value < 32 }) else { throw CapsuleError.invalidData }
            } else if entity.url != nil { throw CapsuleError.invalidData }
            if entity.type != "pre" && entity.language != nil { throw CapsuleError.invalidData }
            if let language = entity.language {
                guard language.utf8.allSatisfy({ CapsuleWire.isBase64URL($0) || $0 == 43 || $0 == 46 }) else { throw CapsuleError.invalidData }
            }
        }
        // Nested formatting is supported; crossing ranges and code/pre nesting are not.
        for i in entities.indices {
            for j in entities.indices where j > i {
                let a = entities[i], b = entities[j]
                let aEnd = a.offset + a.length, bEnd = b.offset + b.length
                let overlaps = a.offset < bEnd && b.offset < aEnd
                if overlaps {
                    let nested = (a.offset <= b.offset && aEnd >= bEnd) || (b.offset <= a.offset && bEnd >= aEnd)
                    guard nested, ![a.type, b.type].contains("code"), ![a.type, b.type].contains("pre") else { throw CapsuleError.invalidData }
                }
            }
        }
    }
}

public struct CapsuleDescriptor: Codable, Equatable {
    public let v: Int
    public let service: String
    public let capsuleId: String
    public let senderId: String
    public let recipientId: String
    public let createdMs: Int64
    public let unlockMs: Int64
    public let durationSeconds: Int64
    public let bindingSHA256: String
    public let payloadSHA256: String
    public let layout: CapsuleLayout
    enum CodingKeys: String, CodingKey {
        case v, service, capsuleId = "capsule_id", senderId = "sender_id", recipientId = "recipient_id"
        case createdMs = "created_ms", unlockMs = "unlock_ms", durationSeconds = "duration_s"
        case bindingSHA256 = "binding_sha256", payloadSHA256 = "payload_sha256", layout
    }
    func validate(service expectedService: String) throws {
        guard v == 1, service == expectedService, CapsuleWire.validOpaqueId(capsuleId),
            CapsuleWire.validUserId(senderId), CapsuleWire.validUserId(recipientId), senderId != recipientId,
            (1...31_536_000).contains(durationSeconds), createdMs > 0,
            createdMs <= Int64.max - durationSeconds * 1000,
            unlockMs == createdMs + durationSeconds * 1000,
            try CapsuleWire.decode(bindingSHA256, maximum: 32).count == 32,
            try CapsuleWire.decode(payloadSHA256, maximum: 32).count == 32 else { throw CapsuleError.invalidData }
        try layout.validate()
    }
}

struct CapsuleBinding: Codable, Equatable {
    let v: Int
    let service: String
    let capsuleId: String
    let senderId: String
    let recipientId: String
    let durationSeconds: Int64
    let layout: CapsuleLayout
    enum CodingKeys: String, CodingKey {
        case v, service, capsuleId = "capsule_id", senderId = "sender_id", recipientId = "recipient_id", durationSeconds = "duration_s", layout
    }
    func matches(_ descriptor: CapsuleDescriptor) -> Bool {
        return v == descriptor.v && service == descriptor.service && capsuleId == descriptor.capsuleId && senderId == descriptor.senderId && recipientId == descriptor.recipientId && durationSeconds == descriptor.durationSeconds && layout == descriptor.layout
    }
}

public struct CapsuleMessageContext: Equatable {
    public let accountId: String
    public let senderId: String
    public let peerId: String
    public let isOutgoing: Bool
    public let isForwarded: Bool
    public let isDirectCloudChat: Bool
    public init(accountId: String, senderId: String, peerId: String, isOutgoing: Bool, isForwarded: Bool, isDirectCloudChat: Bool) {
        self.accountId = accountId; self.senderId = senderId; self.peerId = peerId
        self.isOutgoing = isOutgoing; self.isForwarded = isForwarded; self.isDirectCloudChat = isDirectCloudChat
    }
    public func validate(_ descriptor: CapsuleDescriptor) throws {
        guard isDirectCloudChat, !isForwarded, senderId == descriptor.senderId else { throw CapsuleError.integrity }
        if isOutgoing {
            guard accountId == descriptor.senderId, peerId == descriptor.recipientId else { throw CapsuleError.integrity }
        } else {
            guard accountId == descriptor.recipientId, peerId == descriptor.senderId else { throw CapsuleError.integrity }
        }
    }
}

public struct CapsuleEnvelope: Equatable {
    public let descriptor: CapsuleDescriptor
    public let carrier: String
    public let keyId: String
    public let descriptorBytes: Data
    public let signatureDER: Data
}

public struct CapsuleConfiguration: Codable {
    public let service: String
    public let baseURL: URL
    public let verificationKeys: [String: String]
    enum CodingKeys: String, CodingKey { case service, baseURL = "base_url", verificationKeys = "verification_keys" }
    public init(service: String, baseURL: URL, verificationKeys: [String: String]) throws {
        self.service = service; self.baseURL = baseURL; self.verificationKeys = verificationKeys
        try validate()
    }
    public func validate() throws {
        guard !service.isEmpty, service.utf8.count <= 64, baseURL.scheme == "https", baseURL.host != nil,
            baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
            baseURL.path.isEmpty || baseURL.path == "/", !verificationKeys.isEmpty, verificationKeys.count <= 8 else { throw CapsuleError.invalidData }
        for (kid, encoded) in verificationKeys {
            guard CapsuleWire.validKeyId(kid), let der = Data(base64Encoded: encoded), der.count <= 256 else { throw CapsuleError.invalidData }
            _ = try P256.Signing.PublicKey(derRepresentation: der)
        }
    }
    public static func load(bundle: Bundle = .main) -> CapsuleConfiguration? {
        guard let url = bundle.url(forResource: "TimeCapsuleConfiguration", withExtension: "json"),
            let bytes = try? Data(contentsOf: url), bytes.count <= 8192,
            let configuration = try? CapsuleStrictJSON.decode(CapsuleConfiguration.self, from: bytes),
            (try? configuration.validate()) != nil else { return nil }
        return configuration
    }
}

public enum CapsuleEnvelopeCodec {
    public static let prefix = "Time Capsule — requires a compatible client.\nTCAP1."
    public static func isCandidate(_ text: String) -> Bool { return text.hasPrefix(prefix) }
    public static func verify(_ carrier: String, configuration: CapsuleConfiguration, context: CapsuleMessageContext? = nil) throws -> CapsuleEnvelope {
        guard carrier.utf16.count <= 3500, isCandidate(carrier) else { throw CapsuleError.invalidData }
        let fields = carrier.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { throw CapsuleError.invalidData }
        let kid = String(fields[0])
        guard CapsuleWire.validKeyId(kid), let publicKey = configuration.verificationKeys[kid], let der = Data(base64Encoded: publicKey) else { throw CapsuleError.integrity }
        let descriptorBytes = try CapsuleWire.decode(String(fields[1]), maximum: 2048)
        let signatureDER = try CapsuleWire.decode(String(fields[2]), maximum: 80)
        let key = try P256.Signing.PublicKey(derRepresentation: der)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureDER)
        var signingBytes = Data("TCAP-DESC-v1\0".utf8)
        signingBytes.append(Data(kid.utf8)); signingBytes.append(0); signingBytes.append(descriptorBytes)
        // The Data overload hashes exactly once, matching Go SignASN1(SHA256(message)).
        guard key.isValidSignature(signature, for: signingBytes) else { throw CapsuleError.integrity }
        let descriptor = try CapsuleStrictJSON.decode(CapsuleDescriptor.self, from: descriptorBytes)
        try descriptor.validate(service: configuration.service)
        if let context = context { try context.validate(descriptor) }
        return CapsuleEnvelope(descriptor: descriptor, carrier: carrier, keyId: kid, descriptorBytes: descriptorBytes, signatureDER: signatureDER)
    }
}

enum CapsuleWire {
    static func validUserId(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 19, value.first != "0", value.utf8.allSatisfy({ (48...57).contains($0) }), let id = Int64(value), id > 0 else { return false }
        return true
    }
    static func validKeyId(_ value: String) -> Bool { return !value.isEmpty && value.utf8.count <= 32 && value.utf8.allSatisfy(isBase64URL) }
    static func validOpaqueId(_ value: String) -> Bool { return value.utf8.count >= 16 && value.utf8.count <= 128 && value.utf8.allSatisfy(isBase64URL) }
    static func isBase64URL(_ byte: UInt8) -> Bool { return (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95 }
    static func encode(_ data: Data) -> String { return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decode(_ value: String, maximum: Int) throws -> Data {
        guard !value.isEmpty, value.utf8.count <= ((maximum + 2) / 3) * 4,
            value.utf8.allSatisfy(isBase64URL), value.utf8.count % 4 != 1 else { throw CapsuleError.invalidData }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let result = Data(base64Encoded: base64), result.count <= maximum, encode(result) == value else { throw CapsuleError.invalidData }
        return result
    }
}
