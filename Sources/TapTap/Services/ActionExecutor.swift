import AppKit
import CoreGraphics
import Darwin
import Foundation

@MainActor
final class ActionExecutor {
    /// Execute the action bound to a gesture. Runs asynchronously so the gesture
    /// pipeline stays responsive. Logs success/failure via the provided logger.
    func execute(_ binding: GestureBinding, logger: EventLogger) async {
        let label = "\(binding.gesture.displayName) → \(binding.actionType.displayName): \(binding.value)"
        do {
            switch binding.actionType {
            case .shortcut: try await runShortcut(named: binding.value)
            case .shell:    try await runShell(binding.value)
            case .app:      try openApp(at: binding.value)
            case .media:    try await sendMediaCommand(binding.value)
            case .system:   try await runSystemCommand(binding.value)
            case .url:      try openURL(binding.value)
            }
            logger.log("✓ \(label)", kind: .execution)
        } catch {
            logger.log("✗ \(label) — \(error.localizedDescription)", kind: .error)
        }
    }

    /// Public entry point for manual testing from the UI.
    func testAction(_ binding: GestureBinding, logger: EventLogger) async {
        await execute(binding, logger: logger)
    }

    // MARK: - Shortcut

    private func runShortcut(named name: String) async throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ActionError.emptyValue("Shortcut name is empty")
        }
        try await runProcess("/usr/bin/shortcuts", arguments: ["run", name])
    }

    // MARK: - Shell

    private func runShell(_ command: String) async throws {
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ActionError.emptyValue("Shell command is empty")
        }
        try await runProcess("/bin/zsh", arguments: ["-c", command])
    }

    // MARK: - App launch

    private func openApp(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw ActionError.notFound("App not found at \(path)")
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Media

    /// Sends a media command.
    ///
    /// Play/pause, next, and previous are dispatched via `MRMediaRemoteSendCommand`
    /// from the private MediaRemote framework — the only reliable path on macOS 12+.
    /// Volume is adjusted with a simple AppleScript `set volume` command so it works
    /// independently of which app is playing audio.
    private func sendMediaCommand(_ rawValue: String) async throws {
        guard let cmd = MediaCommand(rawValue: rawValue) else {
            throw ActionError.unknown("Unknown media command: \(rawValue)")
        }
        switch cmd {
        case .playPause: sendMediaRemote(command: 2)   // kMRTogglePlayPause
        case .next:      sendMediaRemote(command: 4)   // kMRNextTrack
        case .previous:  sendMediaRemote(command: 5)   // kMRPreviousTrack
        case .volumeUp:
            try await runProcess("/usr/bin/osascript", arguments: [
                "-e", "set v to output volume of (get volume settings)",
                "-e", "set v to v + 10",
                "-e", "if v > 100 then set v to 100",
                "-e", "set volume output volume v"
            ])
        case .volumeDown:
            try await runProcess("/usr/bin/osascript", arguments: [
                "-e", "set v to output volume of (get volume settings)",
                "-e", "set v to v - 10",
                "-e", "if v < 0 then set v to 0",
                "-e", "set volume output volume v"
            ])
        }
    }

    /// Dispatches a media command through the MediaRemote private framework.
    ///
    /// The framework is loaded lazily on first use and kept open for the lifetime of
    /// the process.  If the symbol is unavailable the call is silently a no-op.
    private func sendMediaRemote(command: Int) {
        // Lazy open — harmless if called multiple times; the OS caches the handle.
        if Self.mediaRemoteHandle == nil {
            Self.mediaRemoteHandle = dlopen(
                "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                RTLD_NOW
            )
        }
        guard let handle = Self.mediaRemoteHandle,
              let sym    = dlsym(handle, "MRMediaRemoteSendCommand") else { return }
        typealias MRSendCommand = @convention(c) (Int, AnyObject?) -> Bool
        _ = unsafeBitCast(sym, to: MRSendCommand.self)(command, nil)
    }

    // nonisolated static so dlopen is called at most once per process.
    private static var mediaRemoteHandle: UnsafeMutableRawPointer? = nil

    // MARK: - System actions

    private func runSystemCommand(_ rawValue: String) async throws {
        guard let cmd = SystemCommand(rawValue: rawValue) else {
            throw ActionError.unknown("Unknown system command: \(rawValue)")
        }
        switch cmd {
        case .lockScreen:
            // ⌃⌘Q — lock screen shortcut
            postKeyEvent(keyCode: 0x0C, flags: [.maskControl, .maskCommand])

        case .sleepDisplay:
            try await runProcess("/usr/bin/pmset", arguments: ["displaysleepnow"])

        case .toggleMute:
            try await runProcess("/usr/bin/osascript", arguments: [
                "-e", "set volume output muted not (output muted of (get volume settings))"
            ])

        case .toggleDarkMode:
            try await runProcess("/usr/bin/osascript", arguments: [
                "-e",
                "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
            ])

        case .screenshotFull:
            let desktop = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop")
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd at HH.mm.ss"
            let path = desktop.appendingPathComponent("Screenshot \(formatter.string(from: Date())).png").path
            try await runProcess("/usr/sbin/screencapture", arguments: ["-x", path])

        case .screenshotRegion:
            // ⇧⌘4 — system interactive screenshot selector
            postKeyEvent(keyCode: 0x15, flags: [.maskShift, .maskCommand])

        case .missionControl:
            try await runProcess("/usr/bin/open", arguments: ["-a", "Mission Control"])

        case .launchpad:
            try await runProcess("/usr/bin/open", arguments: ["-a", "Launchpad"])

        case .emptyTrash:
            try await runProcess("/usr/bin/osascript", arguments: [
                "-e", "tell application \"Finder\" to empty trash"
            ])

        case .doNotDisturb:
            // Clicks the Focus item in the menu-bar Control Center (macOS 12+)
            try await runProcess("/usr/bin/osascript", arguments: [
                "-e",
                "tell application \"System Events\" to tell process \"ControlCenter\" to click menu bar item \"Focus\" of menu bar 1"
            ])

        case .copy:            postKeyEvent(keyCode: 0x08, flags: .maskCommand)             // ⌘C
        case .paste:           postKeyEvent(keyCode: 0x09, flags: .maskCommand)             // ⌘V
        case .undo:            postKeyEvent(keyCode: 0x06, flags: .maskCommand)             // ⌘Z
        case .redo:            postKeyEvent(keyCode: 0x06, flags: [.maskCommand, .maskShift]) // ⌘⇧Z
        case .previousDesktop: postKeyEvent(keyCode: 0x7B, flags: .maskControl)             // ⌃←
        case .nextDesktop:     postKeyEvent(keyCode: 0x7C, flags: .maskControl)             // ⌃→
        case .spotlight:       postKeyEvent(keyCode: 0x31, flags: .maskCommand)             // ⌘Space
        case .nextTab:         postKeyEvent(keyCode: 0x30, flags: .maskControl)             // ⌃⇥
        case .previousTab:     postKeyEvent(keyCode: 0x30, flags: [.maskControl, .maskShift]) // ⌃⇧⇥
        }
    }

    // MARK: - URL

    private func openURL(_ raw: String) throws {
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ActionError.emptyValue("URL is empty")
        }
        guard let url = URL(string: raw) else {
            throw ActionError.unknown("Invalid URL: \(raw)")
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Key event helpers

    /// Posts a regular keyboard key-down + key-up pair via CGEvent.
    private func postKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Process helper

    private func runProcess(_ path: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ActionError.processExited(Int(p.terminationStatus)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum ActionError: LocalizedError {
    case emptyValue(String)
    case notFound(String)
    case processExited(Int)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .emptyValue(let m):    m
        case .notFound(let m):      m
        case .processExited(let c): "Process exited with code \(c)"
        case .unknown(let m):       m
        }
    }
}
