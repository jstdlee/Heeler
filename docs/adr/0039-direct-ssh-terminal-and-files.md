---
status: accepted
---

# Direct SSH: a login shell and SFTP files on any saved Host

Heeler reached a Host only through herdr: Agents, herdr Panes and herdr's
Shell Terminal. Using the same phone for plain SSH work on the same machines
meant a second app (Termius, Blink) holding a second copy of the Hosts,
routes and keys. We decided every saved Host also offers **SSH Terminal** and
**Files** from its Hosts row, Termius-style, outside herdr.

- **Terminal.** A new attach target, `loginShell`, opens a PTY that runs the
  account's login shell (`"${SHELL:-/bin/sh}" -l`) under `/bin/sh`, on the
  existing attach pipeline: the same bootstrap marker drops account-shell
  chatter, the same pumps carry input, resize and paste review, and
  `ShellTerminalView` renders it with libghostty. The branch comes before any
  herdr socket or API call, so it works on a Host with no herdr at all. The
  shell is not `exec`ed and the wrapper exits 0: a shell exits with its last
  command's status, and ending it is a normal end, not a failed attach.
- **Files.** One SFTP channel per operation on the same connection: list
  (first 1,000 entries, folders first), open a link, download to a protected
  temporary file shown in Quick Look, upload from Files under a staging name
  then rename, new folder, rename and delete. Uploads and renames never
  replace an existing item; delete removes files, links and empty folders
  only, since SFTP has no recursive delete and the browser does not fake one.
  `HeelerSSH` gained `removeDirectory` for this.
- **Trust and credentials.** A Direct SSH connection dials with the Host's
  own routes and credentials and the Console's rule: only a host key already
  trusted for that Host is accepted, and it never prompts. One connection per
  open screen, closed with the screen; a dropped line is redialed by the next
  request, which starts a new shell.
- **Scope.** POSIX Hosts only; a native Windows Host says the feature is
  unavailable. No port forwarding, agent forwarding, snippets or tabs of
  sessions: those stay Termius territory until asked for.

## Consequences

- Heeler is now a general SSH client for saved Hosts. The Device Key already
  allowed a full login (its `authorized_keys` line is unrestricted, ADR 0007);
  the app now offers that shell directly, so physical access to an unlocked
  phone reaches a shell on every saved Host.
- A Host added only for SSH still goes through Host detail once, to confirm
  its host key; its herdr checks may fail without blocking Direct SSH.
