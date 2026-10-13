import Foundation

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(_ status: Int, _ object: Any, correlationId: String? = nil) -> HTTPResponse {
        let data: Data
        if JSONSerialization.isValidJSONObject(object),
           let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) {
            data = encoded
        } else {
            data = Data("{\"error\":\"extract_failed\",\"message\":\"响应无法编码\"}".utf8)
        }
        var headers = [
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store"
        ]
        if let correlationId {
            headers["X-Correlation-Id"] = correlationId
        }
        return HTTPResponse(status: status, headers: headers, body: data)
    }

    func encoded() -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 500: reason = "Internal Server Error"
        case 504: reason = "Gateway Timeout"
        default: reason = "Error"
        }
        var fields = headers
        fields["Content-Length"] = String(body.count)
        fields["Connection"] = "close"
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for key in fields.keys.sorted() {
            text += "\(key): \(fields[key] ?? "")\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}

enum HTTPParser {
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<separator.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }
        lines.removeFirst()
        let pieces = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard pieces.count >= 2 else { return nil }
        let target = String(pieces[1])
        let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(split[0])
        let query = split.count == 2 ? parseQuery(String(split[1])) : [:]
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                headers[name] = value
            }
        }
        return HTTPRequest(method: String(pieces[0]).uppercased(), path: path, query: query, headers: headers)
    }

    static func completeRequest(_ buffer: Data) -> Data? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<separator.lowerBound)
        let length = contentLength(headerData) ?? 0
        let bodyStart = separator.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= length else { return nil }
        return buffer.subdata(in: buffer.startIndex..<buffer.index(bodyStart, offsetBy: length))
    }

    static func contentLength(_ header: Data) -> Int? {
        guard let text = String(data: header, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else {
                continue
            }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func parseQuery(_ raw: String) -> [String: String] {
        guard !raw.isEmpty else { return [:] }
        var query: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = formDecode(String(kv[0]))
            let value = kv.count > 1 ? formDecode(String(kv[1])) : ""
            query[key] = value
        }
        return query
    }

    static func formDecode(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? value
    }

    static func pathDecode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}

enum Route: Equatable {
    case healthz
    case status
    case me
    case messages
    case message(id: String)
    case debugDom
    case debugAria
    case debugSnapshot
    case debugExtract
    case debugEval
}

func route(path: String) -> Route? {
    var normalized = path
    if normalized.count > 1, normalized.hasSuffix("/") {
        normalized.removeLast()
    }
    switch normalized {
    case "/healthz": return .healthz
    case "/status": return .status
    case "/me": return .me
    case "/messages": return .messages
    case "/debug/dom": return .debugDom
    case "/debug/aria": return .debugAria
    case "/debug/snapshot": return .debugSnapshot
    case "/debug/extract": return .debugExtract
    case "/debug/eval": return .debugEval
    default:
        let prefix = "/messages/"
        guard normalized.hasPrefix(prefix) else { return nil }
        let id = HTTPParser.pathDecode(String(normalized.dropFirst(prefix.count)))
        guard !id.isEmpty else { return nil }
        return .message(id: id)
    }
}

func bearerToken(from headers: [String: String]) -> String? {
    guard let header = headers["authorization"] else { return nil }
    let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
    let token = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
}

func queryFlag(_ query: [String: String], _ name: String) -> Bool {
    guard let raw = query[name]?.lowercased() else { return false }
    return raw == "1" || raw == "true" || raw == "yes"
}

func queryTop(_ query: [String: String]) -> Int {
    guard let raw = query["top"], let value = Int(raw) else { return 10 }
    return min(50, max(1, value))
}

func errorObject(_ code: String, _ message: String) -> [String: String] {
    ["error": code, "message": message]
}
