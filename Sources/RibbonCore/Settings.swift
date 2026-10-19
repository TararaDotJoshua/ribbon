import Foundation

/// User settings, read from `~/.config/ribbon/config.json`. Every key is
/// optional; anything missing keeps its default.
public struct Settings: Codable, Equatable, Sendable {
    /// Space between windows and around the strip, in points.
    public var gap: Double = 8
    /// Width ratios that grow / shrink / cycle-width step through.
    public var widthPresets: [Double] = [1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0]
    /// Width given to newly managed windows. `nil` keeps the window's own width.
    public var defaultWidth: Double?
    /// Ratio added or removed by widen / narrow.
    public var widthStep: Double = 0.05
    public var minWidth: Double = 0.1
    /// Points of a parked (off-screen) window left showing at the edge.
    public var sliver: Double = 5
    /// Height of the tab bar above a tab group.
    public var tabBarHeight: Double = 28
    /// Seconds a glide takes when Smooth Motion is on (menu bar); 0 always snaps.
    public var animationDuration: Double = 0.12
    /// Modifiers that turn the scroll wheel into canvas panning. "" disables.
    public var panModifiers: String = "ctrl+alt"
    public var panSpeed: Double = 1.0
    /// Bundle IDs or app names never managed.
    public var excludeApps: [String] = []
    /// Key combo -> command name. Merged over the defaults; map a combo to
    /// "none" to unbind it.
    public var bindings: [String: String] = [:]

    public static let defaultBindings: [String: String] = [
        "ctrl+left": "focus-left",
        "ctrl+right": "focus-right",
        "ctrl+shift+left": "page-left",
        "ctrl+shift+right": "page-right",
        "ctrl+alt+left": "shrink",
        "ctrl+alt+right": "grow",
        "ctrl+alt+shift+left": "move-left",
        "ctrl+alt+shift+right": "move-right",
        "ctrl+alt+r": "cycle-width",
        "ctrl+alt+minus": "narrow",
        "ctrl+alt+equal": "widen",
        "ctrl+alt+f": "toggle-fill",
        "ctrl+alt+c": "center",
        "ctrl+alt+t": "toggle-float",
        "ctrl+alt+leftbracket": "tab-into-left",
        "ctrl+alt+rightbracket": "tab-into-right",
        "ctrl+alt+backslash": "untab",
        "ctrl+alt+up": "prev-tab",
        "ctrl+alt+down": "next-tab",
        "ctrl+alt+p": "toggle-pause",
    ]

    public init() {}

    public var effectiveBindings: [String: String] {
        Self.defaultBindings.merging(bindings) { _, user in user }.filter { $0.value != "none" }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? d.gap
        widthPresets = try c.decodeIfPresent([Double].self, forKey: .widthPresets) ?? d.widthPresets
        defaultWidth = try c.decodeIfPresent(Double.self, forKey: .defaultWidth) ?? d.defaultWidth
        widthStep = try c.decodeIfPresent(Double.self, forKey: .widthStep) ?? d.widthStep
        minWidth = try c.decodeIfPresent(Double.self, forKey: .minWidth) ?? d.minWidth
        sliver = try c.decodeIfPresent(Double.self, forKey: .sliver) ?? d.sliver
        tabBarHeight = try c.decodeIfPresent(Double.self, forKey: .tabBarHeight) ?? d.tabBarHeight
        animationDuration = try c.decodeIfPresent(Double.self, forKey: .animationDuration) ?? d.animationDuration
        panModifiers = try c.decodeIfPresent(String.self, forKey: .panModifiers) ?? d.panModifiers
        panSpeed = try c.decodeIfPresent(Double.self, forKey: .panSpeed) ?? d.panSpeed
        excludeApps = try c.decodeIfPresent([String].self, forKey: .excludeApps) ?? d.excludeApps
        bindings = try c.decodeIfPresent([String: String].self, forKey: .bindings) ?? d.bindings
    }

    public static func load(from url: URL) throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
        return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
    }
}
