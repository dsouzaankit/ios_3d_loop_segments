import Foundation

/// pCloud REST `gethlslink` → HTTPS `master.m3u8` for AVFoundation (transcoded H.264/AAC).
enum PCloudHLSLink {
    /// Only use HLS transcode when estimated source bitrate exceeds this (Mbps).
    static let minSourceMbpsForTranscode = 2.5

    /// `gethlslink` caps per pCloud API (request maximum).
    static let maxTranscodeVideoKbps = 4000
    static let maxTranscodeAudioKbps = 320
    static let maxTranscodeResolution = "1280x960"

    struct ResolvedLink: Sendable {
        let masterPlaylistURL: URL
        let expires: String?
        let apiHost: String
    }

    static var transcodeQualityParameters: [String: String] {
        [
            "vbitrate": "\(maxTranscodeVideoKbps)",
            "abitrate": "\(maxTranscodeAudioKbps)",
            "resolution": maxTranscodeResolution,
        ]
    }

    /// Map WebDAV browse `href` to pCloud API `path` for `gethlslink`.
    static func apiPath(fromWebDAVHref href: String, webDAVFilesRoot: String?) -> String {
        let normalized = PCloudMetadataParsing.normalizeAPIPathForREST(
            WebDAVURLBuilder.normalizedHrefPath(href)
        )
        guard let root = webDAVFilesRoot, !root.isEmpty else { return normalized }
        let rootPath = WebDAVURLBuilder.directoryListingPath(root)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let hrefTrimmed = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if hrefTrimmed.lowercased().hasPrefix(rootPath.lowercased() + "/") {
            return "/" + String(hrefTrimmed.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
        }
        if hrefTrimmed.lowercased().contains("remote.php/dav/files/") {
            let parts = hrefTrimmed.split(separator: "/")
            if let filesIdx = parts.firstIndex(of: "files"), filesIdx + 2 < parts.count {
                let afterUser = parts[(filesIdx + 2)...].joined(separator: "/")
                return WebDAVURLBuilder.canonicalBrowsePath("/\(afterUser)")
            }
        }
        return normalized
    }

    static func resolveMasterPlaylist(
        credentials: WebDAVCredentials,
        sourceHref: String,
        log: ((String) -> Void)? = nil
    ) async throws -> ResolvedLink {
        let apiClient = PCloudAPIClient(credentials: credentials)
        let apiPath = apiPath(
            fromWebDAVHref: sourceHref,
            webDAVFilesRoot: credentials.webDAVFilesRoot
        )
        log?(
            "pCloud HLS — gethlslink for \(apiPath) " +
                "(max \(maxTranscodeResolution) @ \(maxTranscodeVideoKbps) kbps video)"
        )
        let link = try await apiClient.fetchHLSMasterPlaylist(apiPath: apiPath, log: log)
        let variantURL = try await resolveHighestBandwidthVariant(
            masterPlaylistURL: link.masterPlaylistURL,
            log: log
        )
        log?("pCloud HLS — using highest variant \(variantURL.lastPathComponent)")
        return PCloudHLSLink.ResolvedLink(
            masterPlaylistURL: variantURL,
            expires: link.expires,
            apiHost: link.apiHost
        )
    }

    /// Pick top `EXT-X-STREAM-INF` rendition from `master.m3u8`.
    private static func resolveHighestBandwidthVariant(
        masterPlaylistURL: URL,
        log: ((String) -> Void)?
    ) async throws -> URL {
        var request = URLRequest(url: masterPlaylistURL)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            log?("pCloud HLS — could not read master playlist; using master URL")
            return masterPlaylistURL
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return masterPlaylistURL
        }
        let base = masterPlaylistURL.deletingLastPathComponent()
        let lines = text.split(whereSeparator: \.isNewline)
        var bestBandwidth = 0
        var bestURI: String?
        var index = 0
        while index < lines.count {
            let line = String(lines[index])
            if line.hasPrefix("#EXT-X-STREAM-INF:"),
               let bandwidth = parseBandwidth(from: line),
               index + 1 < lines.count {
                let next = String(lines[index + 1]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !next.isEmpty, !next.hasPrefix("#") {
                    if bandwidth > bestBandwidth {
                        bestBandwidth = bandwidth
                        bestURI = next
                    }
                    index += 2
                    continue
                }
            }
            index += 1
        }
        guard let bestURI, !bestURI.isEmpty else {
            return masterPlaylistURL
        }
        if bestURI.hasPrefix("http://") || bestURI.hasPrefix("https://") {
            guard let url = URL(string: bestURI) else { return masterPlaylistURL }
            return url
        }
        return base.appendingPathComponent(bestURI)
    }

    private static func parseBandwidth(from streamInfLine: String) -> Int? {
        guard let range = streamInfLine.range(of: "BANDWIDTH=") else { return nil }
        let tail = streamInfLine[range.upperBound...]
        let digits = tail.prefix(while: { $0.isNumber })
        return Int(digits)
    }
}
