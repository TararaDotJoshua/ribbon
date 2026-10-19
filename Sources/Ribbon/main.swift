import AppKit
import RibbonCore

let commandNotification = Notification.Name("dev.ribbon.command")

func log(_ message: String) {
    let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
    print("[\(time)] \(message)")
}

let usage = """
Ribbon — a scrolling window canvas for macOS.

  Ribbon                     run the window manager
  Ribbon --only <app>        manage only this app (name or bundle ID; repeatable)
  Ribbon --config <path>     settings file (default ~/.config/ribbon/config.json)
  Ribbon send <command>      send a command to the running instance
  Ribbon list                show which windows would be tiled (moves nothing)

Commands: \(Command.allCases.map(\.rawValue).joined(separator: ", "))
"""

var arguments = Array(CommandLine.arguments.dropFirst())
var options = Options()

if arguments.first == "list" {
    // Read-only: which windows Ribbon would tile, per Space. Moves nothing.
    print("active space \(Spaces.active)")
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        for element in AX.elements(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) {
            guard let window = AXWindow(element: element, pid: app.processIdentifier) else { continue }
            let verdict = window.isTileable ? "tile" : "skip (\(window.subrole ?? "?")\(window.isMinimized ? ", minimized" : ""))"
            let frame = window.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "?"
            print("\(verdict)\t\(app.localizedName ?? "?") “\(window.title)” #\(window.id) space \(Spaces.space(of: window.id).map(String.init) ?? "?") \(frame)")
        }
    }
    exit(0)
}

if arguments.first == "send" {
    guard arguments.count == 2, let command = Command(rawValue: arguments[1]) else {
        print(usage)
        exit(2)
    }
    DistributedNotificationCenter.default().postNotificationName(
        commandNotification, object: command.rawValue, userInfo: nil, deliverImmediately: true)
    exit(0)
}

while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--only" where !arguments.isEmpty:
        options.only.append(arguments.removeFirst())
    case "--config" where !arguments.isEmpty:
        options.configURL = URL(fileURLWithPath: (arguments.removeFirst() as NSString).expandingTildeInPath)
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        print(usage)
        exit(2)
    }
}

if Bundle.main.bundleIdentifier != nil && isatty(STDOUT_FILENO) == 0 {
    // Launched as an app: keep a log where `Ribbon send dump` output can be read.
    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    freopen(logs.appendingPathComponent("Ribbon.log").path, "a", stdout)
}
setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.run()
