import SwiftUI

/// One open SSH Terminal (ADR 0039): its own connection, its shell's
/// pipeline, and the terminal surface kept across switches, so another
/// session can be in front while this one keeps its shell and scrollback.
@MainActor
final class DirectSSHTerminalTab: Identifiable {
    nonisolated let id: UUID
    let host: Host
    /// Which of this Host's sessions this is, counting from 1.
    let number: Int
    let session: DirectSSHSession
    let store: ShellTerminalStore
    let retention = TerminalSurfaceRetention()

    init(host: Host, number: Int, session: DirectSSHSession) {
        let id = UUID()
        self.id = id
        self.host = host
        self.number = number
        self.session = session
        let shellID = id.uuidString
        store = ShellTerminalStore(
            identity: ShellTerminalIdentity(
                paneID: "direct-ssh-\(shellID)", tabID: "direct-ssh", terminalID: shellID),
            attachTarget: .loginShell(shellID),
            transportGeneration: nil,
            takeover: false,
            isOnStage: { true },
            runTerminal: session.terminalRunner())
    }

    var title: String {
        number > 1 ? "\(host.displayName) (\(number))" : host.displayName
    }

    /// Stops the shell, drops the kept surface and closes the connection.
    func end() async {
        await store.leave().value
        retention.clear()
        session.close()
    }
}

/// A window's open SSH Terminals, Termius-style: several at once, across
/// Hosts, one in front. Backing out hides them without ending them; they
/// stay listed under Hosts until closed. iOS still suspends a backgrounded
/// app, and a session whose connection did not survive that reconnects with
/// a new shell.
@MainActor
@Observable
final class DirectSSHSessions {
    private(set) var tabs: [DirectSSHTerminalTab] = []
    private(set) var selectedID: DirectSSHTerminalTab.ID?
    var isPresented = false

    @ObservationIgnored private let makeSession: @MainActor (Host) -> DirectSSHSession

    init(makeSession: @escaping @MainActor (Host) -> DirectSSHSession = { DirectSSHSession(host: $0) }) {
        self.makeSession = makeSession
    }

    var selected: DirectSSHTerminalTab? {
        tabs.first { $0.id == selectedID } ?? tabs.last
    }

    /// Opens another session on `host` and brings it to the front.
    @discardableResult
    func open(_ host: Host) -> DirectSSHTerminalTab {
        let number = (tabs.filter { $0.host.id == host.id }.map(\.number).max() ?? 0) + 1
        let tab = DirectSSHTerminalTab(host: host, number: number, session: makeSession(host))
        tabs.append(tab)
        selectedID = tab.id
        isPresented = true
        return tab
    }

    func select(_ id: DirectSSHTerminalTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Brings `id` to the front, full screen.
    func show(_ id: DirectSSHTerminalTab.ID) {
        select(id)
        isPresented = !tabs.isEmpty
    }

    /// Hides the sessions; every shell keeps running.
    func hide() {
        isPresented = false
    }

    /// Ends one session. Its neighbour comes to the front; the last one
    /// closed hides the screen.
    func close(_ id: DirectSSHTerminalTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        if selectedID == id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if tabs.isEmpty { isPresented = false }
        Task { await tab.end() }
    }

    func closeAll() {
        for tab in tabs { close(tab.id) }
    }
}

/// The front session full screen. Its header offers the session list and
/// another session on the same Host; Back hides every session.
struct DirectSSHSessionsScreen: View {
    let sessions: DirectSSHSessions
    let context: DirectSSHContext

    @State private var isShowingSwitcher = false

    var body: some View {
        Group {
            if let tab = sessions.selected {
                ShellTerminalView(
                    store: tab.store,
                    agentID: ConsoleAgent.ID(hostID: tab.host.id, paneID: tab.store.identity.paneID),
                    terminal: context.terminal,
                    activity: context.activity,
                    isReturning: false,
                    onCloseTerminal: { sessions.close(tab.id) },
                    finishedMessage: "The shell ended.",
                    managesLifecycle: false,
                    offersTakeOver: false,
                    surfaceRetention: tab.retention,
                    title: tab.title,
                    backTitle: "Hosts",
                    backReturnsToAgent: false,
                    offersSnippets: true,
                    extraHeaderActions: headerActions(for: tab),
                    onBack: { sessions.hide() })
                    .environment(\.showsDetailBackButton, true)
                    .id(tab.id)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .sheet(isPresented: $isShowingSwitcher) {
            DirectSSHSessionSwitcher(sessions: sessions) { isShowingSwitcher = false }
        }
    }

    private func headerActions(for tab: DirectSSHTerminalTab) -> [AgentDetailHeaderAction] {
        [
            AgentDetailHeaderAction(
                title: "Sessions (\(sessions.tabs.count))", systemImage: "rectangle.stack"
            ) {
                isShowingSwitcher = true
            },
            AgentDetailHeaderAction(
                title: "New Session on This Host", systemImage: "plus.rectangle.on.rectangle"
            ) {
                sessions.open(tab.host)
            },
        ]
    }
}

/// Every open session: switch to one, close one, or close them all.
struct DirectSSHSessionSwitcher: View {
    let sessions: DirectSSHSessions
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions.tabs) { @Sendable tab in
                    MainActorContent { row(tab) }
                }
            }
            .navigationTitle("SSH Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Close All", role: .destructive) {
                        onDone()
                        sessions.closeAll()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ tab: DirectSSHTerminalTab) -> some View {
        Button {
            sessions.select(tab.id)
            onDone()
        } label: {
            DirectSSHSessionRow(tab: tab, isSelected: sessions.selected?.id == tab.id)
        }
        .tint(.primary)
        .swipeActions(edge: .trailing) {
            Button {
                sessions.close(tab.id)
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .tint(.red)
        }
    }
}

/// One session in a list: its Host and how its shell is doing.
struct DirectSSHSessionRow: View {
    let tab: DirectSSHTerminalTab
    var isSelected = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .lineLimit(1)
                Text(Self.statusText(tab.store.terminalStatus))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Current session")
            }
        }
        .contentShape(Rectangle())
    }

    static func statusText(_ status: AttachTerminalStore.Status) -> String {
        switch status {
        case .waitingForSize, .connecting: "Connecting"
        case .live: "Connected"
        case .reconnecting, .restarting: "Reconnecting"
        case .ended: "Disconnected"
        case .finished: "Shell ended"
        case .stopped: "Closed"
        }
    }
}
