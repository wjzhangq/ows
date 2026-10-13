import Foundation
import Network

final class HTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "owa-bridge.http")
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private var listener: NWListener?
    var onFailure: (@Sendable (String) -> Void)?

    init(handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.handler = handler
    }

    func start(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.badPort
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                BridgeLog.info("HTTP 已监听 127.0.0.1:\(port)")
            case .failed(let error):
                let message = "端口 \(port) 绑定失败"
                BridgeLog.error("\(message): \(error.localizedDescription)")
                self?.onFailure?(message)
            case .waiting(let error):
                let message = "端口 \(port) 暂不可用"
                BridgeLog.error("\(message): \(error.localizedDescription)")
                self?.onFailure?(message)
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard Self.isLoopback(connection) else {
                    BridgeLog.error("拒绝非本机连接")
                    connection.cancel()
                    return
                }
                self?.serve(connection)
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func serve(_ connection: NWConnection) {
        Task {
            do {
                let data = try await Self.receiveRequest(connection)
                guard let request = HTTPParser.parse(data) else {
                    await Self.send(connection, HTTPResponse.json(400, errorObject("extract_failed", "无法解析 HTTP 请求")))
                    return
                }
                let response = await handler(request)
                await Self.send(connection, response)
            } catch {
                connection.cancel()
            }
        }
    }

    private static func isLoopback(_ connection: NWConnection) -> Bool {
        switch connection.endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address):
                return String(describing: address).hasPrefix("127.")
            case .ipv6(let address):
                let text = String(describing: address)
                return text == "::1" || text == "0:0:0:0:0:0:0:1"
            default:
                return false
            }
        default:
            return false
        }
    }

    private static func receiveRequest(_ connection: NWConnection) async throws -> Data {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(5)
        while buffer.count < 1_048_576, Date() < deadline {
            if let complete = HTTPParser.completeRequest(buffer) {
                return complete
            }
            let chunk = try await receive(connection, maximum: 65_536)
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)
        }
        if let complete = HTTPParser.completeRequest(buffer) {
            return complete
        }
        throw ServerError.badRequest
    }

    private static func receive(_ connection: NWConnection, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }

    private static func send(_ connection: NWConnection, _ response: HTTPResponse) async {
        let payload = response.encoded()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
                continuation.resume()
            })
        }
    }
}

enum ServerError: Error {
    case badPort
    case badRequest
}
