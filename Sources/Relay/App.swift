import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
enum Main {
    static func main() {
        // Installed as ~/.relay/relay-hook, the same binary runs as the Claude Code / Codex hook.
        if (CommandLine.arguments[0] as NSString).lastPathComponent == "relay-hook" { HookCLI.run() }
        // `Relay --dump-presets` prints the built-in presets as JSON (the same shape as ~/.relay/presets.json).
        if CommandLine.arguments.contains("--dump-presets") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: (try? encoder.encode(Preset.builtIns)) ?? Data(), as: UTF8.self))
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = RelayStore()
    private var panel: RelayPanel!
    private var picker: PickController!
    private var fadeTimer: Timer?
    private var hiding = false
    private var statusItem: NSStatusItem!
    private var hookServer: HookServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = RelayPanel(size: NSSize(width: 430, height: 600))

        // The blur is the window's content view; SwiftUI sits on top of it.
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = .roundedMask(radius: 18)
        let host = NSHostingView(rootView: RootView().environment(store))
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        panel.contentView = glass

        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 28, y: screen.maxY - panel.frame.height - 28))
        }
        panel.orderFrontRegardless()

        let isSnapshot = CommandLine.arguments.contains { $0.hasSuffix("snapshot") }
        if !isSnapshot {
            store.load()
            store.startSaving()
            let server = HookServer { [weak self] event in self?.store.handle(event) }
            if server.start() { hookServer = server } else { store.notice = "Relay couldn't open its socket at \(RelayPaths.socket)." }
            store.checkHooks()
            if CommandLine.arguments.contains("--start-flows") {
                for f in store.flows where f.isComplete { store.start(f.id) }
            }
            if CommandLine.arguments.contains("--arm-flows") {
                for f in store.flows where f.isComplete { store.arm(f.id) }
            }
        }

        picker = PickController(store: store, panel: panel)
        store.picker = picker
        store.togglePanel = { [weak self] in self?.togglePanel() }
        registerShortcuts()
        setUpMenuBarIcon()
        store.startPolling()

        if let i = CommandLine.arguments.firstIndex(of: "--thread-snapshot"), i + 1 < CommandLine.arguments.count {
            // Scripted pick: armed from the Pick button → click a pane → it latches, then reels into Relay.
            let out = CommandLine.arguments[i + 1], thread = ThreadOverlay()
            // `--thread-to x,y` puts the clicked pane somewhere else, e.g. on another display.
            var pane = NSPoint(x: 350, y: 600)
            if let j = CommandLine.arguments.firstIndex(of: "--thread-to"), j + 1 < CommandLine.arguments.count {
                let xy = CommandLine.arguments[j + 1].split(separator: ",").compactMap { Double($0) }
                if xy.count == 2 { pane = NSPoint(x: xy[0], y: xy[1]) }
            }
            let button = NSPoint(x: 1100, y: 1000)
            func save(_ name: String) {
                try? thread.debugImage()?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + name + ".png"))
            }
            thread.attach(at: button, color: NSColor(Theme.live))
            thread.debugScreens().forEach { print("overlay", $0) }
            thread.debugRun(frames: 240, cursor: pane)
            save("1-armed")
            thread.pin(at: pane)
            thread.connect(to: pane, color: NSColor(Theme.claude)) {}
            let away = NSPoint(x: pane.x + 70, y: pane.y - 40)
            thread.debugRun(frames: 30, cursor: away)
            save("2-latched")
            thread.debugRun(frames: 16, cursor: away)
            save("3-reeling")
            NSApp.terminate(nil)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            snapshot(to: CommandLine.arguments[i + 1])
            return
        }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateFade() }
    }

    /// ⌃⌥K shows/hides Relay from anywhere; ⌥⌘P picks a pane (and brings Relay up first).
    private func registerShortcuts() {
        var taken: [String] = []
        if !HotKeys.register(keyCode: kVK_ANSI_K, modifiers: controlKey | optionKey, action: { [weak self] in self?.togglePanel() }) {
            taken.append("⌃⌥K")
        }
        if !HotKeys.register(keyCode: kVK_ANSI_P, modifiers: cmdKey | optionKey, action: { [weak self] in
            self?.showPanel()
            self?.picker.hotkeyPressed()
        }) {
            taken.append("⌥⌘P")
        }
        if !taken.isEmpty { store.notice = "Another app already uses \(taken.joined(separator: " and ")), so that shortcut won't work." }
    }

    /// Menu bar icon: click shows/hides Relay, right-click for a menu.
    private func setUpMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = .relayMenuBarIcon
        button.toolTip = "Relay · click to show/hide (⌃⌥K)"
        button.target = self
        button.action = #selector(menuBarIconClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func menuBarIconClicked() {
        let event = NSApp.currentEvent
        guard event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true else { return togglePanel() }

        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: panel.isVisible && !hiding ? "Hide Relay" : "Show Relay",
                                  action: #selector(togglePanelAction), keyEquivalent: "k")
        toggle.keyEquivalentModifierMask = [.control, .option]
        let pick = menu.addItem(withTitle: "Pick a pane", action: #selector(pickAction), keyEquivalent: "p")
        pick.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Relay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // so the next left-click toggles instead of opening the menu
    }

    @objc private func togglePanelAction() { togglePanel() }

    @objc private func pickAction() {
        showPanel()
        picker.begin()
    }

    func togglePanel() {
        panel.isVisible && !hiding ? hidePanel() : showPanel()
    }

    /// Brings Relay up; if it's on another display, it comes to the one your cursor is on.
    func showPanel() {
        guard !panel.isVisible || hiding else { return }
        hiding = false
        let m = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }), !screen.frame.intersects(panel.frame) {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 28, y: v.maxY - panel.frame.height - 28))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = CGFloat(store.opacity) }
    }

    func hidePanel() {
        if store.pick != .idle { picker.cancel() }
        hiding = true
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }, completionHandler: { [weak self] in
            guard let self, hiding else { return }
            hiding = false
            panel.orderOut(nil)
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.save()
    }

    /// Opening Relay.app again while it's running (Spotlight, Finder) brings the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    /// Debug: `Relay --snapshot out.png [--demo] [--sim] [--pick]` renders the panel to a PNG and quits.
    private func snapshot(to path: String) {
        let args = CommandLine.arguments
        panel.alphaValue = 0.01
        if args.contains("--tall") { panel.setContentSize(NSSize(width: 430, height: 1060)) }
        if args.contains("--demo") { store.loadDemo() }
        if args.contains("--settings") { store.showingSettings = true }
        if let i = args.firstIndex(of: "--delay"), let d = Double(args[i + 1]) { store.sendDelay = d }
        if let i = args.firstIndex(of: "--preset"), let p = store.allPresets.first(where: { $0.id == "builtin." + args[i + 1] }) {
            store.apply(p, to: store.flows[0].id)
        }
        if args.contains("--saved-preset") {
            store.presets = [Preset(from: store.flows[0], name: "My review loop")]
            store.flows[0].presetID = store.presets[0].id
            store.flows[0].stopPhrase = "SHIP IT"
        }
        if args.contains("--needs-you") {
            store.flows[0].halted = "Codex said \u{201C}NEEDS HUMAN\u{201D}"
            store.flows[0].needsYou = true
            store.flows[0].rounds = 2
        }
        if args.contains("--empty-slots") { store.flows[0].a = nil; store.flows[0].b = nil; store.sessions = [] }
        if args.contains("--oneway") { store.flows[0].loop = false }
        if args.contains("--half") { store.flows[0].b = nil }
        if args.contains("--peek"), let a = store.flows[0].a { store.peeking.insert(a) }
        if args.contains("--sim") { store.start(store.flows[0].id) }
        if args.contains("--pick") { store.pick = .armed }
        let wait = args.firstIndex(of: "--at").flatMap { Double(args[$0 + 1]) } ?? (args.contains("--sim") ? 10 : 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            let view = panel.contentView!
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
            // Always render at 2x, whatever display this happens to run on.
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    /// Fades the panel back when the cursor isn't over it, so it doesn't cover your terminals.
    private func updateFade() {
        guard panel.isVisible, !hiding else { return }
        let hovered = panel.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
        let awake = hovered || store.pick != .idle || panel.isKeyWindow || store.simulating || !store.fadeWhenIdle
        let target = CGFloat(awake ? store.opacity : store.opacity * 0.5)
        guard abs(panel.alphaValue - target) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = awake ? 0.15 : 0.6
            panel.animator().alphaValue = target
        }
    }
}

