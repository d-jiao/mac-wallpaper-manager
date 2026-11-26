// Temporary CI check: does macOS's shuffle keep going after the picture on screen is moved to the Trash?
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
let folder = home.appendingPathComponent("Pictures/TrashCheck", isDirectory: true)
let colors: [(String, NSColor)] = [("red", .red), ("green", .green), ("blue", .blue), ("yellow", .yellow), ("magenta", .magenta), ("cyan", .cyan)]
try? FileManager.default.removeItem(at: folder)
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (name, color) in colors {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setFill()
    NSRect(x: 0, y: 0, width: 640, height: 400).fill()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(name).png"))
}

func onScreen() -> String {
    let path = "/tmp/trash-shot.png"
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

func openFiles() -> [String] {
    sh("lsof -n -P -w -F n -c WallpaperImage | grep '^n' | cut -c2- | grep -E 'TrashCheck|\\.Trash'")
        .split(separator: "\n").map(String.init)
}

func watch(_ label: String, seconds: Double) {
    print("\n### \(label)")
    let start = Date()
    var last = ""
    while Date().timeIntervalSince(start) < seconds {
        let line = "screen=\(onScreen()) open=\(openFiles().map { $0.replacingOccurrences(of: home.path, with: "~") }.joined(separator: ","))"
        if line != last { print(String(format: "  %6.2fs  %@", Date().timeIntervalSince(start), line)); last = line }
        usleep(500_000)
    }
}

func setFrequency(_ id: String) {
    func walk(_ v: Any) -> Any {
        if var d = v as? [String: Any] {
            for (k, x) in d {
                if k == "EncodedOptionValues", let data = x as? Data,
                   var inner = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   var values = inner["values"] as? [String: Any] {
                    values["shuffleFrequency"] = ["picker": ["_0": ["id": id]]]
                    inner["values"] = values
                    d[k] = try! PropertyListSerialization.data(fromPropertyList: inner, format: .binary, options: 0)
                } else { d[k] = walk(x) }
            }
            return d
        }
        if let a = v as? [Any] { return a.map(walk) }
        return v
    }
    let root = try! PropertyListSerialization.propertyList(from: Data(contentsOf: indexURL), format: nil)
    try! PropertyListSerialization.data(fromPropertyList: walk(root), format: .binary, options: 0).write(to: indexURL)
}

try! NSWorkspace.shared.setDesktopImageURL(folder, for: NSScreen.screens[0], options: [:])
sleep(3)
setFrequency("shuffle_every_1_minute")
sh("killall WallpaperAgent")
watch("1-minute shuffle running (t=0 at restart)", seconds: 70)

// Trash whatever is on screen right now, like the app's Move to Trash.
guard let current = openFiles().first(where: { $0.contains("/TrashCheck/") }) else { print("no current file"); exit(1) }
var resulting: NSURL?
try! FileManager.default.trashItem(at: URL(fileURLWithPath: current), resultingItemURL: &resulting)
print("\nTrashed \(current) -> \(resulting?.path ?? "?")")
watch("after trashing the picture on screen (expect a change within ~60 s)", seconds: 150)
print("\nDONE")
