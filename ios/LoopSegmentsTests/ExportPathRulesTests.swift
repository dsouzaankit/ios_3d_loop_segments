import XCTest
@testable import LoopSegments

/// Which media paths the LAN can see and write. These decide what WebDAV DELETE and PUT may touch,
/// including the per-file Delete on `/browse`, so pipeline files must stay protected.
final class ExportPathRulesTests: XCTestCase {
    private let root = ExportPaths.mediaExportFolderName

    func testMediaFolderMembership() {
        XCTAssertTrue(ExportPaths.isUnderMediaExportLANPath("\(root)/archive/a.mp4"))
        XCTAssertTrue(ExportPaths.isUnderMediaExportLANPath(root))
        XCTAssertTrue(ExportPaths.isUnderMediaExportLANPath("/\(root)/"), "leading and trailing slashes are ignored")
        XCTAssertFalse(ExportPaths.isUnderMediaExportLANPath("other/a.mp4"))
        XCTAssertFalse(ExportPaths.isUnderMediaExportLANPath("\(root)/../secret"))
        XCTAssertFalse(ExportPaths.isUnderMediaExportLANPath(""))
    }

    func testArchiveDownloadsAndScriptsAreWritable() {
        for path in ["\(root)/archive/clip_3D_2026-11-05.mp4", "\(root)/downloads/a.mkv", "\(root)/scripts/export_trigger.json"] {
            XCTAssertTrue(ExportPaths.isLANWritableMediaRelativePath(path), path)
        }
    }

    func testPipelineFilesAreProtected() {
        let protected = [
            root,
            "\(root)/loop",
            "\(root)/loop/op_00.mp4",
            "\(root)/LOOP/op_01.mp4",
            "\(root)/parked",
            "\(root)/parked/clip/a.mp4",
            "\(root)/logs/export_latest.txt",
            "\(root)/_working.mp4",
            "\(root)/_working.sparse.json",
            "\(root)/_vanilla_download.wmv",
            "\(root)/_vanilla_faststart.mp4",
            "\(root)/_working_pcloud_transcode.mp4",
        ]
        for path in protected {
            XCTAssertFalse(ExportPaths.isLANWritableMediaRelativePath(path), path)
        }
    }

    func testHiddenAndStagingFilesAreProtected() {
        for name in [".hidden.mp4", "clip.staging.mp4", "clip.sparse.json", "_export_retention_source.json", ".faststart-x.mp4"] {
            XCTAssertTrue(ExportPaths.isExcludedFromLANMediaServe(fileName: name), name)
            XCTAssertFalse(ExportPaths.isLANWritableMediaRelativePath("\(root)/archive/\(name)"), name)
        }
        XCTAssertFalse(ExportPaths.isExcludedFromLANMediaServe(fileName: "clip.mp4"))
    }

    func testPathsOutsideTheMediaFolderAreNotWritable() {
        XCTAssertFalse(ExportPaths.isLANWritableMediaRelativePath("Exports/a.mp4"))
        XCTAssertFalse(ExportPaths.isLANWritableMediaRelativePath("\(root)/archive/../../etc"))
    }

    /// Known limit (audit A6): any ".." in a name blocks it, even a harmless one.
    func testNameWithDoubleDotIsRejected() {
        XCTAssertFalse(ExportPaths.isLANWritableMediaRelativePath("\(root)/archive/clip..final.mp4"))
    }
}
