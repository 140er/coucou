#if !APPSTORE
import Foundation
import Network

/// The local door the WhatsApp gateway knocks on with each new message: an HTTP listener bound
/// to 127.0.0.1 only (never reachable from another machine), on the port set in Settings.
/// Each request is handed over whole; nothing of it is logged.
final class WhatsAppWebhook: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "fr.louisraille.NotchBuddy.whatsapp.webhook")
    private(set) var port: UInt16 = 0

    /// Called on `queue` with each complete request; returns the HTTP status to answer.
    var onRequest: (@Sendable (WAHTTPRequest) -> Int)?

    /// Starts listening; false when the port is taken or invalid.
    @discardableResult
    func start(port: UInt16) -> Bool {
        stop()
        guard port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        params.acceptLocalOnly = true
        guard let listener = try? NWListener(using: params) else { return false }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                appendAppLog("nb.log", "[WhatsApp] webhook listener failed: \(error.localizedDescription)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        self.port = port
        return true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    private func serve(_ connection: NWConnection) {
        // Only the loopback: the listener is bound to it, this is a second lock.
        if case .hostPort(let host, _) = connection.endpoint {
            switch host {
            case .ipv4(let a) where a == .loopback: break
            case .ipv6(let a) where a == .loopback: break
            default:
                connection.cancel()
                return
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        // A request that never finishes is dropped.
        queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch WAHTTPRequest.parse(buffer) {
            case .incomplete where !isComplete && error == nil:
                self.receive(connection, buffer: buffer)
            case .done(let request):
                let status = self.onRequest?(request) ?? 503
                let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : "Error")
                connection.send(content: WAHTTPRequest.response(status, reason), completion: .contentProcessed { _ in connection.cancel() })
            default:
                connection.send(content: WAHTTPRequest.response(400, "Bad Request"), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
#endif
