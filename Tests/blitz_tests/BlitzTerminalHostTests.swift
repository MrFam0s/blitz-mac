import Foundation
import AppKit
import SwiftTerm
import Testing
@testable import Blitz

@Test func shellChildrenOwnForegroundTTY() async throws {
    let fileManager = FileManager.default
    let zdotdir = fileManager.temporaryDirectory
        .appendingPathComponent("blitz-terminal-host-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: zdotdir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: zdotdir) }

    let callbackQueue = DispatchQueue(label: "blitz.terminal.tests")
    let delegate = PTYProbeDelegate()
    let process = BlitzPTYProcess(delegate: delegate, dispatchQueue: callbackQueue)

    let command = #"/usr/bin/python3 -c "import os, sys; print(f'{os.getpgrp()} {os.tcgetpgrp(0)}'); sys.stdout.flush()""#
    let environment = [
        "HOME=\(zdotdir.path)",
        "ZDOTDIR=\(zdotdir.path)",
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
        "TERM=xterm-256color",
        "PS1=",
        "PROMPT=",
        "RPROMPT=",
        "LC_ALL=C",
    ]

    process.startProcess(
        executable: "/bin/zsh",
        // `-i` makes this test depend on runner-specific interactive startup behavior.
        // The PTY contract we care about is narrower: a shell-launched child should own
        // the foreground TTY process group regardless of startup files.
        args: ["-fc", command],
        environment: environment,
        execName: "-zsh"
    )
    defer { process.terminate() }

    for _ in 0..<500 {
        if delegate.didTerminate {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    let snapshot = delegate.snapshot
    #expect(delegate.didTerminate)
    #expect(snapshot.exitCode == 0)

    let numericLines = snapshot.output
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .compactMap { line -> (Int32, Int32)? in
            let numbers = line
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int32($0) }
            guard numbers.count >= 2 else { return nil }
            return (numbers[0], numbers[1])
        }

    let lastPair = try #require(numericLines.last)
    #expect(lastPair.0 == lastPair.1)
}

@Test func navigationKeysStripNumericPadFlagBeforeSwiftTermEncoding() {
    let flags: NSEvent.ModifierFlags = [.numericPad, .shift]
    let normalized = BlitzTerminalView.normalizedModifierFlags(
        for: 125,
        modifierFlags: flags,
        charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!)
    )

    #expect(normalized.contains(.shift))
    #expect(!normalized.contains(.numericPad))
}

@Test func keypadDigitRetainsNumericPadFlag() {
    let flags: NSEvent.ModifierFlags = [.numericPad]
    let normalized = BlitzTerminalView.normalizedModifierFlags(
        for: 84,
        modifierFlags: flags,
        charactersIgnoringModifiers: "2"
    )

    #expect(normalized.contains(.numericPad))
}

@Test func terminalFocusSequencesAreSuppressed() {
    #expect(BlitzTerminalView.shouldSuppressTerminalGeneratedSequence([0x1b, 0x5b, 0x49][...]))
    #expect(BlitzTerminalView.shouldSuppressTerminalGeneratedSequence([0x1b, 0x5b, 0x4f][...]))
    #expect(!BlitzTerminalView.shouldSuppressTerminalGeneratedSequence([0x1b, 0x5b, 0x41][...]))
}

@Test func terminateSignalsEntireProcessGroup() async throws {
    let fileManager = FileManager.default
    let tempDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("blitz-terminal-terminate-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDirectory) }

    let pidFile = tempDirectory.appendingPathComponent("child.pid")
    let callbackQueue = DispatchQueue(label: "blitz.terminal.terminate.tests")
    let delegate = PTYProbeDelegate()
    let process = BlitzPTYProcess(delegate: delegate, dispatchQueue: callbackQueue)

    let command = "sleep 30 & echo $! > \(shellQuote(pidFile.path)); wait"
    process.startProcess(
        executable: "/bin/sh",
        args: ["-c", command],
        environment: [
            "HOME=\(tempDirectory.path)",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM=xterm-256color",
        ],
        execName: "/bin/sh"
    )

    let childPid = try await waitForChildPID(at: pidFile)
    #expect(processIsLive(childPid))

    process.terminate()

    try await waitForExit(of: process, delegate: delegate)
    try await waitForExitOrZombie(of: childPid)
}

private func waitForChildPID(at fileURL: URL) async throws -> pid_t {
    for _ in 0..<500 {
        if let contents = try? String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(contents) {
            return pid
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    throw NSError(domain: "BlitzTerminalHostTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Timed out waiting for child PID"
    ])
}

private func waitForExit(of process: BlitzPTYProcess, delegate: PTYProbeDelegate) async throws {
    for _ in 0..<500 {
        if !process.isRunning || delegate.didTerminate {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    throw NSError(domain: "BlitzTerminalHostTests", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "Timed out waiting for PTY process exit"
    ])
}

private func waitForExitOrZombie(of pid: pid_t) async throws {
    for _ in 0..<500 {
        if !processIsLive(pid) {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    throw NSError(domain: "BlitzTerminalHostTests", code: 3, userInfo: [
        NSLocalizedDescriptionKey: "Timed out waiting for child process termination (\(processDebugInfo(pid) ?? "unknown"))"
    ])
}

private func processIsLive(_ pid: pid_t) -> Bool {
    guard let status = processStatus(pid) else {
        return false
    }
    return !status.hasPrefix("Z")
}

private func processStatus(_ pid: pid_t) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "stat=", "-p", String(pid)]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return nil
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        return nil
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private func processDebugInfo(_ pid: pid_t) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "pid=,ppid=,pgid=,tpgid=,stat=,command=", "-p", String(pid)]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return nil
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        return nil
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private final class PTYProbeDelegate: BlitzPTYProcessDelegate {
    private let lock = NSLock()
    private var collectedOutput = Data()
    private var observedTermination = false
    private var observedExitCode: Int32?

    var didTerminate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedTermination
    }

    var snapshot: (output: String, exitCode: Int32?) {
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: collectedOutput, as: UTF8.self), observedExitCode)
    }

    func terminalProcess(_ process: BlitzPTYProcess, didReceive data: ArraySlice<UInt8>) {
        lock.lock()
        collectedOutput.append(contentsOf: data)
        lock.unlock()
    }

    func terminalProcess(_ process: BlitzPTYProcess, didTerminateWith exitCode: Int32?) {
        lock.lock()
        observedTermination = true
        observedExitCode = exitCode
        lock.unlock()
    }

    func windowSize(for process: BlitzPTYProcess) -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }
}


