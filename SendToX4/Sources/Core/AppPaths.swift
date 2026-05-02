import Foundation

public enum AppPaths {
    public static let bundleId = "com.justingarner.sendtox4"

    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SendToX4", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var queueDir: URL {
        let dir = supportDir.appendingPathComponent("queue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var manifestURL: URL {
        supportDir.appendingPathComponent("queue.json")
    }

    public static var settingsURL: URL {
        supportDir.appendingPathComponent("settings.json")
    }

    public static var logURL: URL {
        supportDir.appendingPathComponent("daemon.log")
    }
}
