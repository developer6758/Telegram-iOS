import Foundation

/// A bounded preflight which rejects duplicate object members, including escaped aliases.
/// JSONDecoder performs the final grammar/type validation; no unbounded JSON graph is made.
enum CapsuleStrictJSON {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, maximum: Int = 160_000) throws -> T {
        guard !data.isEmpty, data.count <= maximum, String(data: data, encoding: .utf8) != nil else { throw CapsuleError.invalidData }
        var scanner = Scanner(bytes: Array(data))
        try scanner.value(depth: 0)
        scanner.whitespace()
        guard scanner.index == scanner.bytes.count else { throw CapsuleError.invalidData }
        do { return try JSONDecoder().decode(type, from: data) } catch { throw CapsuleError.invalidData }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func consume(_ byte: UInt8) throws { guard index < bytes.count, bytes[index] == byte else { throw CapsuleError.invalidData }; index += 1 }
        mutating func string() throws -> String {
            let start = index
            try consume(34)
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if !escaped && byte == 34 {
                    guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { throw CapsuleError.invalidData }
                    return value
                }
                if !escaped && byte < 32 { throw CapsuleError.invalidData }
                if !escaped && byte == 92 { escaped = true } else { escaped = false }
            }
            throw CapsuleError.invalidData
        }
        mutating func value(depth: Int) throws {
            guard depth <= 24 else { throw CapsuleError.invalidData }
            whitespace()
            guard index < bytes.count else { throw CapsuleError.invalidData }
            switch bytes[index] {
            case 123:
                index += 1; whitespace()
                if index < bytes.count && bytes[index] == 125 { index += 1; return }
                var keys = Set<String>()
                while true {
                    whitespace(); let key = try string()
                    guard keys.count < 1024, keys.insert(key).inserted else { throw CapsuleError.invalidData }
                    whitespace(); try consume(58); try value(depth: depth + 1); whitespace()
                    guard index < bytes.count else { throw CapsuleError.invalidData }
                    if bytes[index] == 125 { index += 1; return }
                    try consume(44)
                }
            case 91:
                index += 1; whitespace()
                if index < bytes.count && bytes[index] == 93 { index += 1; return }
                var count = 0
                while true {
                    count += 1; guard count <= 1024 else { throw CapsuleError.invalidData }
                    try value(depth: depth + 1); whitespace()
                    guard index < bytes.count else { throw CapsuleError.invalidData }
                    if bytes[index] == 93 { index += 1; return }
                    try consume(44)
                }
            case 34: _ = try string()
            default:
                let start = index
                while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw CapsuleError.invalidData }
            }
        }
    }
}
