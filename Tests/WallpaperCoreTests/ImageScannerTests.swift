import XCTest
@testable import WallpaperCore

final class ImageScannerTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageScannerTests-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        // A directory whose name looks like an image must be ignored.
        try fm.createDirectory(at: folder.appendingPathComponent("folder.jpg"), withIntermediateDirectories: true)
        for name in ["a.jpg", "B.PNG", "c.heic", "notes.txt", ".hidden.jpg", "sub/d.jpeg", "sub/deeper/e.webp"] {
            try Data([0]).write(to: folder.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func names(_ paths: [String]) -> Set<String> {
        Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent })
    }

    func testTopLevelOnly() {
        let paths = ImageScanner.imagePaths(in: folder, includeSubfolders: false)
        XCTAssertEqual(names(paths), ["a.jpg", "B.PNG", "c.heic"])
    }

    func testIncludingSubfolders() {
        let paths = ImageScanner.imagePaths(in: folder, includeSubfolders: true)
        XCTAssertEqual(names(paths), ["a.jpg", "B.PNG", "c.heic", "d.jpeg", "e.webp"])
        XCTAssertEqual(paths, paths.sorted())
    }

    func testMissingFolderIsEmpty() {
        let missing = folder.appendingPathComponent("does-not-exist")
        XCTAssertEqual(ImageScanner.imagePaths(in: missing, includeSubfolders: true), [])
    }
}
