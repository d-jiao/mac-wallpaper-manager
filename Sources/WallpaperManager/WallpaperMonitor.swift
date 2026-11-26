import AppKit
import WallpaperCore

/// Watches what macOS's own wallpaper shuffle is showing on each display and performs the file actions.
///
/// - The folder each display rotates through comes from System Settings' wallpaper store (Index.plist).
/// - The picture on screen is found from the files macOS's wallpaper process (WallpaperImageExtension)
///   has open, since macOS doesn't offer an API for it.
@MainActor
final class WallpaperMonitor {
    struct Screen {
        /// Display UUID, as used in the wallpaper store.
        let id: String
        let name: String
        let wallpaper: DisplayWallpaper?
        /// The picture on screen, when it could be determined.
        let current: URL?

        var isRotatingFolder: Bool { wallpaper?.folder != nil }
    }

    private(set) var screens: [Screen] = []
    private(set) var storeReadable = true
    /// The most recently trashed picture, so it can be put back.
    private(set) var lastTrashed: (original: URL, inTrash: URL)?
    /// Displays whose picture was just trashed (display ID to file name), until macOS shows the next one.
    private(set) var trashedOnScreen: [String: String] = [:]
    /// Called on the main thread when anything shown in the menu changed.
    var onChange: (() -> Void)?

    /// While true (the menu is open), the monitor checks for changes more often.
    var isWatchingClosely = false {
        didSet {
            if isWatchingClosely && !oldValue { refresh() }
        }
    }

    private var tracker = CurrentPictureTracker()
    private var nextRefresh: Timer?
    private var isRefreshing = false
    /// Check often until this time, because a change is in progress (one screen switched, others may
    /// follow, and the previous file is still being released).
    private var fastUntil = Date.distantPast
    /// After Next or Trash, macOS needs about a second to open the new pictures.
    private var loadingUntil = Date.distantPast
    /// No checks while the displays sleep.
    private var displaysAsleep = false

    /// True right after Next or Trash, while macOS is still loading the new pictures.
    var isLoadingNewPictures: Bool { Date() < loadingUntil }

    /// Seconds between checks. Each check runs `lsof` on macOS's wallpaper process (about 10 ms of CPU).
    /// macOS opens a new picture's file as soon as it starts showing it, so checking often is what
    /// makes the menu keep up.
    private var pollInterval: TimeInterval {
        isWatchingClosely || Date() < fastUntil ? 0.25 : 1
    }

