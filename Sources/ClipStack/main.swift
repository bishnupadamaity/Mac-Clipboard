import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import os.log

// MARK: - Logging

/// Logs to the unified log (`log stream --predicate 'subsystem == "com.inneitec.ClipStack"'`)
/// and to ~/Library/Logs/ClipStack.log so problems are diagnosable after the fact.
let logger = Logger(subsystem: "com.inneitec.ClipStack", category: "app")

private let logFileURL: URL = FileManager.default
    .urls(for: .libraryDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Logs/ClipStack.log")

private let logQueue = DispatchQueue(label: "com.inneitec.ClipStack.log")

func log(_ message: String) {
    logger.info("\(message, privacy: .public)")
    logQueue.async {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(
                at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: logFileURL)
        }
    }
}

// MARK: - Model & storage

struct ClipItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var date = Date()
    var pinned = false
}

/// User-editable settings, kept as JSON beside the history because there is no
/// preferences window yet. Re-read whenever the file changes, so an edit takes effect
/// without restarting the app.
struct ClipSettings: Codable {
    /// Age after which unpinned items are discarded. 0 disables expiry entirely.
    var retentionDays: Int = 30
    /// Discard unpinned history as soon as the screen locks.
    var clearOnScreenLock: Bool = false
    /// Apps whose copies are never recorded.
    var excludedBundleIDs: [String] = ClipSettings.defaultExcludedBundleIDs

    /// The org.nspasteboard.* markers cover apps that cooperate. These are the common
    /// credential holders that do not set them, so they have to be excluded by identity.
    static let defaultExcludedBundleIDs = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "in.sinew.Enpass-Desktop",
        "com.dashlane.Dashlane",
        "com.keepersecurity.KeeperDesktop",
        "com.apple.keychainaccess",
    ]
}

final class ClipStore: ObservableObject {
    @Published var items: [ClipItem] = []
    let maxUnpinned = 100

    /// Name of the file an unreadable history was preserved as, so the menu can say so.
    @Published private(set) var loadFailure: String?

    private let dirURL: URL
    private let fileURL: URL
    private let settingsURL: URL
    private(set) var settings = ClipSettings()
    private var settingsStamp: Date?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    /// Set when history could not be parsed *and* could not be moved aside. Saving
    /// would then overwrite the only copy, so it is refused.
    private var savingDisabled = false

    var settingsFileURL: URL { settingsURL }

    init() {
        dirURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipStack", isDirectory: true)
        fileURL = dirURL.appendingPathComponent("history.json")
        settingsURL = dirURL.appendingPathComponent("settings.json")

        // The history is a verbatim record of everything copied, so it must not be
        // readable by other accounts on the machine. createDirectory ignores the
        // attributes when the directory already exists, hence the explicit set.
        try? FileManager.default.createDirectory(
            at: dirURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: dirURL.path)

        loadSettings()
        load()
        expire()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        observeScreenLock()
    }

    // MARK: Loading and saving

