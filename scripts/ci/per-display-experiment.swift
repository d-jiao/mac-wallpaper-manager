// Temporary CI experiment: can one display be advanced without touching the others?
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
let colors: [(String, NSColor)] = [
    ("red", .red), ("green", .green), ("blue", .blue), ("yellow", .yellow), ("magenta", .magenta), ("cyan", .cyan),
]
let f1 = home.appendingPathComponent("Pictures/F1", isDirectory: true)
let f2 = home.appendingPathComponent("Pictures/F2", isDirectory: true)
for (i, (name, color)) in colors.enumerated() {
    let dir = i < 3 ? f1 : f2
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setFill()
    NSRect(x: 0, y: 0, width: 640, height: 400).fill()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(name).png"))
}

func onScreen() -> String {
    let path = "/tmp/exp-shot.png"
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

func openFiles() -> String {
    sh("lsof -n -P -w -F n -c WallpaperImage | grep '^n' | cut -c2- | grep -E '/F[12]/' | sed 's#.*/Pictures/##' | tr '\\n' ' '")
}

func watch(_ label: String, seconds: Double) {
    print("\n### \(label)")
    let start = Date()
    var last = ""
    while Date().timeIntervalSince(start) < seconds {
        let line = "screen=\(onScreen()) open=\(openFiles())"
        if line != last {
            print(String(format: "  %6.2fs  %@", Date().timeIntervalSince(start), line))
            last = line
        }
        usleep(250_000)
    }
}

/// Applies `edit` to every Desktop entry's Content dictionary in the store.
func patchStore(_ edit: (inout [String: Any]) -> Void) {
    func walk(_ v: Any) -> Any {
        guard var d = v as? [String: Any] else {
            if let a = v as? [Any] { return a.map(walk) }
            return v
        }
        for (k, x) in d {
            if k == "Content", var content = x as? [String: Any], content["Choices"] != nil {
                edit(&content)
                d[k] = content
            } else {
                d[k] = walk(x)
            }
        }
        return d
    }
    let root = try! PropertyListSerialization.propertyList(from: Data(contentsOf: indexURL), format: nil)
    try! PropertyListSerialization.data(fromPropertyList: walk(root), format: .binary, options: 0).write(to: indexURL)
}

func setFrequency(_ id: String) -> (inout [String: Any]) -> Void {
    return { content in
        guard let data = content["EncodedOptionValues"] as? Data,
              var inner = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var values = inner["values"] as? [String: Any] else { return }
        values["shuffleFrequency"] = ["picker": ["_0": ["id": id]]]
        inner["values"] = values
        content["EncodedOptionValues"] = try! PropertyListSerialization.data(fromPropertyList: inner, format: .binary, options: 0)
    }
}

func setFolder(_ folder: URL) -> (inout [String: Any]) -> Void {
    return { content in
        guard var choices = content["Choices"] as? [[String: Any]], !choices.isEmpty else { return }
        let config: [String: Any] = ["type": "imageFolder", "url": ["relative": folder.absoluteString]]
        choices[0]["Configuration"] = try! PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0)
        content["Choices"] = choices
    }
}

func storeSummary() -> String {
    let text = sh("plutil -p '\(indexURL.path)'")
    let urls = Set(text.components(separatedBy: "\n").filter { $0.contains("Pictures/F") }.map { $0.trimmingCharacters(in: .whitespaces) })
    var freqs = Set<String>()
    let root = try! PropertyListSerialization.propertyList(from: Data(contentsOf: indexURL), format: nil)
    func walk(_ v: Any) {
        if let d = v as? [String: Any] {
            for (k, x) in d {
                if k == "EncodedOptionValues", let data = x as? Data,
                   let inner = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    freqs.insert("\((((inner["values"] as? [String: Any])?["shuffleFrequency"] as? [String: Any])?["picker"] as? [String: Any]).map { "\($0)" } ?? "-")")
                } else if k == "Configuration", let data = x as? Data,
                          let inner = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                    freqs.insert("config \(inner)".replacingOccurrences(of: "\n", with: " "))
                } else { walk(x) }
            }
        } else if let a = v as? [Any] { a.forEach(walk) }
    }
    walk(root)
    return (Array(urls) + Array(freqs)).sorted().joined(separator: "\n    ")
}

let screen = NSScreen.screens[0]

print("### Setup: folder F1, every minute")
try! NSWorkspace.shared.setDesktopImageURL(f1, for: screen, options: [:])
sleep(3)
patchStore(setFrequency("shuffle_every_1_minute"))
sh("killall WallpaperAgent")
watch("after setup restart", seconds: 6)
print("  store:\n    \(storeSummary())")

// E1: does the agent pick up an external edit of the store without a restart?
patchStore(setFolder(f2))
watch("E1: store edited to folder F2, no restart", seconds: 15)
print("  store after E1:\n    \(storeSummary())")
// Put F1 back in the store (still no restart) so the rest starts clean.
patchStore(setFolder(f1))
watch("E1b: store edited back to F1, no restart", seconds: 8)

// E2: re-apply via a single file, then the folder. Does it change, and what happens to the frequency?
try! NSWorkspace.shared.setDesktopImageURL(f1.appendingPathComponent("red.png"), for: screen, options: [:])
try! NSWorkspace.shared.setDesktopImageURL(f1, for: screen, options: [:])
watch("E2: set file then folder", seconds: 6)
print("  store after E2:\n    \(storeSummary())")

// E3: patch the frequency back to 1 minute without a restart. Does it rotate within ~70 s?
patchStore(setFrequency("shuffle_every_1_minute"))
print("  store after E3 patch:\n    \(storeSummary())")
watch("E3: frequency patched to 1 minute, no restart (watch 80 s)", seconds: 80)
print("  store after E3:\n    \(storeSummary())")

// E4: re-apply the same folder with the store already saying 1 minute: does the setter keep it?
try! NSWorkspace.shared.setDesktopImageURL(f1.appendingPathComponent("green.png"), for: screen, options: [:])
patchStore(setFrequency("shuffle_every_1_minute"))
try! NSWorkspace.shared.setDesktopImageURL(f1, for: screen, options: [:])
watch("E4: set file, patch store to 1 min, set folder", seconds: 6)
print("  store after E4:\n    \(storeSummary())")
watch("E4: watch for 1-minute rotation (75 s)", seconds: 75)
print("\nDONE")
