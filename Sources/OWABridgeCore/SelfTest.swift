import Darwin
import Foundation
import JavaScriptCore

public func runBridgeSelfTests() async -> Int32 {
    let check = Check()
    testHTTP(check)
    testConfig(check)
    await testAPI(check)
    testAdapters(check)
    await testServer(check)
    if check.failed == 0 {
        FileHandle.standardOutput.write(Data("self-test ok\n".utf8))
        return 0
    }
    FileHandle.standardError.write(Data("self-test failed: \(check.failed)\n".utf8))
    return 1
}

private final class Check {
    var failed = 0

    func expect(_ condition: Bool, _ message: String) {
        if !condition {
            failed += 1
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
        }
    }

    func equal<T: Equatable>(_ lhs: T?, _ rhs: T?, _ message: String) {
        expect(lhs == rhs, "\(message): \(String(describing: lhs)) != \(String(describing: rhs))")
    }
}

private func testHTTP(_ check: Check) {
    let raw = "GET /messages/AAMk+abc%2Fdef?top=3&unread=true&debug=1 HTTP/1.1\r\nAuthorization: Bearer secret\r\nHost: 127.0.0.1:5333\r\n\r\n"
    let request = HTTPParser.parse(Data(raw.utf8))
    check.equal(request?.method, "GET", "method")
    check.equal(request?.path, "/messages/AAMk+abc%2Fdef", "path")
    check.equal(request?.query["top"], "3", "top query")
    check.equal(request?.headers["authorization"], "Bearer secret", "authorization")
    check.equal(route(path: request?.path ?? ""), .message(id: "AAMk+abc/def"), "decoded id")
    check.equal(queryTop(request?.query ?? [:]), 3, "top int")
    check.expect(queryFlag(request?.query ?? [:], "unread"), "unread")
    check.equal(bearerToken(from: request?.headers ?? [:]), "secret", "bearer")
    check.equal(queryTop(["top": "99"]), 50, "clamp high")
    check.equal(queryTop(["top": "0"]), 1, "clamp low")
    check.equal(queryTop([:]), 10, "default top")
    check.expect(route(path: "/nope") == nil, "unknown route")
    check.equal(route(path: "/messages/"), .messages, "trailing slash is the list")
    check.equal(route(path: "/debug/aria"), .debugAria, "aria route")
    check.expect(secureEqual("abc", "abc"), "equal token")
    check.expect(!secureEqual("abc", "abd"), "different token")
    check.expect(!secureEqual("abc", "abcd"), "different length")
    check.expect(!secureEqual("", ""), "empty token")

    let response = HTTPResponse.json(401, errorObject("session_expired", "Outlook 会话已失效"), correlationId: "cid")
    let text = String(data: response.encoded(), encoding: .utf8) ?? ""
    check.expect(text.contains("HTTP/1.1 401 Unauthorized"), "status line")
    check.expect(text.contains("\"error\":\"session_expired\""), "error code")
    check.expect(text.contains("X-Correlation-Id: cid"), "correlation")
    check.expect(text.contains("application/json; charset=utf-8"), "content type")

    let partial = Data("GET /healthz HTTP/1.1\r\nContent-Length: 4\r\n\r\n".utf8)
    check.expect(HTTPParser.completeRequest(partial) == nil, "incomplete body")
    var full = partial
    full.append(Data("true".utf8))
    check.equal(HTTPParser.completeRequest(full)?.count, full.count, "complete body")
}

private func testConfig(_ check: Check) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BridgePaths(root: root)
    do {
        let first = try paths.prepare()
        check.equal(first.config.port, UInt16(5333), "default port")
        check.expect(!first.config.debugEvalEnabled, "eval off")
        check.expect(!first.token.isEmpty, "token created")
        let second = try paths.prepare()
        check.equal(first.token, second.token, "token stable")
        let custom: [String: Any] = [
            "port": 6000,
            "logLevel": "debug",
            "debugEvalEnabled": true,
            "requestTimeoutSeconds": 4
        ]
        let data = try JSONSerialization.data(withJSONObject: custom)
        try data.write(to: paths.configURL)
        let loaded = try paths.loadOrCreateConfig()
        check.equal(loaded.port, UInt16(6000), "custom port")
        check.equal(loaded.logLevel, "debug", "log level")
        check.expect(loaded.debugEvalEnabled, "eval on")
        check.expect(loaded.requestTimeoutSeconds == 4, "timeout")
    } catch {
        check.expect(false, "config threw \(error)")
    }
}

