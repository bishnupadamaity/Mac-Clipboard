import AppKit
import os.log

// MARK: - Logging

/// Logs to the unified log (`log stream --predicate 'subsystem == "com.inneitec.ClipStack"'`)
/// and to ~/Library/Logs/ClipStack.log so problems are diagnosable after the fact.
public let logger = Logger(subsystem: "com.inneitec.ClipStack", category: "app")

private let logFileURL: URL = FileManager.default
    .urls(for: .libraryDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Logs/ClipStack.log")

private let logQueue = DispatchQueue(label: "com.inneitec.ClipStack.log")

/// Largest log file kept before it is rotated. One previous file is retained.
private let maxLogBytes = 1 << 20  // 1 MB

/// Diagnostics only. Clipboard *contents* are never logged — only lengths, counts and
/// identifiers — so the log cannot become a second copy of the user's history.
public func log(_ message: String) {
    logger.info("\(message, privacy: .public)")
    logQueue.async {
        rotateLogIfNeeded()
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

/// Keeps the log from growing without bound: at the cap the current file becomes
/// `.1` (replacing any previous one) and logging continues into a fresh file.
private func rotateLogIfNeeded() {
    let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)
    guard let size = attributes?[.size] as? Int, size > maxLogBytes else { return }
    let rotated = logFileURL.appendingPathExtension("1")
    try? FileManager.default.removeItem(at: rotated)
    try? FileManager.default.moveItem(at: logFileURL, to: rotated)
}

/// Renders a key code and Carbon modifier mask the way macOS writes shortcuts, so the
/// menu and the preferences window agree.
public enum Shortcut {
    public static func describe(code: Int, modifiers: Int) -> String {
        var text = ""
        if modifiers & 0x1000 != 0 { text += "⌃" }
        if modifiers & 0x0800 != 0 { text += "⌥" }
        if modifiers & 0x0200 != 0 { text += "⇧" }
        if modifiers & 0x0100 != 0 { text += "⌘" }
        return text + keyName(code)
    }

    static let names: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        29: "0", 49: "Space", 36: "Return", 48: "Tab", 53: "Escape",
    ]

    public static func keyName(_ code: Int) -> String { names[code] ?? "Key \(code)" }
}

// MARK: - Model & storage

public struct ClipItem: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var text: String
    public var date = Date()
    public var pinned = false
    /// Every flavour the clip was copied with, keyed by pasteboard type, so pasting
    /// reproduces the original exactly — styled text, HTML, file references — rather
    /// than a flattened string. Absent on items stored before this existed, which
    /// still paste correctly from `text`.
    public var flavours: [String: Data]?

    public init(id: UUID = UUID(), text: String, date: Date = Date(),
                pinned: Bool = false, flavours: [String: Data]? = nil) {
        self.id = id
        self.text = text
        self.date = date
        self.pinned = pinned
        self.flavours = flavours
    }

    /// Total stored size, used for the capture size limit.
    public var byteCount: Int {
        flavours.map { $0.values.reduce(0) { $0 + $1.count } } ?? text.utf8.count
    }

    /// Two clips are the same clip when their flavours match; fall back to the text
    /// for items captured before flavours were stored.
    public func isSameContent(as other: ClipItem) -> Bool {
        if let mine = flavours, let theirs = other.flavours { return mine == theirs }
        return text == other.text
    }
}

/// User-editable settings, kept as JSON beside the history because there is no
/// preferences window yet. Re-read whenever the file changes, so an edit takes effect
/// without restarting the app.
public struct ClipSettings: Codable {
    public init() {}

    /// Age after which unpinned items are discarded. 0 disables expiry entirely.
    public var retentionDays: Int = 30
    /// Discard unpinned history as soon as the screen locks.
    public var clearOnScreenLock: Bool = false
    /// Apps whose copies are never recorded.
    public var excludedBundleIDs: [String] = ClipSettings.defaultExcludedBundleIDs
    /// Largest clip to keep. Bigger copies stay on the system clipboard but are not
    /// stored, so one huge paste cannot bloat every subsequent write.
    public var maxItemKilobytes: Int = 1024
    /// Put the previous clipboard back after pasting a picked item, so a following
    /// ⌘V does what the user expects rather than repeating the pick.
    public var restoreClipboardAfterPaste: Bool = true
    /// Keep every pasteboard flavour, not just plain text. Costs disk space — a
    /// styled-text copy carries RTF and HTML alongside the string — but means a paste
    /// is indistinguishable from the original copy.
    public var keepRichContent: Bool = true
    /// The global shortcut, as a virtual key code plus Carbon modifier mask.
    /// Defaults to ⌃⌘V (kVK_ANSI_V, controlKey | cmdKey).
    public var hotKeyCode: Int = 9
    public var hotKeyModifiers: Int = 0x1000 | 0x0100

