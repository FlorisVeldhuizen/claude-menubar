import AppKit

/// Which sound a new request plays, and how to silence it.
enum Sound {
    static let silent = "None"

    static let names = ["Pop", "Purr", "Bottle", "Glass", "Submarine", "Ping", "Hero", "Tink", silent]

    static var current: String {
        get { UserDefaults.standard.string(forKey: "sound") ?? "Purr" }
        set { UserDefaults.standard.set(newValue, forKey: "sound") }
    }

    /// What unmuting returns you to, so muting is not a one-way trip back to the default.
    static var lastAudible: String {
        get { UserDefaults.standard.string(forKey: "lastAudibleSound") ?? "Purr" }
        set { UserDefaults.standard.set(newValue, forKey: "lastAudibleSound") }
    }

    static var muted: Bool { current == silent }

    static func play(_ name: String = current) { NSSound(named: name)?.play() }
}
