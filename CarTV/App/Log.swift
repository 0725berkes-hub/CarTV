import OSLog

/// Centralised loggers. Use `Log.<category>.info/debug/error`.
nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "kurdsoft.CarTV"

    static let app      = Logger(subsystem: subsystem, category: "app")
    static let carplay  = Logger(subsystem: subsystem, category: "carplay")
    static let player   = Logger(subsystem: subsystem, category: "player")
    static let playlist = Logger(subsystem: subsystem, category: "playlist")
    static let media    = Logger(subsystem: subsystem, category: "media")
    static let network  = Logger(subsystem: subsystem, category: "network")
}