private func testAPI(_ check: Check) async {
    let api = APIHandler(token: "local-token", config: BridgeConfig(), backend: FakeBackend())
    let health = await api.handle(HTTPRequest(method: "GET", path: "/healthz", query: [:], headers: [:]))
    check.equal(health.status, 200, "health status")
    check.equal(json(health)["ok"] as? Bool, true, "health body")

    let denied = await api.handle(HTTPRequest(method: "GET", path: "/me", query: [:], headers: [:]))
    check.equal(denied.status, 403, "missing token")
    check.equal(json(denied)["error"] as? String, "unauthorized", "unauthorized code")

    let backend = FakeBackend()
    backend.payload = [
        "status": 200,
        "body": ["folder": "inbox", "count": 0, "messages": []],
        "trace": ["provider": "internalFetchProvider"]
    ]
    let messagesAPI = APIHandler(token: "local-token", config: BridgeConfig(), backend: backend)
    var sawAuth = false
    messagesAPI.onSession = { signal in
        if case .authenticated = signal { sawAuth = true }
    }
    let listed = await messagesAPI.handle(HTTPRequest(
        method: "GET",
        path: "/messages",
        query: ["top": "80", "folder": "sent", "unread": "true", "debug": "true"],
        headers: ["authorization": "Bearer local-token"]
    ))
    check.equal(listed.status, 200, "messages status")
    check.equal(backend.lastOp, "messages", "messages op")
    check.equal(backend.lastParams?["top"] as? Int, 50, "clamped top")
    check.equal(backend.lastParams?["folder"] as? String, "sent", "folder")
    check.equal(backend.lastParams?["unread"] as? Bool, true, "unread param")
    check.expect(sawAuth, "session authenticated")

    let detailBackend = FakeBackend()
    detailBackend.payload = ["status": 404, "body": ["error": "not_found", "message": "找不到这封邮件"]]
    let detailAPI = APIHandler(token: "local-token", config: BridgeConfig(), backend: detailBackend)
    let detail = await detailAPI.handle(HTTPRequest(
        method: "GET",
        path: "/messages/AAMk%2Babc%2Fdef",
        query: [:],
        headers: ["authorization": "Bearer local-token"]
    ))
    check.equal(detail.status, 404, "detail status")
    check.equal(detailBackend.lastParams?["id"] as? String, "AAMk+abc/def", "decoded detail id")

    let eval = await detailAPI.handle(HTTPRequest(
        method: "GET",
        path: "/debug/eval",
        query: ["code": "1"],
        headers: ["authorization": "Bearer local-token"]
    ))
    check.equal(eval.status, 403, "eval disabled")
    check.equal(json(eval)["error"] as? String, "eval_disabled", "eval code")
    check.equal(detailBackend.lastOp, "message", "eval did not call the page")

    let timeoutBackend = FakeBackend()
    timeoutBackend.error = MailBackendError.timeout
    let timeoutAPI = APIHandler(token: "local-token", config: BridgeConfig(), backend: timeoutBackend)
    let timedOut = await timeoutAPI.handle(HTTPRequest(
        method: "GET",
        path: "/me",
        query: [:],
        headers: ["authorization": "Bearer local-token"]
    ))
    check.equal(timedOut.status, 504, "timeout status")
    check.equal(json(timedOut)["error"] as? String, "timeout", "timeout code")

    let statusBackend = FakeBackend()
    statusBackend.payload = [
        "status": 200,
        "body": [
            "loggedIn": false,
            "provider": NSNull(),
            "adapterVersion": "1.0.0",
            "lastExtract": NSNull()
        ]
    ]
    let statusAPI = APIHandler(token: "local-token", config: BridgeConfig(), backend: statusBackend)
    let status = await statusAPI.handle(HTTPRequest(
        method: "GET",
        path: "/status",
        query: [:],
        headers: ["authorization": "Bearer local-token"]
    ))
    check.equal(status.status, 200, "status http")
    check.equal(json(status)["pageURL"] as? String, "https://outlook.office.com/mail/", "page url")
    check.equal(json(status)["port"] as? Int, 5333, "status port")
    check.equal(json(status)["loggedIn"] as? Bool, false, "logged out")
}

