import Foundation
import Network

/// Listens on 127.0.0.1:port for an on-demand tunnel and pipes each client to 127.0.0.1 on the port
/// `upstream` returns. `upstream` is asked once per client, when it connects, so the real tunnel can
/// start then; the client waits meanwhile, and is closed when `upstream` returns nil.
public final class TCPProxy: @unchecked Sendable {
    public typealias Upstream = @Sendable () async -> Int?

    private let upstream: Upstream
    private let onActiveChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "Portkeep.TCPProxy")
    private let lock = NSLock()
    private var listener: NWListener?
    private var pairs: [ObjectIdentifier: Pair] = [:]
    private var stopped = false

    /// - Parameter onActiveChange: called after a client connects or its connection closes; read `activeCount`.
    public init(upstream: @escaping Upstream, onActiveChange: @escaping @Sendable () -> Void = {}) {
        self.upstream = upstream
        self.onActiveChange = onActiveChange
    }

    /// Clients connected now, including those still waiting for the upstream.
    public var activeCount: Int { lock.withLock { pairs.count } }

    /// Starts listening and returns the port (the system picks one for 0); throws when it can't be bound.
    @discardableResult
    public func start(port: Int) async throws -> Int {
        let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any
        let parameters = NWParameters.tcp
        // Our own earlier connections may still be in TIME_WAIT. Callers check the port is free first,
        // since reuse would also let us bind over a wildcard listener.
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let resumed = Flag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.set() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    if resumed.set() { continuation.resume(throwing: error) }
                case .cancelled:
                    if resumed.set() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        let late = lock.withLock {
            self.listener = listener
            return stopped
        }
        if late { listener.cancel() }
        return Int(listener.port?.rawValue ?? UInt16(clamping: port))
    }

    /// Stops listening and closes every client.
    public func stop() {
        let (listener, open) = lock.withLock {
            stopped = true
            defer { self.listener = nil }
            return (self.listener, Array(pairs.values))
        }
        listener?.cancel()
        open.forEach { $0.close() }
    }

    private func accept(_ client: NWConnection) {
        let pair = Pair(client: client)
        let key = ObjectIdentifier(pair)
        let refused = lock.withLock {
            if stopped { return true }
            pairs[key] = pair
            return false
        }
        if refused {
            client.cancel()
            return
        }
        pair.onClose = { [weak self] in
            guard let self else { return }
            self.lock.withLock { _ = self.pairs.removeValue(forKey: key) }
            self.onActiveChange()
        }
        pair.start(queue: queue)
        onActiveChange()
        let upstream = self.upstream, queue = self.queue
        Task {
            guard let port = await upstream() else {
                pair.close()
                return
            }
            pair.connect(to: port, queue: queue)
        }
    }
}

/// True the first time `set()` is called.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func set() -> Bool {
        lock.withLock {
            defer { isSet = true }
            return !isSet
        }
    }
}

/// One client and its upstream connection, copying bytes both ways.
private final class Pair: @unchecked Sendable {
    let client: NWConnection
    var onClose: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var server: NWConnection?
    private var closed = false
    private var finishedDirections = 0

    init(client: NWConnection) {
        self.client = client
    }

    func start(queue: DispatchQueue) {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        client.start(queue: queue)
    }

    func connect(to port: Int, queue: DispatchQueue) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            close()
            return
        }
        let server = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let isClosed = lock.withLock {
            if !closed { self.server = server }
            return closed
        }
        guard !isClosed else { return }
        server.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.pump(from: self.client, to: server)
                self.pump(from: server, to: self.client)
            // .waiting means nothing listens there; Network would keep retrying, but the client can't wait.
            case .failed, .waiting, .cancelled:
                self.close()
            default:
                break
            }
        }
        server.start(queue: queue)
    }

    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil {
                        self.close()
                    } else if isComplete {
                        self.finish(sink)
                    } else {
                        self.pump(from: source, to: sink)
                    }
                })
            } else if error != nil {
                close()
            } else if isComplete {
                finish(sink)
            } else {
                pump(from: source, to: sink)
            }
        }
    }

    /// One direction reached end of stream: pass it on, and close once both directions have.
    private func finish(_ sink: NWConnection) {
        sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        let both = lock.withLock {
            finishedDirections += 1
            return finishedDirections == 2
        }
        if both { close() }
    }

    func close() {
        let (first, server) = lock.withLock {
            defer { closed = true }
            return (!closed, self.server)
        }
        guard first else { return }
        client.cancel()
        server?.cancel()
        onClose?()
    }
}
