// Temporary CI exploration: what can talk to macOS's wallpaper system per display?
import Foundation
import ObjectiveC

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

print("### Wallpaper frameworks")
let frameworks = sh("ls -d /System/Library/PrivateFrameworks/*allpaper*.framework /System/Library/Frameworks/*allpaper*.framework 2>/dev/null")
    .split(separator: "\n").map(String.init)
print(frameworks.joined(separator: "\n"))

print("\n### AppKit desktop image exports")
print(sh("dyld_info -exports /System/Library/Frameworks/AppKit.framework/AppKit 2>&1 | grep -i -E 'desktopimage|wallpaper' | head -40"))

let interesting = ["shuffle", "next", "advance", "rotate", "refresh", "choice", "display", "frequency", "option", "store", "set", "client", "update"]

for framework in frameworks {
    let name = URL(fileURLWithPath: framework).deletingPathExtension().lastPathComponent
    let binary = "\(framework)/\(name)"
    print("\n### \(name)")
    print("exports (filtered):")
    print(sh("dyld_info -exports '\(binary)' 2>&1 | grep -i -E 'shuffle|advance|nextwallpaper|refresh|frequency' | head -40"))
    guard dlopen(binary, RTLD_NOW) != nil else {
        print("dlopen failed: \(String(cString: dlerror()))")
        continue
    }
    var count: UInt32 = 0
    guard let names = objc_copyClassNamesForImage(binary, &count) else { print("no ObjC classes"); continue }
    print("ObjC classes: \(count)")
    for i in 0..<Int(count) {
        let className = String(cString: names[i])
        guard let cls = objc_getClass(names[i]) as? AnyClass else { continue }
        var methods: [String] = []
        for (target, prefix) in [(cls as AnyClass?, "-"), (object_getClass(cls), "+")] {
            var n: UInt32 = 0
            if let list = class_copyMethodList(target, &n) {
                for j in 0..<Int(n) {
                    let sel = NSStringFromSelector(method_getName(list[j]))
                    if interesting.contains(where: { sel.lowercased().contains($0) }) { methods.append(prefix + sel) }
                }
                free(list)
            }
        }
        if !methods.isEmpty || className.lowercased().contains("client") || className.lowercased().contains("shuffle") {
            print("  \(className): \(methods.prefix(40).joined(separator: " "))")
        }
    }
    free(names)
}

print("\n### ObjC protocols mentioning wallpaper")
var protoCount: UInt32 = 0
if let protos = objc_copyProtocolList(&protoCount) {
    for i in 0..<Int(protoCount) {
        let name = String(cString: protocol_getName(protos[i]))
        guard name.lowercased().contains("wallpaper") else { continue }
        var methods: [String] = []
        for required in [true, false] {
            var n: UInt32 = 0
            if let list = protocol_copyMethodDescriptionList(protos[i], required, true, &n) {
                for j in 0..<Int(n) { if let s = list[j].name { methods.append(NSStringFromSelector(s)) } }
                free(list)
            }
        }
        print("  \(name): \(methods.joined(separator: " "))")
    }
}

print("\n### WallpaperAgent strings")
print(sh("strings -a /System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent | grep -i -E 'shuffle|notif|com\\.apple\\.wallpaper|xpc|mach' | sort -u | head -60"))

print("\n### WallpaperAgent launchd service")
print(sh("launchctl print gui/$(id -u)/com.apple.wallpaper.agent 2>&1 | sed -n '/endpoints/,/}/p;/program/p' | head -30"))
print(sh("ls /System/Library/CoreServices/WallpaperAgent.app/Contents/ /System/Library/CoreServices/WallpaperAgent.app/Contents/* 2>&1 | head -40"))
print("\nDONE")
