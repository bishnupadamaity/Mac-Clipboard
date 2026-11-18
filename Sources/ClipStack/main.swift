import ClipStackCore
import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import os.log

// MARK: - SwiftUI popup

struct HistoryView: View {
    @ObservedObject var store: ClipStore
    var onPick: (ClipItem) -> Void
    var onClose: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private var filtered: [ClipItem] {
        let base = query.isEmpty
            ? store.items
            : store.items.filter { $0.text.localizedCaseInsensitiveContains(query) }
        return base.filter(\.pinned) + base.filter { !$0.pinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search clipboard…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(12)
                .focused($searchFocused)
                .accessibilityLabel("Search clipboard history")
                .onSubmit { pickSelected() }
                .onChange(of: query) { _ in selection = 0 }
            Divider()
            if filtered.isEmpty {
                Spacer()
                Text(store.items.isEmpty ? "Copy something to get started" : "No matches")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                                row(item, index: index).id(index)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selection) { index in
                        withAnimation(.linear(duration: 0.1)) { scroller.scrollTo(index) }
                    }
                }
            }
        }
        .frame(width: 380, height: 460)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onExitCommand(perform: onClose)
        .onAppear { selection = 0; searchFocused = true }
        // ↑/↓ move the selection and ⏎ pastes it, so the list is usable without
        // reaching for the mouse or memorising ⌘1…⌘9.
        .background {
            VStack {
                Button("") { move(-1) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { move(1) }.keyboardShortcut(.downArrow, modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selection = min(max(selection + delta, 0), filtered.count - 1)
    }

    private func pickSelected() {
        guard filtered.indices.contains(selection) else { return }
        onPick(filtered[selection])
    }

    @ViewBuilder
    private func row(_ item: ClipItem, index: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index < 9 ? "⌘\(index + 1)" : "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 13))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onPick(item) }
            Button { store.togglePin(item) } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            .foregroundStyle(item.pinned ? Color.accentColor : .secondary)
            .accessibilityLabel(item.pinned ? "Unpin clip" : "Pin clip")
            Button { store.delete(item) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Delete clip")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(index == selection ? Color.accentColor.opacity(0.22)
                                         : Color.primary.opacity(0.05))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.pinned ? "Pinned clip: \(item.text)" : "Clip: \(item.text)")
        .accessibilityHint("Paste this clip into the previous app")
        .background(
            // Hidden button gives ⌘1…⌘9 quick-paste shortcuts.
            Group {
                if index < 9 {
                    Button("") { onPick(item) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        .opacity(0)
                }
            }
        )
    }
}


// MARK: - Preferences

/// A real preferences window. settings.json stays the source of truth and remains
/// hand-editable; this is the discoverable way to reach the same values.
struct PreferencesView: View {
    @ObservedObject var store: ClipStore
    var onHotKeyChange: () -> Void

    @State private var draft: ClipSettings
    @State private var recording = false
    @State private var excluded: String

    init(store: ClipStore, onHotKeyChange: @escaping () -> Void) {
        self.store = store
        self.onHotKeyChange = onHotKeyChange
        _draft = State(initialValue: store.settings)
        _excluded = State(initialValue: store.settings.excludedBundleIDs.joined(separator: "\n"))
    }

    var body: some View {
        Form {
            Section("Shortcut") {
                HStack {
                    Text(Shortcut.describe(code: draft.hotKeyCode, modifiers: draft.hotKeyModifiers))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .frame(minWidth: 70, alignment: .leading)
                    Button(recording ? "Press keys…" : "Change") { recording.toggle() }
                        .accessibilityLabel("Record a new shortcut")
                    if let error = AppDelegate.shared.hotKeyError {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                }
                .background(ShortcutRecorder(active: $recording) { code, modifiers in
                    draft.hotKeyCode = code
                    draft.hotKeyModifiers = modifiers
                    recording = false
                })
            }

            Section("History") {
                Stepper("Keep for \(draft.retentionDays) days (0 = forever)",
                        value: $draft.retentionDays, in: 0...365)
                Stepper("Largest clip: \(draft.maxItemKilobytes) KB",
                        value: $draft.maxItemKilobytes, in: 1...10_240, step: 64)
                Toggle("Keep styled text, HTML and file references", isOn: $draft.keepRichContent)
                Toggle("Clear unpinned clips when the screen locks", isOn: $draft.clearOnScreenLock)
                Toggle("Put the previous clipboard back after pasting",
                       isOn: $draft.restoreClipboardAfterPaste)
            }

            Section("Never record copies from") {
                TextEditor(text: $excluded)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 110)
                    .accessibilityLabel("Excluded application bundle identifiers, one per line")
                Text("One bundle identifier per line.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
        .onDisappear(perform: apply)
        .toolbar { Button("Apply", action: apply) }
    }

    private func apply() {
        var updated = draft
        updated.excludedBundleIDs = excluded
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let shortcutChanged = updated.hotKeyCode != store.settings.hotKeyCode
            || updated.hotKeyModifiers != store.settings.hotKeyModifiers
        store.apply(updated)
        if shortcutChanged { onHotKeyChange() }
    }
}

/// Captures the next key combination the user presses, so the shortcut can be set by
/// pressing it rather than by editing a key code.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var active: Bool
    var onCapture: (Int, Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = RecorderView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? RecorderView else { return }
        view.onCapture = onCapture
        view.listening = active
        if active { view.window?.makeFirstResponder(view) }
    }

    final class RecorderView: NSView {
        var onCapture: ((Int, Int) -> Void)?
        var listening = false
        override var acceptsFirstResponder: Bool { listening }

        override func keyDown(with event: NSEvent) {
            guard listening else { super.keyDown(with: event); return }
            // Carbon masks, matching what RegisterEventHotKey expects.
            var modifiers = 0
            if event.modifierFlags.contains(.control) { modifiers |= 0x1000 }
            if event.modifierFlags.contains(.option)  { modifiers |= 0x0800 }
            if event.modifierFlags.contains(.shift)   { modifiers |= 0x0200 }
            if event.modifierFlags.contains(.command) { modifiers |= 0x0100 }
            guard modifiers != 0 else { NSSound.beep(); return }  // bare keys are not global shortcuts
            listening = false
            onCapture?(Int(event.keyCode), modifiers)
        }
    }
}

// MARK: - Floating panel

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // Must be able to become main: an accessory app whose only window refuses main
    // status gets its activation handed straight back by macOS, which dropped the
    // popup (and the keystroke aimed at it) roughly one time in six.
    override var canBecomeMain: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        log("panel becomeKey")
    }

    override func resignKey() {
        super.resignKey()
        // Deliberately does NOT hide the panel. A non-activating panel loses key
        // status the moment it gets it while the app is inactive, so hiding here
        // closed the popup in the same breath the hotkey opened it. Dismissal is
        // driven by the app resigning active instead — see AppDelegate.
        log("panel resignKey")
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate!

    let store = ClipStore()
    var panel: FloatingPanel!
    var statusItem: NSStatusItem!
    var loginItem: NSMenuItem!
    var recoveryItem: NSMenuItem!
    var hotKeyItem: NSMenuItem!
    var hotKeyError: String?
    var preferencesWindow: NSWindow?
    var hotKeyRef: EventHotKeyRef?
    /// The app that was frontmost when the popup opened — the one a pick pastes into.
    var previousApp: NSRunningApplication?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy would register the same hotkey and one of them would silently
        // lose it — exactly what made a stale build so confusing to diagnose.
        if let running = otherRunningInstance() {
            log("another instance is already running (pid \(running.processIdentifier)) — exiting")
            running.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        setupPanel()
        setupStatusItem()
        registerHotKey()
        // Ask for Accessibility permission (needed to auto-paste with ⌘V).
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        log("launched: policy=accessory axTrusted=\(AXIsProcessTrusted()) items=\(store.items.count)")
        if !AXIsProcessTrusted() {
            log("WARNING: no Accessibility permission — picking an item will copy but not auto-paste. "
                + "Grant it in System Settings › Privacy & Security › Accessibility.")
        }
        // Click-away dismissal: hide the popup when the user switches to another app.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            log("app resigned active -> hiding panel")
            self.panel.orderOut(nil)
        }
        installDebugTrigger()
    }

    private func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != mine }
    }

    /// Debounced writes must not be lost when the app quits.
    func applicationWillTerminate(_ notification: Notification) {
        store.writeNow()
    }

    // Panel

    private func setupPanel() {
        let view = HistoryView(store: store,
                               onPick: { [weak self] in self?.paste($0) },
                               onClose: { [weak self] in self?.hidePanel(restoreFocus: true) })
        let hosting = NSHostingView(rootView: view)
        // No .nonactivatingPanel: that flag tells the window server this panel must
        // never make its app active, which silently undid our NSApp.activate() a beat
        // after the popup appeared and left it unable to hold keyboard focus.
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func togglePanel() {
        log("togglePanel: isVisible=\(panel.isVisible) appActive=\(NSApp.isActive)")
        if panel.isVisible { hidePanel(restoreFocus: true); return }

        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 10)
        let vis = screen.visibleFrame
        origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
        origin.y = min(max(origin.y, vis.minY + 8), vis.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
        // The panel can only hold keyboard focus — search field, ⎋, ⌘1…⌘9 — while the
        // app is active, so take activation deliberately and hand it back on dismiss.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        log("togglePanel: shown isVisible=\(panel.isVisible) isKey=\(panel.isKeyWindow) "
            + "previousApp=\(previousApp?.localizedName ?? "none")")
    }

    func hidePanel(restoreFocus: Bool) {
        panel.orderOut(nil)
        if restoreFocus, let app = previousApp, !app.isTerminated {
            app.activate(options: [])
        }
    }

    // Pasting

    func paste(_ item: ClipItem) {
        let target = previousApp
        log("paste: axTrusted=\(AXIsProcessTrusted()) len=\(item.text.count) "
            + "target=\(target?.localizedName ?? "none")")

        // Captured before the pick overwrites it, so the user's clipboard can be put
        // back afterwards instead of being silently replaced by whatever they pasted.
        let previousClipboard = store.settings.restoreClipboardAfterPaste
            ? store.snapshotPasteboard() : nil

        store.copyToPasteboard(item)
        // Give focus back to the app the user came from before synthesising ⌘V.
        hidePanel(restoreFocus: true)
        guard AXIsProcessTrusted() else {
            log("paste: no Accessibility permission — text is on the clipboard, ⌘V pastes it manually")
            return
        }
        postPaste(into: target, attempt: 0, restoring: previousClipboard)
    }

    /// Posts ⌘V once the target app is actually frontmost and the user's own modifier
    /// keys are up. Posting while ⌃⌘ are still physically held turns the synthetic ⌘V
    /// into ⌃⌘V — which is not Paste, and re-triggers our own hotkey.
    private func postPaste(into target: NSRunningApplication?, attempt: Int,
                           restoring previousClipboard: [[String: Data]]? = nil) {
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let isFront = target == nil || frontPid == target?.processIdentifier
        if (!isFront || !held.isEmpty) && attempt < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.postPaste(into: target, attempt: attempt + 1, restoring: previousClipboard)
            }
            return
        }
        // A private source does not merge the hardware modifier state into the posted
        // events the way .combinedSessionState does.
        let src = CGEventSource(stateID: .privateState)
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else {
            log("paste: could not create key events")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        log("paste: posted ⌘V after \(attempt) wait(s), front="
            + "\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")

        // Restore only once the target app has had time to read the pasteboard.
        if let previousClipboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.store.restorePasteboard(previousClipboard)
                log("paste: restored the previous clipboard")
            }
        }
    }

    /// `kill -USR1 <pid>` toggles the panel, so the popup path can be exercised
    /// without a keystroke when diagnosing hotkey problems. Debug builds only — a
    /// release build should not expose a way to open the panel without the user.
    private var debugSignalSource: DispatchSourceSignal?

    private func installDebugTrigger() {
#if DEBUG
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            log("SIGUSR1 debug trigger")
            self?.togglePanel()
        }
        source.resume()
        debugSignalSource = source
