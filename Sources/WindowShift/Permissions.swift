// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import ApplicationServices

enum Permissions {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Screen Recording. WindowShift never captures anything — this is the
    /// grant macOS checks before one process may drive ANOTHER app's windows,
    /// which is exactly what the window-server drag call does. Without it the
    /// call reports success and the window sits still, so moves fall back to
    /// Accessibility writes and lose tiling and snap-app integration.
    ///
    /// Cached, because the check is a TCC round trip and the menu consults it
    /// on every open; `refreshScreenRecording()` drops the cache.
    private static let lock = NSLock()
    private static var cached: Bool?

    static var screenRecordingGranted: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let granted = CGPreflightScreenCaptureAccess()
        cached = granted
        return granted
    }

    static func refreshScreenRecording() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// Ask for it. macOS shows its own alert the first time and thereafter
    /// only lists the app in Settings, so open the pane too.
    static func requestScreenRecording() {
        refreshScreenRecording()
        if CGRequestScreenCaptureAccess() { return }
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Prompt (once) and poll until the Accessibility grant appears, then call
    /// back on the main thread. TCC caches lag a settings toggle by a few
    /// hundred ms, so wait a beat after trust flips before starting the tap.
    static func waitUntilTrusted(then callback: @escaping () -> Void) {
        if trusted {
            callback()
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if trusted {
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: callback)
            }
        }
    }
}
