import Cocoa

// Non-activating panel so clicking a row (or dragging the window) never steals focus from the
// terminal/editor you're watching — the app is an .accessory agent and must stay invisible to
// Cmd-Tab. canBecomeKey stays false so keystrokes keep going to whatever is actually frontmost.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Always-on-top translucent window listing every session the dropdown would show, live-updated
// from the same tick as the menu bar icon. Toggled from the "Overlay window" row in the menu.
final class OverlayController: NSObject {
    private weak var owner: StatusController?
    private var panel: OverlayPanel?
    private let effect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Sessions")
    private let emptyLabel = NSTextField(labelWithString: "No active sessions")
    private let closeButton = NSButton()
    private let rowsView = NSView()
    private var rows: [(view: SessionRowView, id: String)] = []
    private var lastIDs: [String] = []   // rebuild the row set only when it actually changes

    private let rowH: CGFloat = 24, headerH: CGFloat = 28, pad: CGFloat = 6
    private let hPad: CGFloat = 10   // side margin; tighter than the menu's 14 (no shortcut gutter here)
    // Same live knob the dropdown reads (uiconfig.json), so the shared rows lay out identically in
    // both places; picked up on the next rebuild.
    private var width: CGFloat { CGFloat(owner?.uiConfig()["boxWidth"] ?? 300) }

    init(owner: StatusController) {
        self.owner = owner
        super.init()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        lastIDs = []            // force a rebuild: the session set moved on while we were hidden
        refresh()
        panel.orderFrontRegardless()   // no activation — .accessory apps have no windows to front
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: headerH + rowH + pad),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.level = .floating                    // above ordinary windows, below the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true   // drag it anywhere by its background/header
        panel.isFloatingPanel = true
        panel.animationBehavior = .utilityWindow

        effect.material = .hudWindow               // the translucency; alphaValue thins it further
        effect.blendingMode = .behindWindow
        effect.state = .active
        // Rounded via maskImage, NOT layer.cornerRadius: a behind-window blur is composited by the
        // window server over the view's full rect, so a layer mask clips only what WE draw and the
        // square blur keeps showing through as pale corners. maskImage is the one knob the server honours.
        effect.maskImage = OverlayController.roundedMask(radius: 12)
        panel.contentView = effect

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.sizeToFit()   // the fitted height is what centers the text, not a guessed 16pt box
        effect.addSubview(titleLabel)

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close overlay")
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.frame = NSRect(x: 0, y: 0, width: 16, height: 16)   // placed by layout()
        closeButton.autoresizingMask = [.minXMargin]
        effect.addSubview(closeButton)

        emptyLabel.font = .menuFont(ofSize: 0)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.frame = NSRect(x: hPad, y: 0, width: width - hPad * 2, height: 16)
        emptyLabel.isHidden = true
        effect.addSubview(emptyLabel)

        rowsView.autoresizingMask = [.width]
        effect.addSubview(rowsView)

        panel.setFrame(savedFrame(size: panel.frame.size), display: false)
        return panel
    }

    // A 9-part stretchable rounded rect: the corners stay their drawn size at any window height.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    @objc private func closeClicked() { owner?.setOverlayVisible(false) }

    // Called from the poll tick: cheap when the session set is unchanged (just re-configures the
    // existing rows, exactly like the open dropdown does).
    func refresh() {
        guard let owner = owner, let panel = panel else { return }
        panel.alphaValue = CGFloat(owner.uiConfig()["overlayAlpha"] ?? 0.9)
        let sessions = owner.visibleSessions()
        let ids = sessions.map { $0.id }
        if ids != lastIDs {
            lastIDs = ids
            rows.forEach { $0.view.removeFromSuperview() }
            rows = sessions.map { s in
                let v = SessionRowView(id: s.id, width: width, pad: hPad)
                let sid = s.id, ep = s.entrypoint, tp = s.termProgram, spid = s.pid, scwd = s.cwd
                v.onClick = { [weak owner] in
                    owner?.openSession(sid, entrypoint: ep, termProgram: tp, pid: spid, cwd: scwd)
                }
                rowsView.addSubview(v)
                return (v, s.id)
            }
            layout(rowCount: rows.count)
        }
        let now = Date().timeIntervalSince1970
        for (v, id) in rows {
            guard let s = owner.sessions[id] else { continue }
            owner.configureSessionRow(v, s, eff: s.eff.isEmpty ? owner.effectiveState(s, now: now) : s.eff,
                                      pillInset: hPad)
        }
    }

    // Height follows the row count; the window grows downward from its current top-left corner so a
    // panel the user parked stays put instead of drifting as sessions come and go.
    private func layout(rowCount: Int) {
        guard let panel = panel else { return }
        let bodyH = max(rowH, CGFloat(rowCount) * rowH)
        let total = headerH + bodyH + pad
        let top = panel.frame.maxY, left = panel.frame.minX
        panel.setFrame(NSRect(x: left, y: top - total, width: width, height: total), display: true)

        // Title and close button share one center line through the header band, so they read as a row
        // instead of two independently-guessed offsets.
        let h = panel.frame.height
        let centerY = h - headerH / 2
        titleLabel.setFrameOrigin(NSPoint(x: hPad, y: centerY - titleLabel.frame.height / 2))
        closeButton.setFrameOrigin(NSPoint(x: width - hPad - closeButton.frame.width,
                                           y: centerY - closeButton.frame.height / 2))
        rowsView.frame = NSRect(x: 0, y: pad, width: width, height: bodyH)
        emptyLabel.isHidden = rowCount > 0
        emptyLabel.setFrameOrigin(NSPoint(x: hPad, y: pad + (bodyH - 16) / 2))
        // Full frame, not just the origin: rows are added while rowsView is still zero-width, and the
        // resize that follows would otherwise hand each flexible-width row the whole delta on top of
        // its own width, pushing the timer and pill (pinned to the trailing edge) out of the window.
        for (i, r) in rows.enumerated() {
            r.view.frame = NSRect(x: 0, y: bodyH - CGFloat(i + 1) * rowH, width: width, height: rowH)
        }
    }

    // Remembered position (the user drags it where they want it); defaults to the top-right corner
    // just under the menu bar, near the status item it mirrors.
    private func savedFrame(size: NSSize) -> NSRect {
        if let s = UserDefaults.standard.string(forKey: "overlayOrigin") {
            let p = NSPointFromString(s)
            let frame = NSRect(x: p.x, y: p.y - size.height, width: size.width, height: size.height)
            // Only reuse it if it still lands on an attached screen (displays get unplugged).
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return frame }
        }
        let vis = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: vis.maxX - size.width - 12, y: vis.maxY - size.height - 12, width: size.width, height: size.height)
    }

    // Store the TOP-left corner: the height changes with the row count, so a bottom-left origin
    // would reopen the window at a different visual spot.
    func savePosition() {
        guard let f = panel?.frame else { return }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.minX, y: f.maxY)), forKey: "overlayOrigin")
    }
}