    /// The org.nspasteboard.* markers cover apps that cooperate. These are the common
    /// credential holders that do not set them, so they have to be excluded by identity.
    public static let defaultExcludedBundleIDs = [
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

public final class ClipStore: ObservableObject {
    @Published public var items: [ClipItem] = []
    public let maxUnpinned = 100

    /// Name of the file an unreadable history was preserved as, so the menu can say so.
    @Published public private(set) var loadFailure: String?

    private let dirURL: URL
    private let fileURL: URL
    private let settingsURL: URL
    public private(set) var settings = ClipSettings()
    private var settingsStamp: Date?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    /// Set when history could not be parsed *and* could not be moved aside. Saving
    /// would then overwrite the only copy, so it is refused.
    private var savingDisabled = false
    private var pendingSave: DispatchWorkItem?

    public var settingsFileURL: URL { settingsURL }

    /// - Parameters:
    ///   - directory: where history and settings live. Defaults to Application
    ///     Support; tests pass a temporary directory so they never touch real history.
    ///   - polling: whether to watch the pasteboard. Tests drive `add` directly.
    public init(directory: URL? = nil, polling: Bool = true) {
        dirURL = directory ?? FileManager.default
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

        // .common, not the default mode: while a menu is tracking or a window is being
        // resized the run loop leaves the default mode, and a default-mode timer stops
        // firing — copies made during that window were silently missed.
        guard polling else { return }

        // .common rather than the default mode. In-process event tracking — a drag, a
        // resize, a modal tracking loop — leaves the default mode and stops a
        // default-mode timer firing. Status-bar menus turned out not to block this
        // app's run loop on macOS 27, so this is hardening against the tracking loops
        // that do, not a fix for an observed miss.
        let poller = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(poller, forMode: .common)
        timer = poller
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

    /// Coalesces bursts of changes into one write. The whole history is re-encoded on
    /// every save, so writing once per copy was wasteful; callers that must not lose
    /// data on a crash use `writeNow()` instead.
    private func save() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    /// Writes immediately, cancelling any debounced write.
    public func writeNow() {
        pendingSave?.cancel()
        pendingSave = nil
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

        let flavours = settings.keepRichContent ? snapshotPasteboard().first : nil
        let plain = pb.string(forType: .string)

        // Something with neither text nor flavours is not a clip we can reproduce.
        guard let display = plain.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })
                ?? flavours.flatMap(Self.describe) else { return }

        var item = ClipItem(text: display, flavours: (flavours?.isEmpty == false) ? flavours : nil)
        guard isWithinSizeLimit(item) else {
            log("capture: skipped a \(item.byteCount / 1024) KB clip "
                + "(limit \(max(1, settings.maxItemKilobytes)) KB)")
            return
        }
        if plain == nil { log("capture: stored a non-text clip — \(display)") }
        item.date = Date()
        insert(item)
    }

    /// Clips past the configured size stay on the system clipboard rather than being
    /// stored, so one huge paste cannot bloat every subsequent write.
    public func isWithinSizeLimit(_ text: String) -> Bool {
        isWithinSizeLimit(ClipItem(text: text))
    }

    public func isWithinSizeLimit(_ item: ClipItem) -> Bool {
        item.byteCount <= max(1, settings.maxItemKilobytes) * 1024
    }

    /// A human label for a clip with no text representation, e.g. "PNG image (242 KB)".
    static func describe(_ flavours: [String: Data]) -> String? {
        guard let (type, data) = flavours.max(by: { $0.value.count < $1.value.count })
        else { return nil }
        let name = type.split(separator: ".").last.map(String.init)?.uppercased() ?? "DATA"
        return "\(name) content (\(max(1, data.count / 1024)) KB)"
    }

    /// Replaces settings in memory. Used by the preferences UI and by tests.
    public func apply(_ newSettings: ClipSettings) {
        settings = newSettings
        writeSettings()
        expire()
    }

    public func add(_ text: String) {
        insert(ClipItem(text: text))
    }

    /// Inserts a clip, moving an identical existing one to the front instead of
    /// duplicating it and preserving its pinned state.
    public func insert(_ item: ClipItem) {
        if let i = items.firstIndex(where: { $0.isSameContent(as: item) }) {
            var existing = items.remove(at: i)
            existing.date = Date()
            existing.flavours = item.flavours ?? existing.flavours
            items.insert(existing, at: 0)
        } else {
            items.insert(item, at: 0)
        }
        expire(save: false)
        trim()
        save()
    }

    /// Everything currently on the pasteboard, flavour by flavour, so it can be put
    /// back verbatim after a paste.
    public func snapshotPasteboard() -> [[String: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var flavours: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { flavours[type.rawValue] = data }
            }
            return flavours
        }
    }

    /// Puts a snapshot back and suppresses re-capture, so restoring does not register
    /// as a new copy.
    public func restorePasteboard(_ snapshot: [[String: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let restored = snapshot.compactMap { flavours -> NSPasteboardItem? in
            guard !flavours.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in flavours {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
        lastChangeCount = pb.changeCount
    }

    /// Puts an item on the system clipboard without it being re-added as "new".
    public func copyToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let flavours = item.flavours, !flavours.isEmpty {
            let entry = NSPasteboardItem()
            for (type, data) in flavours {
                entry.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            pb.writeObjects([entry])
        } else {
            pb.setString(item.text, forType: .string)
        }
        lastChangeCount = pb.changeCount
        insert(item)
    }

    // MARK: Retention

    /// Drops unpinned items past the retention window. Pinned items are exempt —
    /// pinning is an explicit instruction to keep something.
    @discardableResult
    public func expire(save shouldSave: Bool = true) -> Int {
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

    public func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(of: item) else { return }
        items[i].pinned.toggle()
        save()
    }

    public func delete(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    public func clearUnpinned() {
        items.removeAll { !$0.pinned }
        writeNow()  // a deliberate clear should survive a crash or an immediate sleep
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

