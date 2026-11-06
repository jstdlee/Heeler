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