    /// Never overwrites data it failed to parse: an unreadable file is moved aside so
    /// the next copy cannot destroy it.
    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            log("history: no existing file, starting empty")
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            items = try JSONDecoder().decode([ClipItem].self, from: data)
            log("history: loaded \(items.count) item(s)")
        } catch {
            let stamp = ISO8601DateFormatter.filenameSafe.string(from: Date())
            let backup = dirURL.appendingPathComponent("history.unreadable-\(stamp).json")
            do {
                try FileManager.default.moveItem(at: fileURL, to: backup)
                loadFailure = backup.lastPathComponent
                log("history: UNREADABLE (\(error.localizedDescription)) — "
                    + "preserved as \(backup.lastPathComponent), starting empty")
            } catch {
                savingDisabled = true
                loadFailure = fileURL.lastPathComponent
                log("history: UNREADABLE and could not be moved aside "
                    + "(\(error.localizedDescription)) — saving disabled to protect it")
            }
        }
    }

    private func save() {
        guard !savingDisabled else {
            log("history: save refused — an unreadable history file is still in place")
            return
        }
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
            // An atomic write replaces the file, so the mode is reapplied every time.
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: fileURL.path)
        } catch {
            log("history: save failed — \(error.localizedDescription)")
        }
    }

    // MARK: Settings

    private func loadSettings() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            writeSettings()  // seed defaults so the file is discoverable and editable
            return
        }
        do {
            let data = try Data(contentsOf: settingsURL)
            settings = try JSONDecoder().decode(ClipSettings.self, from: data)
            settingsStamp = modificationDate(of: settingsURL)
        } catch {
            log("settings: unreadable, keeping defaults — \(error.localizedDescription)")
            settingsStamp = modificationDate(of: settingsURL)
        }
    }

    private func writeSettings() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: settingsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: settingsURL.path)
            settingsStamp = modificationDate(of: settingsURL)
        } catch {
            log("settings: could not write — \(error.localizedDescription)")
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Picks up hand edits to settings.json without needing a restart.
    private func reloadSettingsIfChanged() {
        let stamp = modificationDate(of: settingsURL)
        guard stamp != settingsStamp else { return }
        loadSettings()
        log("settings: reloaded — retentionDays=\(settings.retentionDays), "
            + "excluded=\(settings.excludedBundleIDs.count), "
            + "clearOnScreenLock=\(settings.clearOnScreenLock)")
        expire()
    }

    // MARK: Capture

    private func poll() {
        reloadSettingsIfChanged()

        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        // Respect password managers and other apps that mark data as secret/temporary.
        let types = (pb.types ?? []).map(\.rawValue)
        if types.contains("org.nspasteboard.ConcealedType")
            || types.contains("org.nspasteboard.TransientType")
            || types.contains("org.nspasteboard.AutoGeneratedType") { return }

        // Apps that set none of those markers have to be excluded by identity. The
        // frontmost app just after a copy is the best attribution available without a
        // pasteboard-owner API; it is a heuristic, not a guarantee.
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           settings.excludedBundleIDs.contains(bundleID) {
            log("capture: skipped a copy from excluded app \(bundleID)")
            return
        }

        guard let s = pb.string(forType: .string),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        add(s)
    }

    func add(_ text: String) {
        if let i = items.firstIndex(where: { $0.text == text }) {
            var item = items.remove(at: i)
            item.date = Date()
            items.insert(item, at: 0)
        } else {
            items.insert(ClipItem(text: text), at: 0)
        }
        expire(save: false)
        trim()
        save()
    }

    /// Puts an item on the system clipboard without it being re-added as "new".
    func copyToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.text, forType: .string)
        lastChangeCount = pb.changeCount
        add(item.text)
    }

    // MARK: Retention

    /// Drops unpinned items past the retention window. Pinned items are exempt —
    /// pinning is an explicit instruction to keep something.
    @discardableResult
    func expire(save shouldSave: Bool = true) -> Int {
        guard settings.retentionDays > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(settings.retentionDays) * 86_400)
        let before = items.count
        items.removeAll { !$0.pinned && $0.date < cutoff }
        let removed = before - items.count
        if removed > 0 {
            log("retention: expired \(removed) item(s) older than \(settings.retentionDays) day(s)")
            if shouldSave { save() }
        }
        return removed
    }

    private func observeScreenLock() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] _ in
            guard let self, self.settings.clearOnScreenLock else { return }
            let before = self.items.count
            self.clearUnpinned()
            log("screen locked: cleared \(before - self.items.count) unpinned item(s)")
        }
    }

    // MARK: Mutation

    func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(of: item) else { return }
        items[i].pinned.toggle()
        save()
    }

    func delete(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clearUnpinned() {
        items.removeAll { !$0.pinned }
        save()
    }

    private func trim() {
        var count = 0
        items = items.filter {
            if $0.pinned { return true }
            count += 1
            return count <= maxUnpinned
        }
    }
}

extension ISO8601DateFormatter {
    /// Timestamps used in filenames, so no colons.
    static let filenameSafe: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}

// MARK: - SwiftUI popup

struct HistoryView: View {
    @ObservedObject var store: ClipStore
    var onPick: (ClipItem) -> Void
    var onClose: () -> Void
    @State private var query = ""

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
                .onSubmit { if let first = filtered.first { onPick(first) } }
            Divider()
            if filtered.isEmpty {
                Spacer()
                Text(store.items.isEmpty ? "Copy something to get started" : "No matches")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: 380, height: 460)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onExitCommand(perform: onClose)
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
            Button { store.delete(item) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
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
    var hotKeyRef: EventHotKeyRef?
    /// The app that was frontmost when the popup opened — the one a pick pastes into.
    var previousApp: NSRunningApplication?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        store.copyToPasteboard(item)
        // Give focus back to the app the user came from before synthesising ⌘V.
        hidePanel(restoreFocus: true)
        guard AXIsProcessTrusted() else {
            log("paste: no Accessibility permission — text is on the clipboard, ⌘V pastes it manually")
            return
        }
        postPaste(into: target, attempt: 0)
    }

    /// Posts ⌘V once the target app is actually frontmost and the user's own modifier
    /// keys are up. Posting while ⌃⌘ are still physically held turns the synthetic ⌘V
    /// into ⌃⌘V — which is not Paste, and re-triggers our own hotkey.
    private func postPaste(into target: NSRunningApplication?, attempt: Int) {
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let isFront = target == nil || frontPid == target?.processIdentifier
        if (!isFront || !held.isEmpty) && attempt < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.postPaste(into: target, attempt: attempt + 1)
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
    }

    /// `kill -USR1 <pid>` toggles the panel, so the popup path can be exercised
    /// without a keystroke when diagnosing hotkey problems.
    private var debugSignalSource: DispatchSourceSignal?

    private func installDebugTrigger() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            log("SIGUSR1 debug trigger")
            self?.togglePanel()
        }
        source.resume()
        debugSignalSource = source
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

        let id = EventHotKeyID(signature: OSType(0x434C4950), id: 1) // 'CLIP'
        let registerStatus = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | cmdKey), id,
                                                 GetApplicationEventTarget(), 0, &hotKeyRef)
        log("RegisterEventHotKey status=\(registerStatus) ref=\(String(describing: hotKeyRef))")
    }

    // Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusItem.systemStatusItem()
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                           accessibilityDescription: "Clipboard History")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Show History  (⌃⌘V)", action: #selector(showHistory), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear History", action: #selector(clearHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Edit Settings…", action: #selector(editSettings), keyEquivalent: "").target = self
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
