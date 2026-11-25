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
        desktopEntries(forDisplay: uuid).first?.wallpaper
    }

    /// Every folder configured for a display, most recently used first. The first one is the
    /// display's current folder; the others come from older or per-Space entries.
    public func folders(forDisplay uuid: String) -> [URL] {
        var seen = Set<String>()
        return desktopEntries(forDisplay: uuid).compactMap { $0.wallpaper.folder }.filter { seen.insert($0.path).inserted }
    }

    /// One line per store entry that applies to a display, for troubleshooting.
    public func diagnostics(forDisplay uuid: String) -> [String] {
        desktopEntries(forDisplay: uuid).map { entry in
            let what: String
            switch entry.wallpaper.kind {
            case .folder(let url): what = "folder \(url.path)"
            case .image(let url): what = "picture \(url.path)"
            case .other(let provider): what = provider
            }
            return "\(entry.source): \(what), last used \(entry.lastUse)"
        }
    }

    // MARK: - Parsing

    private struct Entry {
        let wallpaper: DisplayWallpaper
        let lastUse: Date
        /// Where in the store the entry was found.
        let source: String
    }

    /// Entries for a display from the most specific level that has any, most recently used first.
    private func desktopEntries(forDisplay uuid: String) -> [Entry] {
        let spaces = root["Spaces"] as? [String: Any] ?? [:]
        let spaceIDs = spaces.keys.sorted()
        func desktop(_ value: Any?) -> Any? { (value as? [String: Any])?["Desktop"] }
        func space(_ id: String) -> [String: Any] { spaces[id] as? [String: Any] ?? [:] }

        typealias Candidate = (source: String, desktop: Any?)
        let perDisplay: [Candidate] = spaceIDs.map { id -> Candidate in
            (source: "Spaces/\(id)/Displays/\(uuid)", desktop: desktop((space(id)["Displays"] as? [String: Any])?[uuid]))
        }
        let perSpace: [Candidate] = spaceIDs.map { id -> Candidate in
            (source: "Spaces/\(id)/Default", desktop: desktop(space(id)["Default"]))
        }
        let display: Candidate = (source: "Displays/\(uuid)", desktop: desktop((root["Displays"] as? [String: Any])?[uuid]))
        let allDisplays: Candidate = (source: "AllSpacesAndDisplays", desktop: desktop(root["AllSpacesAndDisplays"]))
        let systemDefault: Candidate = (source: "SystemDefault", desktop: desktop(root["SystemDefault"]))

        // Most specific first; fall back to broader settings only if a level has nothing usable.
        let levels: [[Candidate]] = [perDisplay + [display], perSpace + [allDisplays], [systemDefault]]
        for level in levels {
            let entries = level.compactMap { item in
                item.desktop.flatMap { Self.entry(fromDesktop: $0, source: item.source) }
            }
            if !entries.isEmpty {
                return entries.sorted { $0.lastUse > $1.lastUse }
            }
        }
        return []
    }

    private static func entry(fromDesktop value: Any, source: String) -> Entry? {
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
        return Entry(wallpaper: DisplayWallpaper(kind: kind, shuffleDescription: shuffle), lastUse: lastUse, source: source)
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
