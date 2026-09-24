// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Custom views for the status-item menu (Caffeinated-style): a header with
/// an on/off switch, modifier-key chip toggles, icon setting rows, section
/// headers with a collapse chevron, and an About/Quit footer row.

let menuWidth: CGFloat = 280

// MARK: - Custom switch (NSSwitch renders desaturated inside menu windows,
// which never become "active"; drawing it ourselves guarantees accent color)

final class SwitchButton: NSButton {
    var isOnSwitch = false { didSet { needsDisplay = true } }
    var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func clicked() {
        isOnSwitch.toggle()
        onToggle?(isOnSwitch)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: bounds.height / 2, yRadius: bounds.height / 2
        )
        (isOnSwitch ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.25)).setFill()
        track.fill()

        let knobDiameter = bounds.height - 4
        let knobX = isOnSwitch ? bounds.width - knobDiameter - 2 : 2
        let knob = NSBezierPath(ovalIn: NSRect(x: knobX, y: 2, width: knobDiameter, height: knobDiameter))
        NSColor.white.setFill()
        knob.fill()
    }
}

// MARK: - Header: app name + on/off switch

final class MenuHeaderView: NSView {
    let toggle = SwitchButton()
    private let titleLabel = NSTextField(labelWithString: "WindowShift")
    var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 40))
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.frame = NSRect(x: 14, y: 12, width: 180, height: 17)
        addSubview(titleLabel)

        toggle.setFrameOrigin(NSPoint(x: menuWidth - 14 - toggle.frame.width, y: 9))
        toggle.onToggle = { [weak self] on in self?.onToggle?(on) }
        addSubview(toggle)
    }

    required init?(coder: NSCoder) { fatalError("unused") }
}

// MARK: - Wrapping caption row (status / gesture description)

final class WrappingTextView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let width: CGFloat

    init(width: CGFloat = menuWidth) {
        self.width = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func setText(_ text: String, color: NSColor = .secondaryLabelColor) {
        label.textColor = color
        label.stringValue = text
        let inset: CGFloat = 14
        let textWidth = width - inset * 2
        let height = label.cell!.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)
        ).height
        label.frame = NSRect(x: inset, y: 6, width: textWidth, height: height)
        setFrameSize(NSSize(width: width, height: height + 12))
    }

    /// Convenience for submenu description headers.
    static func description(_ text: String, width: CGFloat = OptionRowView.rowWidth) -> WrappingTextView {
        let view = WrappingTextView(width: width)
        view.setText(text)
        return view
    }
}

// MARK: - Section header: small gray title, optional collapse chevron

final class SectionHeaderView: NSView {
    private let label: NSTextField
    private let chevron = NSButton()
    private let collapsible: Bool
    var onToggleCollapse: (() -> Void)?

    init(title: String, collapsible: Bool) {
        self.label = NSTextField(labelWithString: title)
        self.collapsible = collapsible
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 26))

        label.font = .boldSystemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 6, width: 200, height: 14)
        addSubview(label)

        if collapsible {
            chevron.isBordered = false
            chevron.imagePosition = .imageOnly
            chevron.frame = NSRect(x: menuWidth - 34, y: 3, width: 20, height: 20)
            chevron.contentTintColor = .secondaryLabelColor
            chevron.target = self
            chevron.action = #selector(chevronClicked)
            addSubview(chevron)
            setExpanded(false)

            let overlay = NSButton(frame: NSRect(x: 0, y: 0, width: menuWidth - 36, height: 26))
            overlay.isBordered = false
            overlay.isTransparent = true
            overlay.title = ""
            overlay.target = self
            overlay.action = #selector(chevronClicked)
            addSubview(overlay)
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func setExpanded(_ expanded: Bool) {
        guard collapsible else { return }
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: expanded ? "Collapse" : "Expand"
        )
    }

    @objc private func chevronClicked() {
        onToggleCollapse?()
    }
}

// MARK: - Modifier chips row

final class ChipButton: NSButton {
    var isOnChip = false { didSet { needsDisplay = true } }
    var onToggle: ((ChipButton) -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        font = .systemFont(ofSize: 13, weight: .medium)
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func clicked() {
        onToggle?(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2 - 1
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        (isOnChip ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.12)).setFill()
        pill.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: isOnChip ? NSColor.white : NSColor.labelColor,
        ]
        let text = NSAttributedString(string: title, attributes: attrs)
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

final class ModifierChipsView: NSView {
    private(set) var chips: [ChipButton] = []
    var onToggle: ((String) -> Void)?

    init(choices: [(title: String, name: String)]) {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 38))
        let chipWidth: CGFloat = 42
        let spacing: CGFloat = 8
        var x: CGFloat = 14
        for choice in choices {
            let chip = ChipButton(title: choice.title)
            chip.frame = NSRect(x: x, y: 6, width: chipWidth, height: 26)
            chip.identifier = NSUserInterfaceItemIdentifier(choice.name)
            chip.onToggle = { [weak self] c in
                if let name = c.identifier?.rawValue { self?.onToggle?(name) }
            }
            addSubview(chip)
            chips.append(chip)
            x += chipWidth + spacing
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }
}

// MARK: - Setting row: round icon badge + label, whole row clickable

final class SettingRowView: NSView {
    private let iconBadge = NSImageView()
    private let label: NSTextField
    var isOn = false { didSet { refreshTint() } }
    var onClick: (() -> Void)?

