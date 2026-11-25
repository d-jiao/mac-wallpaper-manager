import Foundation

/// What macOS is showing on one display, read from System Settings' wallpaper store.
public struct DisplayWallpaper: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A folder of pictures that macOS rotates through.
        case folder(URL)
        /// A single picture file.
        case image(URL)
        /// Something without a file we can act on (built-in dynamic wallpaper, Photos album, color...).
        case other(provider: String)
    }

    public var kind: Kind
    /// For example "every 30 minutes", when macOS changes the picture on a timer.
    public var shuffleDescription: String?

    public var folder: URL? {
        if case .folder(let url) = kind { return url }
        return nil
    }
}

/// Reads `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`, where macOS 14 and later
/// keep the wallpaper settings. Its format is undocumented, so parsing is defensive: anything unexpected
/// is skipped rather than treated as an error.
///
/// Layout (observed on macOS 26):
///
///     Displays/<display UUID>/Desktop                      settings for one display
///     Spaces/<space UUID>/Displays/<display UUID>/Desktop  per-Space overrides
///     Spaces/<space UUID>/Default/Desktop                  all displays in one Space
///     AllSpacesAndDisplays/Desktop, SystemDefault/Desktop  global fallbacks
///
/// Each `Desktop` holds `Content/Choices[0]` with a `Provider` and a binary-plist `Configuration` such as
/// `{ type = imageFolder; url = { relative = "file:///Users/me/Pictures/Wallpapers" } }`, plus
/// `Content/EncodedOptionValues` (binary plist) with the shuffle frequency.
public struct WallpaperStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    private let root: [String: Any]

    public init(root: [String: Any]) {
        self.root = root
    }

    public init?(data: Data) {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        self.root = root
    }

    public init?(contentsOf url: URL = WallpaperStore.defaultURL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    /// The wallpaper for a display. If the display has several entries (for example different Spaces),
    /// the most recently used one wins.
    public func wallpaper(forDisplay uuid: String) -> DisplayWallpaper? {
        let entries = desktopEntries(forDisplay: uuid)
        return entries.max { $0.lastUse < $1.lastUse }?.wallpaper
    }

    /// Every folder configured for a display, across all Spaces. Used to match the picture files that
    /// macOS has open, since the Space currently on screen isn't recorded in the store.
    public func folders(forDisplay uuid: String) -> [URL] {
        var seen = Set<String>()
        return desktopEntries(forDisplay: uuid).compactMap { $0.wallpaper.folder }.filter { seen.insert($0.path).inserted }
    }

    // MARK: - Parsing

    private struct Entry {
        let wallpaper: DisplayWallpaper
        let lastUse: Date
    }

    private func desktopEntries(forDisplay uuid: String) -> [Entry] {
        let spaces = (root["Spaces"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }

        // Most specific first; fall back to broader settings only if a level has nothing usable.
        let levels: [[Any?]] = [
            spaces.map { (($0["Displays"] as? [String: Any])?[uuid] as? [String: Any])?["Desktop"] }
                + [((root["Displays"] as? [String: Any])?[uuid] as? [String: Any])?["Desktop"]],
            spaces.map { ($0["Default"] as? [String: Any])?["Desktop"] }
                + [(root["AllSpacesAndDisplays"] as? [String: Any])?["Desktop"]],
            [(root["SystemDefault"] as? [String: Any])?["Desktop"]],
        ]
        for level in levels {
            let entries = level.compactMap { $0.flatMap(Self.entry(fromDesktop:)) }
            if !entries.isEmpty { return entries }
        }
        return []
    }

    private static func entry(fromDesktop value: Any) -> Entry? {
        guard let desktop = value as? [String: Any],
              let content = desktop["Content"] as? [String: Any],
              let choice = (content["Choices"] as? [Any])?.first as? [String: Any]
        else { return nil }

        let provider = choice["Provider"] as? String ?? "unknown"
        let configuration = (choice["Configuration"] as? Data).flatMap(plist) as? [String: Any] ?? [:]
        let type = configuration["type"] as? String ?? ""
        let url = fileURL(from: configuration["url"])
            ?? (choice["Files"] as? [Any])?.lazy.compactMap({ fileURL(from: $0) }).first

        let kind: DisplayWallpaper.Kind
        if let url, type.lowercased().contains("folder") || isDirectory(url) {
            kind = .folder(url)
        } else if let url, !url.hasDirectoryPath {
            kind = .image(url)
        } else {
            kind = .other(provider: provider)
        }

        var shuffle: String?
        if case .folder = kind {
            shuffle = (content["EncodedOptionValues"] as? Data).flatMap(plist).flatMap(shuffleDescription(fromOptions:))
        }
        let lastUse = desktop["LastUse"] as? Date ?? desktop["LastSet"] as? Date ?? .distantPast
        return Entry(wallpaper: DisplayWallpaper(kind: kind, shuffleDescription: shuffle), lastUse: lastUse)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func plist(_ data: Data) -> Any? {
        try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    /// Accepts `{ relative = "file:///..." }` or a plain URL string.
    private static func fileURL(from value: Any?) -> URL? {
        let string = (value as? [String: Any])?["relative"] as? String ?? value as? String
        guard let string, let url = URL(string: string), url.isFileURL else { return nil }
        return url.standardizedFileURL
    }

    /// `values/shuffleFrequency/picker/_0/id`, e.g. "shuffle_every_30_minutes" -> "every 30 minutes".
    private static func shuffleDescription(fromOptions options: Any) -> String? {
        let values = (options as? [String: Any])?["values"] as? [String: Any]
        let picker = (values?["shuffleFrequency"] as? [String: Any])?["picker"] as? [String: Any]
        guard let id = (picker?["_0"] as? [String: Any])?["id"] as? String else { return nil }
        var text = id
        if text.hasPrefix("shuffle_") { text.removeFirst("shuffle_".count) }
        return text.replacingOccurrences(of: "_", with: " ")
    }
}
