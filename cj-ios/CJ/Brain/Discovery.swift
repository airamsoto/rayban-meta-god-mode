import Foundation
import Network

/// Finds the brain on the Wi-Fi by its Bonjour name (announced by cj-mac/cj/beacon.py with macOS's dns-sd), so the
/// pairing survives the Mac getting a new address. Only the address is found this way; the token still comes from
/// the QR code.
enum Discovery {
    static let serviceType = "_cjbrain._tcp"

    /// "http://<ipv4>:<port>" of the first brain that answers, or nil after [timeout] seconds.
    static func find(timeout: TimeInterval = 6) async -> String? {
        await withCheckedContinuation { continuation in
            let search = Search(continuation: continuation)
            search.start(timeout: timeout)
        }
    }

    /// One search: browse for the service, open a TCP connection to the first result to learn its IPv4 address.
    private final class Search: @unchecked Sendable {
        private let queue = DispatchQueue(label: "cj.discovery")
        private var continuation: CheckedContinuation<String?, Never>?
        private var browser: NWBrowser?
        private var connections: [NWConnection] = []

        init(continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
        }

        func start(timeout: TimeInterval) {
            let browser = NWBrowser(for: .bonjour(type: Discovery.serviceType, domain: "local."), using: .tcp)
            self.browser = browser
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                for result in results { self?.resolve(result.endpoint) }
            }
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.finish(nil) }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
        }

        private func resolve(_ endpoint: NWEndpoint) {
            let parameters = NWParameters.tcp
            // The phone reaches the Mac over IPv4 on a home network; a link-local IPv6 address would need a scope id.
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            connections.append(connection)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard case .ready = state,
                      case let .hostPort(host, port)? = connection?.currentPath?.remoteEndpoint else { return }
                var address = "\(host)"
                if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
                self?.finish("http://\(address):\(port.rawValue)")
            }
            connection.start(queue: queue)
        }

        private func finish(_ url: String?) {
            queue.async { [self] in
                guard let continuation else { return }
                self.continuation = nil
                browser?.cancel()
                connections.forEach { $0.cancel() }
                continuation.resume(returning: url)
            }
        }
    }
}
