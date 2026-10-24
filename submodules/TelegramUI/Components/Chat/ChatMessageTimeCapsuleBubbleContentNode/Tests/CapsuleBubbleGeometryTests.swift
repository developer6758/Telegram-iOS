import XCTest
import TimeCapsuleCore
import ChatMessageTimeCapsuleBubbleContentNode

final class CapsuleBubbleGeometryTests: XCTestCase {
    func testShortAndMultilineHintsProduceDifferentNativeSizes() {
        let short = CapsuleLayout(samples: [14.0, 20.0, 28.0].map { CapsuleLayoutSample(constraintEm: $0, widthEm: 2.0, heightEm: 1.25) })
        let multiline = CapsuleLayout(samples: [
            CapsuleLayoutSample(constraintEm: 14.0, widthEm: 13.75, heightEm: 5.0),
            CapsuleLayoutSample(constraintEm: 20.0, widthEm: 19.5, heightEm: 3.75),
            CapsuleLayoutSample(constraintEm: 28.0, widthEm: 25.0, heightEm: 2.5),
        ])
        let small = CapsuleBubbleGeometry.estimate(layout: short, fontSize: 17.0, availableWidth: 300.0)
        let large = CapsuleBubbleGeometry.estimate(layout: multiline, fontSize: 17.0, availableWidth: 300.0)
        XCTAssertLessThan(small.width, large.width)
        XCTAssertLessThan(small.height, large.height)
        XCTAssertLessThanOrEqual(large.width, 300.0)
    }

    func testNarrowLayoutConservativelyWrapsWithoutOverflow() {
        let layout = CapsuleLayout(samples: [14.0, 20.0, 28.0].map { CapsuleLayoutSample(constraintEm: $0, widthEm: 12.0, heightEm: 2.5) })
        let narrow = CapsuleBubbleGeometry.estimate(layout: layout, fontSize: 34.0, availableWidth: 90.0)
        let regular = CapsuleBubbleGeometry.estimate(layout: layout, fontSize: 34.0, availableWidth: 500.0)
        XCTAssertLessThanOrEqual(narrow.width, 90.0)
        XCTAssertGreaterThan(narrow.height, regular.height)
    }

    func testUntrustedSamplesAndExtremeFontRemainFiniteAndBounded() {
        let hostile = CapsuleLayout(samples: [
            CapsuleLayoutSample(constraintEm: .nan, widthEm: .infinity, heightEm: -1.0),
            CapsuleLayoutSample(constraintEm: 14.0, widthEm: 1.0e100, heightEm: 1.0e100),
        ])
        let result = CapsuleBubbleGeometry.estimate(layout: hostile, fontSize: .infinity, availableWidth: .nan)
        XCTAssertTrue(result.width.isFinite)
        XCTAssertTrue(result.height.isFinite)
        XCTAssertGreaterThan(result.width, 0.0)
        XCTAssertLessThanOrEqual(result.width, 1.0)
        XCTAssertLessThanOrEqual(result.height, 512.0 * 128.0)
    }
}
