import XCTest
@testable import UpTimePrizes

// The referral token must be the same bytes the backend derives, or a
// referred iPhone sale credits nobody and nobody notices. Expected values come
// from two implementations outside this app: the App Builder's (Node `uuid`
// 14.0.3, published 8 Nov 2026) and Python's `uuid.uuid5` (run by the iOS
// Builder, 8 Nov 2026). They agree with each other; this file checks Swift
// agrees with both.

final class ReferralCodeTests: XCTestCase {

    func testNamespaceIsDerivedFromTheDNSNamespace() {
        XCTAssertEqual(
            ReferralCode.uuidV5(namespace: ReferralCode.dnsNamespace, name: "affiliate.uptimeprizes.com"),
            UUID(uuidString: "c073b658-63a9-5686-b284-4f5ccf51c7a4")
        )
    }

    func testPublishedCheckValue() {
        XCTAssertEqual(ReferralCode.token(for: "katie"),
                       UUID(uuidString: "df49c53c-4d1e-59a3-931b-28d68b424f06"))
        XCTAssertTrue(ReferralCode.derivationMatchesBackend())
    }

    func testFurtherValuesFromPython() {
        XCTAssertEqual(ReferralCode.token(for: "test001"), UUID(uuidString: "c5918b8e-418b-502b-a576-d70a6483e7d3"))
        XCTAssertEqual(ReferralCode.token(for: "kg"), UUID(uuidString: "82fa0f1c-6b56-536b-a9f0-cdaa6edb543c"))
        XCTAssertEqual(ReferralCode.token(for: "apryl-and-gregory"), UUID(uuidString: "0b6fb69b-1950-583c-b4e1-3b473147fb46"))
    }

    func testTrimAndLowercaseBeforeHashing() {
        XCTAssertEqual(ReferralCode.token(for: "  Katie \n"), ReferralCode.token(for: "katie"))
        XCTAssertEqual(ReferralCode.token(for: "KG"), ReferralCode.token(for: "kg"))
    }

    func testStoredCodeShape() {
        // Accepted: what a lookup accepts, including 0 and 1 (test001 exists).
        for ok in ["katie", "test001", "kg", "a_b", "x-1", "0a", String(repeating: "a", count: 64)] {
            XCTAssertTrue(ReferralCode.isValid(ok), ok)
        }
        // Refused.
        for bad in ["", "a", "-katie", "_katie", "ka tie", "katie!", "katie.", "kätie",
                    "katie/1", String(repeating: "a", count: 65)] {
            XCTAssertFalse(ReferralCode.isValid(bad), bad)
            XCTAssertNil(ReferralCode.token(for: bad), bad)
        }
    }
}
