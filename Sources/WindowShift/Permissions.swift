import AppKit
import ApplicationServices

enum Permissions {
    static var trusted: Bool { AXIsProcessTrusted() }

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