private func testAdapters(_ check: Check) {
    do {
        let context = JSContext()!
        var failure: String?
        context.exceptionHandler = { _, value in
            failure = value?.toString()
        }
        context.evaluateScript(try ExtractorScript.load())
        check.expect(failure == nil, "script exception \(failure ?? "")")
        check.expect(context.objectForKeyedSubscript("__owaBridge") != nil, "bridge installed")

        let rest = try object(context, """
        __owaBridge._test.adaptRestDetail({
          Id: "AAMk",
          ConversationId: "AAQk",
          Subject: "Q4 compute plan",
          From: { EmailAddress: { Name: "Alice", Address: "alice@contoso.com" } },
          ToRecipients: [{ EmailAddress: { Name: "Wenjin", Address: "wenjin@contoso.com" } }],
          CcRecipients: [],
          ReceivedDateTime: "2026-10-13T08:12:00Z",
          BodyPreview: "preview",
          IsRead: false,
          HasAttachments: true,
          Importance: "High",
          Body: { ContentType: "Text", Content: "完整正文" },
          Attachments: [{ Name: "plan.xlsx", Size: 20480, ContentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }]
        })
        """)
        check.equal(rest["id"] as? String, "AAMk", "rest id")
        check.equal(rest["conversationId"] as? String, "AAQk", "rest conversation")
        check.equal(rest["importance"] as? String, "high", "importance")
        check.equal((rest["body"] as? [String: Any])?["content"] as? String, "完整正文", "body")
        let attachments = rest["attachments"] as? [[String: Any]]
        check.equal(attachments?.first?["name"] as? String, "plan.xlsx", "attachment name")
        check.equal((attachments?.first?["size"] as? NSNumber)?.intValue, 20480, "attachment size")

        let ews = try object(context, """
        __owaBridge._test.adaptEwsMessage({
          ItemId: { Id: "AAMkEws" },
          ConversationId: { Id: "AAQkEws" },
          Subject: "Hello",
          From: { Mailbox: { Name: "Bob", EmailAddress: "bob@contoso.com" } },
          DateTimeReceived: "/Date(1760343120000)/",
          IsRead: true,
          HasAttachments: false,
          Importance: "Low",
          Preview: "preview"
        })
        """)
        check.equal(ews["id"] as? String, "AAMkEws", "ews id")
        check.equal((ews["from"] as? [String: Any])?["address"] as? String, "bob@contoso.com", "ews from")
        check.equal(ews["importance"] as? String, "low", "ews importance")
        check.expect(ews["receivedDateTime"] as? String != nil, "ews date")

        let user = try object(context, """
        __owaBridge._test.adaptRestUser({ DisplayName: "Wenjin", Mail: "wenjin@contoso.onmicrosoft.com" })
        """)
        check.equal(user["displayName"] as? String, "Wenjin", "display name")
        check.equal(user["tenant"] as? String, "contoso.onmicrosoft.com", "tenant")
        check.equal(user["loggedIn"] as? Bool, true, "logged in")

        let folder = try object(context, "__owaBridge._test.mapFolder('sent')")
        check.equal(folder["rest"] as? String, "sentitems", "sent folder")
        let top = context.evaluateScript("__owaBridge._test.clampTop(99)")
        check.equal(top?.toInt32(), Int32(50), "js clamp")
        let redacted = context.evaluateScript(
            #"__owaBridge._test.redact('Bearer abc.def token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature12')"#
        )?.toString() ?? ""
        check.expect(!redacted.contains("eyJhbGciOiJIUzI1NiJ9"), "jwt redacted")
        check.expect(redacted.contains("[redacted]"), "redaction marker")
    } catch {
        check.expect(false, "adapter threw \(error)")
    }
}

private func testServer(_ check: Check) async {
    let backend = FakeBackend()
    let port = reservePort()
    guard port > 0 else {
        check.expect(false, "no free port")
        return
    }
    var config = BridgeConfig()
    config.port = port
    let api = APIHandler(token: "local-token", config: config, backend: backend)
    let server = HTTPServer { request in
        await api.handle(request)
    }
    do {
        try server.start(port: port)
    } catch {
        check.expect(false, "server start \(error)")
        return
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    do {
        let health = try await get(port: port, path: "/healthz", token: nil)
        check.equal(health.status, 200, "live health")
        let denied = try await get(port: port, path: "/me", token: "nope")
        check.equal(denied.status, 403, "live denied")
    } catch {
        check.expect(false, "live request \(error)")
    }
    server.stop()
}

private func json(_ response: HTTPResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
}

private func object(_ context: JSContext, _ source: String) throws -> [String: Any] {
    context.exception = nil
    let value = context.evaluateScript(source)
    if let exception = context.exception {
        FileHandle.standardError.write(Data("JS \(exception.toString() ?? "")\n".utf8))
        throw ExtractorScriptError.missing
    }
    guard let object = value?.toObject() as? [String: Any] else {
        throw ExtractorScriptError.missing
    }
    return object
}

private func reservePort() -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    if descriptor < 0 { return 0 }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if bound != 0 { return 0 }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    return UInt16(bigEndian: address.sin_port)
}

private func get(port: UInt16, path: String, token: String?) async throws -> (status: Int, body: String) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.timeoutInterval = 3
    if let token {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = response as? HTTPURLResponse
    return (http?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
}

private final class FakeBackend: MailBackend {
    var payload: [String: Any] = ["status": 200, "body": ["ok": true]]
    var error: Error?
    var lastOp: String?
    var lastParams: [String: Any]?

    func invoke(op: String, params: [String: Any]) async throws -> [String: Any] {
        lastOp = op
        lastParams = params
        if let error { throw error }
        return payload
    }

    func takeSnapshotPNG() async throws -> Data {
        Data([0x89, 0x50, 0x4E, 0x47])
    }

    func currentPageURL() async -> String {
        "https://outlook.office.com/mail/"
    }
}
