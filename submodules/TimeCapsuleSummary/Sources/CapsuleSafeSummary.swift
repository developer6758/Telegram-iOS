import Foundation

/// Presentation redaction only. Recognition here never authenticates a descriptor or enables release.
/// This module deliberately has no credentials, storage, networking or cryptographic dependencies,
/// so notification extensions and other preview consumers cannot obtain capsule content.
public enum CapsuleSafeSummary {
    public static let carrierPrefix = "Time Capsule — requires a compatible client.\nTCAP1."

    public static func isCarrier(_ text: String) -> Bool {
        return text.hasPrefix(carrierPrefix)
    }

    public static func resolve(_ text: String, summary: String = "Time capsule") -> String {
        return isCarrier(text) ? summary : text
    }
}
