import Foundation
import CryptoKit
import Security

struct CapsuleEncryptedPayload: Codable {
    let bindingSHA256: String
    let nonce: String
    let ciphertext: String
    let tag: String
    let contentKey: String
    enum CodingKeys: String, CodingKey { case bindingSHA256 = "binding_sha256", nonce, ciphertext, tag, contentKey = "content_key" }
}

public enum CapsuleCrypto {
    static let buckets = [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { bytes in SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!) }
        guard result == errSecSuccess else { throw CapsuleError.unavailable }
        return data
    }
    static func digest(_ data: Data) -> String { return CapsuleWire.encode(Data(SHA256.hash(data: data))) }
    static func encrypt(_ payload: CapsulePayload, binding: Data) throws -> CapsuleEncryptedPayload {
        try payload.validate()
        let json = try JSONEncoder().encode(payload)
        guard let bucket = buckets.first(where: { $0 >= json.count + 4 }) else { throw CapsuleError.invalidData }
        var padded = try random(bucket)
        let length = UInt32(json.count)
        padded[0] = UInt8((length >> 24) & 255); padded[1] = UInt8((length >> 16) & 255)
        padded[2] = UInt8((length >> 8) & 255); padded[3] = UInt8(length & 255)
        padded.replaceSubrange(4..<(json.count + 4), with: json)
        let keyData = try random(32), nonceData = try random(12)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        var aad = Data("TCAP-PAYLOAD-v1\0".utf8); aad.append(binding)
        let box = try AES.GCM.seal(padded, using: SymmetricKey(data: keyData), nonce: nonce, authenticating: aad)
        return CapsuleEncryptedPayload(bindingSHA256: digest(binding), nonce: CapsuleWire.encode(nonceData), ciphertext: CapsuleWire.encode(box.ciphertext), tag: CapsuleWire.encode(box.tag), contentKey: CapsuleWire.encode(keyData))
    }
    static func decrypt(_ response: CapsuleReleaseResponse, envelope: CapsuleEnvelope) throws -> CapsulePayload {
        let bindingBytes = try CapsuleWire.decode(response.bindingB64URL, maximum: 4096)
        guard digest(bindingBytes) == envelope.descriptor.bindingSHA256 else { throw CapsuleError.integrity }
        let binding = try CapsuleStrictJSON.decode(CapsuleBinding.self, from: bindingBytes, maximum: 4096)
        guard binding.matches(envelope.descriptor) else { throw CapsuleError.integrity }
        let nonce = try CapsuleWire.decode(response.nonce, maximum: 12)
        let ciphertext = try CapsuleWire.decode(response.ciphertext, maximum: 65536)
        let tag = try CapsuleWire.decode(response.tag, maximum: 16)
        var key = try CapsuleWire.decode(response.contentKey, maximum: 32)
        defer { key.resetBytes(in: 0..<key.count) }
        guard nonce.count == 12, tag.count == 16, key.count == 32, buckets.contains(ciphertext.count),
            digest(nonce + ciphertext + tag) == envelope.descriptor.payloadSHA256 else { throw CapsuleError.integrity }
        var aad = Data("TCAP-PAYLOAD-v1\0".utf8); aad.append(bindingBytes)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
        var padded: Data
        do { padded = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad) } catch { throw CapsuleError.integrity }
        defer { padded.resetBytes(in: 0..<padded.count) }
        guard padded.count >= 4 else { throw CapsuleError.integrity }
        let length = (UInt32(padded[0]) << 24) | (UInt32(padded[1]) << 16) | (UInt32(padded[2]) << 8) | UInt32(padded[3])
        guard length > 0, Int(length) <= padded.count - 4 else { throw CapsuleError.integrity }
        let payload = try CapsuleStrictJSON.decode(CapsulePayload.self, from: padded.subdata(in: 4..<(4 + Int(length))), maximum: 65532)
        try payload.validate()
        return payload
    }
}
