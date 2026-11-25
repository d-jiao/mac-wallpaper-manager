import Foundation

/// Works out which file each display is showing, from the picture files macOS's wallpaper process
/// has open.
///
/// When macOS switches pictures, the previous file stays open for a few seconds next to the new one.
/// The tracker is fed snapshots every few seconds and prefers a file that just appeared, then the
/// file it picked last time, then the order the files were listed in.
public struct CurrentPictureTracker {
    private var previouslyOpen: Set<String> = []
    private var lastPick: [String: String] = [:]

    public init() {}

    /// - Parameters:
    ///   - openFiles: paths of files open in the wallpaper processes, in the order they were listed.
    ///   - folders: for each display, the folders it rotates through.
    /// - Returns: the current picture path for each display that has one open.
    public mutating func update(openFiles: [String], folders: [String: [URL]]) -> [String: String] {
        var picks: [String: String] = [:]
        var taken = Set<String>()

        for display in folders.keys.sorted() {
            var dirs: [String] = []
            for folder in folders[display, default: []] {
                for path in [folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path] where !dirs.contains(path) {
                    dirs.append(path)
                }
            }
            var candidates: [String] = []
            for path in openFiles where !candidates.contains(path) && dirs.contains(where: { Self.path(path, isInside: $0) }) {
                candidates.append(path)
            }
            guard !candidates.isEmpty else { continue }

            let fresh = candidates.filter { !previouslyOpen.contains($0) }
            let previous = lastPick[display].map { [$0] } ?? []
            let preferenceOrder = fresh + previous.filter({ candidates.contains($0) }) + candidates
            var ranked: [String] = []
            for path in preferenceOrder where !ranked.contains(path) {
                ranked.append(path)
            }
            // Two displays can rotate the same folder; give them different files when possible.
            let pick = ranked.first { !taken.contains($0) } ?? ranked[0]
            picks[display] = pick
            taken.insert(pick)
        }

        previouslyOpen = Set(openFiles)
        lastPick = picks
        return picks
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
