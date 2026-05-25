import AVFoundation
import Foundation

/// Infers 3D / high-res tier labels for `archive/<name>_3D_<n>K_<time>.<ext>` (when n > 2).
enum ExportVideoDimensions {
    /// Full side-by-side: tier from **coded width** (3840×2160 SBS → `4K`). Flat/OU: from **longer edge**.
    /// Returns a label only when n > 2 (3K, 4K, 5K, … — not 1K/2K).
    static func inferNKLabel(width: Int, height: Int) -> String? {
        let w = max(width, 0)
        let h = max(height, 0)
        guard w > 0, h > 0 else { return nil }

        let referencePixels: Int
        if w >= h * 2 {
            referencePixels = w
        } else {
            referencePixels = max(w, h)
        }

        guard let n = nkMultiplier(fromReferencePixels: referencePixels), n > 2 else {
            return nil
        }
        return "\(n)K"
    }

    /// Map horizontal (or SBS full-width) pixels to n in nK (3, 4, 5, 6, 7, 8, …).
    static func nkMultiplier(fromReferencePixels pixels: Int) -> Int? {
        switch pixels {
        case 7680...:
            return 8
        case 7168 ..< 7680:
            return 7
        case 6144 ..< 7168:
            return 6
        case 5120 ..< 6144:
            return 5
        case 3200 ..< 5120:
            return 4
        case 2560 ..< 3200:
            return 3
        default:
            return nil
        }
    }

    /// `_3D_4K` from an inferred label (`3K`, `4K`, …).
    static func threeDSuffixSegment(nkLabel: String) -> String? {
        "_3D_\(nkLabel)"
    }

    static func probeNKLabelForRetention(from files: [URL]) -> String? {
        for url in probeCandidates(from: files) {
            if let label = probeNKLabel(from: url) {
                return label
            }
        }
        return nil
    }

    private static func probeCandidates(from files: [URL]) -> [URL] {
        let fm = FileManager.default
        func rank(_ url: URL) -> Int {
            let name = url.lastPathComponent.lowercased()
            if name == "_working.mp4" { return 0 }
            if name == "_working_pcloud_transcode.mp4" { return 1 }
            if name.hasPrefix("_vanilla_download.") { return 2 }
            if name == "_vanilla_faststart.mp4" { return 3 }
            if name.hasSuffix(".mp4") || name.hasSuffix(".mov") || name.hasSuffix(".m4v") { return 4 }
            return 5
        }
        return files
            .filter { fm.fileExists(atPath: $0.path) }
            .sorted { rank($0) < rank($1) }
    }

    private static func probeNKLabel(from url: URL) -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let transformed = track.naturalSize.applying(track.preferredTransform)
        let width = Int(abs(transformed.width).rounded())
        let height = Int(abs(transformed.height).rounded())
        return inferNKLabel(width: width, height: height)
    }
}
