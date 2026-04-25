import AppKit
import AVFoundation
@preconcurrency import ApplicationServices

@Observable
@MainActor
final class PermissionManager {
    private(set) var accessibilityGranted: Bool = false
    private(set) var microphoneGranted: Bool = false

    init() {
        refresh()
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: Accessibility

    /// Opens System Settings to the Accessibility pane so the user can grant access.
    func requestAccessibility() {
        let options: [String: Any] = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        refresh()
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Microphone

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
