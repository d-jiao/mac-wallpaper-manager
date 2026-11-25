// Throwaway experiment #2: natural rotation, and whether "next" keeps the user's settings.
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

let home = FileManager.default.homeDirectoryForCurrentUser
let indexURL = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

func loadIndex() -> [String: Any] {
    let data = try! Data(contentsOf: indexURL)
    return try! PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
}

/// Every shuffleFrequency id and placement id found anywhere in the store.
func summarizeOptions(_ label: String) {
    var found: [String] = []
    func walk(_ v: Any, _ path: String) {
        if let d = v as? [String: Any] {
            for (k, x) in d {
                if k == "EncodedOptionValues", let data = x as? Data,
                   let inner = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let values = inner["values"] as? [String: Any] {
                    let shuffle = (((values["shuffleFrequency"] as? [String: Any])?["picker"] as? [String: Any])?["_0"] as? [String: Any])?["id"]
                    let placement = (((values["placement"] as? [String: Any])?["picker"] as? [String: Any])?["_0"] as? [String: Any])?["id"]
                    found.append("\(path): shuffle=\(shuffle ?? "-") placement=\(placement ?? "-")")
                } else if k == "Configuration", let data = x as? Data,
                          let inner = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                    found.append("\(path): config=\(inner)".replacingOccurrences(of: "\n", with: " "))
                } else {
                    walk(x, path + "/" + k)
                }
            }
        } else if let a = v as? [Any] {
            for (i, x) in a.enumerated() { walk(x, path + "[\(i)]") }
        }
    }
    walk(loadIndex(), "")
    print("\n=== Store options [\(label)]")
    for line in found.sorted() { print("  " + line) }
}

/// Rewrites every shuffleFrequency id in the store.
func setShuffleFrequency(_ id: String) {
    func rewrite(_ v: Any) -> Any {
        if var d = v as? [String: Any] {
            for (k, x) in d {
                if k == "EncodedOptionValues", let data = x as? Data,
                   var inner = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   var values = inner["values"] as? [String: Any] {
                    values["shuffleFrequency"] = ["picker": ["_0": ["id": id]]]
                    inner["values"] = values
                    d[k] = try! PropertyListSerialization.data(fromPropertyList: inner, format: .binary, options: 0)
                } else {
                    d[k] = rewrite(x)
                }
            }
            return d
        }
        if let a = v as? [Any] { return a.map(rewrite) }
        return v
    }
    let out = try! PropertyListSerialization.data(fromPropertyList: rewrite(loadIndex()), format: .binary, options: 0)
    try! out.write(to: indexURL)
}

func openFiles() -> [String] {
    sh("lsof -n -P -F n -c Wallpaper 2>/dev/null | grep '^n' | cut -c2- | grep WPTest")
        .split(separator: "\n").map { URL(fileURLWithPath: String($0)).lastPathComponent }
}

let colors: [(String, NSColor)] = [
    ("red", .red), ("green", .green), ("blue", .blue), ("yellow", .yellow),
    ("magenta", .magenta), ("cyan", .cyan), ("orange", .orange), ("purple", .purple),
]
let folder = home.appendingPathComponent("Pictures/WPTest", isDirectory: true)
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

func onScreen() -> String {
    let path = "/tmp/probe-shot.png"
    _ = sh("screencapture -x \(path)")
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let c = NSBitmapImageRep(cgImage: cg).colorAt(x: cg.width / 4, y: cg.height / 2)?.usingColorSpace(.deviceRGB)
    else { return "?" }
    func d(_ x: NSColor) -> CGFloat {
        guard let x = x.usingColorSpace(.deviceRGB) else { return 9 }
        return pow(c.redComponent - x.redComponent, 2) + pow(c.greenComponent - x.greenComponent, 2) + pow(c.blueComponent - x.blueComponent, 2)
    }
    return colors.min { d($0.1) < d($1.1) }!.0
}

func report(_ label: String) {
    print(String(format: "[%@] %@  screen=%@  open=%@", Date().formatted(date: .omitted, time: .standard), label, onScreen(), openFiles().joined(separator: ",")))
}

let screen = NSScreen.screens[0]

print("### Shuffle frequency ids in system binaries")
print(sh("""
for f in /System/Library/ExtensionKit/Extensions/Wallpaper*.appex/Contents/MacOS/* /System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent; do
  strings -a "$f" 2>/dev/null | grep -E '^shuffle_' ; done | sort -u
"""))

print("\n### Step 1: set folder")
try! NSWorkspace.shared.setDesktopImageURL(folder, for: screen, options: [:])
sleep(5)
report("after set folder")
summarizeOptions("after set folder")

print("\n### Step 2: change shuffle frequency in the store to every minute, restart agent")
setShuffleFrequency("shuffle_every_minute")
sh("killall WallpaperAgent")
sleep(8)
summarizeOptions("after edit + restart")
report("after restart")

print("\n### Step 3: watch natural rotation for ~130 s")
for i in 1...26 {
    sleep(5)
    report("t+\(i * 5)s")
}

print("\n### Step 4: 'next' by re-setting the folder with current options (5 times)")
for i in 1...5 {
    let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
    try! NSWorkspace.shared.setDesktopImageURL(folder, for: screen, options: options)
    sleep(2)
    report("next #\(i) +2s")
    sleep(5)
    report("next #\(i) +7s")
}
summarizeOptions("after re-set folder")

print("\n### Step 5: 'next' by restarting WallpaperAgent (3 times)")
for i in 1...3 {
    sh("killall WallpaperAgent")
    sleep(4)
    report("killall #\(i) +4s")
    sleep(4)
    report("killall #\(i) +8s")
}
summarizeOptions("after killall")
print("\nDONE")
