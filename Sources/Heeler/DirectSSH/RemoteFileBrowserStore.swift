import Foundation
import HeelerSSH

/// One entry in a Direct SSH directory listing (ADR 0039).
struct RemoteFileItem: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case directory
        case file
        case symlink
        case other
    }

    let name: String
    let path: String
    let kind: Kind
    let size: UInt64?
    let modified: Date?

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }
}

/// POSIX path arithmetic for the file browser. Paths come from the server's
/// own canonical home and the names it lists, never from a shell.
enum RemotePath {
    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// The containing directory, or nil at the root.
    static func parent(of path: String) -> String? {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard trimmed != "/", let slash = trimmed.lastIndex(of: "/") else { return nil }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    /// A single name a user may create or rename to: no separators, no NUL,
    /// and not one of the directory links.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\u{0}")
    }

    /// Folders first, then names in the order Finder uses.
    static func sorted(_ items: [RemoteFileItem]) -> [RemoteFileItem] {
        items.sorted { lhs, rhs in
            let lhsFolder = lhs.kind == .directory
            let rhsFolder = rhs.kind == .directory
            if lhsFolder != rhsFolder { return lhsFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// What a file operation refused, in the words the browser shows.
enum RemoteFileError: Error, Equatable, LocalizedError {
    case server(status: UInt64)
    case directoryMissing(String)
    case nameTaken(String)
    case invalidName
    case notAFile
    case fileVanished

    var errorDescription: String? {
        switch self {
        case .server(let status):
            switch status {
            case 2: "The item no longer exists."
            case 3: "Permission denied."
            case 4: "The server refused the change. A folder must be empty to delete it."
            case 11: "An item with that name already exists."
            case 14: "The disk on the Host is full."
            case 18: "The folder isn't empty."
            case 19: "That isn't a folder."
            default: "The server refused the request (SFTP status \(status))."
            }
        case .directoryMissing(let path): "\(path) doesn't exist or can't be read."
        case .nameTaken(let name): "\(name) already exists here."
        case .invalidName: "Use a name without slashes."
        case .notAFile: "Only regular files can be downloaded."
        case .fileVanished: "The file was removed while it downloaded."
        }
    }

    /// Turns the package's SFTP status into this browser's wording.
    static func adapting(_ error: any Error) -> any Error {
        if let ssh = error as? SSHError, case .sftpFailure(let status) = ssh {
            return RemoteFileError.server(status: status)
        }
        return error
    }
}

/// The Direct SSH file browser's state: one directory at a time, listed and
/// changed over SFTP on the Host's Direct SSH connection.
@MainActor
@Observable
final class RemoteFileBrowserStore {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// Largest chunk one SFTP read or write carries.
    nonisolated static let chunkBytes = 256 * 1024

    private(set) var path: String?
    private(set) var items: [RemoteFileItem] = []
    private(set) var phase: Phase = .loading
    /// The server listed more than the browser shows (the first 1,000).
    private(set) var isTruncated = false
    var showsHiddenFiles = false
    /// What the browser is doing right now, for the status row.
    private(set) var progress: String?
    /// The last refused operation, shown as an alert.
    var operationError: String?
    /// A downloaded file waiting to be shared or opened.
    var downloaded: URL?

    @ObservationIgnored private let session: DirectSSHSession
    @ObservationIgnored private let downloads: URL
    @ObservationIgnored private var isBusy = false

    init(session: DirectSSHSession) {
        self.session = session
        downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectSSHDownloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    var visibleItems: [RemoteFileItem] {
        showsHiddenFiles ? items : items.filter { !$0.isHidden }
    }

    var canGoUp: Bool { path.flatMap(RemotePath.parent(of:)) != nil }

    /// Opens the account's home directory, as the SFTP server reports it.
    func start() async {
        guard path == nil else { return }
        phase = .loading
        do {
            let home = try await session.withSFTP { sftp, timeout -> String in
                do {
                    return try await sftp.canonicalPath(".", timeout: timeout)
                } catch {
                    throw RemoteFileError.adapting(error)
                }
            }
            await load(home)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func reload() async {
        guard let path else { return await start() }
        await load(path)
    }

    func goUp() async {
        guard let parent = path.flatMap(RemotePath.parent(of:)) else { return }
        await load(parent)
    }

    /// Enters a folder, or a link that leads to one. Anything else is a file.
    func open(_ item: RemoteFileItem) async {
        switch item.kind {
        case .directory:
            await load(item.path)
        case .symlink:
            let target = item.path
            do {
                let status = try await session.withSFTP { sftp, timeout -> SSHSFTPFileStatus? in
                    do {
                        return try await sftp.fileStatus(at: target, followSymlinks: true, timeout: timeout)
                    } catch {
                        throw RemoteFileError.adapting(error)
                    }
                }
                if status?.kind == .directory {
                    await load(target)
                } else {
                    await download(item)
                }
            } catch {
                operationError = Self.message(for: error)
            }
        case .file:
            await download(item)
        case .other:
            operationError = RemoteFileError.notAFile.errorDescription
        }
    }

    func load(_ directory: String) async {
        phase = .loading
        do {
            let listing = try await session.withSFTP { sftp, timeout -> SSHSFTPEntryListing? in
                do {
                    return try await sftp.listEntries(
                        at: directory,
                        matching: SSHSFTPEntryQuery(
                            maximumEntries: SSHSFTPEntryQuery.entryLimit,
                            maximumScanned: SSHSFTPEntryQuery.scanLimit),
                        timeout: timeout)
                } catch {
                    throw RemoteFileError.adapting(error)
                }
            }
            guard let listing else { throw RemoteFileError.directoryMissing(directory) }
            items = RemotePath.sorted(listing.entries.map { Self.item($0, in: directory) })
            isTruncated = listing.truncated || listing.scanIncomplete
            path = directory
            phase = .loaded
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    // MARK: Transfers

    /// Copies a remote file to this device, then offers it to share or open.
    func download(_ item: RemoteFileItem) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false; progress = nil }
        let local = downloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(item.name)
        let remote = item.path
        let name = item.name
        progress = "Downloading \(name)…"
        do {
            try FileManager.default.createDirectory(
                at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(
                atPath: local.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.complete])
            else { throw CocoaError(.fileWriteUnknown) }
            let report = progressReporter(verb: "Downloading", name: name)
            try await session.withSFTP { sftp, timeout in
                let handle = try FileHandle(forWritingTo: local)
                defer { try? handle.close() }
                var offset: UInt64 = 0
                while true {
                    let slice: SSHSFTPFileSlice
                    do {
                        slice = try await sftp.readFileRange(
                            at: remote, offset: offset,
                            maxBytes: RemoteFileBrowserStore.chunkBytes, timeout: timeout)
                    } catch {
                        throw RemoteFileError.adapting(error)
                    }
                    guard let length = slice.length else { throw RemoteFileError.fileVanished }
                    if slice.data.isEmpty { break }
                    try handle.write(contentsOf: slice.data)
                    offset += UInt64(slice.data.count)
                    report(offset, length)
                    if offset >= length { break }
                }
            }
            excludeFromBackup(local)
            downloaded = local
        } catch {
            try? FileManager.default.removeItem(at: local.deletingLastPathComponent())
            operationError = Self.message(for: error)
        }
    }

    /// Uploads a file picked on this device into the current folder. It is
    /// written beside its final name first and renamed once complete, so a
    /// failed upload never leaves a half file under the real name, and an
    /// existing file is never replaced.
    func upload(from source: URL) async {
        guard !isBusy, let directory = path else { return }
        let name = source.lastPathComponent
        guard RemotePath.isValidName(name) else {
            operationError = RemoteFileError.invalidName.errorDescription
            return
        }
        isBusy = true
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped { source.stopAccessingSecurityScopedResource() }
            isBusy = false
            progress = nil
        }
        progress = "Uploading \(name)…"
        let destination = RemotePath.join(directory, name)
        let staging = RemotePath.join(directory, ".\(name).heeler-upload-\(UUID().uuidString.prefix(8))")
        let total: UInt64? = (try? source.resourceValues(forKeys: [.fileSizeKey]))?
            .fileSize.map { UInt64(max(0, $0)) }
        let report = progressReporter(verb: "Uploading", name: name)
        do {
            try await session.withSFTP { sftp, timeout in
                do {
                    if try await sftp.fileStatus(at: destination, followSymlinks: false, timeout: timeout) != nil {
                        throw RemoteFileError.nameTaken(name)
                    }
                    let reader = try FileHandle(forReadingFrom: source)
                    defer { try? reader.close() }
                    let file = try await sftp.openFileForWriting(
                        at: staging, permissions: 0o644, timeout: timeout)
                    do {
                        var sent: UInt64 = 0
                        while let chunk = try reader.read(upToCount: RemoteFileBrowserStore.chunkBytes),
                            !chunk.isEmpty
                        {
                            try await file.write(chunk, timeout: timeout)
                            sent += UInt64(chunk.count)
                            report(sent, total)
                        }
                        try await file.close(timeout: timeout)
                    } catch {
                        try? await file.close(timeout: .seconds(2))
                        throw error
                    }
                    // Checked again: someone may have created it meanwhile,
                    // and the rename would replace it.
                    if try await sftp.fileStatus(at: destination, followSymlinks: false, timeout: timeout) != nil {
                        throw RemoteFileError.nameTaken(name)
                    }
                    try await sftp.renameFileAtomically(from: staging, to: destination, timeout: timeout)
                } catch {
                    try? await sftp.removeFile(at: staging, timeout: .seconds(5))
                    throw RemoteFileError.adapting(error)
                }
            }
            await load(directory)
        } catch {
            operationError = Self.message(for: error)
        }
    }

    // MARK: Changes

    func makeFolder(named name: String) async {
        guard let directory = path else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemotePath.isValidName(trimmed) else {
            operationError = RemoteFileError.invalidName.errorDescription
            return
        }
        let target = RemotePath.join(directory, trimmed)
        await change(reloading: directory) { sftp, timeout in
            try await sftp.createDirectory(at: target, permissions: 0o755, timeout: timeout)
        }
    }

    func rename(_ item: RemoteFileItem, to name: String) async {
        guard let directory = path else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemotePath.isValidName(trimmed) else {
            operationError = RemoteFileError.invalidName.errorDescription
            return
        }
        guard trimmed != item.name else { return }
        let source = item.path
        let target = RemotePath.join(directory, trimmed)
        await change(reloading: directory) { sftp, timeout in
            // The server's rename replaces an existing target; a rename here
            // never should.
            if try await sftp.fileStatus(at: target, followSymlinks: false, timeout: timeout) != nil {
                throw RemoteFileError.nameTaken(trimmed)
            }
            try await sftp.renameFileAtomically(from: source, to: target, timeout: timeout)
        }
    }

    /// Deletes a file or link, or an empty folder. SFTP has no recursive
    /// delete, and the browser does not walk a tree to fake one.
    func delete(_ item: RemoteFileItem) async {
        guard let directory = path else { return }
        let target = item.path
        let isFolder = item.kind == .directory
        await change(reloading: directory) { sftp, timeout in
            if isFolder {
                try await sftp.removeDirectory(at: target, timeout: timeout)
            } else {
                try await sftp.removeFile(at: target, timeout: timeout)
            }
        }
    }

    /// Drops every downloaded copy this browser made.
    func discardDownloads() {
        downloaded = nil
        try? FileManager.default.removeItem(at: downloads)
    }

    // MARK: Helpers

    private func change(
        reloading directory: String,
        _ operation: @escaping @Sendable (SSHSFTPClient, Duration) async throws -> Void
    ) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await session.withSFTP { sftp, timeout in
                do {
                    try await operation(sftp, timeout)
                } catch {
                    throw RemoteFileError.adapting(error)
                }
            }
        } catch {
            operationError = Self.message(for: error)
        }
        await load(directory)
    }

    private func progressReporter(
        verb: String, name: String
    ) -> @Sendable (UInt64, UInt64?) -> Void {
        { [self] done, total in
            let text = RemoteFileBrowserStore.progressText(
                verb: verb, name: name, done: done, total: total)
            Task { @MainActor in
                guard self.progress != nil else { return }
                self.progress = text
            }
        }
    }

    nonisolated static func progressText(
        verb: String, name: String, done: UInt64, total: UInt64?
    ) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let doneText = formatter.string(fromByteCount: Int64(clamping: done))
        guard let total, total > 0 else { return "\(verb) \(name)… \(doneText)" }
        let totalText = formatter.string(fromByteCount: Int64(clamping: total))
        return "\(verb) \(name)… \(doneText) of \(totalText)"
    }

    private func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try? url.setResourceValues(values)
    }

    nonisolated static func item(_ entry: SSHSFTPEntry, in directory: String) -> RemoteFileItem {
        let kind: RemoteFileItem.Kind =
            switch entry.status.kind {
            case .directory: .directory
            case .regular: .file
            case .symlink: .symlink
            case .other, nil: .other
            }
        return RemoteFileItem(
            name: entry.name,
            path: RemotePath.join(directory, entry.name),
            kind: kind,
            size: entry.status.size,
            modified: entry.status.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    nonisolated static func message(for error: any Error) -> String {
        switch error {
        case let error as RemoteFileError:
            error.errorDescription ?? "The request failed."
        case let error as TransportError:
            error.presentation(usesHerdrEndpoint: false).message
        case is CancellationError:
            "The request was cancelled."
        default:
            error.localizedDescription
        }
    }
}
