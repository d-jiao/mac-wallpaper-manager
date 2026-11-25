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

    /// The reported bug: display B's settings also list A's folder (an old or per-Space entry), and B
    /// is processed first. When A switches, B must not grab A's new picture, and the two screens must
    /// never end up showing the same file.
    func testStaleFolderEntryDoesNotStealAnotherDisplaysPicture() {
        var tracker = CurrentPictureTracker()
        let folders = ["1-B": [city, landscapes], "2-A": [landscapes]]
        let a1 = "/Users/me/Pictures/Landscapes/a1.jpg", a2 = "/Users/me/Pictures/Landscapes/a2.jpg"
        let b1 = "/Users/me/Pictures/City/b1.jpg", b2 = "/Users/me/Pictures/City/b2.jpg"

        XCTAssertEqual(tracker.update(openFiles: [a1, b1], folders: folders), ["2-A": a1, "1-B": b1])
        // A switches; its old file lingers for a few seconds.
        XCTAssertEqual(tracker.update(openFiles: [a2, a1, b1], folders: folders), ["2-A": a2, "1-B": b1])
        XCTAssertEqual(tracker.update(openFiles: [a2, b1], folders: folders), ["2-A": a2, "1-B": b1])
        // B switches a bit later.
        XCTAssertEqual(tracker.update(openFiles: [b2, a2, b1], folders: folders), ["2-A": a2, "1-B": b2])
        XCTAssertEqual(tracker.update(openFiles: [a2, b2], folders: folders), ["2-A": a2, "1-B": b2])
    }

    func testDisplayWithoutFilesInItsCurrentFolderNeverCopiesAnotherDisplay() {
        var tracker = CurrentPictureTracker()
        let a1 = "/Users/me/Pictures/Landscapes/a1.jpg"
        // B's new picture hasn't loaded yet; only A's file is open.
        let picks = tracker.update(openFiles: [a1], folders: ["1-B": [city, landscapes], "2-A": [landscapes]])
        XCTAssertEqual(picks, ["2-A": a1])
    }

    func testFallsBackToOlderFolderForUnclaimedFiles() {
        var tracker = CurrentPictureTracker()
        let old = URL(fileURLWithPath: "/Users/me/Pictures/Old")
        let picks = tracker.update(openFiles: ["/Users/me/Pictures/Old/x.jpg"], folders: ["A": [landscapes, old]])
        XCTAssertEqual(picks, ["A": "/Users/me/Pictures/Old/x.jpg"])
    }

    func testMoreSpecificFolderWins() {
        var tracker = CurrentPictureTracker()
        let pictures = URL(fileURLWithPath: "/Users/me/Pictures")
        let picks = tracker.update(
            openFiles: ["/Users/me/Pictures/City/night.jpg", "/Users/me/Pictures/top.jpg"],
            folders: ["A": [pictures], "B": [city]]
        )
        XCTAssertEqual(picks, ["A": "/Users/me/Pictures/top.jpg", "B": "/Users/me/Pictures/City/night.jpg"])
    }

    func testSharedFolderWithOneOpenFileIsNotDuplicated() {
        var tracker = CurrentPictureTracker()
        let picks = tracker.update(openFiles: ["/Users/me/Pictures/Landscapes/1.jpg"], folders: ["A": [landscapes], "B": [landscapes]])
        XCTAssertEqual(picks.count, 1)
    }

    /// While macOS restarts its wallpaper process (after Next), nothing is open for a moment.
    func testKeepsPicksWhileNothingIsOpen() {
        var tracker = CurrentPictureTracker()
        let a1 = "/Users/me/Pictures/Landscapes/a1.jpg"
        let folders = ["A": [landscapes]]
        _ = tracker.update(openFiles: [a1], folders: folders, fileExists: { _ in true })
        XCTAssertEqual(tracker.update(openFiles: [], folders: folders, fileExists: { _ in true }), ["A": a1])
        XCTAssertEqual(tracker.update(openFiles: [], folders: folders, fileExists: { _ in false }), [:], "trashed")
    }

    func testParsesLsofFieldOutput() {
        let output = "p430\nftxt\nn/Users/me/Pictures/Landscapes/hills.jpg\nftxt\nn/System/Library/x.png\np2113\n"
        XCTAssertEqual(
            CurrentPictureTracker.paths(fromLsofOutput: output),
            ["/Users/me/Pictures/Landscapes/hills.jpg", "/System/Library/x.png"]
        )
    }
}
