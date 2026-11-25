// Throwaway experiment: how does macOS expose folder-shuffle wallpapers?
import AppKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

@discardableResult
func sh(_ command: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", command]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func describe(_ value: Any, _ indent: String = "") -> String {
    let next = indent + "  "
    switch value {
    case let dict as [String: Any]:
        return "{\n" + dict.keys.sorted().map { "\(next)\($0) = \(describe(dict[$0]!, next))" }.joined(separator: "\n") + "\n\(indent)}"
    case let array as [Any]:
        return "[\n" + array.map { next + describe($0, next) }.joined(separator: "\n") + "\n\(indent)]"
    case let data as Data:
        if let inner = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            return "<data \(data.count)B plist> " + describe(inner, indent)
        }
        if let s = String(data: data, encoding: .utf8), s.count < 400 { return "<data utf8> \(s)" }
        return "<data \(data.count)B> " + data.prefix(48).map { String(format: "%02x", $0) }.joined()
    default:
        return "\(value)"
    }
}

let indexURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

func dumpIndex(_ label: String) {
    print("\n=== Index.plist [\(label)]")
    guard let data = try? Data(contentsOf: indexURL),
          let obj = try? PropertyListSerialization.propertyList(from: data, format: nil)
    else { print("unreadable"); return }
    print(describe(obj))
}

func displayUUID(_ screen: NSScreen) -> String {
    guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
          let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue()
    else { return "?" }
    return CFUUIDCreateString(nil, uuid) as String
}

func screens(_ label: String) {
    print("\n=== Screens [\(label)]")
    for s in NSScreen.screens {
        print("screen \(s.localizedName) uuid=\(displayUUID(s)) frame=\(s.frame)")
        print("  desktopImageURL: \(String(describing: NSWorkspace.shared.desktopImageURL(for: s)))")
        print("  options: \(String(describing: NSWorkspace.shared.desktopImageOptions(for: s)))")
    }
}

func openFiles(_ label: String) {
    print("\n=== Wallpaper processes and open image files [\(label)]")
    print(sh("ps -axo pid,user,comm | grep -i -E 'wallpaper|dock' | grep -v grep"))
    print(sh("""
    for p in $(pgrep -f -i wallpaper); do
      echo "--- PID $p $(ps -o comm= -p $p)"
      lsof -p $p 2>&1 | grep -i -E 'WPTest|\\.(png|jpe?g|heic|bmp|tiff?)' | awk '{print $4, $5, $NF}'
    done
    """))
}

// Distinct solid colors so a screenshot tells us which file is on screen.
let colors: [(String, NSColor)] = [
    ("red", .red), ("green", .green), ("blue", .blue),
    ("yellow", .yellow), ("magenta", .magenta), ("cyan", .cyan),
]
let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/WPTest", isDirectory: true)
try? FileManager.default.removeItem(at: folder)
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (name, color) in colors {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setFill()
    NSRect(x: 0, y: 0, width: 640, height: 400).fill()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(name).png"))
}

let shots = URL(fileURLWithPath: "/tmp/probe-shots", isDirectory: true)
try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
var shotIndex = 0
func shot(_ label: String) {
    shotIndex += 1
    let path = shots.appendingPathComponent(String(format: "%02d-%@.png", shotIndex, label)).path
    _ = sh("screencapture -x '\(path)'")
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("\n=== Screenshot [\(label)]: failed"); return
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    // Sample bottom-left-ish area away from the menu bar and Dock.
    let c = rep.colorAt(x: cg.width / 4, y: cg.height / 2)?.usingColorSpace(.deviceRGB)
    let match = colors.min { a, b in
        func d(_ x: NSColor) -> CGFloat {
            guard let c, let x = x.usingColorSpace(.deviceRGB) else { return 9 }
            return pow(c.redComponent - x.redComponent, 2) + pow(c.greenComponent - x.greenComponent, 2) + pow(c.blueComponent - x.blueComponent, 2)
        }
        return d(a.1) < d(b.1)
    }
    print("\n=== Screenshot [\(label)]: \(cg.width)x\(cg.height) sample=\(String(describing: c)) nearest=\(match?.0 ?? "?")")
}

func pause(_ s: UInt32) { sleep(s) }

print(sh("sw_vers; whoami; echo; defaults read com.apple.wallpaper 2>&1 | head -50"))
screens("initial")
dumpIndex("initial")
openFiles("initial")
shot("initial")

// Experiment 1: does setDesktopImageURL accept a folder?
print("\n### Experiment 1: setDesktopImageURL(folder)")
for s in NSScreen.screens {
    do {
        try NSWorkspace.shared.setDesktopImageURL(folder, for: s, options: [:])
        print("set folder OK on \(s.localizedName)")
    } catch {
        print("set folder FAILED on \(s.localizedName): \(error)")
    }
}
pause(6)
screens("after set folder")
dumpIndex("after set folder")
openFiles("after set folder")
shot("after-set-folder")
print(sh("osascript -e 'tell application \"System Events\" to get picture of every desktop' 2>&1"))
print(sh("osascript -e 'tell application \"System Events\" to get picture rotation of every desktop' 2>&1"))
print(sh("osascript -e 'tell application \"Finder\" to get POSIX path of (desktop picture as alias)' 2>&1"))

// Experiment 2: set a single file, then check what the APIs report.
print("\n### Experiment 2: setDesktopImageURL(file)")
for s in NSScreen.screens {
    try? NSWorkspace.shared.setDesktopImageURL(folder.appendingPathComponent("green.png"), for: s, options: [:])
}
pause(5)
screens("after set green file")
dumpIndex("after set green file")
openFiles("after set green file")
shot("after-set-green")

// Experiment 3: AppleScript folder rotation (older documented route).
print("\n### Experiment 3: System Events picture rotation")
print(sh("""
osascript -e 'tell application "System Events" to tell every desktop
  set pictures folder to "\(folder.path)"
  set picture rotation to 1
  set random order to true
  set change interval to 5.0
end tell' 2>&1
"""))
pause(6)
screens("after AppleScript rotation")
dumpIndex("after AppleScript rotation")
openFiles("after AppleScript rotation")
shot("after-applescript-rotation")
for i in 1...3 {
    pause(6)
    openFiles("rotation +\(i * 6)s")
    shot("rotation-\(i)")
}

// Experiment 4: re-apply the reported URL (claimed to advance the shuffle).
print("\n### Experiment 4: re-apply current URL + options")
for s in NSScreen.screens {
    if let url = NSWorkspace.shared.desktopImageURL(for: s) {
        let opts = NSWorkspace.shared.desktopImageOptions(for: s) ?? [:]
        do { try NSWorkspace.shared.setDesktopImageURL(url, for: s, options: opts); print("re-applied \(url.path)") }
        catch { print("re-apply failed: \(error)") }
    }
}
pause(4)
screens("after re-apply")
openFiles("after re-apply")
shot("after-reapply")

// Experiment 5: restart WallpaperAgent.
print("\n### Experiment 5: killall WallpaperAgent")
print(sh("killall WallpaperAgent 2>&1; echo exit=$?"))
pause(8)
screens("after killall")
dumpIndex("after killall")
openFiles("after killall")
shot("after-killall")
print("\nDONE")
