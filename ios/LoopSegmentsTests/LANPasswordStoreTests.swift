import XCTest
@testable import LoopSegments

/// The per-install LAN password (audit #4): its format, the rules for a chosen one, and that it
/// stays the same between reads.
final class LANPasswordStoreTests: XCTestCase {
    func testRandomPasswordFormat() {
        let password = LANPasswordStore.makeRandomPassword()
        XCTAssertEqual(password.count, 19)
        XCTAssertNotNil(password.range(of: "^[a-hjkmnp-z2-9]{4}(-[a-hjkmnp-z2-9]{4}){3}$", options: .regularExpression), password)
        XCTAssertNil(LANPasswordStore.validationProblem(password))
    }

    func testRandomPasswordsDiffer() {
        let many = Set((0..<50).map { _ in LANPasswordStore.makeRandomPassword() })
        XCTAssertEqual(many.count, 50)
    }

    func testChosenPasswordRules() {
        XCTAssertNil(LANPasswordStore.validationProblem("my:Quest#pass1"), "colons and symbols are fine")
        XCTAssertNotNil(LANPasswordStore.validationProblem("short"))
        XCTAssertNotNil(LANPasswordStore.validationProblem(String(repeating: "a", count: 65)))
        XCTAssertNotNil(LANPasswordStore.validationProblem(" leading-space"))
        XCTAssertNotNil(LANPasswordStore.validationProblem("trailing-space "))
        XCTAssertNotNil(LANPasswordStore.validationProblem("émoji-pass😀"))
    }

    func testPasswordStaysTheSameAndSetReplacesIt() {
        let before = LANPasswordStore.current
        XCTAssertEqual(LANPasswordStore.current, before, "reads do not make a new one")
        XCTAssertEqual(ExportLANServer.lanWebDAVPassword, before)
        defer { LANPasswordStore.set(before) }
        XCTAssertNil(LANPasswordStore.set("chosen-pass-123"))
        XCTAssertEqual(LANPasswordStore.current, "chosen-pass-123")
        XCTAssertNotNil(LANPasswordStore.set("bad"))
        XCTAssertEqual(LANPasswordStore.current, "chosen-pass-123", "a refused password changes nothing")
    }
}
