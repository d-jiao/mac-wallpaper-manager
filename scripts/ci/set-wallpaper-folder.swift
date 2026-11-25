// CI helper: makes every display shuffle the given folder, like choosing it in System Settings › Wallpaper.
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for screen in NSScreen.screens {
    try NSWorkspace.shared.setDesktopImageURL(folder, for: screen, options: [:])
}