@MainActor @Test func terminalScrollbackRetainsOlderMessagesAndDoesNotJumpOnOutput() {
    let view = BlitzTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let output = (1...800).map { "message \($0)\r\n" }.joined()
    view.receiveOutput(Array(output.utf8)[...])
    #expect(view.canScroll)
    view.scroll(toPosition: 0)
    #expect(String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self).contains("message 1\n"))
    view.scroll(toPosition: 0.5)
    let row = view.getTerminal().getTopVisibleRow()
    view.receiveOutput(Array("new message\r\n".utf8)[...])
    #expect(view.getTerminal().getTopVisibleRow() == row)
    view.scrollWheel(deltaY: 3, precise: false, location: .zero)
    #expect(view.getTerminal().getTopVisibleRow() < row)
    view.scrollWheel(deltaY: -3, precise: false, location: .zero)
    #expect(view.getTerminal().getTopVisibleRow() == row)
    view.scroll(toPosition: 1)
    let bottom = view.getTerminal().getTopVisibleRow()
    view.receiveOutput(Array("follow new output\r\n".utf8)[...])
    #expect(view.getTerminal().getTopVisibleRow() > bottom)
}

@MainActor @Test func terminalWheelReachesFullScreenMouseApplications() {
    let view = BlitzTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let probe = TerminalInputProbe()
    view.terminalDelegate = probe
    view.feed(text: "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
    view.scrollWheel(deltaY: 1, precise: false, location: NSPoint(x: 0, y: 400))
    view.scrollWheel(deltaY: -1, precise: false, location: NSPoint(x: 0, y: 400))
    #expect(probe.output == "\u{1b}[<64;1;1M\u{1b}[<65;1;1M")
    probe.output = ""
    view.scrollWheel(deltaY: 1, precise: false, location: .zero, modifiers: .shift)
    #expect(probe.output.isEmpty)
}

@MainActor @Test func terminalTrackpadAccumulatesSmallDeltasAndSupportsKeyboardPaging() {
    let view = BlitzTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let probe = TerminalInputProbe()
    view.terminalDelegate = probe
    view.feed(text: "\u{1b}[?1049h")
    let cellHeight = view.getOptimalFrameSize().height / CGFloat(view.getTerminal().rows)
    view.scrollWheel(deltaY: cellHeight / 2, precise: true, location: .zero)
    #expect(probe.output.isEmpty)
    view.scrollWheel(deltaY: cellHeight / 2, precise: true, location: .zero)
    #expect(probe.output == "\u{1b}[5~")
    probe.output = ""
    view.scrollWheel(deltaY: -1, precise: false, location: .zero)
    #expect(probe.output == "\u{1b}[6~")
}

@MainActor @Test func terminalLegacyMouseWheelIsSafeInWideWindows() {
    let view = BlitzTerminalView(frame: NSRect(x: 0, y: 0, width: 5000, height: 400))
    let probe = TerminalInputProbe()
    view.terminalDelegate = probe
    view.feed(text: "\u{1b}[?1049h\u{1b}[?1000h")
    view.scrollWheel(deltaY: 1, precise: false, location: NSPoint(x: 4990, y: 400))
    #expect(!probe.output.isEmpty)
}

private final class TerminalInputProbe: TerminalViewDelegate {
    var output = ""
    func clipboardCopy(source: TerminalView, content: Data) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { output += String(decoding: data, as: UTF8.self) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor @Test func terminalScrollRoutingExcludesInactiveHiddenAndOutsideViews() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let view = BlitzTerminalView(frame: container.bounds)
    container.addSubview(view)
    let point = NSPoint(x: 20, y: 20)
    #expect(view.acceptsScroll(at: point))
    #expect(!view.acceptsScroll(at: NSPoint(x: 900, y: 20)))
    view.isActiveForInput = false
    #expect(!view.acceptsScroll(at: point))
    view.isActiveForInput = true
    container.isHidden = true
    #expect(!view.acceptsScroll(at: point))
}
