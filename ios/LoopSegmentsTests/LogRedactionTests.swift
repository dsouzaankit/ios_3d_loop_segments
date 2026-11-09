import XCTest
@testable import LoopSegments

/// Export logs are served on the LAN without a login, so URLs written to them must not carry
/// passwords or tokens.
final class LogRedactionTests: XCTestCase {
    private func redacted(_ s: String) -> String {
        guard let url = URL(string: s) else { XCTFail("bad test URL: \(s)"); return "" }
        return url.redactedForLog
    }

    func testDropsUserInfoQueryAndFragment() {
        XCTAssertEqual(redacted("https://user:secret@media.example.com:8443/a/b.mp4?token=abc&exp=1#t=10"),
                       "https://media.example.com:8443/a/b.mp4?…")
    }

    func testKeepsPlainURLsUnchanged() {
        XCTAssertEqual(redacted("https://webdav.pcloud.com/p_cld_media/clip.mp4"), "https://webdav.pcloud.com/p_cld_media/clip.mp4")
        XCTAssertEqual(redacted("http://10.0.100.10:8765/"), "http://10.0.100.10:8765/")
    }

    func testKeepsPercentEncodedPath() {
        XCTAssertEqual(redacted("https://h.example/My%20Clip%20%231.mp4"), "https://h.example/My%20Clip%20%231.mp4")
    }

    func testMarksAnEmptyQuery() {
        XCTAssertEqual(redacted("https://h.example/a.mp4?"), "https://h.example/a.mp4?…")
    }

    func testNeverLeaksTheSecret() {
        let out = redacted("https://u:hunter2@h.example/x?sig=hunter3")
        XCTAssertFalse(out.contains("hunter2"))
        XCTAssertFalse(out.contains("hunter3"))
    }
}