#endif
    }

    // Global hotkey: Control + Command + V

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            log("hotkey event received")
            DispatchQueue.main.async { AppDelegate.shared.togglePanel() }
            return noErr
        }, 1, &spec, nil, nil)
        log("InstallEventHandler status=\(installStatus)")
        applyHotKey()
    }

    /// (Re)registers the configured shortcut. A failure here used to be invisible —
    /// the user just had a dead shortcut — so it is recorded and shown in the menu.
    func applyHotKey() {
        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
            hotKeyRef = nil
        }
        let code = store.settings.hotKeyCode
        let modifiers = store.settings.hotKeyModifiers
        let id = EventHotKeyID(signature: OSType(0x434C4950), id: 1) // 'CLIP'
        let status = RegisterEventHotKey(UInt32(code), UInt32(modifiers), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        let shortcut = Shortcut.describe(code: code, modifiers: modifiers)
        if status == noErr {
            hotKeyError = nil
            log("hotkey: registered \(shortcut)")
        } else {
            // -9878 is eventHotKeyExistsErr: another app already owns the combination.
            hotKeyError = status == -9878
                ? "\(shortcut) is already taken by another app"
                : "\(shortcut) could not be registered (error \(status))"
            log("hotkey: FAILED to register \(shortcut) — status=\(status)")
        }
    }

    // Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusItem.systemStatusItem()
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                           accessibilityDescription: "Clipboard History")
        let menu = NSMenu()
        menu.delegate = self
        hotKeyItem = menu.addItem(withTitle: "Show History", action: #selector(showHistory),
                                  keyEquivalent: "")
        hotKeyItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear History", action: #selector(clearHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showPreferences), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Reveal Settings File", action: #selector(editSettings), keyEquivalent: "").target = self
        loginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(.separator())
        recoveryItem = menu.addItem(withTitle: "", action: #selector(revealRecoveredHistory),
                                    keyEquivalent: "")
        recoveryItem.target = self
        recoveryItem.isHidden = true
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        // A shortcut that failed to register must say so rather than just not working.
        let shortcut = Shortcut.describe(code: store.settings.hotKeyCode,
                                         modifiers: store.settings.hotKeyModifiers)
        hotKeyItem.title = hotKeyError.map { "Show History  —  ⚠︎ \($0)" }
            ?? "Show History  (\(shortcut))"
        // Losing a history file should be visible in the app, not just in the log.
        if let preserved = store.loadFailure {
            recoveryItem.title = "⚠︎ Previous history kept as \(preserved)"
            recoveryItem.isHidden = false
        } else {
            recoveryItem.isHidden = true
        }
    }

    @objc private func showHistory() { togglePanel() }
    @objc private func clearHistory() { store.clearUnpinned() }

    @objc private func showPreferences() {
        if preferencesWindow == nil {
            let view = PreferencesView(store: store) { [weak self] in self?.applyHotKey() }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ClipStack Settings"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            preferencesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func editSettings() {
        NSWorkspace.shared.open(store.settingsFileURL)
    }

    @objc private func revealRecoveredHistory() {
        NSWorkspace.shared.activateFileViewerSelecting([
            store.settingsFileURL.deletingLastPathComponent()
        ])
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
    }
}

extension NSStatusItem {
    static func systemStatusItem() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
