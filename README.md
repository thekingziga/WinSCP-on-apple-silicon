# MacSCP

A native macOS dual-pane SFTP client, in Swift and SwiftUI. Started as an
attempt to port [WinSCP](https://github.com/winscp/winscp) to macOS.

## What this actually is

It is **not** a translation of WinSCP's source. That turned out not to be a
sensible thing to attempt, for reasons worth writing down.

WinSCP is ~332,000 lines of Embarcadero C++Builder code plus ~145,000 lines of
`.dfm` VCL form definitions. Measured on the current `master`:

| Area                | Lines   | Portable? |
|---------------------|---------|-----------|
| `source/packages`   | 126,014 | No — third-party VCL component libraries |
| `source/core`       |  76,572 | Partly — logic is sound, expression is not |
| `source/forms`      |  55,270 | No — VCL forms, plus 144,697 lines of `.dfm` |
| `source/windows`    |  32,391 | No — COM, registry, shell extensions |
| `source/filezilla`  |  19,447 | No — MFC (`CString`, `CAsyncSocket`) |
| `source/putty`      |  14,646 | Partly |

The blocker is not the UI, which is the obvious guess. It is that even the
"portable" engine is written in Embarcadero's C++ dialect against the Delphi
runtime. In `source/core` alone: `UnicodeString` appears 6,246 times,
`__fastcall` 5,291 times, and `TStrings`/`TStringList`/`TDateTime` around 950
more. Those are not `std::string` and `std::chrono` under different names —
`UnicodeString` has reference-counted copy-on-write semantics with no C++
equivalent. Clang cannot parse a meaningful fraction of that code, and no shim
makes it portable.

So this is a **reimplementation of WinSCP's design**, not its code: the
dual-pane model, the session data model, the transfer-mask semantics, and a
direct implementation of the same SFTP protocol WinSCP speaks.

## Architecture

```
Sources/SFTPKit/     SFTP protocol + transport   (replaces source/core + source/putty)
Sources/CoreKit/     Session model, masks, local FS
Sources/AppCore/     AppModel + TransferQueue — application state and behaviour
Sources/MacSCP/      SwiftUI views + @main       (replaces source/forms + source/packages)
```

`AppCore` is a library rather than part of the executable for a specific
reason: an executable target cannot be imported, so anything living there is
untestable. Keeping `AppModel` in a library means the tests drive the same
object the views are bound to. The views are deliberately thin — they read
published properties and call model methods, nothing more.

Two deliberate departures from WinSCP:

**SSH is delegated to the system OpenSSH client.** WinSCP links PuTTY in-process
to own the SSH layer. On macOS that buys nothing — the OS ships a maintained
OpenSSH. `SSHTransport` spawns `ssh -s sftp` and speaks the SFTP wire protocol
over its stdio pipes. The result is that `~/.ssh/config`, ssh-agent, hardware
keys, `ProxyJump`, and Keychain-stored passphrases all work without this app
containing a line of crypto or ever handling a secret. `SFTPClient` implements
the protocol itself — it is not a wrapper around the `sftp` command.

**The codec has no `import Foundation`.** `SFTPProtocol.swift`,
`SFTPPacket.swift`, and `Glob.swift` are Swift-stdlib-only. This is correct
layering — the SFTP grammar has nothing to do with Foundation's types — and it
has a practical payoff described below.

## Status

Builds clean, launches, and transfers files against a real SFTP server.
**234 checks passing.**

| Component | State |
|---|---|
| SFTP codec (framing, attributes, glob) | 67 checks |
| Session model, masks, local FS | 60 checks |
| SSH transport + client engine | 107 checks against live OpenSSH |
| `AppModel` (what the views are bound to) | covered by the live suite |
| SwiftUI views themselves | render only — **no automated UI interaction** |
| Directory (recursive) transfers | Implemented — symlinks skipped, not followed |
| Transfer queue with per-item cancel | Implemented |
| Drag and drop between panes | Implemented — engine path tested, the drag gesture itself is not |
| Resume interrupted transfers | Implemented, both directions |
| Overwrite protection | Implemented — conflicts wait for overwrite / resume / skip |
| Reconnect and resume on connection loss | Implemented |
| Transfer pipelining | 16 requests in flight |
| Password-only authentication | Not supported — key/agent only |
| FTP / FTPS / S3 / WebDAV | Not implemented — SFTP only |

The remaining honest gap is now narrow: `AppModel` is exercised end-to-end
against a real server — connect, navigate, upload, download, recursive folder
transfer, recursive delete, session persistence, and error logging all run in
the suite. What is *not* covered is SwiftUI itself: no test clicks a button or
types in a field. Since the views only read published properties and call model
methods, the untested surface is that binding layer.

## Building

```bash
./build.sh          # release; pass "debug" for a debug build
open build/MacSCP.app
```

`build.sh` assembles the `.app` bundle by hand around the SPM executable, since
there is no Xcode project here.

### Two things worth knowing about this toolchain

**Command Line Tools ships neither XCTest nor Swift Testing**, so `swift test`
cannot work without full Xcode. The suite is therefore a plain executable with
its own assertions:

```bash
swift run MacSCPTests     # 60 checks — codec bridge, masks, sessions, local FS
./Scripts/verify-codec.sh # 67 checks — compiles without Foundation at all
```

The second script exists because it survives a broken SDK. This machine's CLT
install was corrupt at one point — `Foundation/NSString.h` and
`IOKit/graphics/IOGraphicsTypes.h` were missing, so nothing importing Foundation
would compile. Keeping the codec Foundation-free meant it stayed testable
throughout. If that recurs, the fix needs admin rights:

```bash
sudo rm -rf /Library/Developer/CommandLineTools && sudo xcode-select --install
```

And against a real server — this one needs a host you can already `ssh` into:

```bash
swift run MacSCPLiveTest user@host [port] [ssh options...]
```

107 checks in two halves. First the engine directly: connect, REALPATH,
MKDIR/LIST/STAT, text and binary round-trips, non-ASCII filenames, RENAME,
SETSTAT, recursive upload/download/delete, symlink skipping, and error mapping.
Then `AppModel` — the object the SwiftUI views bind to — driven the way the UI
drives it: set a pane selection, call `uploadSelected()`, check the other pane
refreshed itself.

It also covers the queue: serial execution, cancelling a queued item, failure
and retry, resume from a partial file in both directions, the `enqueueTransfer`
path a pane drop calls, and overwrite protection — that an existing destination
raises a conflict, that nothing is written while the conflict is unresolved, and
that skip / overwrite / resume each do what they say.

Everything runs inside a temporary directory under the login directory and is
deleted afterwards; sessions are written to an injected store so your real
`sessions.json` is never touched. Add `MACSCP_BENCH_MB=48` for a throughput
measurement.

If you have no host handy, a throwaway sshd on localhost works and needs no
`sudo` — see `Scripts/local-sftp-server.sh`.

### Why transfers are pipelined

One chunk at a time costs a round trip per 32 KiB, capping throughput at
`chunk / RTT` regardless of bandwidth — about 320 KB/s on a 100 ms link.
Measured over loopback, where RTT is nearly zero and the effect is therefore
*understated*:

| Depth | Upload | Download |
|---|---|---|
| 1 (sequential) | 310 MiB/s | 308 MiB/s |
| 16 (current)   | 877 MiB/s | 785 MiB/s |

~2.6× even with no network latency to hide. On a real link the gap is far wider.

### Transfers never overwrite silently

A transfer whose destination already exists stops in a `conflict` state and
waits: overwrite, resume, or skip. Nothing is written until the question is
answered, and `clearFinished` deliberately keeps unresolved conflicts rather
than discarding the request. Directory transfers are the exception — the
per-file prompt is not implemented inside a recursive copy.

### Resume trusts existing bytes

Resuming a partial transfer restarts at the existing file's length and assumes
those bytes match the other side. SFTP offers no cheap way to verify that, and
WinSCP behaves the same way. A partial file left over from a *different* source
would therefore produce a silently corrupt result.

**Do not add an `NSApplicationDelegateAdaptor` to `MacSCPApp`.** An earlier
version had one calling `setActivationPolicy(.regular)` on the theory that an
SPM executable would otherwise launch without a window. That was wrong — the
bundle's `Info.plist` already makes it a regular app — and the redundant call
raced SwiftUI's own window setup. The result was a process that ran, laid out
its views, and created a correctly-sized window that was never ordered on
screen: `onscreen=false`, no error anywhere. Removing the delegate fixed it.

## If you just want WinSCP working today

CrossOver is already installed on this machine and WinSCP runs under it — that
remains the fastest path to the real application, and nothing in this repo
changes that.
