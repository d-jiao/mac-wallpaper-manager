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
    /// Called on the main thread when anything shown in the menu changed.
    var onChange: (() -> Void)?

    private var tracker = CurrentPictureTracker()
    private var timer: Timer?
    private var isRefreshing = false

    func start() {
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    // MARK: - Actions

    /// Moves a display's current picture to the Trash, then shows new pictures.
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
        nextPictures()
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
        for delay in [1.5, 3.5, 6.0] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.refresh()
            }
        }
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
        if changed { onChange?() }
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
            var current = picks[display.id].map { URL(fileURLWithPath: $0) }
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
        let snapshot = takeSnapshot(displayIDs: displays.map(\.id))
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
        }
        lines.append("")
        lines.append("Files open in macOS's wallpaper processes:")
        lines.append(contentsOf: snapshot.openFiles.map { "  \($0)" })
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

    /// Paths of files open in macOS's wallpaper processes, using `lsof`.
    nonisolated static func openWallpaperFiles() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-P", "-w", "-F", "n", "-c", "WallpaperImage", "-c", "WallpaperAgent"]
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
