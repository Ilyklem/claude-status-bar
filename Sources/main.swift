import Cocoa

// Custom-drawn toggle. NSSwitch can't show its accent inside a menu (the menu's vibrant, non-key
// window draws the implicit accent gray), so we render the track + knob as layers and fill the
// "on" color explicitly. Layer-hosted so the knob can slide on Apple's switch spring (CASpringAnimation),
// with the track color crossfading; CA animations run in the render server, so they play during menu tracking.
final class ToggleView: NSView {
    static let w: CGFloat = 33, h: CGFloat = 16
    private let track = CALayer()
    private let knob = CALayer()
    private var lastToggle = Date.distantPast   // debounce: ignore a re-click within a short window
    private var hovered = false
    var isOn: Bool { didSet { updateState(animated: true) } }
    var onToggle: ((Bool) -> Void)?

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: ToggleView.w, height: ToggleView.h))
        layer = CALayer()
        wantsLayer = true
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        layer?.addSublayer(track)
        let kh = bounds.height - 4, kw = kh + 3   // capsule: a touch wider than tall, like modern macOS
        knob.bounds = CGRect(x: 0, y: 0, width: kw, height: kh)
        knob.cornerRadius = kh / 2
        knob.backgroundColor = NSColor.white.cgColor
        layer?.addSublayer(knob)
        updateState(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: ToggleView.w, height: ToggleView.h) }

    private func knobCenter() -> CGPoint {
        let kw = knob.bounds.width
        return CGPoint(x: isOn ? bounds.width - kw / 2 - 2 : kw / 2 + 2, y: bounds.height / 2)
    }

    // Track fill. ON = accent. OFF = an explicit mid gray (the system's faint off color disappears on a
    // light menu, and a dynamic NSColor's .cgColor can latch the wrong appearance → white-on-white), so
    // pick black-on-light / white-on-dark from our OWN effectiveAppearance. Hover nudges it darker.
    private func trackColor() -> CGColor {
        if isOn {
            let accent = NSColor.controlAccentColor
            return (hovered ? (accent.blended(withFraction: 0.10, of: .white) ?? accent) : accent).cgColor
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let base: CGFloat = dark ? 1.0 : 0.0
        let alpha: CGFloat = (dark ? 0.30 : 0.34) + (hovered ? 0.10 : 0)
        return NSColor(white: base, alpha: alpha).cgColor
    }

    private func updateState(animated: Bool) {
        let toColor = trackColor()
        let toPos = knobCenter()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            let spring = CASpringAnimation(keyPath: "position")
            spring.fromValue = NSValue(point: knob.presentation()?.position ?? knob.position)
            spring.toValue = NSValue(point: toPos)
            spring.damping = 16; spring.stiffness = 260; spring.mass = 1; spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            knob.add(spring, forKey: "position")
            let col = CABasicAnimation(keyPath: "backgroundColor")
            col.fromValue = track.presentation()?.backgroundColor ?? track.backgroundColor
            col.toValue = toColor
            col.duration = 0.2
            track.add(col, forKey: "backgroundColor")
        }
        knob.position = toPos
        track.backgroundColor = toColor
        CATransaction.commit()
    }

    // Recolor when the view actually lands in the menu (its effectiveAppearance only resolves to the
    // menu's light/dark then, not at init), so the off gray matches the menu it's drawn on.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateState(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateState(animated: false) }
    override func mouseExited(with event: NSEvent) { hovered = false; updateState(animated: false) }

    override func mouseDown(with event: NSEvent) {
        guard Date().timeIntervalSince(lastToggle) > 0.1 else { return }
        lastToggle = Date()
        isOn.toggle()
        onToggle?(isOn)
    }
}

// A session row as a custom view so a flexible spacer can pin the timer + pill to the true trailing
// edge (a plain menu-item title can't cross the menu's reserved shortcut/submenu-arrow column).
// Layout: [icon] name  <spacer>  timer  [pill], with timer+pill pinned right via autoresizing.
final class SessionRowView: NSView {
    let id: String
    var onClick: (() -> Void)?
    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let nameField = NSTextField(labelWithString: "")
    private let timerField = NSTextField(labelWithString: "")
    private let pillView = NSImageView()
    private let pad: CGFloat, iconSize: CGFloat = 16, rowH: CGFloat = 24
    private let highlightView = NSVisualEffectView()  // system selection material = exact native highlight
    private var hovered = false
    private var iconBaseTint: NSColor?       // tint when not hovered (template icons); white on hover
    private var pillNormal: NSImage?, pillSelected: NSImage?
    private var nameText = "", branchText = ""

    // `pad` is the leading inset: the menu's 14pt gutter by default, tightened by the overlay window,
    // which has no menu chrome to line up with.
    init(id: String, width: CGFloat, pad: CGFloat = 14) {
        self.id = id
        self.pad = pad
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH))
        autoresizingMask = [.width]
        highlightView.material = .selection
        highlightView.state = .active
        highlightView.isEmphasized = true
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 5
        highlightView.isHidden = true
        addSubview(highlightView)
        iconView.frame = NSRect(x: pad, y: (rowH - iconSize) / 2, width: iconSize, height: iconSize)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.autoresizingMask = [.maxXMargin]
        addSubview(iconView)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        let spinSize = iconSize * 0.9
        spinner.frame = NSRect(x: pad + (iconSize - spinSize) / 2, y: (rowH - spinSize) / 2, width: spinSize, height: spinSize)
        spinner.autoresizingMask = [.maxXMargin]
        spinner.isHidden = true
        addSubview(spinner)
        nameField.font = .menuFont(ofSize: 0)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.frame = NSRect(x: pad + iconSize + 8, y: (rowH - 16) / 2, width: 160, height: 16)
        nameField.autoresizingMask = [.maxXMargin]
        addSubview(nameField)
        timerField.font = NSFont.monospacedSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
        timerField.textColor = .secondaryLabelColor
        timerField.alignment = .right
        timerField.autoresizingMask = [.minXMargin]
        addSubview(timerField)
        pillView.imageScaling = .scaleNone
        pillView.autoresizingMask = [.minXMargin]
        addSubview(pillView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(icon: NSImage?, iconTint: NSColor?, spinning: Bool, name: String, branch: String, timer: String?,
                   pillNormal: NSImage?, pillSelected: NSImage?, pillInset: CGFloat, timerGap: CGFloat) {
        let w = bounds.width
        iconView.image = icon
        iconBaseTint = iconTint
        iconView.contentTintColor = hovered ? .white : iconTint
        if spinning {
            iconView.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            iconView.isHidden = false
        }
        nameText = name; branchText = branch
        renderName()
        self.pillNormal = pillNormal; self.pillSelected = pillSelected
        let pill = hovered ? pillSelected : pillNormal
        var pillLeft = w - pillInset
        if let pill = pill {
            pillView.isHidden = false
            pillView.image = pill
            pillView.frame = NSRect(x: w - pillInset - pill.size.width, y: (rowH - pill.size.height) / 2,
                                    width: pill.size.width, height: pill.size.height)
            pillLeft = pillView.frame.minX
        } else { pillView.isHidden = true }
        if let timer = timer {
            timerField.isHidden = false
            timerField.stringValue = timer
            // Fit the column to the text (mono font, right edge anchored at the pill): a fixed-width
            // column reserved ~50pt of blank space that pixel-truncated the name · branch next to it.
            let font = timerField.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
            let tw = ceil(timer.size(withAttributes: [.font: font]).width) + 2
            // Same point size and same box (y/height) as the name field, so the timer sits on the name's
            // baseline instead of floating at the row's vertical center.
            timerField.frame = NSRect(x: pillLeft - timerGap - tw, y: (rowH - 16) / 2, width: tw, height: 16)
        } else { timerField.isHidden = true }
        // Name stretches to whatever the timer/pill leave free (branch text made the fixed 160 tight);
        // pixel truncation via the paragraph style handles overflow.
        let nameRight = timer != nil ? timerField.frame.minX : pillLeft
        nameField.frame.size.width = max(40, nameRight - timerGap - nameField.frame.minX)
    }
    // name in the label color, " · branch" dimmed — mirrored on hover, where setting textColor
    // can't restyle an attributed string.
    private func renderName() {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        // Barely-overflowing text otherwise gets its tracking silently condensed to fit ("default
        // tightening"), so the same name renders visibly squished on a row whose timer narrows the
        // field. Constant tracking on every row; overflow shows an honest ellipsis instead.
        para.allowsDefaultTighteningForTruncation = false
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(string: nameText, attributes: [
            .font: font, .paragraphStyle: para,
            .foregroundColor: hovered ? NSColor.white : .labelColor,
        ])
        if !branchText.isEmpty {
            text.append(NSAttributedString(string: " · " + branchText, attributes: [
                .font: font, .paragraphStyle: para,
                .foregroundColor: hovered ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor,
            ]))
        }
        nameField.attributedStringValue = text
    }
    // Custom views don't get the menu's automatic hover highlight, so draw it ourselves.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    private func setHover(_ h: Bool) {
        hovered = h
        highlightView.isHidden = !h
        renderName()
        timerField.textColor = h ? .white : .secondaryLabelColor
        iconView.contentTintColor = h ? .white : iconBaseTint
        if !pillView.isHidden { pillView.image = h ? pillSelected : pillNormal }
    }
    override func layout() {
        super.layout()
        highlightView.frame = bounds.insetBy(dx: 5, dy: 0)
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// Custom view for the same reason as SessionRowView (a trailing-edge icon needs a flexible
// spacer; a plain menu item can't cross the shortcut/submenu-arrow gutter), with the same
// self-drawn hover highlight.
final class CopyRowView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let highlightView = NSVisualEffectView()
    private let command: String
    private let pad: CGFloat = 14, rowH: CGFloat = 24, iconSize: CGFloat = 15
    private var copied = false

    init(title: String, command: String, width: CGFloat) {
        self.command = command
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH))
        autoresizingMask = [.width]
        highlightView.material = .selection
        highlightView.state = .active
        highlightView.isEmphasized = true
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 5
        highlightView.isHidden = true
        addSubview(highlightView)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.stringValue = title
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: pad, y: (rowH - label.frame.height) / 2))
        label.autoresizingMask = [.maxXMargin]
        addSubview(label)
        icon.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.frame = NSRect(x: width - pad - iconSize, y: (rowH - iconSize) / 2, width: iconSize, height: iconSize)
        icon.autoresizingMask = [.minXMargin]
        addSubview(icon)
        toolTip = command
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    private func setHover(_ h: Bool) {
        highlightView.isHidden = !h
        label.textColor = h ? .white : .labelColor
        icon.contentTintColor = h ? .white : (copied ? .labelColor : .secondaryLabelColor)
    }
    override func layout() {
        super.layout()
        highlightView.frame = bounds.insetBy(dx: 5, dy: 0)
    }
    override func mouseDown(with event: NSEvent) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command, forType: .string)
        copied = true
        icon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        icon.contentTintColor = .white  // click happens mid-hover; setHover keeps it labelColor otherwise
        // Give the checkmark a beat to register before the menu closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.enclosingMenuItem?.menu?.cancelTracking()
        }
    }
}

