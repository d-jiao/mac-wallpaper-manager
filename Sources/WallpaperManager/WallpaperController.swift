import AppKit
import WallpaperCore

/// How the picture is fitted to the screen (same choices as System Settings).
enum Scaling: String, CaseIterable {
    case fill, fit, stretch, center

    var title: String {
        switch self {
        case .fill: return "Fill Screen"
        case .fit: return "Fit to Screen"
        case .stretch: return "Stretch to Fill Screen"
        case .center: return "Center"
        }
    }

    var options: [NSWorkspace.DesktopImageOptionKey: Any] {
        switch self {
        case .fill:
            return [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]
        case .fit:
            return [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: false]
        case .stretch:
            return [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: true]
        case .center:
            return [.imageScaling: NSImageScaling.scaleNone.rawValue, .allowClipping: true]
        }
    }
}

/// Owns the shuffle timer and the current wallpaper, and performs the file actions
/// (move to Trash, put back, show in Finder).
@MainActor
final class WallpaperController: NSObject {
    private enum Key {
        static let folder = "folderPath"
        static let interval = "intervalSeconds"
        static let paused = "paused"
        static let includeSubfolders = "includeSubfolders"
        static let scaling = "scaling"
        static let shuffleState = "shuffleState"
    }

    private let defaults = UserDefaults.standard
    private(set) var folder: URL?
    private(set) var interval: TimeInterval
    private(set) var isPaused: Bool
    private(set) var includeSubfolders: Bool
    private(set) var scaling: Scaling
    /// Number of pictures found in the folder by the last scan.
    private(set) var imageCount = 0
    /// The most recently trashed picture, so it can be put back.
    private(set) var lastTrashed: (original: URL, inTrash: URL)?

    private var shuffler: WallpaperShuffler
    private var timer: Timer?

    /// Called whenever the wallpaper or a setting changes.
    var onChange: (() -> Void)?

    var current: URL? { shuffler.current.map { URL(fileURLWithPath: $0) } }
    var nextChangeDate: Date? { timer?.isValid == true ? timer?.fireDate : nil }

    override init() {
        let defaults = UserDefaults.standard
        folder = defaults.string(forKey: Key.folder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let savedInterval = defaults.double(forKey: Key.interval)
        interval = savedInterval >= 10 ? savedInterval : 10 * 60
        isPaused = defaults.bool(forKey: Key.paused)
        includeSubfolders = defaults.bool(forKey: Key.includeSubfolders)
        scaling = defaults.string(forKey: Key.scaling).flatMap(Scaling.init(rawValue:)) ?? .fill
        if let data = defaults.data(forKey: Key.shuffleState),
           let saved = try? JSONDecoder().decode(WallpaperShuffler.self, from: data) {
            shuffler = saved
        } else {
            shuffler = WallpaperShuffler()
        }
        super.init()
    }

    func start() {
        // Keep every Space and every display on the same picture.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reapplyCurrent(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(reapplyCurrent(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        guard folder != nil else {
            chooseFolder()
            return
        }
        if let current, FileManager.default.fileExists(atPath: current.path) {
            refreshImageCount()
            apply(current)
            scheduleTimer()
            onChange?()
        } else {
            advance(userInitiated: false)
        }
    }

    // MARK: - Actions

    func next() {
        advance(userInitiated: true)
    }

    func previous() {
        guard let folder else { return }
        let available = Set(scan(folder))
        if let path = shuffler.goBack(available: available) {
            display(path)
        } else {
            save()
            NSSound.beep()
        }
    }

    /// Moves the current picture to the Trash and shows the next one.
    func trashCurrent() {
        guard let url = current else {
            NSSound.beep()
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                lastTrashed = resultingURL.map { (original: url, inTrash: $0 as URL) }
            } catch {
                showAlert("Couldn’t move “\(url.lastPathComponent)” to the Trash.", error.localizedDescription)
                return
            }
        }
        shuffler.remove(url.path)
        advance(userInitiated: false)
    }

    /// Takes the last trashed picture out of the Trash and shows it again.
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
            onChange?()
            return
        }
        shuffler.show(item.original.path)
        display(item.original.path)
    }

    func revealCurrent() {
        guard let url = current else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openCurrent() {
        guard let url = current else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Settings

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Wallpaper Folder"
        panel.message = "Wallpaper Manager will shuffle the pictures in this folder."
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        folder = url
        defaults.set(url.path, forKey: Key.folder)
        shuffler.reset()
        advance(userInitiated: true)
    }

    func setInterval(_ seconds: TimeInterval) {
        interval = seconds
        defaults.set(seconds, forKey: Key.interval)
        scheduleTimer()
        onChange?()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        defaults.set(paused, forKey: Key.paused)
        scheduleTimer()
        onChange?()
    }

    func setIncludeSubfolders(_ include: Bool) {
        includeSubfolders = include
        defaults.set(include, forKey: Key.includeSubfolders)
        refreshImageCount()
        onChange?()
    }

    func setScaling(_ newScaling: Scaling) {
        scaling = newScaling
        defaults.set(newScaling.rawValue, forKey: Key.scaling)
        if let current {
            apply(current)
        }
        onChange?()
    }

    func refreshImageCount() {
        if let folder {
            _ = scan(folder)
        }
    }

    func showAlert(_ message: String, _ information: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = information
        alert.runModal()
    }

    // MARK: - Internals

    private func advance(userInitiated: Bool) {
        guard let folder else {
            if userInitiated { chooseFolder() }
            return
        }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            // For example an external drive that isn't connected. Keep the current state and try again later.
            if userInitiated {
                showAlert("The folder “\(folder.lastPathComponent)” can’t be found.", folder.path)
            }
            scheduleTimer()
            return
        }

        if let path = shuffler.advance(candidates: scan(folder)) {
            display(path)
        } else {
            save()
            scheduleTimer()
            onChange?()
            if userInitiated {
                showAlert("There are no pictures in “\(folder.lastPathComponent)”.", folder.path)
            }
        }
    }

    private func display(_ path: String) {
        apply(URL(fileURLWithPath: path))
        save()
        scheduleTimer()
        onChange?()
    }

    private func apply(_ url: URL, onlyIfChanged: Bool = false) {
        for screen in NSScreen.screens {
            if onlyIfChanged, NSWorkspace.shared.desktopImageURL(for: screen) == url {
                continue
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: scaling.options)
            } catch {
                NSLog("WallpaperManager: couldn't set wallpaper on \(screen.localizedName): \(error)")
            }
        }
    }

    @objc private func reapplyCurrent(_ notification: Notification) {
        guard let current, FileManager.default.fileExists(atPath: current.path) else { return }
        apply(current, onlyIfChanged: true)
    }

    @objc private func timerFired(_ timer: Timer) {
        advance(userInitiated: false)
    }

    /// (Re)starts the countdown, so a manual change always gets the full interval.
    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard !isPaused, folder != nil else { return }
        let timer = Timer(
            timeInterval: interval, target: self, selector: #selector(timerFired(_:)),
            userInfo: nil, repeats: true
        )
        timer.tolerance = min(interval * 0.1, 30)
        // `.common` keeps the timer running while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func scan(_ folder: URL) -> [String] {
        let paths = ImageScanner.imagePaths(in: folder, includeSubfolders: includeSubfolders)
        imageCount = paths.count
        return paths
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shuffler) {
            defaults.set(data, forKey: Key.shuffleState)
        }
    }
}
