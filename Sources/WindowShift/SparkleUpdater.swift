// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

#if SPARKLE
import AppKit
import Combine
import Sparkle
import SwiftUI

/// The Sparkle updater, alive for the whole run of the app.
///
/// Only `./build.sh --sparkle` builds compile this file: the App Store build never
/// links Sparkle, so everything Sparkle-related in the app sits behind `#if SPARKLE`.
/// Creating the shared instance starts the updater. Because that build writes
/// SUEnableAutomaticChecks into Info.plist, Sparkle checks for an update shortly
/// after launch — without first asking permission — and then once a day.
@MainActor
final class SparkleUpdater: ObservableObject {
    static let shared = SparkleUpdater()

    /// False while a check is already in progress, so menu items can disable themselves.
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Call once early in launch: the App's `init`, or `applicationDidFinishLaunching`.
    static func start() {
        _ = shared
    }

    /// A user-initiated check, with Sparkle's own progress and result UI.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// "Check for Updates…" for menus built by hand, such as a status-item menu.
    /// Sparkle validates it through the controller, greying it out mid-check.
    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…",
                              action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                              keyEquivalent: "")
        item.target = controller
        return item
    }

    /// "Check for Updates…" as a push button, for a settings pane built in AppKit.
    /// Disabled while a check is already running, like the menu item.
    func makeButton() -> NSButton {
        let button = UpdaterButton(title: "Check for Updates…", target: controller,
                                   action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)))
        button.subscription = $canCheckForUpdates.sink { [weak button] enabled in
            MainActor.assumeIsolated { button?.isEnabled = enabled }
        }
        return button
    }

    /// An NSButton that owns the subscription keeping its enabled state current.
    private final class UpdaterButton: NSButton {
        var subscription: AnyCancellable?
    }
}

/// "Check for Updates…" directly under "About <App>" in the application menu.
/// Add it to the App's `.commands { }` block.
struct SparkleCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            SparkleCheckForUpdatesButton()
        }
    }
}

/// The same "Check for Updates…" as a plain SwiftUI button, for apps whose menu
/// is a SwiftUI view: a `MenuBarExtra`, or a group that already replaces `.appInfo`.
struct SparkleCheckForUpdatesButton: View {
    @ObservedObject private var updater = SparkleUpdater.shared

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
#endif
