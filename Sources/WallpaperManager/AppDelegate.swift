import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let intervalChoices: [(seconds: Int, title: String)] = [
        (60, "1 Minute"),
        (5 * 60, "5 Minutes"),
        (10 * 60, "10 Minutes"),
        (15 * 60, "15 Minutes"),
        (30 * 60, "30 Minutes"),
        (60 * 60, "1 Hour"),
        (3 * 60 * 60, "3 Hours"),
        (24 * 60 * 60, "1 Day"),
    ]

    private let controller: WallpaperController
    private var statusItem: NSStatusItem!
    private var thumbnailCache: (path: String, image: NSImage?)?

    override init() {
        controller = WallpaperController()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Wallpaper Manager")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Wallpaper Manager"
        }
        // The menu is rebuilt each time it opens (see `menuNeedsUpdate`). It opens on left or right click.
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        controller.onChange = { [weak self] in self?.wallpaperDidChange() }
        controller.start()
    }

    private func wallpaperDidChange() {
        let name = controller.current?.lastPathComponent
        statusItem.button?.toolTip = name.map { "Wallpaper: \($0)" } ?? "Wallpaper Manager"
        // Prepare the preview now so the menu opens instantly.
        if let url = controller.current {
            _ = thumbnail(for: url)
        }
    }

    private func thumbnail(for url: URL) -> NSImage? {
        if let cache = thumbnailCache, cache.path == url.path {
            return cache.image
        }
        let image = Thumbnail.make(for: url)
        thumbnailCache = (url.path, image)
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        controller.refreshImageCount()

        // Current picture: preview and file name. Clicking it opens the picture.
        if let url = controller.current {
            let preview = NSMenuItem(title: url.lastPathComponent, action: #selector(openCurrent), keyEquivalent: "")
            preview.target = self
            preview.image = thumbnail(for: url)
            preview.toolTip = url.path
            menu.addItem(preview)
        } else {
            menu.addItem(infoItem(controller.folder == nil ? "No folder selected" : "No pictures found"))
        }
        if let status = statusText() {
            menu.addItem(infoItem(status))
        }
        menu.addItem(.separator())

        let hasCurrent = controller.current != nil
        menu.addItem(actionItem("Next Wallpaper", #selector(nextWallpaper)))
        menu.addItem(actionItem("Previous Wallpaper", #selector(previousWallpaper)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Move to Trash", #selector(trashCurrent), enabled: hasCurrent))
        menu.addItem(actionItem("Show in Finder", #selector(revealCurrent), enabled: hasCurrent))
        menu.addItem(actionItem("Open", #selector(openCurrent), enabled: hasCurrent))
        if let trashed = controller.lastTrashed {
            menu.addItem(actionItem("Put Back “\(trashed.original.lastPathComponent)”", #selector(restoreLastTrashed)))
        }
        menu.addItem(.separator())

        menu.addItem(actionItem(controller.isPaused ? "Resume Shuffling" : "Pause Shuffling", #selector(togglePause)))
        menu.addItem(submenuItem("Change Picture Every", intervalMenu()))
        menu.addItem(submenuItem("Picture Size", scalingMenu()))
        menu.addItem(.separator())

        if let folder = controller.folder {
            let count = controller.imageCount
            let item = infoItem("\(folder.lastPathComponent): \(count) picture\(count == 1 ? "" : "s")")
            item.toolTip = folder.path
            menu.addItem(item)
        }
        menu.addItem(actionItem("Choose Folder…", #selector(chooseFolder)))
        let subfolders = actionItem("Include Subfolders", #selector(toggleSubfolders))
        subfolders.state = controller.includeSubfolders ? .on : .off
        menu.addItem(subfolders)
        menu.addItem(.separator())

        let login = actionItem("Open at Login", #selector(toggleOpenAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = NSMenuItem(title: "Quit Wallpaper Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func statusText() -> String? {
        if controller.folder == nil { return "Choose a folder to get started" }
        if controller.isPaused { return "Shuffling is paused" }
        guard let date = controller.nextChangeDate else { return nil }
        if date.timeIntervalSinceNow < 60 { return "Next picture in less than a minute" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Next picture \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func intervalMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for choice in Self.intervalChoices {
            let item = NSMenuItem(title: choice.title, action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = choice.seconds
            item.state = Int(controller.interval.rounded()) == choice.seconds ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func scalingMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for scaling in Scaling.allCases {
            let item = NSMenuItem(title: scaling.title, action: #selector(selectScaling(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scaling.rawValue
            item.state = controller.scaling == scaling ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    // MARK: - Menu actions

    @objc private func nextWallpaper() { controller.next() }
    @objc private func previousWallpaper() { controller.previous() }
    @objc private func trashCurrent() { controller.trashCurrent() }
    @objc private func revealCurrent() { controller.revealCurrent() }
    @objc private func openCurrent() { controller.openCurrent() }
    @objc private func restoreLastTrashed() { controller.restoreLastTrashed() }
    @objc private func togglePause() { controller.setPaused(!controller.isPaused) }
    @objc private func chooseFolder() { controller.chooseFolder() }
    @objc private func toggleSubfolders() { controller.setIncludeSubfolders(!controller.includeSubfolders) }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        controller.setInterval(TimeInterval(sender.tag))
    }

    @objc private func selectScaling(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let scaling = Scaling(rawValue: raw) else { return }
        controller.setScaling(scaling)
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            controller.showAlert(
                "Couldn’t change the login item.",
                "\(error.localizedDescription)\n\nYou can also add Wallpaper Manager in System Settings › General › Login Items."
            )
        }
    }
}
