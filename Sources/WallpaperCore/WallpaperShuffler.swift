import Foundation

/// Decides which wallpaper to show next.
///
/// - Random order without repeats: every image in the folder is shown once before any image is
///   shown again (a "round"), and the same image is never shown twice in a row.
/// - Back/forward history, like a web browser: `goBack` returns to earlier wallpapers and
///   `advance` replays them forward before picking new random ones.
///
/// Images are identified by their file path. The candidate list is passed in on every call, so
/// images added to or removed from the folder are picked up automatically.
public struct WallpaperShuffler: Codable, Equatable {
    public private(set) var current: String?
    public private(set) var back: [String] = []
    public private(set) var forward: [String] = []
    /// Images already shown in the current round.
    public private(set) var seen: Set<String> = []
    public var historyLimit: Int = 200

    public init(current: String? = nil) {
        self.current = current
        if let current { seen.insert(current) }
    }

    /// Moves to the next wallpaper and returns its path.
    ///
    /// Returns `current` unchanged when it is the only image available, and `nil` when there is
    /// nothing to show at all.
    @discardableResult
    public mutating func advance<G: RandomNumberGenerator>(candidates: [String], using rng: inout G) -> String? {
        let available = Set(candidates)

        // Replay forward history first (after the user went back).
        while let path = forward.popLast() {
            if path != current, available.contains(path) {
                move(to: path)
                return path
            }
        }

        seen.formIntersection(available)
        var pool = candidates.filter { $0 != current && !seen.contains($0) }
        if pool.isEmpty {
            // Every image has been shown this round, so start a new one. The current image counts
            // as already seen so it doesn't come straight back.
            seen.removeAll()
            if let current { seen.insert(current) }
            pool = candidates.filter { $0 != current }
        }

        guard let pick = pool.randomElement(using: &rng) else {
            if let current, available.contains(current) {
                return current
            }
            current = nil
            return nil
        }
        move(to: pick)
        return pick
    }

    @discardableResult
    public mutating func advance(candidates: [String]) -> String? {
        var rng = SystemRandomNumberGenerator()
        return advance(candidates: candidates, using: &rng)
    }

    /// Goes back to the previous wallpaper that still exists, or returns `nil` if there is none.
    @discardableResult
    public mutating func goBack(available: Set<String>) -> String? {
        while let path = back.popLast() {
            guard path != current, available.contains(path) else { continue }
            if let current { forward.append(current) }
            current = path
            return path
        }
        return nil
    }

    /// Shows a specific image now (for example one restored from the Trash).
    public mutating func show(_ path: String) {
        guard path != current else { return }
        forward.removeAll()
        move(to: path)
    }

    /// Forgets an image that was deleted. If it is the current image, `current` becomes `nil`
    /// and the next `advance` will not put it into the back history.
    public mutating func remove(_ path: String) {
        back.removeAll { $0 == path }
        forward.removeAll { $0 == path }
        seen.remove(path)
        if current == path { current = nil }
    }

    /// Starts over, for example after switching to another folder.
    public mutating func reset() {
        let limit = historyLimit
        self = WallpaperShuffler()
        historyLimit = limit
    }

    private mutating func move(to path: String) {
        if let current {
            back.append(current)
            if back.count > historyLimit {
                back.removeFirst(back.count - historyLimit)
            }
        }
        current = path
        seen.insert(path)
    }
}
