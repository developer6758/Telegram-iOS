import Foundation
import TimeCapsuleCore

/// Converts the deliberately coarse, authenticated sender measurement into native content bounds.
/// It never measures a recipient's hidden text and remains bounded even for hostile layout hints.
public enum CapsuleBubbleGeometry {
    public static func estimate(layout: CapsuleLayout, fontSize: Double, availableWidth: Double) -> (width: Double, height: Double) {
        let fontSize = min(128.0, max(1.0, fontSize.isFinite ? fontSize : 17.0))
        let availableWidth = min(4096.0, max(1.0, availableWidth.isFinite ? availableWidth : 1.0))
        let constraint = availableWidth / fontSize
        let samples = layout.samples.filter {
            $0.constraintEm.isFinite && $0.widthEm.isFinite && $0.heightEm.isFinite &&
            $0.constraintEm > 0 && $0.widthEm > 0 && $0.heightEm > 0
        }.sorted { $0.constraintEm < $1.constraintEm }
        guard let first = samples.first, let last = samples.last else {
            return (min(availableWidth, fontSize * 8.0), fontSize * 1.25)
        }
        var width = first.widthEm
        var height = first.heightEm
        if constraint < first.constraintEm {
            width = min(constraint, first.widthEm)
            height = first.heightEm * max(1.0, first.constraintEm / max(0.25, constraint))
        } else if constraint >= last.constraintEm {
            width = last.widthEm
            height = last.heightEm
        } else {
            for index in 1 ..< samples.count {
                let lower = samples[index - 1]
                let upper = samples[index]
                if constraint <= upper.constraintEm {
                    let fraction = (constraint - lower.constraintEm) / max(0.25, upper.constraintEm - lower.constraintEm)
                    width = lower.widthEm + (upper.widthEm - lower.widthEm) * fraction
                    height = max(lower.heightEm, upper.heightEm)
                    break
                }
            }
        }
        return (
            min(availableWidth, max(1.0, min(512.0, width) * fontSize)),
            max(fontSize * 1.0, min(512.0, height) * fontSize)
        )
    }
}
