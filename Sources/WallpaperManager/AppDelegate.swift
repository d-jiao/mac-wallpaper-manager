import AppKit
import ServiceManagement
import WallpaperCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor: WallpaperMonitor
    private var statusItem: NSStatusItem!
    private var thumbnailCache: [String: NSImage] = [:]

    override init() {
        monitor = WallpaperMonitor()
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

        monitor.onChange = { [weak self] in self?.wallpapersDidChange() }
        monitor.start()
    }

    private func wallpapersDidChange() {
        let names = monitor.screens.compactMap { $0.current?.lastPathComponent }
        statusItem.button?.toolTip = names.isEmpty ? "Wallpaper Manager" : names.joined(separator: "\n")

        // Prepare previews now so the menu opens instantly, and drop ones no longer needed.
        let paths = Set(monitor.screens.compactMap { $0.current?.path })
        thumbnailCache = thumbnailCache.filter { paths.contains($0.key) }
        for screen in monitor.screens {
            if let url = screen.current { _ = thumbnail(for: url) }
        }
    }

    private func thumbnail(for url: URL) -> NSImage? {
        if let cached = thumbnailCache[url.path] { return cached }
        let image = Thumbnail.make(for: url)
        thumbnailCache[url.path] = image
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !monitor.storeReadable {
            menu.addItem(infoItem("Couldn’t read the wallpaper settings"))
            menu.addItem(infoItem("Check System Settings › Wallpaper"))
            menu.addItem(.separator())
        }

        for screen in monitor.screens {
            addSection(for: screen, to: menu)
            menu.addItem(.separator())
        }

        let canAdvance = monitor.screens.contains { $0.isRotatingFolder }
        let next = actionItem("Next Picture on All Screens", #selector(nextPictures), enabled: canAdvance)
        next.toolTip = "Shows a new picture from each screen’s folder. macOS can only do this for all screens at once."
        menu.addItem(next)
        if let trashed = monitor.lastTrashed {
            menu.addItem(actionItem("Put Back “\(trashed.original.lastPathComponent)”", #selector(restoreLastTrashed)))
        }
        menu.addItem(.separator())

        let login = actionItem("Open at Login", #selector(toggleOpenAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = NSMenuItem(title: "Quit Wallpaper Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func addSection(for screen: WallpaperMonitor.Screen, to menu: NSMenu) {
        let folder = screen.wallpaper?.folder
        let title = folder.map { "\(screen.name) · \($0.lastPathComponent)" } ?? screen.name
        menu.addItem(headerItem(title, toolTip: folder?.path))

        if let url = screen.current {
            // Preview and file name; clicking opens the picture.
            let preview = actionItem(url.lastPathComponent, #selector(openPicture(_:)), screen: screen)
            preview.image = thumbnail(for: url)
            preview.toolTip = url.path
            menu.addItem(preview)
        } else if folder != nil {
            menu.addItem(infoItem("Finding the current picture…"))
        } else {
            menu.addItem(infoItem(description(of: screen.wallpaper)))
        }

        if screen.isRotatingFolder {
            menu.addItem(actionItem("Move to Trash", #selector(trashPicture(_:)), screen: screen, enabled: screen.current != nil))
        }
        if screen.current != nil || folder != nil {
            let title = screen.current != nil ? "Show in Finder" : "Show Folder in Finder"
            menu.addItem(actionItem(title, #selector(revealPicture(_:)), screen: screen))
        }
        if let shuffle = screen.wallpaper?.shuffleDescription {
            menu.addItem(infoItem("macOS changes it \(shuffle)"))
        }
    }

    private func description(of wallpaper: DisplayWallpaper?) -> String {
        switch wallpaper?.kind {
        case .image?: return "Picture file not found"
        case .other?: return "Not shuffling a folder"
        case .folder?, nil: return "Wallpaper not found in settings"
        }
    }

    private func headerItem(_ title: String, toolTip: String?) -> NSMenuItem {
        let item: NSMenuItem
        if #available(macOS 14.0, *) {
            item = NSMenuItem.sectionHeader(title: title)
        } else {
            item = infoItem(title)
        }
        item.toolTip = toolTip
        return item
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(
        _ title: String,
        _ action: Selector,
        screen: WallpaperMonitor.Screen? = nil,
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = screen?.id
        item.isEnabled = enabled
        return item
    }

    // MARK: - Menu actions

    @objc private func trashPicture(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { monitor.trashCurrent(on: id) }
    }

    @objc private func revealPicture(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { monitor.reveal(on: id) }
    }

    @objc private func openPicture(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { monitor.open(on: id) }
    }

    @objc private func nextPictures() { monitor.nextPictures() }
    @objc private func restoreLastTrashed() { monitor.restoreLastTrashed() }

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
            monitor.showAlert(
                "Couldn’t change the login item.",
                "\(error.localizedDescription)\n\nYou can also add Wallpaper Manager in System Settings › General › Login Items."
            )
        }
    }
}
