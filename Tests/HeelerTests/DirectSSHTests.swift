import Foundation
import HeelerSSH
import Testing

@testable import Heeler

@Suite("Direct SSH")
struct DirectSSHTests {
    @Test func loginShellPrintsTheMarkerThenRunsTheAccountShellAndEndsCleanly() {
        let command = HeelerSSHTransport.loginShellCommand
        #expect(command.hasPrefix("/bin/sh -c '"))
        #expect(command.contains("printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\";"))
        #expect(command.contains("\"${SHELL:-/bin/sh}\" -l; exit 0'"))
        // Never execs: a shell's last status is not the session's outcome.
        #expect(!command.contains("exec"))
        // One quoted script, so the account shell sees no other word.
        #expect(command.filter { $0 == "'" }.count == 2)
    }

    @Test func loginShellTargetsAreDistinctPerSession() {
        let first = TerminalAttachTarget.loginShell("a")
        let second = TerminalAttachTarget.loginShell("b")
        #expect(first != second)
        #expect(first.identifier == "a")
        #expect(TerminalAttachTarget.loginShell("a") != .terminal("a"))
    }

    @MainActor
    @Test func shellStoreKeepsTheHerdrTerminalByDefault() {
        let identity = ShellTerminalIdentity(paneID: "p", tabID: "t", terminalID: "term-1")
        let herdr = ShellTerminalStore(
            identity: identity, transportGeneration: nil, isOnStage: { true },
            runTerminal: { _, _ in })
        let direct = ShellTerminalStore(
            identity: identity, attachTarget: .loginShell("s-1"), transportGeneration: nil,
            isOnStage: { true }, runTerminal: { _, _ in })
        #expect(herdr.attachTarget == .terminal("term-1"))
        #expect(direct.attachTarget == .loginShell("s-1"))
    }

    @Test(arguments: [
        ("/", "etc", "/etc"),
        ("/home/dev", "notes.txt", "/home/dev/notes.txt"),
        ("/home/dev/", "a b", "/home/dev/a b"),
    ])
    func joinsANameOntoAFolder(directory: String, name: String, expected: String) {
        #expect(RemotePath.join(directory, name) == expected)
    }

    @Test(arguments: [
        ("/home/dev/src", "/home/dev"),
        ("/home", "/"),
        ("/home/dev/", "/home"),
        ("/", nil),
        ("relative", nil),
    ] as [(String, String?)])
    func findsTheEnclosingFolder(path: String, expected: String?) {
        #expect(RemotePath.parent(of: path) == expected)
    }

    @Test func refusesNamesThatAreNotOneEntry() {
        #expect(RemotePath.isValidName("report.pdf"))
        #expect(RemotePath.isValidName(".env"))
        for name in ["", ".", "..", "a/b", "/", "a\u{0}b"] {
            #expect(!RemotePath.isValidName(name), "\(name.debugDescription)")
        }
    }

    @Test func listsFoldersFirstThenNamesInFinderOrder() {
        func item(_ name: String, _ kind: RemoteFileItem.Kind) -> RemoteFileItem {
            RemoteFileItem(name: name, path: "/x/\(name)", kind: kind, size: nil, modified: nil)
        }
        let sorted = RemotePath.sorted([
            item("file10.txt", .file), item("zeta", .directory), item("file2.txt", .file),
            item("Alpha", .directory), item("link", .symlink),
        ])
        #expect(sorted.map(\.name) == ["Alpha", "zeta", "file2.txt", "file10.txt", "link"])
    }

    @Test func mapsListedEntriesOntoItems() {
        let entry = SSHSFTPEntry(
            name: "build.log",
            status: SSHSFTPFileStatus(kind: .regular, size: 2048, modificationTime: 1_700_000_000))
        let item = RemoteFileBrowserStore.item(entry, in: "/var/log")
        #expect(item.path == "/var/log/build.log")
        #expect(item.kind == .file)
        #expect(item.size == 2048)
        #expect(item.modified == Date(timeIntervalSince1970: 1_700_000_000))

        let unknown = RemoteFileBrowserStore.item(
            SSHSFTPEntry(name: ".cache", status: SSHSFTPFileStatus(kind: nil, size: nil, modificationTime: nil)),
            in: "/")
        #expect(unknown.path == "/.cache")
        #expect(unknown.kind == .other)
        #expect(unknown.isHidden)
    }

