import XCTest
@testable import WallpaperCore

/// Deterministic random numbers (SplitMix64) so test runs are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class WallpaperShufflerTests: XCTestCase {
    let images = (1...10).map { "/wallpapers/\($0).jpg" }
    var rng = SeededGenerator(state: 42)

    func testShowsEveryImageOnceBeforeRepeating() {
        var shuffler = WallpaperShuffler()
        var shown: [String] = []
        for _ in images {
            shown.append(shuffler.advance(candidates: images, using: &rng)!)
        }
        XCTAssertEqual(Set(shown), Set(images))
        XCTAssertEqual(shown.count, Set(shown).count, "no image repeats within a round")
    }

    func testNeverShowsSameImageTwiceInARow() {
        var shuffler = WallpaperShuffler()
        let three = Array(images.prefix(3))
        var previous: String?
        for _ in 0..<300 {
            let next = shuffler.advance(candidates: three, using: &rng)
            XCTAssertNotNil(next)
            XCTAssertNotEqual(next, previous)
            previous = next
        }
    }

    func testSingleImageStaysPut() {
        var shuffler = WallpaperShuffler()
        XCTAssertEqual(shuffler.advance(candidates: ["/a.jpg"], using: &rng), "/a.jpg")
        XCTAssertEqual(shuffler.advance(candidates: ["/a.jpg"], using: &rng), "/a.jpg")
        XCTAssertEqual(shuffler.back, [])
    }

    func testEmptyFolderReturnsNil() {
        var shuffler = WallpaperShuffler(current: "/gone.jpg")
        XCTAssertNil(shuffler.advance(candidates: [], using: &rng))
        XCTAssertNil(shuffler.current)
    }

    func testBackAndForward() {
        var shuffler = WallpaperShuffler()
        let first = shuffler.advance(candidates: images, using: &rng)!
        let second = shuffler.advance(candidates: images, using: &rng)!
        let third = shuffler.advance(candidates: images, using: &rng)!
        let all = Set(images)

        XCTAssertEqual(shuffler.goBack(available: all), second)
        XCTAssertEqual(shuffler.goBack(available: all), first)
        XCTAssertNil(shuffler.goBack(available: all), "nothing before the first image")
        XCTAssertEqual(shuffler.current, first)

        // Forward replays history before picking new images.
        XCTAssertEqual(shuffler.advance(candidates: images, using: &rng), second)
        XCTAssertEqual(shuffler.advance(candidates: images, using: &rng), third)
        let fourth = shuffler.advance(candidates: images, using: &rng)!
        XCTAssertFalse([first, second, third].contains(fourth))
    }

    func testGoBackSkipsImagesThatNoLongerExist() {
        var shuffler = WallpaperShuffler()
        let first = shuffler.advance(candidates: images, using: &rng)!
        let second = shuffler.advance(candidates: images, using: &rng)!
        _ = shuffler.advance(candidates: images, using: &rng)!

        var available = Set(images)
        available.remove(second)
        XCTAssertEqual(shuffler.goBack(available: available), first)
    }

    func testRemoveCurrentForgetsItEverywhere() {
        var shuffler = WallpaperShuffler()
        let first = shuffler.advance(candidates: images, using: &rng)!
        let second = shuffler.advance(candidates: images, using: &rng)!
        let trashed = shuffler.advance(candidates: images, using: &rng)!

        shuffler.remove(trashed)
        XCTAssertNil(shuffler.current)

        let remaining = images.filter { $0 != trashed }
        let next = shuffler.advance(candidates: remaining, using: &rng)!
        XCTAssertNotEqual(next, trashed)
        XCTAssertEqual(shuffler.goBack(available: Set(remaining)), second, "trashed image is not in history")
        XCTAssertEqual(shuffler.goBack(available: Set(remaining)), first)
    }

    func testNewImagesAreIncludedInTheCurrentRound() {
        var shuffler = WallpaperShuffler()
        let few = Array(images.prefix(2))
        shuffler.advance(candidates: few, using: &rng)
        shuffler.advance(candidates: few, using: &rng)

        // A new image appears in the folder; it should be picked next because the others were seen.
        let added = few + ["/wallpapers/new.jpg"]
        XCTAssertEqual(shuffler.advance(candidates: added, using: &rng), "/wallpapers/new.jpg")
    }

    func testShowSpecificImage() {
        var shuffler = WallpaperShuffler()
        let first = shuffler.advance(candidates: images, using: &rng)!
        shuffler.show("/restored.jpg")
        XCTAssertEqual(shuffler.current, "/restored.jpg")
        XCTAssertEqual(shuffler.back.last, first)
    }

    func testHistoryIsCapped() {
        var shuffler = WallpaperShuffler()
        shuffler.historyLimit = 3
        for _ in 0..<8 {
            shuffler.advance(candidates: images, using: &rng)
        }
        XCTAssertEqual(shuffler.back.count, 3)
    }

    func testCodableRoundTrip() throws {
        var shuffler = WallpaperShuffler()
        for _ in 0..<4 {
            shuffler.advance(candidates: images, using: &rng)
        }
        shuffler.goBack(available: Set(images))
        let data = try JSONEncoder().encode(shuffler)
        XCTAssertEqual(try JSONDecoder().decode(WallpaperShuffler.self, from: data), shuffler)
    }
}
