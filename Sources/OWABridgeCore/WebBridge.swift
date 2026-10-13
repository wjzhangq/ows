import Foundation
import WebKit

/// Serializes native calls into the single WKWebView. A timed-out HTTP waiter
/// does not cancel the in-flight script, so the next request cannot overlap it.
final class WebBridge: MailBackend {
    private let webView: WKWebView
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var busy = false
    private var jobs: [() -> Void] = []
    private var script: String?

    init(webView: WKWebView, timeout: TimeInterval) {
        self.webView = webView
        self.timeout = timeout
    }

    func invoke(op: String, params: [String: Any]) async throws -> [String: Any] {
        let box = OneShot<[String: Any]>()
        enqueue {
            do {
                let value = try await self.evaluate(op: op, params: params)
                box.finish(.success(value))
            } catch {
                box.finish(.failure(error))
            }
        }
        return try await box.wait(timeout: timeout)
    }

    func takeSnapshotPNG() async throws -> Data {
        let box = OneShot<Data>()
        enqueue {
            do {
                let data = try await self.snapshot()
                box.finish(.success(data))
            } catch {
                box.finish(.failure(error))
            }
        }
        return try await box.wait(timeout: timeout)
    }

    func currentPageURL() async -> String {
        await MainActor.run {
            safePageURL(self.webView.url)
        }
    }

    private func enqueue(_ job: @escaping () async -> Void) {
        lock.lock()
        jobs.append {
            Task {
                await job()
                self.markIdleAndPump()
            }
        }
        lock.unlock()
        pump()
    }

    private func markIdleAndPump() {
        lock.lock()
        busy = false
        lock.unlock()
        pump()
    }

    private func pump() {
        lock.lock()
        guard !busy, !jobs.isEmpty else {
            lock.unlock()
            return
        }
        busy = true
        let job = jobs.removeFirst()
        lock.unlock()
        job()
    }

    private func installedScript() throws -> String {
        if let script { return script }
        let source = try ExtractorScript.load()
        script = source
        return source
    }

    private func evaluate(op: String, params: [String: Any]) async throws -> [String: Any] {
        let source = try installedScript()
        let arguments = bridgeArguments(op: op, params: params)
        do {
            return try await call(
                """
                if (!globalThis.__owaBridge || !globalThis.__owaBridge.dispatch) {
                  throw new Error("extractor_missing");
                }
                return await globalThis.__owaBridge.dispatch(op, params);
                """,
                arguments: arguments
            )
        } catch {
            let missing = String(describing: error).contains("extractor_missing")
            if !missing { throw error }
            return try await call(
                source + "\nreturn await globalThis.__owaBridge.dispatch(op, params);\n",
                arguments: arguments
            )
        }
    }

    private func bridgeArguments(op: String, params: [String: Any]) -> [String: Any] {
        var clean: [String: Any] = [:]
        for (key, value) in params {
            switch value {
            case let text as String:
                clean[key] = text
            case let flag as Bool:
                clean[key] = flag
            case let number as Int:
                clean[key] = number
            case let number as NSNumber:
                clean[key] = number
            default:
                break
            }
        }
        return ["op": op, "params": clean]
    }

    private func call(_ body: String, arguments: [String: Any]) async throws -> [String: Any] {
        let raw: Any = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                    continuation.resume(with: result)
                }
            }
        }
        return try jsonDictionary(raw)
    }

    private func snapshot() async throws -> Data {
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.webView.takeSnapshot(with: nil) { image, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? MailBackendError.unavailable)
                    }
                }
            }
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw MailBackendError.unavailable
        }
        return png
    }

    private func jsonDictionary(_ value: Any) throws -> [String: Any] {
        if value is NSNull {
            throw MailBackendError.badResult
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MailBackendError.badResult
        }
        return object
    }
}

final class OneShot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var resumed = false

    func wait(timeout: TimeInterval) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if resumed, let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(MailBackendError.timeout))
                }
            }
        }
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        let continuation = self.continuation
        self.continuation = nil
        self.result = result
        lock.unlock()
        continuation?.resume(with: result)
    }
}
