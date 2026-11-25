// Temporary CI measurement: when does the screen change vs. when does the new file show up as open?
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
let folder = home.appendingPathComponent("Pictures/Latency", isDirectory: true)
let colors: [(String, NSColor)] = [
    ("red", .red), ("green", .green), ("blue", .blue), ("yellow", .yellow), ("magenta", .magenta), ("cyan", .cyan),
]

// Photo-sized JPEGs (left half solid color for detection, right half noise so decoding takes real work).
try? FileManager.default.removeItem(at: folder)
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let width = 6000, height = 4000
for (name, color) in colors {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: width * 3, bitsPerPixel: 24)!
    let c = color.usingColorSpace(.deviceRGB)!
    let px = rep.bitmapData!
    var seed: UInt32 = 12345
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 3
            if x < width / 2 {
                px[i] = UInt8(c.redComponent * 255); px[i + 1] = UInt8(c.greenComponent * 255); px[i + 2] = UInt8(c.blueComponent * 255)
            } else {
                seed = seed &* 1_103_515_245 &+ 12345
                px[i] = UInt8(truncatingIfNeeded: seed >> 16); px[i + 1] = UInt8(truncatingIfNeeded: seed >> 8); px[i + 2] = UInt8(truncatingIfNeeded: seed)
            }
        }
    }
    let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
    try! data.write(to: folder.appendingPathComponent("\(name).jpg"))
}
print("created \(colors.count) JPEGs of \(width)x\(height), \(sh("du -sh '\(folder.path)'"))")

func openFiles() -> [String] {
    sh("lsof -n -P -w -F n -c WallpaperImage | grep '^n' | cut -c2- | grep Latency")
        .split(separator: "\n").map { URL(fileURLWithPath: String($0)).deletingPathExtension().lastPathComponent }
}

func onScreen() -> String {
    let path = "/tmp/latency-shot.png"
    _ = sh("screencapture -x -R 0,300,300,10 \(path)")
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let c = NSBitmapImageRep(cgImage: cg).colorAt(x: cg.width / 2, y: cg.height / 2)?.usingColorSpace(.deviceRGB)
    else { return "?" }
    func d(_ x: NSColor) -> CGFloat {
        let x = x.usingColorSpace(.deviceRGB)!
        return pow(c.redComponent - x.redComponent, 2) + pow(c.greenComponent - x.greenComponent, 2) + pow(c.blueComponent - x.blueComponent, 2)
    }
    let best = colors.min { d($0.1) < d($1.1) }!
    return d(best.1) < 0.3 ? best.0 : "other"
}

/// Samples for `seconds`, printing only changes, relative to `start`.
func watch(_ label: String, seconds: Double, start: Date = Date()) {
    print("\n### \(label)")
    var lastFiles: [String] = ["-"], lastScreen = "-"
    while Date().timeIntervalSince(start) < seconds {
        let t = Date().timeIntervalSince(start)
        let files = openFiles()
        let screen = onScreen()
        if files != lastFiles { print(String(format: "  %6.2fs  open: %@", t, files.joined(separator: ","))); lastFiles = files }
        if screen != lastScreen { print(String(format: "  %6.2fs  screen: %@", t, screen)); lastScreen = screen }
        usleep(150_000)
    }
}

let indexURL = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
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
    let root = try! PropertyListSerialization.propertyList(from: Data(contentsOf: indexURL), format: nil)
    try! PropertyListSerialization.data(fromPropertyList: rewrite(root), format: .binary, options: 0).write(to: indexURL)
}

print(sh("launchctl print gui/$(id -u) 2>/dev/null | grep -i wallpaper | head -20"))

for screen in NSScreen.screens {
    try! NSWorkspace.shared.setDesktopImageURL(folder, for: screen, options: [:])
}
watch("set folder (t=0 at set)", seconds: 8)

setShuffleFrequency("shuffle_every_1_minute")
let restart = Date()
sh("killall WallpaperAgent")
watch("1-minute rotation after restart (t=0 at restart)", seconds: 140, start: restart)

for i in 1...2 {
    let t0 = Date()
    sh("killall WallpaperAgent")
    watch("killall #\(i) (t=0 at kill)", seconds: 12, start: t0)
}

let label = sh("launchctl print gui/$(id -u) 2>/dev/null | grep -o 'com.apple.wallpaper.agent[^ ]*' | head -1")
    .trimmingCharacters(in: .whitespacesAndNewlines)
print("\nlaunchd label: '\(label)'")
for i in 1...2 {
    let t0 = Date()
    print(sh("launchctl kickstart -k gui/$(id -u)/\(label.isEmpty ? "com.apple.wallpaper.agent" : label) 2>&1; echo exit=$?"))
    watch("kickstart -k #\(i) (t=0 at kickstart)", seconds: 12, start: t0)
}
print("\nDONE")
