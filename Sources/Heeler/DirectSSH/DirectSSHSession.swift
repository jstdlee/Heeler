import Foundation
import HeelerSSH

/// One Direct SSH connection to a saved Host (ADR 0039), shared by its login
/// shell terminals and its file browser.
///
/// It dials with the Host's own credentials and routes, and trusts only the
/// host key already confirmed for that Host, as the Console does: it never
/// prompts. A Host never connected before is confirmed once from Host detail.
/// A dropped connection is redialed by the next terminal or file request.
@MainActor
final class DirectSSHSession {
    typealias Dial = @Sendable () async throws -> HeelerSSHTransport

    let host: Host
    private let dial: Dial
    private var transport: HeelerSSHTransport?
    private var pending: Task<HeelerSSHTransport, any Error>?
    private var generation: UInt64 = 0
    private var isClosed = false

    init(host: Host, dial: @escaping Dial) {
        self.host = host
        self.dial = dial
    }

    /// The production dial: the Console's credentials and trust rules.
    convenience init(
        host: Host,
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        overlays: OverlayNetworkRuntime = .shared
    ) {
        self.init(host: host) {
            let resolved: SSHCredentials
            do {
                resolved = try credentials.credentials(for: host)
            } catch HostCredentialsError.passwordNotSet {
                throw TransportError.authenticationFailed
            }
            let settings = SSHTransportSettings(
                host: host,
                credentials: resolved,
                hostKeyPolicy: HostKeyPolicy(knownHosts: knownHosts) { _ in false },
                overlays: overlays)
            return try await HeelerSSHTransport.connect(settings: settings)
        }
    }

    /// A live transport and the generation it belongs to, dialing a new one
    /// when there is none or the last one dropped. Concurrent callers share
    /// one dial.
    func connectedTransport() async throws -> (transport: HeelerSSHTransport, generation: UInt64) {
        guard !isClosed else { throw TransportError.cancelled }
        if let current = transport {
            if await current.isConnected, transport === current {
                return (current, generation)
            }
            if transport === current {
                transport = nil
                Task { try? await current.close() }
            }
        }
        let task: Task<HeelerSSHTransport, any Error>
        if let pending {
            task = pending
        } else {
            let dial = dial
            task = Task { try await dial() }
            pending = task
        }
        let opened: HeelerSSHTransport
        do {
            opened = try await task.value
        } catch {
            if pending == task { pending = nil }
            throw error
        }
        if pending == task {
            pending = nil
            guard !isClosed else {
                Task { try? await opened.close() }
                throw TransportError.cancelled
            }
            transport = opened
            generation &+= 1
        }
        guard let current = transport else { throw TransportError.cancelled }
        return (current, generation)
    }

    /// Runs one login shell per attach. A reattach after a dropped line starts
    /// a new shell: the old one ended with its channel.
    func terminalRunner() -> TerminalSessionRunner {
        { [weak self] request, handler in
            guard let self else { throw TransportError.cancelled }
            let (transport, generation) = try await self.connectedTransport()
            await handler.transportDidBecomeReady(generation)
            let session = try await transport.attachTerminal(request)
            try await handler.runEndingSession(session)
        }
    }

    /// Runs `body` with one SFTP channel on the live connection.
    func withSFTP<Value: Sendable>(
        _ body: @escaping @Sendable (SSHSFTPClient, Duration) async throws -> Value
    ) async throws -> Value {
        let (transport, _) = try await connectedTransport()
        return try await transport.withDirectSFTP(body)
    }

    /// Ends the connection. Terminals and the file browser should already
    /// have stopped; anything still running sees the channel close.
    func close() {
        isClosed = true
        pending?.cancel()
        pending = nil
        if let transport {
            self.transport = nil
            Task { try? await transport.close() }
        }
    }
}