final class StatusController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let stateDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/state.d")
    let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    var pollTimer: Timer?
    var animTimer: Timer?
    var frameIdx = 0

    let launchedAt = Date()
    var notNeededSince: Date?
    let launchGrace: TimeInterval = 5   // settle time after launch before we may quit
    let idleQuitDelay: TimeInterval = 3 // "not needed" must persist this long before quitting
    // "Hide idle after" setting (seconds): hide a resting session's ROW once it's been quiet this long.
    // Render-only — it never deletes the file or affects liveness (that's pid-driven now), and the
    // most-recent session is always kept visible (floor at one). 0 = Never. Defaults to 30 min.
    var stalePruneAge: TimeInterval { UserDefaults.standard.object(forKey: "hideIdleAfter") as? Double ?? 900 }

    struct Session {
        var id: String, state: String, label: String, project: String, transcript: String
        var cwd: String         // session working directory; "" on pre-upgrade files
        var entrypoint: String  // CLAUDE_CODE_ENTRYPOINT: "cli", "claude-desktop", …
        var termProgram: String // TERM_PROGRAM for CLI sessions: "Apple_Terminal", "iTerm.app", …
        var pid: Int32          // the session's `claude` process; kill(pid,0) drives liveness. 0 = pre-upgrade file.
        var started: Bool       // true once the session had real activity (a prompt/tool); a merely-opened
                                // conversation seeds started=false and stays out of the dropdown.
        var startedAt: Double, ts: Double
        var eff: String = ""   // effective state, recomputed once per tick in evaluate()
        var branch: String = ""      // git branch (or short SHA when detached); "" outside a repo
        var displayName: String = "" // project, parent-qualified when two live sessions share a name

        init(json o: [String: Any], id: String) {
            self.id = id
            self.state = o["state"] as? String ?? "idle"
            self.label = o["label"] as? String ?? ""
            self.project = o["project"] as? String ?? ""
            self.transcript = o["transcript"] as? String ?? ""
            self.cwd = o["cwd"] as? String ?? ""
            self.entrypoint = o["entrypoint"] as? String ?? ""
            self.termProgram = o["term_program"] as? String ?? ""
            self.pid = Int32(truncatingIfNeeded: (o["pid"] as? NSNumber)?.intValue ?? 0)
            self.started = o["started"] as? Bool ?? false
            self.startedAt = (o["startedAt"] as? NSNumber)?.doubleValue ?? 0
            self.ts = (o["ts"] as? NSNumber)?.doubleValue ?? 0
        }
    }
    var sessions: [String: Session] = [:]  // id -> latest parsed per-session state
    var fileMTimes: [String: Date] = [:]   // "<id>.json" -> last-parsed mtime (re-parse only on change)
    var accessibilityPrompted = false        // the system alert is a once-per-launch thing
    var gitHeadCache: [String: String] = [:]  // cwd -> resolved HEAD path ("" = confirmed non-git)
    var prevState: [String: String] = [:]  // id -> previous raw state per session
    var menuIsOpen = false                  // refresh the dropdown's per-session timers only while open
    var sessionMenuItems: [(item: NSMenuItem, id: String)] = []
    var activeBase = ""        // label without the elapsed clock
    var startedAt: Double = 0  // unix seconds the current turn began (0 = no clock)
    var activeColor: NSColor? = nil
    var lastTitleText: String? = nil
    // Tinted frames are deterministic per (style, frame, color); rebuilding one per animation
    // step re-rasterized identical images at fps. Cleared when the style or color changes.
    var iconCache: [String: NSImage] = [:]
    var turnLineCache: [String: (mtime: Date?, line: String?)] = [:]
    var desktopRunning = false

    let brand = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #d97757, Anthropic's official "Orange" accent
    let amber = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1) // "awaiting permission" yellow dot
    let frames: [NSImage] = StatusController.loadFrames()
    let spriteFPS: Double = 9 // tune: 8 frames per loop -> ~0.9s/cycle

    enum AnimStyle: String { case web, code, crab }
    var animStyle: AnimStyle = .web
    var showTimer = false
    var iconSystem = false // false = brand Orange; true = adaptive black/white (template image)
    var useThinkingWords = true     // rotate a playful verb ("Manifesting…") in place of "Thinking…"
    var overlayVisible = false      // the always-on-top session window (see OverlayController)
    lazy var overlay = OverlayController(owner: self)
    var sessionWord: [String: String] = [:] // id -> current thinking word; re-picked on each entry into "thinking"
    var soundThreshold: Double = 0  // 0 = off; else the min turn length (seconds) that chimes on completion
    var turnStart: [String: Double] = [:]  // id -> active turn start, for the completion-sound length gate
    lazy var completionSound: NSSound? = {
        guard let p = Bundle.main.path(forResource: "completion", ofType: "mp3"),
              let s = NSSound(contentsOfFile: p, byReference: true) else { return nil }
        s.volume = 0.7 // the clip is loud at full system volume; play it a bit softer
        return s
    }()
    // Claude Code's SPINNER_VERBS, minus the hyphenated/tongue-twister ones. Longest kept is ~14 chars
    // ("Hullaballooing"/"Metamorphosing"); with the timer showing they can get wide in a crowded menu bar.
    let thinkingWords = [
        "Accomplishing", "Actioning", "Actualizing", "Architecting", "Baking", "Beaming", "Beboppin'",
        "Befuddling", "Billowing", "Blanching", "Bloviating", "Boogieing", "Boondoggling", "Booping",
        "Bootstrapping", "Brewing", "Bunning", "Burrowing", "Calculating", "Canoodling", "Caramelizing",
        "Cascading", "Catapulting", "Cerebrating", "Channeling", "Channelling", "Churning", "Clauding",
        "Coalescing", "Cogitating", "Combobulating", "Composing", "Computing", "Concocting", "Considering",
        "Contemplating", "Cooking", "Crafting", "Creating", "Crunching", "Crystallizing", "Cultivating",
        "Deciphering", "Deliberating", "Determining", "Doing", "Doodling", "Drizzling", "Ebbing",
        "Effecting", "Elucidating", "Embellishing", "Enchanting", "Envisioning", "Evaporating", "Fermenting",
        "Finagling", "Flambéing", "Flowing", "Flummoxing", "Fluttering", "Forging", "Forming", "Frolicking",
        "Gallivanting", "Galloping", "Garnishing", "Generating", "Gesticulating", "Germinating", "Gitifying",
        "Grooving", "Gusting", "Harmonizing", "Hashing", "Hatching", "Herding", "Honking", "Hullaballooing",
        "Hyperspacing", "Ideating", "Imagining", "Improvising", "Incubating", "Inferring", "Infusing",
        "Ionizing", "Jitterbugging", "Julienning", "Kneading", "Leavening", "Levitating", "Lollygagging",
        "Manifesting", "Marinating", "Meandering", "Metamorphosing", "Misting", "Moonwalking", "Moseying",
        "Mulling", "Mustering", "Musing", "Nebulizing", "Nesting", "Noodling", "Nucleating", "Orbiting",
        "Orchestrating", "Osmosing", "Perambulating", "Percolating", "Perusing", "Pollinating", "Pondering",
        "Pontificating", "Pouncing", "Precipitating", "Processing", "Proofing", "Propagating", "Puttering",
        "Puzzling", "Quantumizing", "Razzmatazzing", "Reticulating", "Roosting", "Ruminating", "Sautéing",
        "Scampering", "Schlepping", "Scurrying", "Seasoning", "Shenaniganing", "Shimmying", "Simmering",
        "Skedaddling", "Sketching", "Slithering", "Smooshing", "Spelunking", "Spinning", "Sprouting",
        "Stewing", "Sublimating", "Swirling", "Swooping", "Symbioting", "Synthesizing", "Tempering",
        "Thinking", "Thundering", "Tinkering", "Tomfoolering", "Transfiguring", "Transmuting", "Twisting",
        "Undulating", "Unfurling", "Unravelling", "Vibing", "Waddling", "Wandering", "Warping",
        "Whirlpooling", "Whirring", "Whisking", "Wibbling", "Working", "Wrangling", "Zesting", "Zigzagging"]
    var iconColor: NSColor? { iconSystem ? nil : brand } // nil => render as an adaptive template
    let codeGlyphs = ["✻", "✽", "✶", "✳", "✢"]
    let codePeaks: [CGFloat] = [1.0, 1.0, 1.0, 1.0, 1.0]
    let codeDip: CGFloat = 0.14 // glyph shrinks to this at each swap
    let codeSub = 18            // sub-frames per glyph (tween smoothness)
    let codeCycle: Double = 3.8 // seconds for the full loop (lower = faster)
    lazy var codeGlyphMasks: [NSImage] = codeGlyphs.map { StatusController.glyphMask($0) }
    let crabFPS: Double = 12.5 // matches the source GIF's 0.08s frame delay
    lazy var crabFrames: [NSImage] = StatusController.decodePNGs(clawdCrabFramePNGs)
    // Template frames: bright pixels (white eyes) become transparent holes so they're
    // visible as negative space against the menu bar in System color mode.
    lazy var crabTemplateFrames: [NSImage] = crabFrames.map { adaptiveCrabFrame($0) }
    var fps: Double {
        switch animStyle {
        case .web: return spriteFPS
        case .code: return Double(codeGlyphs.count * codeSub) / codeCycle
        case .crab: return crabFPS
        }
    }
    var frameCount: Int {
        switch animStyle {
        case .web: return max(1, frames.count)
        case .code: return codeGlyphs.count * codeSub
        case .crab: return max(1, crabFrames.count)
        }
    }

    override init() {
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "showTimer") != nil { showTimer = d.bool(forKey: "showTimer") }
        if d.object(forKey: "iconSystem") != nil { iconSystem = d.bool(forKey: "iconSystem") }
        if d.object(forKey: "thinkingWords") != nil { useThinkingWords = d.bool(forKey: "thinkingWords") }
        if d.object(forKey: "soundThreshold") != nil { soundThreshold = d.double(forKey: "soundThreshold") }
        if d.object(forKey: "overlayVisible") != nil { overlayVisible = d.bool(forKey: "overlayVisible") }
        if let s = d.string(forKey: "animStyle"), let st = AnimStyle(rawValue: s) { animStyle = st }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render(label: "", color: iconColor, animate: false, startedAt: 0)
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        tick()
        observeDesktopApp()
        try? FileManager.default.removeItem(atPath: (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/quit-intent"))
        removeOldNamedBundle()
        ensureHooksInstalled()
        checkForUpdate()
        if overlayVisible { overlay.show() }   // the app restarts with sessions; the window returns with it
    }

    // Single entry point for the overlay so the menu toggle, the window's own close button and the
    // restore-on-launch path all keep the preference and the window in sync.
    func setOverlayVisible(_ on: Bool) {
        overlayVisible = on
        UserDefaults.standard.set(on, forKey: "overlayVisible")
        if on { overlay.show() } else { overlay.savePosition(); overlay.hide() }
        evaluate()   // the bar rests while the overlay is up, so switch it over now, not a tick later
    }

    // 0.4.0 rename transition ("ClaudeStatusBar.app" to "Claude Status Bar.app"): Finder won't
    // replace across different filenames, so a manual DMG update leaves the old-named copy behind;
    // remove it on launch. Guarded by bundle id so a fork or unrelated app at that path is never
    // touched, and skipped when running FROM that path (old-named dev builds).
    func removeOldNamedBundle() {
        let old = "/Applications/ClaudeStatusBar.app"
        guard Bundle.main.bundlePath != old,
              let info = NSDictionary(contentsOfFile: old + "/Contents/Info.plist"),
              info["CFBundleIdentifier"] as? String == "com.local.claudestatusbar" else { return }
        for app in NSWorkspace.shared.runningApplications
            where app.bundleURL?.path == old && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.forceTerminate()
        }
        try? FileManager.default.removeItem(atPath: old)
    }

    // Re-runs on first install AND on every version change, so upgrades pick up hook
    // changes and retire old artifacts.
    func ensureHooksInstalled() {
        let d = UserDefaults.standard
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        guard d.string(forKey: "installedVersion") != current,
              let installer = Bundle.main.path(forResource: "install", ofType: "js") else { return }
        DispatchQueue.global().async {
            guard let node = Self.locateNode() else {
                NSLog("ClaudeStatusBar: could not find node; hooks not installed (will retry next launch)")
                return
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: node)
            task.arguments = [installer]
            try? task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { UserDefaults.standard.set(current, forKey: "installedVersion") }
        }
    }

    // `/bin/zsh -lc node` saw only the login PATH, missing nvm/fnm set in .zshrc.
    static func locateNode() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.asdf/shims/node",
        ]
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted(by: >) { candidates.append("\(nvmDir)/\(v)/bin/node") }
        }
        for path in candidates where fm.isExecutableFile(atPath: path) { return path }

        for args in [["-ilc", "command -v node"], ["-lc", "command -v node"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !path.isEmpty, fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: update check

    var currentVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }
    let releaseAPIURL = "https://api.github.com/repos/m1ckc3s/claude-status-bar/releases/latest"
    let releasePageURL = "https://github.com/m1ckc3s/claude-status-bar/releases/latest"
    // Homebrew: the cask lags a GitHub release by up to ~a day (autobump), so brew-managed
    // installs gate "update available" on the CASK version, so the copy command always works
    // when offered. Public JSON, nothing sent anywhere (same privacy story as the GitHub check).
    let brewCaskAPIURL = "https://formulae.brew.sh/api/cask/claude-status-bar.json"
    let brewUpgradeCommand = "brew upgrade --cask claude-status-bar"
    // The trailing `open` matters: brew only copies the app, and the first launch of the new copy
    // is what installs hooks and removes the old-named bundle (0.4.0 rename transition).
    let brewInstallCommand = "brew install --cask claude-status-bar && open -a \"Claude Status Bar\""
    var brewManaged: Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/Caskroom/claude-status-bar")
            || FileManager.default.fileExists(atPath: "/usr/local/Caskroom/claude-status-bar")
    }

    // Once/day: cache GitHub's latest release tag in UserDefaults. Nothing sent to us.
    func checkForUpdate() {
        let d = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if now - d.double(forKey: "lastUpdateCheck") < 86400 { return }
        guard let url = URL(string: releaseAPIURL) else { return }
        var req = URLRequest(url: url)
        req.setValue("ClaudeStatusBar", forHTTPHeaderField: "User-Agent") // GitHub API requires a UA
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            UserDefaults.standard.set(ver, forKey: "latestVersion")
            UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        }.resume()
        guard let brewURL = URL(string: brewCaskAPIURL) else { return }
        URLSession.shared.dataTask(with: URLRequest(url: brewURL)) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ver = obj["version"] as? String else { return }
            UserDefaults.standard.set(ver, forKey: "brewCaskVersion")
        }.resume()
    }

    // Numeric component-wise compare so "0.0.10" > "0.0.9".
    func versionIsNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @objc func openLatestRelease() {
        if let url = URL(string: releasePageURL) { NSWorkspace.shared.open(url) }
    }

    // MARK: menu

    // The poll timer runs in .common mode, so it keeps firing while the menu tracks; we use that
    // to live-update the per-session elapsed clocks. menuNeedsUpdate rebuilds the rows on each open.
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        sessionMenuItems.removeAll()
    }

    // The session SET only changes on reopen (NSMenu can't add/remove rows reliably mid-track).
    func refreshOpenMenuRows() {
        let now = Date().timeIntervalSince1970
        for (item, id) in sessionMenuItems {
            guard let s = sessions[id], let v = item.view as? SessionRowView else { continue }
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            configureSessionRow(v, s, eff: eff)
        }
    }

    // The session rows worth showing, most-recent first — shared by the dropdown and the overlay
    // window so the two never disagree about what's alive.
    //
    // Gate ONLY the desktop app: opening/clicking a conversation there seeds an idle session without
    // real activity (the click-through clutter), so a desktop session stays out of the list until
    // a prompt/tool fires (started=true). CLI / terminal / editor sessions are launched deliberately,
    // so they surface the moment they start. Any active state counts as started too (and covers
    // pre-upgrade files with no flag).
    func visibleSessions() -> [Session] {
        let now = Date().timeIntervalSince1970
        let ordered = sessions.values.sorted { $0.ts > $1.ts }   // most-recent first
            .filter { s in
                let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
                let resting = !(eff == "permission" || eff == "thinking" || eff == "tool")
                let gated = s.entrypoint == "claude-desktop"   // only the desktop app is gated
                return !gated || s.started || !resting
            }
        // Hide rows idle past the threshold, but ALWAYS keep the most-recent started session (floor at
        // one) so the list never goes empty while a session is alive. Hiding is render-only; the file
        // (and thus liveness) is untouched — see stalePruneAge and the pid-driven reap in evaluate().
        var visible = ordered.filter { s in
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            let resting = !(eff == "permission" || eff == "thinking" || eff == "tool")
            return !(stalePruneAge > 0 && resting && now - s.ts > stalePruneAge)
        }
        if visible.isEmpty, let lead = ordered.first { visible = [lead] }   // floor: never empty while alive
        return visible
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        checkForUpdate() // refreshes the update cache for next open (gated to once a day)

        // Branches otherwise refresh only on hook events, so re-read on open (one tiny file read per
        // session) to catch a checkout made while a session sat idle.
        for (id, s) in sessions where !s.cwd.isEmpty {
            if gitHeadCache[s.cwd] == "" { gitHeadCache[s.cwd] = nil }  // recheck non-git: may have been git-init'd since
            var u = s; u.branch = branchForCwd(u.cwd); sessions[id] = u
        }

        sessionMenuItems.removeAll()
        let now = Date().timeIntervalSince1970
        let visible = visibleSessions()

        if !visible.isEmpty {
            menu.addItem(header("Sessions"))
            for s in visible {
                let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
                let view = SessionRowView(id: s.id, width: CGFloat(uiConfig()["boxWidth"] ?? 300))
                let sid = s.id, ep = s.entrypoint, tp = s.termProgram, spid = s.pid, scwd = s.cwd
                view.onClick = { [weak self] in
                    menu.cancelTracking()
                    self?.openSession(sid, entrypoint: ep, termProgram: tp, pid: spid, cwd: scwd)
                }
                configureSessionRow(view, s, eff: eff)
                let it = NSMenuItem()
                it.view = view
                menu.addItem(it)
                sessionMenuItems.append((it, s.id))  // kept so tick() can live-update the timers
            }
            menu.addItem(.separator())
        } else if desktopRunning {
            // No live session to pin, but the desktop app is up — give a way to jump back in.
            menu.addItem(header("Sessions"))
            let open = NSMenuItem(title: "Open Claude", action: #selector(openClaude), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            menu.addItem(.separator())
        }

        menu.addItem(header("Options"))
        menu.addItem(toggleRow(title: "Show timer", isOn: showTimer) { [weak self] on in
            self?.showTimer = on
            UserDefaults.standard.set(on, forKey: "showTimer")
            self?.applyTitle()
        })
        menu.addItem(toggleRow(title: "Thinking words", isOn: useThinkingWords) { [weak self] on in
            self?.useThinkingWords = on
            UserDefaults.standard.set(on, forKey: "thinkingWords")
            self?.evaluate()   // re-render the bar label immediately with/without the rotating word
        })
        menu.addItem(toggleRow(title: "Overlay window", isOn: overlayVisible) { [weak self] on in
            self?.setOverlayVisible(on)
        })

        let animParent = NSMenuItem(title: "Animation", action: nil, keyEquivalent: "")
        let animSub = NSMenu()
        for (style, name) in [(AnimStyle.web, "Claude Spark"), (AnimStyle.code, "Claude Code"), (AnimStyle.crab, "Crab Walking")] {
            let it = NSMenuItem(title: name, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = style.rawValue
            it.state = animStyle == style ? .on : .off
            animSub.addItem(it)
        }
        animParent.submenu = animSub
        menu.addItem(animParent)

        let colorParent = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorSub = NSMenu()
        for (sys, name) in [(false, "Orange"), (true, "System")] {
            let it = NSMenuItem(title: name, action: #selector(chooseColor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = sys
            it.state = iconSystem == sys ? .on : .off
            colorSub.addItem(it)
        }
        colorParent.submenu = colorSub
        menu.addItem(colorParent)

        let soundParent = NSMenuItem(title: "Completion Sound", action: nil, keyEquivalent: "")
        let soundSub = NSMenu()
        for (secs, name) in [(0.0, "Off"), (0.1, "Every turn"), (60.0, "1 min+"), (300.0, "5 min+"), (900.0, "15 min+")] {
            let it = NSMenuItem(title: name, action: #selector(chooseSound(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: secs)
            it.state = soundThreshold == secs ? .on : .off
            soundSub.addItem(it)
        }
        soundParent.submenu = soundSub
        menu.addItem(soundParent)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Version \(currentVersion)", action: nil, keyEquivalent: ""))
        if let latest = UserDefaults.standard.string(forKey: "latestVersion"), versionIsNewer(latest, than: currentVersion) {
            let width = CGFloat(uiConfig()["boxWidth"] ?? 300)
            let brewVer = UserDefaults.standard.string(forKey: "brewCaskVersion")
            if brewManaged {
                // Silent until the cask catches up (autobump lag): never offer a command that
                // would report "already up to date".
                if let bv = brewVer, versionIsNewer(bv, than: currentVersion) {
                    let title = "Update to \(bv) via brew"
                    let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    it.view = CopyRowView(title: title, command: brewUpgradeCommand, width: width)
                    menu.addItem(it)
                }
            } else {
                let up = NSMenuItem(title: "Update to \(latest)", action: #selector(openLatestRelease), keyEquivalent: "")
                up.target = self
                menu.addItem(up)
                let sw = NSMenuItem(title: "Switch to Homebrew", action: nil, keyEquivalent: "")
                sw.view = CopyRowView(title: "Switch to Homebrew", command: brewInstallCommand, width: width)
                menu.addItem(sw)
            }
        }
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    func toggleRow(title: String, qualifier: String? = nil, isOn: Bool, onToggle: @escaping (Bool) -> Void) -> NSMenuItem {
        let width = CGFloat(uiConfig()["boxWidth"] ?? 300), height: CGFloat = 24, leftInset: CGFloat = 14, rightInset: CGFloat = 12
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        row.autoresizingMask = [.width]

        let labelFont = NSFont.menuFont(ofSize: 0)
        let label = NSTextField(labelWithString: title)
        label.font = labelFont
        label.textColor = .labelColor
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: leftInset, y: (height - label.frame.height) / 2))
        label.autoresizingMask = [.maxXMargin]
        row.addSubview(label)

        let toggle = ToggleView(isOn: isOn)
        toggle.onToggle = onToggle
        let toggleX = width - toggle.frame.width - rightInset
        toggle.setFrameOrigin(NSPoint(x: toggleX, y: (height - toggle.frame.height) / 2))
        toggle.autoresizingMask = [.minXMargin]
        row.addSubview(toggle)

        // Optional trailing qualifier ("5 min+") pinned just left of the toggle, in the SAME font/size/color
        // and right-alignment as the session-row timer, so the two read as the same kind of trailing note.
        if let qualifier = qualifier {
            let qW: CGFloat = 74, gap: CGFloat = 8
            let q = NSTextField(labelWithString: qualifier)
            q.font = NSFont.monospacedSystemFont(ofSize: labelFont.pointSize - 2, weight: .regular)
            q.textColor = .secondaryLabelColor
            q.alignment = .right
            q.frame = NSRect(x: toggleX - gap - qW, y: (height - 16) / 2, width: qW, height: 16)
            q.autoresizingMask = [.minXMargin]
            row.addSubview(q)
        }

        let item = NSMenuItem()
        item.view = row
        return item
    }

    func sessionMenuLine(_ s: Session) -> String {
        let now = Date().timeIntervalSince1970
        let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff  // cached by evaluate() each tick
        // The icon carries the state (spinner / amber dot / caret); the row text is just the project,
        // plus a live timer while working since the spinner can't convey elapsed.
        var line = truncated(sessionName(s))
        if !s.branch.isEmpty { line += " · " + truncated(s.branch, max: 22, keep: 20) }
        if eff == "thinking" || eff == "tool", s.startedAt > 0 {
            line += "  " + elapsed(max(0, Int(now - s.startedAt)))
        }
        return line
    }

    // Live layout knobs read fresh from ~/.claude/statusbar/uiconfig.json each render, so numeric
    // tweaks (timer column, pill offset, gap) take effect on the next menu open with NO rebuild.
    func uiConfig() -> [String: Double] {
        let p = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/uiconfig.json")
        guard let d = FileManager.default.contents(atPath: p),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    // `pillInset` overrides the trailing inset for callers with their own margins (the overlay window).
    func configureSessionRow(_ v: SessionRowView, _ s: Session, eff: String, pillInset: CGFloat? = nil) {
        let cfg = uiConfig()
        let now = Date().timeIntervalSince1970
        // Generous cap: the row's pixel truncation does the real limiting now that the name field
        // sizes to the free space; this only guards against pathological strings.
        let nameMax = Int(cfg["nameMax"] ?? 30)
        let working = (eff == "thinking" || eff == "tool") && s.startedAt > 0
        let resting = !(eff == "permission" || eff == "thinking" || eff == "tool")  // the dim caret
        let tag = surfaceTag(s.entrypoint)
        v.configure(icon: sessionSymbol(s, eff: eff),
                    iconTint: resting ? .tertiaryLabelColor : .labelColor,  // caret dim; spinner matches the name font; amber image ignores tint
                    spinning: (eff == "thinking" || eff == "tool"),
                    name: truncated(sessionName(s), max: nameMax, keep: nameMax),
                    branch: truncated(s.branch, max: 22, keep: 20),
                    timer: working ? elapsed(max(0, Int(now - s.startedAt))) : nil,
                    pillNormal: tag.isEmpty ? nil : pillImage(tag),
                    pillSelected: tag.isEmpty ? nil : pillImage(tag, selected: true),
                    pillInset: pillInset ?? CGFloat(cfg["pillInset"] ?? 12),
                    timerGap: CGFloat(cfg["timerGap"] ?? 10))
        // Truncated rows stay inspectable: full name, branch, and path on hover.
        var tip = sessionName(s)
        if !s.branch.isEmpty { tip += " · " + s.branch }
        if !s.cwd.isEmpty { tip += "\n" + s.cwd }
        v.toolTip = tip
    }

    func statusText(_ s: Session, eff: String) -> String {
        switch eff {
        case "permission":       return "Awaiting permission"
        case "thinking", "tool": return workingLabel(s)
        default:                 return s.state == "done" ? "Done" : "Idle"
        }
    }

    // Just the repo/cwd (parent-qualified on a name collision); the surface (CLI/APP) renders as a
    // trailing badge instead of inline.
    func sessionName(_ s: Session) -> String {
        if !s.displayName.isEmpty { return s.displayName }
        return s.project.isEmpty ? "session" : s.project
    }

    // CLAUDE_CODE_ENTRYPOINT -> a short all-caps badge tag.
    // Every surface collapses to a 3-letter pill: the desktop app is APP, everything else (cli,
    // vscode, cursor, windsurf, …) is a terminal/editor context, so CLI. Keeps pills uniform.
    func surfaceTag(_ entrypoint: String) -> String {
        switch entrypoint {
        case "claude-desktop": return "APP"
        case "":               return ""
        default:               return "CLI"
        }
    }

    // CLI/APP pill rendered as an image so it can sit inside the row text (right after the timer)
    // rather than as a system badge pinned to the menu edge with a fixed, uncloseable gap.
    func pillImage(_ text: String, selected: Bool = false) -> NSImage {
        let t = text as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)  // mono -> 3 chars = uniform width
        let pad: CGFloat = 7, h: CGFloat = 15
        let cfg = uiConfig()
        let dy = CGFloat(cfg["pillTextY"] ?? -1)  // negative nudges the text down (it reads top-heavy)
        // Pill bg is a tunable gray per mode (black-on-light / white-on-dark at a low alpha) so light
        // mode can be lightened independently. On a selected (blue) row it's a light translucent pill.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let bgAlpha = CGFloat(cfg[dark ? "pillBgDark" : "pillBgLight"] ?? (dark ? 0.14 : 0.10))
        let bg = selected ? NSColor.white.withAlphaComponent(0.22)
                          : (dark ? NSColor.white : NSColor.black).withAlphaComponent(bgAlpha)
        let fg = selected ? NSColor.white : NSColor.labelColor
        let w = ceil(t.size(withAttributes: [.font: font]).width) + pad * 2
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            bg.setFill()
            NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
            let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
            let ts = t.size(withAttributes: a)
            t.draw(at: NSPoint(x: (rect.width - ts.width) / 2, y: (rect.height - ts.height) / 2 + dy), withAttributes: a)
            return true
        }
    }

    func sessionSymbol(_ s: Session, eff: String) -> NSImage? {
        switch eff {
        case "permission":       return symbolImage("exclamationmark.circle.fill", tint: amber)
        case "thinking", "tool": return nil
        default:                 return restingCaret   // done/idle merged: dim "ready for input" caret
        }
    }

    // The shell-style prompt caret (U+276F, what Claude Code shows when idle), dimmed and centered in
    // a square that matches the spinner gutter so the resting rows align with the working ones.
    lazy var restingCaret: NSImage? = {
        let glyph = "\u{276F}" as NSString
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let side: CGFloat = 15
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let g = glyph.size(withAttributes: attrs)
            glyph.draw(at: NSPoint(x: (side - g.width) / 2, y: (side - g.height) / 2), withAttributes: attrs)
            return true
        }
        img.isTemplate = true   // tint via contentTintColor: dim (tertiary) normally, white on hover
        return img
    }()

    func symbolImage(_ name: String, tint: NSColor? = nil) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        if let tint = tint, #available(macOS 12.0, *) {
            return img.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        img.isTemplate = true
        return img
    }

    // Keep the bar narrow: over `max` chars, show the first `keep` + an ellipsis (full text stays in the tooltip).
    func truncated(_ s: String, max: Int = 20, keep: Int = 18) -> String {
        s.count > max ? String(s.prefix(keep)) + "…" : s
    }

    // Rank a session's EFFECTIVE state for surfacing (higher = more important), so a session
    // awaiting YOUR permission is never hidden behind one merely thinking. `eff` only ever yields
    // permission / thinking / tool / idle (done collapses to idle; waiting is never emitted).
    func priority(of eff: String) -> Int {
        switch eff {
        case "permission":       return 2
        case "thinking", "tool": return 1
        default:                 return 0   // idle / unknown
        }
    }

    func workingLabel(_ s: Session) -> String {
        if useThinkingWords, s.state == "thinking", let w = sessionWord[s.id], !w.isEmpty { return w + "…" }
        if !s.label.isEmpty { return s.label }
        return s.state == "tool" ? "Working…" : "Thinking…"
    }

    // Re-pick a word each time a session ENTERS the thinking state (prompt, or a tool->thinking `post`),
    // avoiding an immediate repeat, so a tool round-trip lands a different word. Held steady while the
    // session stays thinking. Computed regardless of the toggle so flipping it on shows instantly.
    func updateThinkingWord(_ s: Session) {
        let prev = prevState[s.id] ?? ""
        guard s.state == "thinking", prev != "thinking" else { return }
        var w = thinkingWords.randomElement() ?? "Thinking"
        if thinkingWords.count > 1 { while w == sessionWord[s.id] { w = thinkingWords.randomElement() ?? w } }
        sessionWord[s.id] = w
    }

    // "1m 1s" / "43s" — Claude Code's elapsed-clock style.
    func elapsed(_ secs: Int) -> String {
        let m = secs / 60, s = secs % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    // The marker keeps update.js's self-relaunch from undoing an explicit Quit; cleared on the
    // next SessionStart (lifecycle.js) or the next manual launch (below), whichever comes first.
    @objc func quit() {
        let marker = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/quit-intent")
        FileManager.default.createFile(atPath: marker, contents: nil)
        NSApp.terminate(nil)
    }

    @objc func openClaude() {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // Row click. Desktop session: raise the Claude app. Focusing the exact conversation isn't
    // possible; every deep-link route either imports a copy or needs an id the app never exposes
    // (re-verified 2026-08-08, Claude 1.26832.0 — see the ROADMAP desktop section, issue #58).
    // CLI session: bring the app hosting its terminal to the front (zero permission). Targeting the
    // exact window/tab needs a one-time Automation grant, deferred to the opt-in build (issue #19).
    func openSession(_ id: String, entrypoint: String, termProgram: String, pid: Int32, cwd: String) {
        if entrypoint == "claude-desktop" { openClaude(); return }
        // Map TERM_PROGRAM to a name `open -a` understands; most terminals match verbatim.
        var target: String?
        switch termProgram {
        case "Apple_Terminal": target = "Terminal"
        case "iTerm.app":      target = "iTerm"
        case "vscode":         target = "Visual Studio Code"
        case "WarpTerminal":   target = "Warp"
        case "":               target = nil
        default:               target = termProgram  // Ghostty, WezTerm, Tabby, Hyper, kitty, …
        }
        // No TERM_PROGRAM (JetBrains IDE terminals export none) — ask the process tree instead. The
        // bundle path doubles as the `open -a` target, so nothing has to map a name back to an app.
        var bundle = target == nil ? owningAppBundle(pid) : nil
        // Background sessions (`claude` job runners) hang off the launcher daemon, not the terminal
        // that started them, so the tree holds no app at all. Exactly one running JetBrains IDE is
        // still a safe bet; two of them and we'd be guessing, so the click stays a no-op.
        if bundle == nil, target == nil { bundle = loneRunningJetBrainsIDE() }
        guard let app = target ?? bundle else {            // unknown surface, nothing to focus
            NSLog("ClaudeStatusBar: no app found for session pid \(pid) (\(cwd))")
            return
        }

        // An IDE keeps every project in its own window, so the row's job is to raise ONE of them.
        // `open` can't: handed a project it already has open it does nothing at all (verified with
        // WebStorm 2025.3), and handed anything else it opens a new window. Accessibility can, so
        // that's the path for IDEs — it degrades to a plain app activation without the permission.
        if let bundle = bundle, isJetBrains(bundle), raiseIDEWindow(forCwd: cwd, ide: bundle) { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", app]
        try? p.run()
    }

    // Raise the IDE window whose project contains <cwd>, via the Accessibility API. Returns false
    // when the permission is missing or no window matches, leaving the caller its `open -a` path.
    // The permission prompt is shown at most once per launch, and only for a click that needs it.
    func raiseIDEWindow(forCwd cwd: String, ide bundle: String) -> Bool {
        // Match on bundle id, with the path only as a tiebreak: `open`-style paths, symlinked
        // /Applications and a relaunched IDE all give the same id but not always the same string.
        let wanted = Bundle(path: bundle)?.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications
        guard !cwd.isEmpty,
              let app = running.first(where: { $0.bundleURL?.path == bundle })
                     ?? running.first(where: { $0.bundleIdentifier != nil && $0.bundleIdentifier == wanted })
        else {
            NSLog("ClaudeStatusBar: \(bundle) (\(wanted ?? "no id")) is not among the running apps")
            return false
        }
        guard AXIsProcessTrusted() else {
            NSLog("ClaudeStatusBar: no Accessibility access — activating the IDE instead of its window")
            promptForAccessibilityOnce()
            return false
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            NSLog("ClaudeStatusBar: Accessibility returned no window list for \(bundle)")
            return false
        }
        let titles = windows.map { win -> String in
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t)
            return t as? String ?? ""
        }
        // A JetBrains frame is titled "<project> – <file>" (or "<project> [branch] – <file>"), so the
        // project name is the leading word. Walking up from cwd means the innermost match wins: a
        // worktree opened as its own project beats the repo it lives in, and a session in a
        // subdirectory still resolves to the project window above it.
        var dir = cwd
        while dir.count > 1 {
            let name = (dir as NSString).lastPathComponent
            if let i = titles.firstIndex(where: { $0 == name || $0.hasPrefix(name + " ") }) {
                let win = windows[i]
                // Raised repeatedly on purpose: activating an app restores whichever window it had
                // in front, and that restore lands asynchronously, after our first raise. Once
                // before the activation, then twice behind it, so the last word is ours.
                NSLog("ClaudeStatusBar: raising \"\(titles[i])\" for \(cwd)")
                raise(win)
                app.activate(options: [])
                for delay in [0.15, 0.45] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.raise(win) }
                }
                return true
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        NSLog("ClaudeStatusBar: no window matched \(cwd) — \(titles.count) titles: \(titles)")
        return false
    }

    private func raise(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    // The system's "grant Accessibility access" alert fires once per app, and an .accessory app has
    // no Dock icon to bounce, so the alert is easy to miss entirely: open the settings pane too, on
    // the very pane holding the switch. Both happen once per launch — repeat clicks stay quiet.
    private func promptForAccessibilityOnce() {
        guard !accessibilityPrompted else { return }
        accessibilityPrompted = true
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // The .app bundle owning <pid>, found by walking parent PIDs (the session's `claude` → shell →
    // the terminal or IDE that spawned it). Needed because a process's environment — where
    // TERM_PROGRAM would live — can't be read from another process on macOS, so a terminal that
    // never exports it is invisible to the hooks. Claude's own launcher bundle sits in that chain
    // between `claude` and the shell, and is skipped so the walk reaches the real host app.
    func owningAppBundle(_ pid: Int32) -> String? {
        var cur = pid
        for _ in 0..<12 {
            guard cur > 1 else { return nil }
            if let exec = executablePath(cur), let bundle = appBundlePath(exec),
               !bundle.hasSuffix("/ClaudeCode.app") { return bundle }
            cur = parentPID(cur)
        }
        return nil
    }

    private func executablePath(_ pid: Int32) -> String? {
        // 4 * MAXPATHLEN, i.e. PROC_PIDPATHINFO_MAXSIZE — the macro itself doesn't import into Swift.
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private func parentPID(_ pid: Int32) -> Int32 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    // "/Applications/WebStorm.app/Contents/MacOS/webstorm" -> "/Applications/WebStorm.app"
    private func appBundlePath(_ exec: String) -> String? {
        guard let r = exec.range(of: ".app/Contents/MacOS/") else { return nil }
        return String(exec[exec.startIndex..<r.lowerBound]) + ".app"
    }

    // The one JetBrains IDE currently running, if there's exactly one — used only when the process
    // tree names no app. Two IDEs open and we can't tell which holds the project, so we don't guess.
    // Toolbox is skipped: it's the launcher, never a window a session could live in.
    func loneRunningJetBrainsIDE() -> String? {
        let ides = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return id.hasPrefix("com.jetbrains") && id != "com.jetbrains.toolbox" && $0.activationPolicy == .regular
        }
        return ides.count == 1 ? ides.first?.bundleURL?.path : nil
    }

    func isJetBrains(_ bundle: String) -> Bool {
        Bundle(path: bundle)?.bundleIdentifier?.hasPrefix("com.jetbrains") == true
    }


    @objc func chooseColor(_ sender: NSMenuItem) {
        guard let sys = sender.representedObject as? Bool else { return }
        iconSystem = sys
        UserDefaults.standard.set(iconSystem, forKey: "iconSystem")
        iconCache.removeAll()
        evaluate() // re-render the current state in the new color
    }

    @objc func chooseSound(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        soundThreshold = n.doubleValue
        UserDefaults.standard.set(soundThreshold, forKey: "soundThreshold")
    }

    @objc func chooseStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = AnimStyle(rawValue: raw) else { return }
        animStyle = st
        UserDefaults.standard.set(raw, forKey: "animStyle")
        iconCache.removeAll()
        animTimer?.invalidate(); animTimer = nil // recreate at the new style's fps
        frameIdx = 0
        evaluate()
    }

    // MARK: state polling

    func tick() {
        checkLifecycle()
        reloadSessions()
        evaluate()
        if menuIsOpen { refreshOpenMenuRows() }
        if overlayVisible { overlay.refresh() }
    }

    // The .json session files currently in state.d/ (ignores the .tmp files mid-write).
    func stateFileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: stateDir)) ?? []).filter { $0.hasSuffix(".json") }
    }

    // Refresh `sessions` from state.d/, re-parsing only files whose mtime changed (writes are
    // atomic renames, so a content update bumps mtime and is never read torn).
    func reloadSessions() {
        let fm = FileManager.default
        let files = stateFileNames()
        let present = Set(files)
        for key in Array(fileMTimes.keys) where !present.contains(key) {
            fileMTimes[key] = nil
            sessions[(key as NSString).deletingPathExtension] = nil
        }
        for f in files {
            let full = (stateDir as NSString).appendingPathComponent(f)
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let m = attrs[.modificationDate] as? Date else { continue }
            if fileMTimes[f] == m { continue }
            fileMTimes[f] = m
            guard let data = fm.contents(atPath: full),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = (f as NSString).deletingPathExtension
            var s = Session(json: o, id: id)
            // A hook event means activity in that cwd, which may have JUST become a repo (git init /
            // first branch mid-session) — a cached "" (non-git) would otherwise stick until app restart.
            if gitHeadCache[s.cwd] == "" { gitHeadCache[s.cwd] = nil }
            s.branch = branchForCwd(s.cwd)   // only on file change (a hook event), never on a bare tick
            sessions[id] = s
        }
    }

    // MARK: git branch (no `git` spawn — .git/HEAD is a tiny text file)

    // Resolve <cwd>'s HEAD path by walking toward /. A worktree/submodule has .git as a FILE
    // containing "gitdir: <path>". Resolution walks directories, so cache it per cwd; a cached
    // "" means confirmed non-git. Dropped by branchForCwd if the HEAD read later fails.
    func gitHeadPath(_ cwd: String) -> String? {
        if let hit = gitHeadCache[cwd] { return hit.isEmpty ? nil : hit }
        let fm = FileManager.default
        var dir = cwd, isDir: ObjCBool = false
        for _ in 0..<40 {
            let g = (dir as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: g, isDirectory: &isDir) {
                var head: String? = nil
                if isDir.boolValue {
                    head = (g as NSString).appendingPathComponent("HEAD")
                } else if let d = fm.contents(atPath: g), d.count <= 4096,
                          let s = String(data: d, encoding: .utf8),
                          let line = s.split(separator: "\n").first, line.hasPrefix("gitdir: ") {
                    var gd = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                    if !gd.hasPrefix("/") { gd = ((dir as NSString).appendingPathComponent(gd) as NSString).standardizingPath }
                    head = (gd as NSString).appendingPathComponent("HEAD")
                }
                gitHeadCache[cwd] = head ?? ""
                return head
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        gitHeadCache[cwd] = ""
        return nil
    }

    // HEAD is "ref: refs/heads/<branch>" on a branch, a bare commit hash when detached.
    // nil (no branch text, no error) for non-git dirs and anything unrecognized.
    func branchForCwd(_ cwd: String) -> String {
        guard !cwd.isEmpty, let headPath = gitHeadPath(cwd) else { return "" }
        guard let d = FileManager.default.contents(atPath: headPath), d.count <= 1024,
              let s = String(data: d, encoding: .utf8) else {
            gitHeadCache[cwd] = nil   // stale resolution (repo moved/deleted) — retry next time
            return ""
        }
        let head = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst(16)) }
        if head.hasPrefix("ref: ") { return ((head as NSString).lastPathComponent) }
        if (40...64).contains(head.count), head.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            return String(head.prefix(7))   // detached HEAD -> short SHA
        }
        return ""
    }

    // Working->done edge for the completion chime, gated on turn length >= soundThreshold (0 = off).
    // Reads prevState, which the evaluate() loop writes only AFTER this runs, so it must be called
    // there before that write. Tracks the turn's start while the session is working.
    func completionEdge(_ s: Session, now: Double) -> Bool {
        if s.state == "thinking" || s.state == "tool", s.startedAt > 0 { turnStart[s.id] = s.startedAt }
        let prev = prevState[s.id] ?? ""
        var edge = false
        if soundThreshold > 0, s.state == "done", prev != "done", let st = turnStart[s.id], st > 0, now - st >= soundThreshold { edge = true }
        if s.state == "done" { turnStart[s.id] = 0 }
        return edge
    }

    func evaluate() {
        let now = Date().timeIntervalSince1970
        var chime = false

        for id in Array(sessions.keys) {
            guard var s = sessions[id] else { continue }
            s.eff = effectiveState(s, now: now)   // compute once per tick; the menu + tooltip reuse it
            // Reap on PROCESS death, not idle time: a session leaves only when its `claude` process is
            // gone (closed/crashed terminal, quit app), so an idle-but-open session stays and the icon
            // holds. Pre-upgrade files have no pid (0) — fall back to the old idle+age prune so they
            // can't linger forever. This is also what keeps state.d self-cleaning (no growing cache).
            let dead = s.pid > 0 ? !pidAlive(s.pid)
                                 : (s.eff == "idle" && stalePruneAge > 0 && now - s.ts > stalePruneAge)
            if dead {
                try? FileManager.default.removeItem(atPath: (stateDir as NSString).appendingPathComponent(id + ".json"))
                sessions[id] = nil; fileMTimes[id + ".json"] = nil; prevState[id] = nil; sessionWord[id] = nil; turnStart[id] = nil
                continue
            }
            sessions[id] = s
            updateThinkingWord(s)
            if completionEdge(s, now: now) { chime = true }
            prevState[s.id] = s.state
        }
        for id in Array(prevState.keys) where sessions[id] == nil { prevState[id] = nil; sessionWord[id] = nil; turnStart[id] = nil }
        if chime { completionSound?.play() }

        // Same-named projects (two clones/worktrees of one repo) get a parent-folder qualifier
        // ("work/myrepo" vs "tmp/myrepo") so their rows stay tellable apart. Runs after the reap so
        // dead sessions can't force a qualifier onto a now-unique name.
        // Only non-empty cwds count as colliding locations: a pre-upgrade/warmup file without cwd is
        // location-unknown, and counting its "" as a distinct place forced a bogus qualifier onto a
        // genuinely unique row.
        var cwdsByProject: [String: Set<String>] = [:]
        for s in sessions.values where !s.project.isEmpty && !s.cwd.isEmpty { cwdsByProject[s.project, default: []].insert(s.cwd) }
        for id in Array(sessions.keys) {
            guard var s = sessions[id] else { continue }
            if !s.cwd.isEmpty, (cwdsByProject[s.project]?.count ?? 0) > 1 {
                let parent = (((s.cwd as NSString).deletingLastPathComponent) as NSString).lastPathComponent
                s.displayName = parent.isEmpty ? s.project : parent + "/" + s.project
            } else {
                s.displayName = s.project
            }
            sessions[id] = s
        }

        // Surface the single highest-priority session (permission > working > …); ties broken by
        // recency, so within a tier the most recently active session wins.
        let lead = sessions.values.max { a, b in
            let pa = priority(of: a.eff), pb = priority(of: b.eff)
            return pa == pb ? a.ts < b.ts : pa < pb
        }
        statusItem.button?.toolTip = lead.map(sessionMenuLine)  // names repo + surface + state on hover

        // The overlay window already shows every session live, state pill and timer included, so the
        // bar would only be repeating it — and two things animating for one event is the noise this
        // app exists to avoid. While the overlay is up the icon just rests: no spinner, no clock, no
        // permission dot. Closing it puts the status back on the next tick.
        if overlayVisible { renderResting(); return }

        guard let lead = lead else { renderResting(); return }
        switch lead.eff {
        case "permission":
            render(label: statusText(lead, eff: lead.eff), color: amber, animate: false, startedAt: 0, dot: true)
        case "thinking", "tool":
            render(label: statusText(lead, eff: lead.eff), color: iconColor, animate: true, startedAt: lead.startedAt)
        default:
            renderResting()
        }
    }

    func renderResting() { render(label: "", color: iconColor, animate: false, startedAt: 0) }

    // Per-session effective state with two recovery nets: an absolute age cap, plus the transcript
    // "interrupted by user" marker (Esc / denied permission fire no hook, freezing the file). "done"
    // collapses to rest.
    // effectiveState runs every tick for every working session; re-tailing the transcript each
    // time was 8KB of file I/O per session at 2.5 Hz. Transcripts only grow when text streams
    // (~20s apart), so gate the read on mtime.
    func cachedLastTurnLine(_ path: String) -> String? {
        let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let hit = turnLineCache[path], hit.mtime == m { return hit.line }
        let line = lastTurnLine(ofFileAt: path)
        turnLineCache[path] = (m, line)
        return line
    }

    func effectiveState(_ s: Session, now: Double) -> String {
        if s.state == "thinking" || s.state == "tool" || s.state == "permission" {
            let cap: Double = s.state == "permission" ? 7200 : 900
            if now - s.ts > cap { return "idle" }
            if !s.transcript.isEmpty, let last = cachedLastTurnLine(s.transcript),
               last.contains("interrupted by user") { return "idle" }
            return s.state
        }
        return s.state == "done" ? "idle" : s.state
    }


    // MARK: self-quit lifecycle

    // Asking LaunchServices on every tick meant a synchronous XPC round-trip at 2.5 Hz. Workspace
    // notifications keep a flag instead; the authoritative query runs only at the quit decision,
    // so a missed notification can delay a quit by one debounce but can never quit under a live app.
    func claudeDesktopRunningLive() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: claudeDesktopBundleID).isEmpty
    }

    func observeDesktopApp() {
        desktopRunning = claudeDesktopRunningLive()
        let nc = NSWorkspace.shared.notificationCenter
        for (name, running) in [(NSWorkspace.didLaunchApplicationNotification, true),
                                (NSWorkspace.didTerminateApplicationNotification, false)] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == self.claudeDesktopBundleID else { return }
                self.desktopRunning = running
            }
        }
    }

    func sessionCount() -> Int { stateFileNames().count }

    // Liveness probe: is this session's `claude` process still alive? kill(pid,0) returns 0 if the
    // process exists; EPERM = exists but not ours (won't happen, same user); ESRCH = gone.
    func pidAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // Stay while Claude desktop is open OR a session is active; otherwise quit after a
    // short debounced grace (warmup-session churn must not kill us).
    func checkLifecycle() {
        let now = Date()
        if now.timeIntervalSince(launchedAt) < launchGrace { return }
        if desktopRunning || sessionCount() > 0 {
            notNeededSince = nil
            return
        }
        if let since = notNeededSince {
            if now.timeIntervalSince(since) >= idleQuitDelay {
                if claudeDesktopRunningLive() { desktopRunning = true; notNeededSince = nil; return }
                NSApp.terminate(nil)
            }
        } else {
            notNeededSince = now
        }
    }

    // Read the last non-empty line of a (possibly large) file by tailing ~8KB.
    func lastLine(ofFileAt path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk: UInt64 = 8192
        try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? fh.readToEnd(), let s = String(data: data, encoding: .utf8) else { return nil }
        return s.split(separator: "\n").last { !$0.isEmpty }.map(String.init)
    }

    // Last actual turn line (a user/assistant message), ignoring the bookkeeping lines Claude Code
    // appends after an interrupt (system/away_summary, last-prompt, ai-title, mode, permission-mode).
    // Those would otherwise hide the "interrupted by user" marker and freeze the amber dot.
    func lastTurnLine(ofFileAt path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk: UInt64 = 8192
        try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? fh.readToEnd(), let s = String(data: data, encoding: .utf8) else { return nil }
        return s.split(separator: "\n").last {
            $0.contains("\"type\":\"user\"") || $0.contains("\"type\":\"assistant\"")
        }.map(String.init)
    }

    // MARK: render

    func render(label: String, color: NSColor?, animate: Bool, startedAt: Double, dot: Bool = false) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil // we paint the icon color ourselves; template-tint is unreliable
        activeBase = label
        activeColor = color
        self.startedAt = startedAt

        if animate {
            if animTimer == nil {
                let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.animStep() }
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
            }
        } else {
            animTimer?.invalidate(); animTimer = nil
            frameIdx = 0
            button.image = dot ? dotIcon(color: color) : restingIcon(color: color)
        }
        applyTitle()
        if button.image == nil { button.image = dot ? dotIcon(color: color) : restingIcon(color: color) }
    }

    func animStep() {
        frameIdx = (frameIdx + 1) % frameCount
        statusItem.button?.image = iconImage(color: activeColor, frame: frameIdx)
        applyTitle() // refresh the elapsed clock
    }

    func applyTitle() {
        guard let button = statusItem.button else { return }
        var text = activeBase
        if showTimer, startedAt > 0 {
            text += "  " + elapsed(max(0, Int(Date().timeIntervalSince1970 - startedAt)))
        }
        // Assigning attributedTitle re-shapes the string through CoreText and re-snapshots the
        // status item bitmap, so at animation fps an unchanged title costs a full redraw per frame
        // (the clock only ticks at 1 Hz). labelColor is dynamic and resolves at draw, so skipping
        // the assignment still tracks light/dark menu bars.
        guard text != lastTitleText else { return }
        lastTitleText = text
        if text.isEmpty {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        button.imagePosition = .imageLeading
        // labelColor adapts: white on a dark menu bar, black on a light one. Monospaced
        // digits keep the elapsed clock from nudging neighboring menu bar icons.
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular),
        ]
        button.attributedTitle = NSAttributedString(string: " \(text)", attributes: attrs)
    }

    // MARK: icon

    static func loadFrames() -> [NSImage] { decodePNGs(claudeSparkFramePNGs) }
    static func decodePNGs(_ list: [String]) -> [NSImage] {
        list.compactMap { Data(base64Encoded: $0).flatMap(NSImage.init(data:)) }
    }

    func iconImage(color: NSColor?, frame: Int) -> NSImage {
        let key = "\(animStyle.rawValue)|\(frame)|\(color == nil ? "template" : color!.description)"
        if let cached = iconCache[key] { return cached }
        let img = buildIconImage(color: color, frame: frame)
        iconCache[key] = img
        return img
    }

    func buildIconImage(color: NSColor?, frame: Int) -> NSImage {
        if animStyle == .web { return tint(frames, color: color, frame: frame) }
        if animStyle == .crab { return crabIcon(color: color, frame: frame) }
        let i = (frame / codeSub) % codeGlyphs.count
        let local = (CGFloat(frame % codeSub) + 0.5) / CGFloat(codeSub) // 0…1 within this glyph
        // Scale envelope per glyph: rise, hold at peak, fall, so each lands before the swap.
        let env: CGFloat
        if local < 0.30 { let u = local / 0.30; env = u * u * (3 - 2 * u) }
        else if local > 0.70 { let u = (1 - local) / 0.30; env = u * u * (3 - 2 * u) }
        else { env = 1 }
        let scale = codeDip + (codePeaks[i] - codeDip) * env
        return codeIcon(color: color, glyph: i, scale: scale)
    }

    // nil color => adaptive template image (system draws it black/white per the menu bar).
    func codeIcon(color: NSColor?, glyph: Int, scale: CGFloat) -> NSImage {
        let s: CGFloat = 18
        guard glyph < codeGlyphMasks.count else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = codeGlyphMasks[glyph]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let dw = s * scale
            let r = NSRect(x: (s - dw) / 2, y: (s - dw) / 2, width: dw, height: dw)
            if let c = color {
                c.setFill(); r.fill()
                mask.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Rasterize a single glyph into a centered 60x60 alpha mask filling ~92%.
    static func glyphMask(_ g: String) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 180), .foregroundColor: NSColor.black,
        ]
        let str = NSAttributedString(string: g, attributes: attrs)
        let sz = str.size()
        let big = NSImage(size: sz, flipped: false) { _ in str.draw(at: .zero); return true }
        guard let rep = big.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
            return NSImage(size: NSSize(width: 60, height: 60))
        }
        let w = rep.pixelsWide, h = rep.pixelsHigh, data = rep.bitmapData!
        var minx = w, miny = h, maxx = -1, maxy = -1
        for y in 0..<h { for x in 0..<w where data[(y*w+x)*4+3] > 20 {
            minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
        }}
        guard maxx >= 0 else { return NSImage(size: NSSize(width: 60, height: 60)) }
        let bw = CGFloat(maxx - minx + 1), bh = CGFloat(maxy - miny + 1)
        let out: CGFloat = 60, fill = out * 0.92
        let scale = fill / max(bw, bh)
        let dw = bw * scale, dh = bh * scale
        // NSBitmapImageRep origin is top-left; convert the bbox to bottom-left for drawing.
        let srcRect = NSRect(x: CGFloat(minx), y: CGFloat(h - maxy - 1), width: bw, height: bh)
        return NSImage(size: NSSize(width: out, height: out), flipped: false) { _ in
            big.draw(in: NSRect(x: (out - dw)/2, y: (out - dh)/2, width: dw, height: dh),
                     from: srcRect, operation: .sourceOver, fraction: 1.0)
            return true
        }
    }

    let logoSet: [NSImage] = Data(base64Encoded: claudeLogoPNG).flatMap(NSImage.init(data:)).map { [$0] } ?? []
    func restingIcon(color: NSColor?) -> NSImage {
        if animStyle == .crab { return crabIcon(color: color, frame: 0) }
        return tint(logoSet.isEmpty ? frames : logoSet, color: color, frame: 0)
    }

    // nil color (System) => adaptive shaded template (see adaptiveCrabFrame in CrabRender.swift);
    // non-nil (Orange) => the original full-color sprite, drawn as-is.
    func crabIcon(color: NSColor?, frame: Int) -> NSImage {
        guard !crabFrames.isEmpty else { return NSImage(size: NSSize(width: 18, height: 18)) }
        let pool = color == nil ? crabTemplateFrames : crabFrames
        let src = pool[frame % pool.count]
        let rep = src.representations.first
        let pw = CGFloat(rep?.pixelsWide ?? Int(src.size.width))
        let ph = CGFloat(rep?.pixelsHigh ?? Int(src.size.height))
        let h: CGFloat = 18, w = (ph > 0 ? h * (pw / ph) : h)
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    func dotIcon(color: NSColor?) -> NSImage {
        let s: CGFloat = 18, d: CGFloat = 9
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            (color ?? .systemYellow).setFill()
            NSBezierPath(ovalIn: NSRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Paint `color` through a frame mask's alpha (destinationIn) so frames recolor.
    func tint(_ set: [NSImage], color: NSColor?, frame: Int) -> NSImage {
        let s: CGFloat = 18
        guard !set.isEmpty else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = set[frame % set.count]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            if let c = color {
                c.setFill()
                rect.fill()
                mask.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil) // nil => adaptive black/white in the menu bar
        return img
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
