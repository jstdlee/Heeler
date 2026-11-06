import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What a Direct SSH screen borrows from the app (ADR 0039).
@MainActor
struct DirectSSHContext {
    let terminal: TerminalSettings
    let activity: AppActivityCoordinator
}

extension EnvironmentValues {
    /// Set at the app root; nil (previews, demo) hides the Direct SSH actions.
    @Entry var directSSHContext: DirectSSHContext? = nil
}

/// One Direct SSH screen asked for from the Host list.
struct DirectSSHRequest: Identifiable, Hashable {
    enum Kind: Hashable {
        case terminal
        case files
    }

    let host: Host
    let kind: Kind

    var id: String { "\(host.id)-\(kind)" }
}

/// Owns the screen's connection: the Host's login shell or its files, over
/// one Direct SSH connection that ends when the screen does.
struct DirectSSHScreen: View {
    let request: DirectSSHRequest
    let context: DirectSSHContext
    let onClose: () -> Void

    @State private var session: DirectSSHSession?

    var body: some View {
        Group {
            if let session {
                switch request.kind {
                case .terminal:
                    DirectSSHTerminalScreen(session: session, context: context, onClose: onClose)
                case .files:
                    NavigationStack {
                        RemoteFileBrowserView(session: session, onClose: onClose)
                    }
                }
            } else {
                Color(uiColor: .systemBackground).ignoresSafeArea()
            }
        }
        .onAppear {
            if session == nil { session = DirectSSHSession(host: request.host) }
        }
        .onDisappear { session?.close() }
    }
}

/// The Host's login shell in Heeler's terminal: the same renderer, keyboard
/// row and paste review as a herdr Shell Terminal, with no herdr behind it.
struct DirectSSHTerminalScreen: View {
    let session: DirectSSHSession
    let context: DirectSSHContext
    let onClose: () -> Void

    @State private var store: ShellTerminalStore?

