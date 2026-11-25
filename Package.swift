// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WallpaperManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WallpaperManager", targets: ["WallpaperManager"]),
    ],
    targets: [
        // Pure Foundation logic (folder scanning, shuffle order, history). No AppKit, so it is unit-testable.
        .target(name: "WallpaperCore"),
        // The menu bar app itself.
        .executableTarget(
            name: "WallpaperManager",
            dependencies: ["WallpaperCore"]
        ),
        .testTarget(
            name: "WallpaperCoreTests",
            dependencies: ["WallpaperCore"]
        ),
    ]
)
