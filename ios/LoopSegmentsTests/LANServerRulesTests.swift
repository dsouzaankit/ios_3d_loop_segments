import XCTest
@testable import LoopSegments

/// Request parsing and auth rules of the LAN server. A quiet mistake here exposes files or
/// blocks clients, so these pin the current behaviour, including its known gaps.
final class LANServerRulesTests: XCTestCase {
    private func headers(_ lines: String...) -> String {
        (["GET / HTTP/1.1"] + lines).joined(separator: "\r\n") + "\r\n"
    }

    private func basic(_ user: String, _ password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    // MARK: Range

    func testRangeWithStartAndEnd() {
        let r = ExportLANServer.parseByteRange(requestHeaders: headers("Range: bytes=0-99"), fileSize: 1000)
        XCTAssertEqual(r?.start, 0)
        XCTAssertEqual(r?.end, 99)
    }

    func testRangeOpenEndedRunsToLastByte() {
        let r = ExportLANServer.parseByteRange(requestHeaders: headers("Range: bytes=500-"), fileSize: 1000)
        XCTAssertEqual(r?.start, 500)
        XCTAssertEqual(r?.end, 999)
    }

    func testRangeSuffixAndOversizedSuffix() {
        let last = ExportLANServer.parseByteRange(requestHeaders: headers("Range: bytes=-100"), fileSize: 1000)
        XCTAssertEqual(last?.start, 900)
        XCTAssertEqual(last?.end, 999)
        let all = ExportLANServer.parseByteRange(requestHeaders: headers("Range: bytes=-5000"), fileSize: 1000)
        XCTAssertEqual(all?.start, 0)
        XCTAssertEqual(all?.end, 999)
    }

    func testRangeEndIsClampedToFileSize() {
        let r = ExportLANServer.parseByteRange(requestHeaders: headers("range: bytes=900-5000"), fileSize: 1000)
        XCTAssertEqual(r?.start, 900)
        XCTAssertEqual(r?.end, 999)
    }

    func testRangeUsesOnlyTheFirstOfSeveral() {
        let r = ExportLANServer.parseByteRange(requestHeaders: headers("Range: bytes=0-1, 5-6"), fileSize: 1000)
        XCTAssertEqual(r?.start, 0)
        XCTAssertEqual(r?.end, 1)
    }

    func testRangeRejectsInvalidInput() {
        let cases = ["Range: bytes=999-0", "Range: items=0-1", "Range: bytes=abc-", "Range: bytes=-0", "Range: bytes="]
        for line in cases {
            XCTAssertNil(ExportLANServer.parseByteRange(requestHeaders: headers(line), fileSize: 1000), line)
        }
        XCTAssertNil(ExportLANServer.parseByteRange(requestHeaders: headers(), fileSize: 1000), "no Range header")
        XCTAssertNil(ExportLANServer.parseByteRange(requestHeaders: headers("Range: bytes=0-1"), fileSize: 0), "empty file")
    }

    // MARK: Path and query

    func testSplitPathAndQuery() {
        let r = ExportLANServer.splitPathAndQuery("xr?mode=working&x=1")
        XCTAssertEqual(r.path, "xr")
        XCTAssertEqual(r.query, ["mode": "working", "x": "1"])
        XCTAssertEqual(ExportLANServer.splitPathAndQuery("status.json").query, [:])
    }

    func testQueryValuesArePercentDecodedAndKeepLaterEquals() {
        XCTAssertEqual(ExportLANServer.splitPathAndQuery("p?name=a%20b").query["name"], "a b")
        XCTAssertEqual(ExportLANServer.splitPathAndQuery("p?k=a=b").query["k"], "a=b")
        XCTAssertEqual(ExportLANServer.splitPathAndQuery("p?flag&k=v").query, ["k": "v"], "a key with no = is dropped")
    }

    func testNormalizedGETPathDropsSlashAndQuery() {
        XCTAssertEqual(ExportLANServer.normalizedGETPath("/xr?mode=archive"), "xr")
        XCTAssertEqual(ExportLANServer.normalizedGETPath("/"), "")
    }

    // MARK: Headers and Basic auth

    func testHeaderValueIsCaseInsensitiveAndTrimmed() {
        let h = headers("authorization:   Basic abc  ", "Host: phone")
        XCTAssertEqual(ExportLANServer.headerValue(named: "Authorization", in: h), "Basic abc")
        XCTAssertNil(ExportLANServer.headerValue(named: "Range", in: h))
    }

    func testParseBasicAuthorization() {
        let parsed = ExportLANServer.parseBasicAuthorization(basic("admin", "pa:ss"))
        XCTAssertEqual(parsed?.user, "admin")
        XCTAssertEqual(parsed?.password, "pa:ss", "only the first colon splits user from password")
        let noColon = ExportLANServer.parseBasicAuthorization("basic " + Data("solo".utf8).base64EncodedString())
        XCTAssertEqual(noColon?.user, "solo")
        XCTAssertEqual(noColon?.password, "")
        XCTAssertNil(ExportLANServer.parseBasicAuthorization("Bearer abc"))
        XCTAssertNil(ExportLANServer.parseBasicAuthorization("Basic !!!not-base64"))
    }

    func testAuthorizationCheck() {
        let user = ExportLANServer.lanWebDAVUsername
        let pass = ExportLANServer.lanWebDAVPassword
        XCTAssertTrue(ExportLANServer.lanWebDAVAuthorizationOK(requestHeaders: headers("Authorization: " + basic(user, pass))))
        XCTAssertTrue(ExportLANServer.lanWebDAVAuthorizationOK(requestHeaders: headers("Authorization: " + basic(user.uppercased(), pass))),
                      "the username is compared case-insensitively")
        XCTAssertFalse(ExportLANServer.lanWebDAVAuthorizationOK(requestHeaders: headers("Authorization: " + basic(user, pass + "x"))))
        XCTAssertFalse(ExportLANServer.lanWebDAVAuthorizationOK(requestHeaders: headers("Authorization: Basic !!!")))
    }

    /// Known gap: with no Authorization header this check passes. Protected routes rely on
    /// `enforceLANWebDAVAuth`, which rejects a missing header before calling it.
    func testAuthorizationCheckPassesWhenHeaderIsMissing() {
        XCTAssertTrue(ExportLANServer.lanWebDAVAuthorizationOK(requestHeaders: headers("Host: phone")))
    }

    // MARK: Which requests need a login

    func testWriteAndDAVMethodsAlwaysNeedAuth() {
        for method in ["OPTIONS", "PROPFIND", "LOCK", "PUT", "MKCOL", "DELETE", "MOVE"] {
            XCTAssertTrue(ExportLANServer.requiresLANWebDAVAuth(method: method, path: "/pcld_ios_media/archive/a.mp4", requestHeaders: headers()), method)
        }
    }

    func testPOSTNeedsAuthExceptTheXRDebugLog() {
        XCTAssertTrue(ExportLANServer.requiresLANWebDAVAuth(method: "POST", path: "/export_queue.json", requestHeaders: headers()))
        XCTAssertFalse(ExportLANServer.requiresLANWebDAVAuth(method: "POST", path: "/xr_debug.json", requestHeaders: headers()))
        XCTAssertFalse(ExportLANServer.requiresLANWebDAVAuth(method: "POST", path: "/xr_debug.json?x=1", requestHeaders: headers()))
    }

    /// The LAN pages need the login for everyone (audit S3: their scripts no longer carry the password).
    func testLANPagesNeedAuthForEveryone() {
        let browser = headers("User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36", "Accept: text/html")
        let skybox = headers("User-Agent: Skybox/1.0")
        for path in ["/", "/browse", "/browse?x=1"] {
            XCTAssertTrue(ExportLANServer.requiresLANWebDAVAuth(method: "GET", path: path, requestHeaders: browser), path)
            XCTAssertTrue(ExportLANServer.requiresLANWebDAVAuth(method: "GET", path: path, requestHeaders: skybox), path)
            XCTAssertTrue(ExportLANServer.requiresLANWebDAVAuth(method: "HEAD", path: path, requestHeaders: headers()), path)
        }
    }

    /// Media, the /xr player and the status JSON stay open: Skybox often sends no Authorization,
    /// and /xr plus several PC scripts read them without a login.
    func testMediaXRAndStatusStayOpen() {
        let browser = headers("User-Agent: Mozilla/5.0", "Accept: text/html")
        for path in ["/pcld_ios_media/archive/a.mp4", "/xr", "/xr-assets/aframe.min.js", "/status.json", "/status_lists.json"] {
            XCTAssertFalse(ExportLANServer.requiresLANWebDAVAuth(method: "GET", path: path, requestHeaders: browser), path)
        }
        XCTAssertFalse(ExportLANServer.requiresLANWebDAVAuth(method: "PATCH", path: "/", requestHeaders: headers()))
    }

    func testWebDAVClientDetection() {
        XCTAssertTrue(ExportLANServer.isWebDAVClient(requestHeaders: headers("Depth: 1")))
        XCTAssertTrue(ExportLANServer.isWebDAVClient(requestHeaders: headers("User-Agent: Microsoft-WebDAV-MiniRedir/10.0")))
        XCTAssertFalse(ExportLANServer.isWebDAVClient(requestHeaders: headers("User-Agent: Mozilla/5.0 Chrome/120")))
        XCTAssertFalse(ExportLANServer.isBrowserLikeRequest(requestHeaders: headers("User-Agent: Mozilla/5.0", "Depth: 0")),
                       "a WebDAV client is never treated as a browser")
    }
}