    var body: some View {
        Group {
            if let store {
                ShellTerminalView(
                    store: store,
                    agentID: ConsoleAgent.ID(hostID: session.host.id, paneID: store.identity.paneID),
                    terminal: context.terminal,
                    activity: context.activity,
                    isReturning: false,
                    finishedMessage: "The shell ended.",
                    offersTakeOver: false,
                    title: session.host.displayName,
                    backTitle: "Close",
                    backReturnsToAgent: false,
                    onBack: { onClose() })
                    .environment(\.showsDetailBackButton, true)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .onAppear {
            if store == nil { store = makeStore() }
        }
    }

    private func makeStore() -> ShellTerminalStore {
        let id = UUID().uuidString
        return ShellTerminalStore(
            identity: ShellTerminalIdentity(
                paneID: "direct-ssh-\(id)", tabID: "direct-ssh", terminalID: id),
            attachTarget: .loginShell(id),
            transportGeneration: nil,
            takeover: false,
            isOnStage: { true },
            runTerminal: session.terminalRunner())
    }
}

/// Files on the Host over SFTP: browse, open or share a file, upload from
/// this device, make a folder, rename, delete.
struct RemoteFileBrowserView: View {
    let session: DirectSSHSession
    let onClose: () -> Void

    @State private var store: RemoteFileBrowserStore?
    @State private var isImporting = false
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var renaming: RemoteFileItem?
    @State private var renameText = ""
    @State private var deleting: RemoteFileItem?

    var body: some View {
        Group {
            if let store {
                browser(store)
            } else {
                ProgressView("Connecting…")
            }
        }
        .navigationTitle(store?.path.map(Self.title(for:)) ?? session.host.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { onClose() }
            }
        }
        .onAppear {
            if store == nil { store = RemoteFileBrowserStore(session: session) }
        }
        .onDisappear { store?.discardDownloads() }
    }

    @ViewBuilder
    private func browser(_ store: RemoteFileBrowserStore) -> some View {
        @Bindable var model = store
        Group {
            if store.path == nil, case .failed(let message) = store.phase {
                ContentUnavailableView {
                    Label("Couldn't Open Files", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await store.start() } }
                }
            } else if store.path == nil {
                ProgressView("Connecting…")
            } else {
                list(store)
            }
        }
        .task { await store.start() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Upload File", systemImage: "square.and.arrow.up") { isImporting = true }
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        isCreatingFolder = true
                    }
                    Toggle("Show Hidden Files", systemImage: "eye", isOn: $model.showsHiddenFiles)
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await store.reload() }
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .disabled(store.path == nil)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                Task { await store.upload(from: url) }
            }
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Name", text: $newFolderName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newFolderName
                Task { await store.makeFolder(named: name) }
            }
        }
        .alert(
            "Rename",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming
        ) { item in
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = renameText
                Task { await store.rename(item, to: name) }
            }
        }
        .confirmationDialog(
            deleting.map { "Delete \($0.name)?" } ?? "Delete",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { item in
            Button("Delete", role: .destructive) {
                Task { await store.delete(item) }
            }
        } message: { item in
            Text(item.kind == .directory
                ? "Only an empty folder can be deleted."
                : "This can't be undone.")
        }
        .alert(
            "Couldn't Complete",
            isPresented: Binding(
                get: { store.operationError != nil },
                set: { if !$0 { store.operationError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.operationError ?? "")
        }
        .quickLookPreview($model.downloaded)
    }

    private func list(_ store: RemoteFileBrowserStore) -> some View {
        List {
            Section {
                if store.canGoUp {
                    Button {
                        Task { await store.goUp() }
                    } label: {
                        Label("Enclosing Folder", systemImage: "arrow.turn.left.up")
                    }
                }
            } header: {
                Text(store.path ?? "")
                    .textCase(nil)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            if let progress = store.progress {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(progress)
                            .font(.callout)
                            .lineLimit(2)
                    }
                }
            }
            if case .failed(let message) = store.phase {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await store.reload() } }
                }
            }
            Section {
                ForEach(store.visibleItems) { item in
                    row(item, store: store)
                }
            } footer: {
                if store.isTruncated {
                    Text("Showing the first 1,000 items.")
                } else if store.phase == .loaded, store.visibleItems.isEmpty {
                    Text("This folder is empty.")
                }
            }
        }
        .overlay {
            if store.phase == .loading { ProgressView() }
        }
        .refreshable { await store.reload() }
    }

    private func row(_ item: RemoteFileItem, store: RemoteFileBrowserStore) -> some View {
        Button {
            Task { await store.open(item) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol(for: item))
                    .foregroundStyle(item.kind == .directory ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = Self.detail(for: item) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if item.kind == .directory {
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
        // No `.destructive` role: List would animate the row out while the
        // confirmation is still up.
        .swipeActions(edge: .trailing) {
            Button {
                deleting = item
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
            Button {
                renameText = item.name
                renaming = item
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .contextMenu {
            if item.kind == .file {
                Button("Download", systemImage: "arrow.down.circle") {
                    Task { await store.download(item) }
                }
            }
            Button("Rename", systemImage: "pencil") {
                renameText = item.name
                renaming = item
            }
            Button("Copy Path", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = item.path
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                deleting = item
            }
        }
    }

    private static func symbol(for item: RemoteFileItem) -> String {
        switch item.kind {
        case .directory: "folder.fill"
        case .file: "doc"
        case .symlink: "arrow.triangle.turn.up.right.diamond"
        case .other: "questionmark.square.dashed"
        }
    }

    private static func detail(for item: RemoteFileItem) -> String? {
        var parts: [String] = []
        if item.kind == .file, let size = item.size {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
        }
        if let modified = item.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func title(for path: String) -> String {
        guard path != "/" else { return "/" }
        return path.split(separator: "/").last.map(String.init) ?? path
    }
}