    init(title: String, symbol: String, subtitle: String? = nil, showsSubmenuChevron: Bool = false) {
        self.label = NSTextField(labelWithString: title)
        let height: CGFloat = subtitle == nil ? 34 : 46
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: height))

        iconBadge.frame = NSRect(x: 14, y: (height - 24) / 2, width: 24, height: 24)
        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = 12
        iconBadge.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        iconBadge.contentTintColor = .white
        addSubview(iconBadge)

        label.font = .systemFont(ofSize: 13)
        label.frame = NSRect(x: 48, y: subtitle == nil ? 9 : 24, width: menuWidth - 62, height: 17)
        addSubview(label)

        if let subtitle {
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = .systemFont(ofSize: 10.5)
            sub.textColor = .secondaryLabelColor
            sub.lineBreakMode = .byTruncatingTail
            sub.frame = NSRect(x: 48, y: 8, width: menuWidth - 62, height: 14)
            addSubview(sub)
        }

        if showsSubmenuChevron {
            // Submenu opens on hover (menu tracking handles it); the chevron
            // is a visual affordance, no click overlay needed.
            let chevron = NSImageView(frame: NSRect(x: menuWidth - 30, y: height / 2 - 8, width: 16, height: 16))
            chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            chevron.contentTintColor = .secondaryLabelColor
            addSubview(chevron)
        } else {
            let overlay = NSButton(frame: bounds)
            overlay.isBordered = false
            overlay.isTransparent = true
            overlay.title = ""
            overlay.target = self
            overlay.action = #selector(clicked)
            addSubview(overlay)
        }

        refreshTint()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func clicked() {
        onClick?()
    }

    private func refreshTint() {
        iconBadge.layer?.backgroundColor =
            (isOn ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTint()
    }
}

// MARK: - Submenu option row: checkmark + label, click does NOT dismiss the
// menu (clicks inside view-backed items never auto-close menu tracking),
// so several options can be tried in one visit.

final class OptionRowView: NSView {
    static let rowWidth: CGFloat = 270
    private let check = NSImageView()
    private let label: NSTextField
    private let highlight = NSView()
    var isSelected = false { didSet { check.isHidden = !isSelected } }
    var onClick: (() -> Void)?

    init(title: String) {
        self.label = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 28))

        highlight.frame = NSRect(x: 5, y: 2, width: Self.rowWidth - 10, height: 24)
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 5
        addSubview(highlight)

        check.frame = NSRect(x: 13, y: 7, width: 14, height: 14)
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        check.contentTintColor = .labelColor
        check.isHidden = true
        addSubview(check)

        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 33, y: 6, width: Self.rowWidth - 46, height: 17)
        addSubview(label)

        let overlay = NSButton(frame: bounds)
        overlay.isBordered = false
        overlay.isTransparent = true
        overlay.title = ""
        overlay.target = self
        overlay.action = #selector(clicked)
        addSubview(overlay)

        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func clicked() {
        onClick?()
    }

    override func mouseEntered(with event: NSEvent) {
        highlight.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        highlight.layer?.backgroundColor = nil
    }
}

// MARK: - Footer: About left, Quit right, with icons

final class AboutQuitRowView: NSView {
    var onAbout: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 34))

        let about = NSButton(
            title: " About",
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About")!,
            target: self, action: #selector(aboutClicked)
        )
        about.isBordered = false
        about.imagePosition = .imageLeading
        about.font = .systemFont(ofSize: 13)
        about.sizeToFit()
        about.setFrameOrigin(NSPoint(x: 14, y: (34 - about.frame.height) / 2))
        addSubview(about)

        let quit = NSButton(
            title: " Quit",
            image: NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")!,
            target: self, action: #selector(quitClicked)
        )
        quit.isBordered = false
        quit.imagePosition = .imageLeading
        quit.font = .systemFont(ofSize: 13)
        quit.sizeToFit()
        quit.setFrameOrigin(NSPoint(x: menuWidth - 14 - quit.frame.width, y: (34 - quit.frame.height) / 2))
        addSubview(quit)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func aboutClicked() {
        onAbout?()
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}
