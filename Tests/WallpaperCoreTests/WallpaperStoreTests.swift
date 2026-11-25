import XCTest
@testable import WallpaperCore

/// Fixtures follow the structure of Index.plist observed on macOS 26.
final class WallpaperStoreTests: XCTestCase {
    let displayA = "EEBC8EBB-1747-4179-8CB3-7038F756154C"
    let displayB = "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"

    private func bplist(_ value: Any) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private func desktop(
        type: String? = "imageFolder",
        url: String?,
        provider: String = "com.apple.wallpaper.choice.image",
        shuffle: String? = "shuffle_every_30_minutes",
        files: [String] = [],
        lastUse: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> [String: Any] {
        var configuration: [String: Any] = [:]
        if let type { configuration["type"] = type }
        if let url { configuration["url"] = ["relative": url] }
        var content: [String: Any] = [
            "Choices": [[
                "Configuration": bplist(configuration),
                "Files": files.map { ["relative": $0] },
                "Provider": provider,
            ]],
            "Shuffle": "$null",
        ]
        if let shuffle {
            content["EncodedOptionValues"] = bplist(["values": [
                "shuffleFrequency": ["picker": ["_0": ["id": shuffle]]],
                "placement": ["picker": ["_0": ["id": "Crop"]]],
            ]])
        } else {
            content["EncodedOptionValues"] = "$null"
        }
        return ["Content": content, "LastSet": lastUse, "LastUse": lastUse]
    }

    private func twoDisplayStore() -> WallpaperStore {
        let a = desktop(url: "file:///Users/me/Pictures/Landscapes")
        let b = desktop(url: "file:///Volumes/Photos/City%20Nights", shuffle: "shuffle_every_minute")
        return WallpaperStore(root: [
            "AllSpacesAndDisplays": ["Idle": [:], "Type": "idle"],
            "Displays": [
                displayA: ["Desktop": a, "Type": "individual"],
                displayB: ["Desktop": b, "Type": "individual"],
            ],
            "Spaces": ["": [
                "Default": ["Desktop": a],
                "Displays": [displayA: ["Desktop": a], displayB: ["Desktop": b]],
            ]],
            "SystemDefault": ["Desktop": a],
        ])
    }

    func testEachDisplayGetsItsOwnFolder() {
        let store = twoDisplayStore()
        XCTAssertEqual(store.wallpaper(forDisplay: displayA)?.folder?.path, "/Users/me/Pictures/Landscapes")
        XCTAssertEqual(store.wallpaper(forDisplay: displayB)?.folder?.path, "/Volumes/Photos/City Nights")
        XCTAssertEqual(store.folders(forDisplay: displayA).map(\.path), ["/Users/me/Pictures/Landscapes"])
    }

    func testShuffleDescription() {
        let store = twoDisplayStore()
        XCTAssertEqual(store.wallpaper(forDisplay: displayA)?.shuffleDescription, "every 30 minutes")
        XCTAssertEqual(store.wallpaper(forDisplay: displayB)?.shuffleDescription, "every minute")
    }

    func testUnknownDisplayFallsBackToSharedSettings() {
        let store = twoDisplayStore()
        XCTAssertEqual(store.wallpaper(forDisplay: "NEW-DISPLAY")?.folder?.path, "/Users/me/Pictures/Landscapes")
    }

    func testMostRecentlyUsedEntryWinsButAllFoldersAreKept() {
        let old = desktop(url: "file:///Users/me/Old", lastUse: Date(timeIntervalSince1970: 1_000_000_000))
        let new = desktop(url: "file:///Users/me/New", lastUse: Date(timeIntervalSince1970: 2_000_000_000))
        let store = WallpaperStore(root: [
            "Displays": [displayA: ["Desktop": new]],
            "Spaces": ["SPACE-1": ["Displays": [displayA: ["Desktop": old]]]],
        ])
        XCTAssertEqual(store.wallpaper(forDisplay: displayA)?.folder?.path, "/Users/me/New")
        XCTAssertEqual(Set(store.folders(forDisplay: displayA).map(\.path)), ["/Users/me/Old", "/Users/me/New"])
    }

    func testSingleImage() {
        let store = WallpaperStore(root: [
            "Displays": [displayA: ["Desktop": desktop(type: "image", url: "file:///Users/me/Pictures/one.jpg", shuffle: nil)]],
        ])
        let wallpaper = store.wallpaper(forDisplay: displayA)
        XCTAssertEqual(wallpaper?.kind, .image(URL(fileURLWithPath: "/Users/me/Pictures/one.jpg")))
        XCTAssertNil(wallpaper?.shuffleDescription)
        XCTAssertEqual(store.folders(forDisplay: displayA), [])
    }

    func testImageFromFilesListWhenConfigurationHasNoURL() {
        let store = WallpaperStore(root: [
            "Displays": [displayA: ["Desktop": desktop(type: nil, url: nil, files: ["file:///Users/me/two.png"])]],
        ])
        XCTAssertEqual(store.wallpaper(forDisplay: displayA)?.kind, .image(URL(fileURLWithPath: "/Users/me/two.png")))
    }

    func testBuiltInWallpaperIsOther() {
        let store = WallpaperStore(root: [
            "Displays": [displayA: ["Desktop": desktop(type: nil, url: nil, provider: "com.apple.wallpaper.choice.aerials")]],
        ])
        XCTAssertEqual(store.wallpaper(forDisplay: displayA)?.kind, .other(provider: "com.apple.wallpaper.choice.aerials"))
    }

    func testRoundTripThroughData() throws {
        let root: [String: Any] = ["Displays": [displayA: ["Desktop": desktop(url: "file:///Users/me/Pictures/Landscapes")]]]
        let store = try XCTUnwrap(WallpaperStore(data: bplist(root)))
        XCTAssertEqual(store.wallpaper(forDisplay: displayA)?.folder?.path, "/Users/me/Pictures/Landscapes")
    }

    func testGarbageIsHandled() {
        XCTAssertNil(WallpaperStore(data: Data("not a plist".utf8)))
        let store = WallpaperStore(root: ["Displays": [displayA: ["Desktop": ["Content": 42]]]])
        XCTAssertNil(store.wallpaper(forDisplay: displayA))
    }
}
