import Foundation

protocol MailBackend: AnyObject {
    func invoke(op: String, params: [String: Any]) async throws -> [String: Any]
    func takeSnapshotPNG() async throws -> Data
    func currentPageURL() async -> String
}

enum SessionSignal {
    case authenticated(name: String?, address: String?)
    case unauthenticated
}

final class APIHandler {
    let token: String
    let config: BridgeConfig
    let backend: MailBackend
    var onSession: ((SessionSignal) -> Void)?

    init(token: String, config: BridgeConfig, backend: MailBackend) {
        self.token = token
        self.config = config
        self.backend = backend
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let started = Date()
        let correlationId = UUID().uuidString
        let pathOnly = request.path
        if request.method != "GET" {
            return finish(correlationId, pathOnly, started, .json(405, errorObject("method_not_allowed", "仅支持 GET"), correlationId: correlationId))
        }
        guard let matched = route(path: request.path) else {
            return finish(correlationId, pathOnly, started, .json(404, errorObject("not_found", "未知路径"), correlationId: correlationId))
        }
        if case .healthz = matched {
            return finish(correlationId, pathOnly, started, .json(200, ["ok": true], correlationId: correlationId))
        }
        guard let presented = bearerToken(from: request.headers), secureEqual(presented, token) else {
            return finish(correlationId, pathOnly, started, .json(403, errorObject("unauthorized", "缺少或错误的本地 token"), correlationId: correlationId))
        }

        do {
            switch matched {
            case .healthz:
                return finish(correlationId, pathOnly, started, .json(200, ["ok": true], correlationId: correlationId))
            case .debugSnapshot:
                let png = try await backend.takeSnapshotPNG()
                let body: [String: Any] = [
                    "contentType": "image/png",
                    "encoding": "base64",
                    "data": png.base64EncodedString()
                ]
                return finish(correlationId, pathOnly, started, .json(200, body, correlationId: correlationId))
            case .debugEval where !config.debugEvalEnabled:
                return finish(correlationId, pathOnly, started, .json(403, errorObject("eval_disabled", "debug/eval 默认关闭。在 ~/.owa-bridge/config.json 将 debugEvalEnabled 设为 true 后重启应用"), correlationId: correlationId))
            default:
                let params = parameters(for: matched, query: request.query, correlationId: correlationId)
                let raw = try await backend.invoke(op: operationName(for: matched), params: params)
                let http = try await httpResponse(from: raw, correlationId: correlationId, route: matched)
                observe(route: matched, payload: raw)
                return finish(correlationId, pathOnly, started, http)
            }
        } catch MailBackendError.timeout {
            return finish(correlationId, pathOnly, started, .json(504, errorObject("timeout", "抽取超时"), correlationId: correlationId))
        } catch {
            BridgeLog.error("抽取调用失败 \(pathOnly)")
            return finish(correlationId, pathOnly, started, .json(500, errorObject("extract_failed", "抽取邮件失败"), correlationId: correlationId))
        }
    }

    private func finish(_ correlationId: String, _ path: String, _ started: Date, _ response: HTTPResponse) -> HTTPResponse {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        BridgeLog.info("\(correlationId) GET \(path) \(response.status) \(ms)ms")
        return response
    }

    private func operationName(for route: Route) -> String {
        switch route {
        case .status: return "status"
        case .me: return "me"
        case .messages: return "messages"
        case .message: return "message"
        case .debugDom: return "dom"
        case .debugAria: return "aria"
        case .debugExtract: return "extract"
        case .debugEval: return "eval"
        case .healthz, .debugSnapshot: return ""
        }
    }

    private func parameters(for route: Route, query: [String: String], correlationId: String) -> [String: Any] {
        var params: [String: Any] = [
            "debug": queryFlag(query, "debug"),
            "correlationId": correlationId
        ]
        switch route {
        case .messages:
            params["folder"] = nonempty(query["folder"]) ?? "inbox"
            params["top"] = queryTop(query)
            params["unread"] = queryFlag(query, "unread")
        case .message(let id):
            params["id"] = id
        case .debugDom:
            params["selector"] = nonempty(query["selector"]) ?? "body"
        case .debugExtract:
            params["target"] = nonempty(query["target"]) ?? "messages"
            params["folder"] = nonempty(query["folder"]) ?? "inbox"
            params["top"] = queryTop(query)
            params["unread"] = queryFlag(query, "unread")
            if let id = nonempty(query["id"]) {
                params["id"] = id
            }
            params["debug"] = true
        case .debugEval:
            params["allowEval"] = config.debugEvalEnabled
            params["code"] = query["code"] ?? ""
        default:
            break
        }
        return params
    }

    private func httpResponse(from raw: [String: Any], correlationId: String, route: Route) async throws -> HTTPResponse {
        let status = intValue(raw["status"]) ?? 500
        var body = raw["body"] as? [String: Any] ?? [:]
        if case .status = route {
            body["pageURL"] = await backend.currentPageURL()
            body["port"] = Int(config.port)
        }
        return HTTPResponse.json(status, body, correlationId: correlationId)
    }

    private func observe(route: Route, payload: [String: Any]) {
        let status = intValue(payload["status"]) ?? 0
        let body = payload["body"] as? [String: Any] ?? [:]
        if status == 401 {
            onSession?(.unauthenticated)
            return
        }
        guard status == 200 else { return }
        switch route {
        case .me:
            onSession?(.authenticated(name: body["displayName"] as? String, address: body["address"] as? String))
        case .messages, .message:
            onSession?(.authenticated(name: nil, address: nil))
        case .status:
            if let loggedIn = body["loggedIn"] as? Bool {
                onSession?(loggedIn ? .authenticated(name: nil, address: nil) : .unauthenticated)
            } else if let loggedIn = body["loggedIn"] as? NSNumber {
                onSession?(loggedIn.boolValue ? .authenticated(name: nil, address: nil) : .unauthenticated)
            }
        default:
            break
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
