import Foundation

/// Works out which file each display is showing, from the picture files macOS's wallpaper process
/// has open.
///
/// - Each open file belongs to the display whose current folder contains it (the most specific folder
///   if folders are nested). A display only falls back to its older folders for files no other display
///   claims, and a file is never shown for two displays.
/// - When macOS switches pictures, the previous file stays open for a few seconds next to the new one.
///   Within a display's folder the tracker prefers a file that just appeared, then the file it picked
///   last time, then the order the files were listed in.
public struct CurrentPictureTracker {
    private var previouslyOpen: Set<String> = []
    private var lastPick: [String: String] = [:]

    public init() {}

    /// - Parameters:
    ///   - openFiles: paths of files open in the wallpaper processes, in the order they were listed.
    ///   - folders: for each display, its folders; the first is the current one, the rest are fallbacks.
    ///   - fileExists: used to keep the previous picks while nothing is open (macOS restarting its
    ///     wallpaper process).
    /// - Returns: the current picture path for each display that has one open.
    public mutating func update(
        openFiles: [String],
        folders: [String: [URL]],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String: String] {
        if openFiles.isEmpty {
            lastPick = lastPick.filter { folders[$0.key]?.isEmpty == false && fileExists($0.value) }
            return lastPick
        }

        var files: [String] = []
        for path in openFiles where !files.contains(path) {
            files.append(path)
        }
        let mainFolders = folders.compactMapValues { $0.first.map(Self.pathVariants) }
        let allFolders = folders.mapValues { $0.flatMap(Self.pathVariants) }

        // Hand each file to the display(s) whose current folder holds it most specifically.
        var candidates: [String: [String]] = [:]
        var claimed = Set<String>()
        for file in files {
            var owners: [String] = []
            var bestLength = -1
            for (display, dirs) in mainFolders {
                guard let length = dirs.filter({ Self.path(file, isInside: $0) }).map(\.count).max() else { continue }
                if length > bestLength {
                    owners = [display]
                    bestLength = length
                } else if length == bestLength {
                    owners.append(display)
                }
            }
            for display in owners {
                candidates[display, default: []].append(file)
            }
            if !owners.isEmpty { claimed.insert(file) }
        }
        // Displays with nothing in their current folder may use their older folders, but only for
        // files that no display claims.
        for display in folders.keys where candidates[display, default: []].isEmpty {
            let dirs = allFolders[display, default: []]
            let fallback = files.filter { file in
                !claimed.contains(file) && dirs.contains { Self.path(file, isInside: $0) }
            }
            if !fallback.isEmpty { candidates[display] = fallback }
        }

        var picks: [String: String] = [:]
        var taken = Set<String>()
        for display in folders.keys.sorted() {
            guard let list = candidates[display], !list.isEmpty else { continue }
            let fresh = list.filter { !previouslyOpen.contains($0) }
            let previous = lastPick[display].map { list.contains($0) ? [$0] : [] } ?? []
            if let pick = (fresh + previous + list).first(where: { !taken.contains($0) }) {
                picks[display] = pick
                taken.insert(pick)
            }
        }

        previouslyOpen = Set(files)
        lastPick = picks
        return picks
    }

    /// A folder's path as stored, plus its symlink-resolved form.
    private static func pathVariants(_ folder: URL) -> [String] {
        let paths = [folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path]
        return paths[0] == paths[1] ? [paths[0]] : paths
    }

    static func path(_ path: String, isInside folder: String) -> Bool {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(prefix)
    }

    /// Extracts file paths from `lsof -F n` output (lines starting with "n").
    public static func paths(fromLsofOutput output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            line.first == "n" ? String(line.dropFirst()) : nil
        }
    }
}