    func start() {
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        _ = workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.displaysAsleep = true
                self?.nextRefresh?.invalidate()
            }
        }
        _ = workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.displaysAsleep = false
                self?.refresh()
            }
        }
        refresh()
    }

    // MARK: - Actions

    /// Moves a display's current picture to the Trash. Nothing else changes: macOS keeps showing the
    /// picture until that display's next scheduled change, and other displays aren't touched.
    /// (macOS can't advance one display on its own without resetting its interval to 30 minutes.)
    func trashCurrent(on screenID: String) {
        guard let url = screen(screenID)?.current else {
            NSSound.beep()
            return
        }
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            lastTrashed = resultingURL.map { (original: url, inTrash: $0 as URL) }
        } catch {
            showAlert("Couldn’t move “\(url.lastPathComponent)” to the Trash.", error.localizedDescription)
            return
        }
        trashedOnScreen[screenID] = url.lastPathComponent
        onChange?()
        refresh()
    }

    /// Makes macOS pick new pictures now by restarting its wallpaper agent (launchd starts it again
    /// right away). This keeps every System Settings option, but it changes all displays at once:
    /// macOS has no way to advance a single display without resetting its settings.
    func nextPictures() {
        do {
            _ = try Process.run(URL(fileURLWithPath: "/usr/bin/killall"), arguments: ["WallpaperAgent"])
        } catch {
            showAlert("Couldn’t switch to the next pictures.", error.localizedDescription)
            return
        }
        // The new pictures take a moment to load.
        loadingUntil = Date().addingTimeInterval(8)
        watchFast(for: 15)
    }

    private func watchFast(for seconds: TimeInterval) {
        fastUntil = max(fastUntil, Date().addingTimeInterval(seconds))
        refresh()
    }

    func restoreLastTrashed() {
        guard let item = lastTrashed else { return }
        lastTrashed = nil
        do {
            try FileManager.default.moveItem(at: item.inTrash, to: item.original)
        } catch {
            // macOS can refuse to let apps take files out of the Trash. Finder's Put Back always works.
            showAlert(
                "Couldn’t put back “\(item.original.lastPathComponent)” automatically.",
                "It will be selected in the Trash in Finder. Right-click it and choose Put Back."
            )
            NSWorkspace.shared.activateFileViewerSelecting([item.inTrash])
        }
        onChange?()
    }

    func reveal(on screenID: String) {
        guard let screen = screen(screenID) else { return }
        if let url = screen.current {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let folder = screen.wallpaper?.folder {
            NSWorkspace.shared.open(folder)
        } else {
            NSSound.beep()
        }
    }

    func open(on screenID: String) {
        guard let url = screen(screenID)?.current else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    func showAlert(_ message: String, _ information: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = information
        alert.runModal()
    }

    // MARK: - Detection

    /// Everything read from the system in one go. Built off the main thread.
    struct Snapshot: Sendable {
        let storeReadable: Bool
        let wallpapers: [String: DisplayWallpaper]
        let folders: [String: [URL]]
        let openFiles: [String]
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        nextRefresh?.invalidate()
        let displays = Self.displays()
        let ids = displays.map(\.id)

        // Reading the store and listing open files takes a moment, so do it off the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = WallpaperMonitor.takeSnapshot(displayIDs: ids)
            Task { @MainActor [weak self] in
                self?.finishRefresh(displays: displays, snapshot: snapshot)
            }
        }
    }

    private func finishRefresh(displays: [(id: String, name: String)], snapshot: Snapshot) {
        isRefreshing = false
        let picks = tracker.update(openFiles: snapshot.openFiles, folders: snapshot.folders)
        let newScreens = Self.makeScreens(displays: displays, snapshot: snapshot, picks: picks)

        let changed = storeReadable != snapshot.storeReadable
            || newScreens.map(\.id) != screens.map(\.id)
            || newScreens.map(\.current) != screens.map(\.current)
            || newScreens.map(\.wallpaper) != screens.map(\.wallpaper)
        storeReadable = snapshot.storeReadable
        screens = newScreens
        // A display that shows a picture again has moved on from the trashed one.
        let stillWaiting = trashedOnScreen.filter { id, _ in newScreens.first { $0.id == id }?.current == nil }
        let trashChanged = stillWaiting.count != trashedOnScreen.count
        trashedOnScreen = stillWaiting
        if changed || trashChanged {
            // Other screens often follow within seconds, and lingering files settle; keep watching.
            fastUntil = max(fastUntil, Date().addingTimeInterval(10))
            onChange?()
        }
        scheduleNextRefresh()
    }

    private func scheduleNextRefresh() {
        nextRefresh?.invalidate()
        guard !displaysAsleep else { return }
        let interval = pollInterval
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = interval * 0.2
        // `.common` keeps checking while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        nextRefresh = timer
    }

    nonisolated static func takeSnapshot(displayIDs: [String]) -> Snapshot {
        let store = WallpaperStore(contentsOf: WallpaperStore.defaultURL)
        var wallpapers: [String: DisplayWallpaper] = [:]
        var folders: [String: [URL]] = [:]
        for id in displayIDs {
            wallpapers[id] = store?.wallpaper(forDisplay: id)
            folders[id] = store?.folders(forDisplay: id) ?? []
        }
        let needsFiles = folders.values.contains(where: { !$0.isEmpty })
        return Snapshot(
            storeReadable: store != nil,
            wallpapers: wallpapers,
            folders: folders,
            openFiles: needsFiles ? openWallpaperFiles() : []
        )
    }

    private static func makeScreens(
        displays: [(id: String, name: String)], snapshot: Snapshot, picks: [String: String]
    ) -> [Screen] {
        displays.map { display in
            let wallpaper = snapshot.wallpapers[display.id]
            // A check that started just before a Move to Trash can still report the old path.
            var current = picks[display.id].map { URL(fileURLWithPath: $0) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            if current == nil, case .image(let url)? = wallpaper?.kind,
               FileManager.default.fileExists(atPath: url.path) {
                current = url
            }
            return Screen(id: display.id, name: display.name, wallpaper: wallpaper, current: current)
        }
    }

    /// What the app detects right now, as text. Used by `WallpaperManager --status` for troubleshooting.
    static func statusReport() -> String {
        let displays = displays()
        let started = Date()
        let snapshot = takeSnapshot(displayIDs: displays.map(\.id))
        let elapsed = Date().timeIntervalSince(started)
        let store = WallpaperStore(contentsOf: WallpaperStore.defaultURL)
        var tracker = CurrentPictureTracker()
        let picks = tracker.update(openFiles: snapshot.openFiles, folders: snapshot.folders)
        let screens = makeScreens(displays: displays, snapshot: snapshot, picks: picks)

        var lines = [
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Wallpaper settings: \(snapshot.storeReadable ? "read" : "NOT readable") (\(WallpaperStore.defaultURL.path))",
        ]
        for screen in screens {
            lines.append("")
            lines.append("Display: \(screen.name) [\(screen.id)]")
            switch screen.wallpaper?.kind {
            case .folder(let url)?:
                lines.append("  Folder: \(url.path) (changes \(screen.wallpaper?.shuffleDescription ?? "on an unknown schedule"))")
            case .image(let url)?:
                lines.append("  Single picture: \(url.path)")
            case .other(let provider)?:
                lines.append("  Other wallpaper: \(provider)")
            case nil:
                lines.append("  Not found in settings")
            }
            lines.append("  Current picture: \(screen.current?.path ?? "not found")")
            let entries = store?.diagnostics(forDisplay: screen.id) ?? []
            lines.append("  Settings entries (newest first):")
            lines.append(contentsOf: entries.isEmpty ? ["    none"] : entries.map { "    \($0)" })
        }
        lines.append("")
        lines.append("Pictures open in macOS's wallpaper processes:")
        let pictureExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "avif"]
        let pictures = snapshot.openFiles.filter { pictureExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        lines.append(contentsOf: pictures.isEmpty ? ["  none"] : pictures.map { "  \($0)" })
        lines.append("")
        lines.append(String(format: "One check took %.0f ms", elapsed * 1000))
        return lines.joined(separator: "\n")
    }

    private func screen(_ id: String) -> Screen? {
        screens.first { $0.id == id }
    }

    /// Connected displays as (UUID, name). Names get a number if two displays share one.
    private static func displays() -> [(id: String, name: String)] {
        var result: [(id: String, name: String)] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
            else { continue }
            var name = screen.localizedName
            if result.contains(where: { $0.name == name }) {
                name += " (\(result.filter { $0.name.hasPrefix(screen.localizedName) }.count + 1))"
            }
            result.append((id: CFUUIDCreateString(nil, uuid) as String, name: name))
        }
        return result
    }

    /// Paths of files open in macOS's wallpaper process (WallpaperImageExtension), using `lsof`.
    nonisolated static func openWallpaperFiles() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-P", "-w", "-F", "n", "-c", "WallpaperImage"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CurrentPictureTracker.paths(fromLsofOutput: String(decoding: data, as: UTF8.self))
    }
}
