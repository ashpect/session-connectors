import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The "pick a pane" gesture: click Pick (a thread follows your cursor out of Relay) → click any
/// iTerm pane → it docks. Right-click or Esc cancels.
final class PickController {
    private let store: RelayStore
    private weak var panel: NSPanel?
    private var chip: NSPanel?
    private var followTimer: Timer?
    private var monitors: [Any] = []
    private let thread = ThreadOverlay()
    private static let chipSize = NSSize(width: 360, height: 84)

    init(store: RelayStore, panel: NSPanel) {
        self.store = store
        self.panel = panel
    }

    /// ⊕ / Pick button: the thread starts at the button you just clicked.
    func begin() {
        guard store.pick == .idle else { return cancel() }
        let m = NSEvent.mouseLocation
        store.pick = .armed
        start()
        thread.attach(at: panel?.frame.contains(m) == true ? m : pickButtonPoint, color: NSColor(Theme.live))
    }

    /// ⌥⌘P: from inside an iTerm pane, dock it straight away; from anywhere else, same as Pick.
    func hotkeyPressed() {
        if store.pick != .idle { return cancel() }
        guard ITerm.isFrontmost else {
            store.pick = .armed
            start()
            return thread.attach(at: pickButtonPoint, color: NSColor(Theme.live))
        }
        let paneAt = NSEvent.mouseLocation
        ITerm.currentSession { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let s):
                thread.attach(at: pickButtonPoint, color: NSColor(s.kind.tint))
                thread.connect(to: paneAt, color: NSColor(s.kind.tint), fromAnchor: true) { self.store.dock(s) }
            case .failure(let e):
                store.notice = e.message
            }
        }
    }

    func cancel() {
        store.pick = .idle
        store.pickTarget = nil
        stop()
        thread.reelBack()
    }

    /// Roughly where the Pick button sits in the panel header.
    private var pickButtonPoint: NSPoint {
        guard let f = panel?.frame else { return NSEvent.mouseLocation }
        return NSPoint(x: f.maxX - 72, y: f.maxY - 23)
    }

    // MARK: -

    private func start() {
        showChip()
        followTimer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.follow() }
        RunLoop.main.add(followTimer!, forMode: .common)
        follow()

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            self?.handleOutsideClick(e)
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .keyDown], handler: { [weak self] e in
            self?.handleInsideEvent(e) ?? e
        }) { monitors.append(m) }
    }

    private func stop() {
        followTimer?.invalidate()
        followTimer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let chip {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; chip.animator().alphaValue = 0 },
                                                 completionHandler: { chip.orderOut(nil) })
        }
        chip = nil
    }

    private func handleOutsideClick(_ e: NSEvent) {
        if e.type == .rightMouseDown { return cancel() }
        let clickedAt = NSEvent.mouseLocation
        thread.pin(at: clickedAt)
        // The click lands in iTerm first and focuses the pane; read the focused pane just after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, store.pick != .idle else { return }
            guard ITerm.isFrontmost else { return miss() }
            ITerm.currentSession { [weak self] result in
                guard let self, store.pick != .idle else { return }
                switch result {
                case .success(let s):
                    store.pick = .idle
                    stop()
                    thread.connect(to: clickedAt, color: NSColor(s.kind.tint)) { self.store.dock(s) }
                case .failure(let e):
                    store.notice = e.message
                    miss()
                }
            }
        }
    }

    private func miss() {
        store.pick = .miss
        thread.release()
        thread.setColor(NSColor(Theme.danger), animated: true)
    }

    private func handleInsideEvent(_ e: NSEvent) -> NSEvent? {
        switch e.type {
        case .rightMouseDown:
            cancel()
            return nil
        case .keyDown where e.keyCode == UInt16(kVK_Escape):
            cancel()
            return nil
        default:
            return e
        }
    }

    private func showChip() {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.chipSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentView = NSHostingView(rootView: CursorChip().environment(store))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        chip = p
    }

    private func follow() {
        let m = NSEvent.mouseLocation
        chip?.setFrameOrigin(NSPoint(x: m.x + 10, y: m.y - 10 - Self.chipSize.height))
    }
}

/// System-wide shortcuts through Carbon (they work without Accessibility permission).
enum HotKeys {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false

    /// Returns false if another app already owns the combination.
    @discardableResult
    static func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> Bool {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                DispatchQueue.main.async { HotKeys.actions[id.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let n = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x524C_4159), id: n),
                                         GetApplicationEventTarget(), 0, &ref)  // 'RLAY'
        guard status == noErr, let ref else { return false }
        actions[n] = action
        refs.append(ref)
        return true
    }
}