final class RelayPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false
        minSize = NSSize(width: 360, height: 340)
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // An accessory app has no Edit menu, so wire up the usual text shortcuts by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        let action: Selector? = switch key {
        case "x": #selector(NSText.cut(_:))
        case "c": #selector(NSText.copy(_:))
        case "v": #selector(NSText.paste(_:))
        case "a": #selector(NSText.selectAll(_:))
        case "z": shift ? Selector(("redo:")) : Selector(("undo:"))
        case "q": #selector(NSApplication.terminate(_:))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

extension NSImage {
    /// Two dots joined by a sagging thread, drawn as a template so it follows the menu bar's color.
    static let relayMenuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let a = NSPoint(x: 3.5, y: 12), b = NSPoint(x: 14.5, y: 12)
            let thread = NSBezierPath()
            thread.move(to: a)
            thread.curve(to: b, controlPoint1: NSPoint(x: 6, y: 2.5), controlPoint2: NSPoint(x: 12, y: 2.5))
            thread.lineWidth = 1.6
            thread.lineCapStyle = .round
            thread.stroke()
            for p in [a, b] { NSBezierPath(ovalIn: NSRect(x: p.x - 2.6, y: p.y - 2.6, width: 5.2, height: 5.2)).fill() }
            return true
        }
        image.isTemplate = true
        return image
    }()

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Dragging here moves the panel (it has no title bar).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
