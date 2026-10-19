// Opens N numbered, coloured windows so Ribbon can be tried without touching
// real apps:  RibbonTestWindows 6   then   Ribbon --only RibbonTestWindows
import AppKit

let count = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 5
let app = NSApplication.shared
app.setActivationPolicy(.regular)

var windows: [NSWindow] = []
let widths: [CGFloat] = [420, 640, 520, 900, 380, 720, 560]
for i in 0..<count {
    let offset = CGFloat(i)
    let frame = NSRect(x: 60 + offset * 40, y: 120 + offset * 30, width: widths[i % widths.count], height: 500)
    let window = NSWindow(
        contentRect: frame,
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Test \(i + 1)"
    window.isReleasedWhenClosed = false
    let hue = CGFloat(i) / CGFloat(max(count, 1))
    window.backgroundColor = NSColor(hue: hue, saturation: 0.45, brightness: 0.9, alpha: 1)
    let label = NSTextField(labelWithString: "\(i + 1)")
    label.font = .systemFont(ofSize: 160, weight: .bold)
    label.textColor = .white
    label.translatesAutoresizingMaskIntoConstraints = false
    window.contentView?.addSubview(label)
    if let content = window.contentView {
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
}
app.activate()
app.run()
