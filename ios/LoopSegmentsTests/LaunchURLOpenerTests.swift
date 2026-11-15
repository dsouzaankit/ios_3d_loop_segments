import XCTest
@testable import LoopSegments

/// The PC launches the app over USB with `-openURL <link>`; only SideStore / Shortcuts links may open.
final class LaunchURLOpenerTests: XCTestCase {
    func testSideStoreInstallLinkIsAccepted() {
        let link = "sidestore://install?url=http://10.0.100.5:8766/LoopSegments.ipa"
        let url = LaunchURLOpener.requestedURL(from: ["LoopSegments", "-openURL", link])
        XCTAssertEqual(url?.absoluteString, link)
    }

    func testShortcutsLinkIsAccepted() {
        let url = LaunchURLOpener.requestedURL(from: ["-openURL", "shortcuts://run-shortcut?name=SideStore%20Refresh"])
        XCTAssertEqual(url?.scheme, "shortcuts")
    }

    func testLocalDevVPNLinkIsAccepted() {
        let url = LaunchURLOpener.requestedURL(from: ["-openURL", "localdevvpn://disable"])
        XCTAssertEqual(url?.host, "disable")
    }

    func testOtherSchemesAreRefused() {
        for link in ["https://example.com", "http://10.0.0.1/x.ipa", "file:///etc/passwd", "tel:123", "prefs:root=General"] {
            XCTAssertNil(LaunchURLOpener.requestedURL(from: ["-openURL", link]), link)
        }
    }

    func testNoArgumentMeansNormalLaunch() {
        XCTAssertNil(LaunchURLOpener.requestedURL(from: ["LoopSegments"]))
        XCTAssertNil(LaunchURLOpener.requestedURL(from: ["LoopSegments", "-openURL"]), "flag without a value")
        XCTAssertNil(LaunchURLOpener.requestedURL(from: ["-openURL", ""]))
    }
}
