// Temporary CI exploration #2: wallpaper App Intents, controls, and the "skip" signal.
import AppKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

@discardableResult
func sh(_ command: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", "setopt nullglob; " + command]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

let agent = "/System/Library/CoreServices/WallpaperAgent.app"

print("### Private wallpaper frameworks")
print(sh("ls -d /System/Library/PrivateFrameworks/*allpaper* /System/Library/PrivateFrameworks/*EyeCandy* 2>&1"))

print("\n### App Intents metadata in the agent's extensions")
let metadataFiles = sh("find '\(agent)' -name 'extract.actionsdata' 2>/dev/null").split(separator: "\n").map(String.init)
for file in metadataFiles {
    print("--- \(file)")
    guard let data = FileManager.default.contents(atPath: file),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { print("unreadable"); continue }
    if let actions = json["actions"] as? [String: Any] {
        for (id, value) in actions.sorted(by: { $0.key < $1.key }) {
            let action = value as? [String: Any] ?? [:]
            let title = ((action["title"] as? [String: Any])?["key"] as? String) ?? "\(action["title"] ?? "")"
            let params = (action["parameters"] as? [[String: Any]] ?? []).map { p -> String in
                let name = p["name"] as? String ?? "?"
                let type = (p["valueType"] as? [String: Any]).map { "\($0)".replacingOccurrences(of: "\n", with: " ") } ?? ""
                return "\(name):\(type.prefix(120))"
            }
            print("  action \(id) title=\(title) openApp=\(action["openAppWhenRun"] ?? "-") params=\(params)")
        }
    }
    if let entities = json["entities"] as? [String: Any] { print("  entities: \(entities.keys.sorted())") }
    if let enums = json["enums"] as? [[String: Any]] {
        for e in enums { print("  enum \(e["identifier"] ?? "?"): \((e["cases"] as? [[String: Any]] ?? []).compactMap { $0["identifier"] as? String })") }
    }
}

print("\n### Extension bundles")
print(sh("for p in '\(agent)'/Contents/PlugIns/*.appex; do echo \"$p\"; /usr/libexec/PlistBuddy -c 'Print :NSExtension' \"$p/Contents/Info.plist\" 2>&1 | head -20; /usr/libexec/PlistBuddy -c 'Print :EXAppExtensionAttributes' \"$p/Contents/Info.plist\" 2>&1 | head -10; done"))

print("\n### Strings mentioning skip / next / shuffle")
for binary in sh("ls '\(agent)'/Contents/MacOS/* '\(agent)'/Contents/PlugIns/*.appex/Contents/MacOS/*").split(separator: "\n") {
    print("--- \(binary)")
    print(sh("strings -a '\(binary)' | grep -i -E 'skip|nextwall|next ?wallpaper|shuffle|advance' | sort -u | head -40"))
}

// Experiment: send the "skip" signal in a few ways and watch the screen.
let colors: [(String, NSColor)] = [("red", .red), ("green", .green), ("blue", .blue), ("yellow", .yellow), ("magenta", .magenta), ("cyan", .cyan)]
let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Skip", isDirectory: true)
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
func openFiles() -> String {
    sh("lsof -n -P -w -F n -c WallpaperImage | grep '^n' | cut -c2- | grep /Skip/ | sed 's#.*/##' | tr '\\n' ' '")
}
func watch(_ label: String, seconds: Double) {
    print("\n### \(label)")
    let start = Date()
    var last = ""
    while Date().timeIntervalSince(start) < seconds {
        let line = openFiles()
        if line != last { print(String(format: "  %5.2fs open=%@", Date().timeIntervalSince(start), line)); last = line }
        usleep(250_000)
    }
}
try! NSWorkspace.shared.setDesktopImageURL(folder, for: NSScreen.screens[0], options: [:])
watch("set folder", seconds: 5)

for name in ["com.apple.wallpaper.skip", "com.apple.wallpaper.agent.controls"] {
    print(sh("notifyutil -p \(name); echo notify exit=$?"))
    watch("Darwin notification \(name)", seconds: 5)
    DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
    watch("distributed notification \(name)", seconds: 5)
}
print(sh("shortcuts list 2>&1 | head -5; echo shortcuts exit=$?"))
print("\nDONE")
