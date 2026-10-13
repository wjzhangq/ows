import Foundation
import Security

enum BridgeLog {
    static var level = "info"
    private static let queue = DispatchQueue(label: "owa-bridge.log")

    static func debug(_ message: String) {
        guard level == "debug" else { return }
        write("DEBUG", message)
    }

    static func info(_ message: String) {
        guard level != "error" else { return }
        write("INFO", message)
    }

    static func error(_ message: String) {
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        queue.async {
            let line = "[\(level)] \(message)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}

struct BridgeConfig: Equatable {
    var port: UInt16 = 5333
    var logLevel: String = "info"
    var debugEvalEnabled: Bool = false
    var requestTimeoutSeconds: Double = 10

    var dictionary: [String: Any] {
        [
            "port": Int(port),
            "logLevel": logLevel,
            "debugEvalEnabled": debugEvalEnabled,
            "requestTimeoutSeconds": requestTimeoutSeconds
        ]
    }

    static func load(from object: Any?) -> BridgeConfig {
        guard let json = object as? [String: Any] else { return BridgeConfig() }
        var config = BridgeConfig()
        if let port = json["port"] as? NSNumber {
            let value = port.intValue
            if (1...65535).contains(value) {
                config.port = UInt16(value)
            }
        }
        if let level = json["logLevel"] as? String {
            let normalized = level.lowercased()
            if ["debug", "info", "error"].contains(normalized) {
                config.logLevel = normalized
            }
        }
        if let enabled = json["debugEvalEnabled"] as? Bool {
            config.debugEvalEnabled = enabled
        } else if let number = json["debugEvalEnabled"] as? NSNumber {
            config.debugEvalEnabled = number.boolValue
        }
        if let timeout = json["requestTimeoutSeconds"] as? NSNumber {
            let value = timeout.doubleValue
            if value >= 1, value <= 120 {
                config.requestTimeoutSeconds = value
            }
        }
        return config
    }
}

struct BridgePaths {
    var root: URL

    static func live() -> BridgePaths {
        BridgePaths(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".owa-bridge", isDirectory: true))
    }

    var tokenURL: URL { root.appendingPathComponent("token") }
    var configURL: URL { root.appendingPathComponent("config.json") }

    func prepare() throws -> (token: String, config: BridgeConfig) {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let config = try loadOrCreateConfig()
        let token = try loadOrCreateToken()
        return (token, config)
    }

    func loadOrCreateConfig() throws -> BridgeConfig {
        let manager = FileManager.default
        if !manager.fileExists(atPath: configURL.path) {
            let config = BridgeConfig()
            let data = try JSONSerialization.data(withJSONObject: config.dictionary, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configURL, options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            return config
        }
        let data = try Data(contentsOf: configURL)
        let object = try JSONSerialization.jsonObject(with: data)
        return BridgeConfig.load(from: object)
    }

    func loadOrCreateToken() throws -> String {
        let manager = FileManager.default
        if manager.fileExists(atPath: tokenURL.path) {
            let existing = try String(contentsOf: tokenURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !existing.isEmpty {
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
                return existing
            }
        }
        let token = Self.makeToken()
        try Data(token.utf8).write(to: tokenURL, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        BridgeLog.info("已生成 token")
        return token
    }

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

func secureEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    var diff: UInt8 = left.count == right.count ? 0 : 1
    let count = max(left.count, right.count)
    if count == 0 {
        return false
    }
    for index in 0..<count {
        let l: UInt8 = index < left.count ? left[index] : 0
        let r: UInt8 = index < right.count ? right[index] : 0
        diff |= l ^ r
    }
    return diff == 0
}

enum MailBackendError: Error {
    case timeout
    case unavailable
    case badResult
}

func safePageURL(_ url: URL?) -> String {
    guard let url else { return "" }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url.host ?? ""
    }
    components.query = nil
    components.fragment = nil
    components.user = nil
    components.password = nil
    return components.string ?? ""
}