    @Test func turnsSFTPStatusesIntoReadableRefusals() {
        let denied = RemoteFileError.adapting(SSHError.sftpFailure(status: 3))
        #expect(denied as? RemoteFileError == .server(status: 3))
        #expect(RemoteFileBrowserStore.message(for: denied) == "Permission denied.")

        let other = RemoteFileError.adapting(SSHError.timedOut)
        #expect(other as? SSHError == .timedOut)
    }

    @Test func describesTransferProgress() {
        let partial = RemoteFileBrowserStore.progressText(
            verb: "Uploading", name: "a.zip", done: 1_000_000, total: 4_000_000)
        #expect(partial.hasPrefix("Uploading a.zip… "))
        #expect(partial.contains(" of "))
        let unknownTotal = RemoteFileBrowserStore.progressText(
            verb: "Downloading", name: "b", done: 10, total: nil)
        #expect(!unknownTotal.contains(" of "))
    }
}

@MainActor
@Suite("Direct SSH sessions")
struct DirectSSHSessionsTests {
    private static let mac = Host(name: "Mac", address: "mac.local", username: "dev")
    private static let pi = Host(name: "Pi", address: "pi.local", username: "pi")

    /// Sessions whose connections are never dialed: a shell starts only once
    /// its terminal reports a size, which no view does here.
    private func makeSessions() -> DirectSSHSessions {
        DirectSSHSessions { host in
            DirectSSHSession(host: host) { throw TransportError.cancelled }
        }
    }

    @Test func opensSessionsInFrontAndNumbersThemPerHost() {
        let sessions = makeSessions()
        let first = sessions.open(Self.mac)
        let second = sessions.open(Self.mac)
        let other = sessions.open(Self.pi)

        #expect(sessions.tabs.map(\.title) == ["Mac", "Mac (2)", "Pi"])
        #expect(sessions.selected?.id == other.id)
        #expect(sessions.isPresented)
        #expect(first.store.attachTarget != second.store.attachTarget)
        if case .loginShell = first.store.attachTarget {} else {
            Issue.record("A session must attach to a login shell")
        }
    }

    @Test func hidingKeepsEverySessionAndShowBringsOneBack() {
        let sessions = makeSessions()
        let first = sessions.open(Self.mac)
        sessions.open(Self.pi)

        sessions.hide()
        #expect(!sessions.isPresented)
        #expect(sessions.tabs.count == 2)

        sessions.show(first.id)
        #expect(sessions.isPresented)
        #expect(sessions.selected?.id == first.id)
    }

    @Test func closingTheFrontSessionBringsItsNeighbourForward() {
        let sessions = makeSessions()
        let first = sessions.open(Self.mac)
        let middle = sessions.open(Self.mac)
        let last = sessions.open(Self.pi)

        sessions.select(middle.id)
        sessions.close(middle.id)
        #expect(sessions.tabs.map(\.id) == [first.id, last.id])
        #expect(sessions.selected?.id == last.id)

        sessions.close(last.id)
        #expect(sessions.selected?.id == first.id)
        #expect(sessions.isPresented)
    }

    @Test func closingTheLastSessionHidesTheScreen() {
        let sessions = makeSessions()
        sessions.open(Self.mac)
        sessions.open(Self.pi)

        sessions.closeAll()
        #expect(sessions.tabs.isEmpty)
        #expect(sessions.selected == nil)
        #expect(!sessions.isPresented)
    }

    @Test func aNewSessionNumbersPastTheHighestStillOpen() {
        let sessions = makeSessions()
        let first = sessions.open(Self.mac)
        sessions.open(Self.mac)
        sessions.close(first.id)

        #expect(sessions.open(Self.mac).title == "Mac (3)")
    }

    @Test func describesEachShellState() {
        #expect(DirectSSHSessionRow.statusText(.live) == "Connected")
        #expect(DirectSSHSessionRow.statusText(.connecting) == "Connecting")
        #expect(DirectSSHSessionRow.statusText(.reconnecting) == "Reconnecting")
        #expect(DirectSSHSessionRow.statusText(.ended("gone")) == "Disconnected")
        #expect(DirectSSHSessionRow.statusText(.finished) == "Shell ended")
    }

    @Test func theShellDockOffersSnippetsOnlyWhenAsked() {
        #expect(ShellTerminalKeysDock.tabs == [.controls, .appearance])
        #expect(ShellTerminalKeysDock.tabsWithSnippets == [.controls, .snippets, .appearance])
    }
}
