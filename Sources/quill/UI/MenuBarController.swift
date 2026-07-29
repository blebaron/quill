import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let timerFont: NSFont

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let defaultFont = statusItem.button?.font ?? NSFont.menuBarFont(ofSize: 0)
        timerFont = NSFont.monospacedDigitSystemFont(ofSize: defaultFont.pointSize, weight: .regular)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, openFolder, quit] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            button.image = Self.featherOutlineImage()
            button.imagePosition = .imageLeft
        }
    }

    /// Reflect recording state in the icon and button title, and menu item
    /// titles. While recording, the elapsed counter is shown directly on the
    /// status bar button (not just the menu's state label) and the feather
    /// switches to a filled, red variant, so the "on" state is visible
    /// without opening the dropdown. Call once a second while recording.
    ///
    /// The red comes from baking the color into the image itself rather than
    /// `NSStatusBarButton.contentTintColor` — as of macOS 26 that property is
    /// silently ignored (confirmed with a plain SF Symbol image, Bartender
    /// running and quit), so a template image tinted that way just renders
    /// in the system's flat monochrome menu bar color instead.
    ///
    /// The title uses a monospaced-digit font and a padding space on each
    /// side: the system font's proportional digits (e.g. "1" narrower than
    /// "8") otherwise change the button's fitting width on almost every tick,
    /// which shoves every status item to its left over by a pixel or two —
    /// a constant "bounce" for as long as a recording runs.
    func update(recording: Bool, elapsed: String?) {
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        if let button = statusItem.button {
            button.font = timerFont
            button.title = recording ? " \(elapsed ?? "0:00") " : ""
            button.image = recording ? Self.featherFilledRedImage() : Self.featherOutlineImage()
        }
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    // Inlined Lucide feather SVGs (outline while idle, filled red while
    // recording — a shape change reads as "on" more strongly than a tint
    // alone). Keeping them in source means the executable has no separate
    // resource bundle to install alongside it — true single-binary.
    private static let featherOutlineSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    // Fill/stroke is baked in as an explicit red (not "currentColor") since
    // this image is deliberately not a template image — see `update`.
    private static let featherFilledRedSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="#ff3b30" stroke="#ff3b30" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    </svg>
    """

    private static func featherOutlineImage() -> NSImage? {
        let image = image(fromSVG: featherOutlineSVG)
        image?.isTemplate = true
        return image
    }

    private static func featherFilledRedImage() -> NSImage? {
        image(fromSVG: featherFilledRedSVG)
    }

    private static func image(fromSVG svg: String) -> NSImage? {
        guard let data = svg.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
}
