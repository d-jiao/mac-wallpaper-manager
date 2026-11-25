import XCTest
@testable import WallpaperCore

final class CurrentPictureTrackerTests: XCTestCase {
    let landscapes = URL(fileURLWithPath: "/Users/me/Pictures/Landscapes")
    let city = URL(fileURLWithPath: "/Users/me/Pictures/City")

    func testSingleOpenFilePerDisplay() {
        var tracker = CurrentPictureTracker()
        let picks = tracker.update(
            openFiles: ["/Users/me/Pictures/City/night.jpg", "/Users/me/Pictures/Landscapes/hills.jpg"],
            folders: ["A": [landscapes], "B": [city]]
        )
        XCTAssertEqual(picks, ["A": "/Users/me/Pictures/Landscapes/hills.jpg", "B": "/Users/me/Pictures/City/night.jpg"])
    }

    /// macOS keeps the previous picture open for a few seconds after switching.
    func testNewlyOpenedFileWinsOverTheLingeringPreviousOne() {
        var tracker = CurrentPictureTracker()
        let old = "/Users/me/Pictures/Landscapes/old.jpg"
        let new = "/Users/me/Pictures/Landscapes/new.jpg"
        let folders = ["A": [landscapes]]

        XCTAssertEqual(tracker.update(openFiles: [old], folders: folders)["A"], old)
        XCTAssertEqual(tracker.update(openFiles: [old, new], folders: folders)["A"], new, "new file appeared")
        XCTAssertEqual(tracker.update(openFiles: [old, new], folders: folders)["A"], new, "keeps its pick")
        XCTAssertEqual(tracker.update(openFiles: [new], folders: folders)["A"], new)
    }

    func testFirstSnapshotWithTwoFilesUsesListingOrder() {
        var tracker = CurrentPictureTracker()
        let picks = tracker.update(
            openFiles: ["/Users/me/Pictures/Landscapes/new.jpg", "/Users/me/Pictures/Landscapes/old.jpg"],
            folders: ["A": [landscapes]]
        )
        XCTAssertEqual(picks["A"], "/Users/me/Pictures/Landscapes/new.jpg")
    }

    func testDisplaysSharingAFolderGetDifferentFiles() {
        var tracker = CurrentPictureTracker()
        let picks = tracker.update(
            openFiles: ["/Users/me/Pictures/Landscapes/1.jpg", "/Users/me/Pictures/Landscapes/2.jpg"],
            folders: ["A": [landscapes], "B": [landscapes]]
        )
        XCTAssertEqual(Set(picks.values), ["/Users/me/Pictures/Landscapes/1.jpg", "/Users/me/Pictures/Landscapes/2.jpg"])
    }

    func testIgnoresFilesOutsideTheFolders() {
        var tracker = CurrentPictureTracker()
        let picks = tracker.update(
            openFiles: [
                "/Users/me/Pictures/LandscapesExtra/x.jpg",      // similar prefix, different folder
                "/System/Library/Desktop Pictures/Sequoia.heic",
                "/Users/me/.Trash/trashed.jpg",
            ],
            folders: ["A": [landscapes]]
        )
        XCTAssertEqual(picks, [:])
    }

    func testIncludesSubfolders() {
        var tracker = CurrentPictureTracker()
        let picks = tracker.update(openFiles: ["/Users/me/Pictures/Landscapes/2025/lake.jpg"], folders: ["A": [landscapes]])
        XCTAssertEqual(picks["A"], "/Users/me/Pictures/Landscapes/2025/lake.jpg")
    }

    func testParsesLsofFieldOutput() {
        let output = "p430\nftxt\nn/Users/me/Pictures/Landscapes/hills.jpg\nftxt\nn/System/Library/x.png\np2113\n"
        XCTAssertEqual(
            CurrentPictureTracker.paths(fromLsofOutput: output),
            ["/Users/me/Pictures/Landscapes/hills.jpg", "/System/Library/x.png"]
        )
    }
}
