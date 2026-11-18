import XCTest
@testable import ClipStackCore

/// Every test runs against a throwaway directory, so none of this touches the real
/// clipboard history.
final class ClipStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClipStackTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> ClipStore {
        ClipStore(directory: dir, polling: false)
    }

    // MARK: Ordering and de-duplication

    func testNewestItemComesFirst() {
        let store = makeStore()
        store.add("first")
        store.add("second")
        XCTAssertEqual(store.items.map(\.text), ["second", "first"])
    }

    func testRecopyingMovesToFrontWithoutDuplicating() {
        let store = makeStore()
        store.add("a")
        store.add("b")
        store.add("a")
        XCTAssertEqual(store.items.map(\.text), ["a", "b"],
                       "re-copying an existing clip should move it, not duplicate it")
    }

    func testRecopyingPreservesPinnedState() {
        let store = makeStore()
        store.add("keep me")
        store.togglePin(store.items[0])
        store.add("other")
        store.add("keep me")
        XCTAssertTrue(store.items[0].pinned,
                      "re-copying a pinned clip must not quietly unpin it")
    }

    // MARK: Trimming

    func testTrimKeepsAtMostMaxUnpinned() {
        let store = makeStore()
        for i in 0..<(store.maxUnpinned + 25) { store.add("clip \(i)") }
        XCTAssertEqual(store.items.count, store.maxUnpinned)
        XCTAssertEqual(store.items.first?.text, "clip \(store.maxUnpinned + 24)")
    }

    func testPinnedItemsSurviveTrimmingBeyondTheCap() {
        let store = makeStore()
        store.add("pin me")
        store.togglePin(store.items[0])
        for i in 0..<(store.maxUnpinned + 10) { store.add("clip \(i)") }
        XCTAssertTrue(store.items.contains { $0.text == "pin me" },
                      "a pinned clip must not be pushed out by the unpinned cap")
        XCTAssertEqual(store.items.filter { !$0.pinned }.count, store.maxUnpinned)
    }

    // MARK: Retention

    func testExpiryDropsOldUnpinnedButKeepsPinned() {
        let store = makeStore()
        var settings = ClipSettings()
        settings.retentionDays = 30
        store.apply(settings)

        let old = Date().addingTimeInterval(-60 * 86_400)
        let recent = Date().addingTimeInterval(-29 * 86_400)
        store.items = [
            ClipItem(text: "old unpinned", date: old, pinned: false),
            ClipItem(text: "old pinned", date: old, pinned: true),
            ClipItem(text: "inside window", date: recent, pinned: false),
        ]
        let removed = store.expire()

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(store.items.map(\.text), ["old pinned", "inside window"])
    }

    func testRetentionOfZeroDisablesExpiry() {
        let store = makeStore()
        var settings = ClipSettings()
        settings.retentionDays = 0
        store.apply(settings)
        store.items = [ClipItem(text: "ancient", date: .distantPast)]
        XCTAssertEqual(store.expire(), 0)
        XCTAssertEqual(store.items.count, 1)
    }

    // MARK: Size limit

    func testOversizedClipsAreRejected() {
        let store = makeStore()
        var settings = ClipSettings()
        settings.maxItemKilobytes = 1
        store.apply(settings)
        XCTAssertTrue(store.isWithinSizeLimit(String(repeating: "x", count: 1024)))
        XCTAssertFalse(store.isWithinSizeLimit(String(repeating: "x", count: 1025)))
    }

    func testSizeLimitCountsBytesNotCharacters() {
        let store = makeStore()
        var settings = ClipSettings()
        settings.maxItemKilobytes = 1
        store.apply(settings)
        // Each emoji is 4 UTF-8 bytes, so 300 of them exceed 1 KB despite being
        // only 300 characters.
        XCTAssertFalse(store.isWithinSizeLimit(String(repeating: "😀", count: 300)))
    }

    // MARK: Persistence

    func testHistorySurvivesAReload() {
        let first = makeStore()
        first.add("persisted")
        first.writeNow()

        let second = makeStore()
        XCTAssertEqual(second.items.map(\.text), ["persisted"])
    }

    func testUnreadableHistoryIsPreservedNotOverwritten() throws {
        let first = makeStore()
        first.add("valuable")
        first.writeNow()

        let historyURL = dir.appendingPathComponent("history.json")
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: historyURL)

        let second = makeStore()
        XCTAssertTrue(second.items.isEmpty, "a corrupt file should not load as data")
        XCTAssertNotNil(second.loadFailure, "the failure must be surfaced, not swallowed")

        let preserved = try FileManager.default
            .contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("history.unreadable-") }
        XCTAssertEqual(preserved.count, 1)

        let kept = try Data(contentsOf: dir.appendingPathComponent(preserved[0]))
        XCTAssertEqual(kept, corrupt, "the unreadable bytes must be kept verbatim")
    }

    func testSavingDoesNotDestroyDataAfterAFailedLoad() throws {
        let first = makeStore()
        first.add("valuable")
        first.writeNow()
        let historyURL = dir.appendingPathComponent("history.json")
        try Data("{ not json".utf8).write(to: historyURL)

        let second = makeStore()
        second.add("new clip")
        second.writeNow()

        // The corrupt original lives on under its preserved name.
        let preserved = try FileManager.default
            .contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("history.unreadable-") }
        XCTAssertEqual(preserved.count, 1)
    }

    func testHistoryAndSettingsAreNotWorldReadable() throws {
        let store = makeStore()
        store.add("secret")
        store.writeNow()

        for name in ["history.json", "settings.json"] {
            let path = dir.appendingPathComponent(name).path
            let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber
            XCTAssertEqual(mode.int16Value, 0o600, "\(name) must not be readable by others")
        }
        let dirMode = try FileManager.default
            .attributesOfItem(atPath: dir.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(dirMode.int16Value, 0o700)
    }

    // MARK: Settings

    func testSettingsRoundTripThroughDisk() {
        let first = makeStore()
        var settings = ClipSettings()
        settings.retentionDays = 7
        settings.excludedBundleIDs = ["com.example.secret"]
        settings.restoreClipboardAfterPaste = false
        first.apply(settings)

        let second = makeStore()
        XCTAssertEqual(second.settings.retentionDays, 7)
        XCTAssertEqual(second.settings.excludedBundleIDs, ["com.example.secret"])
        XCTAssertFalse(second.settings.restoreClipboardAfterPaste)
    }

    func testDefaultExclusionsCoverCommonPasswordManagers() {
        let defaults = ClipSettings().excludedBundleIDs
        XCTAssertTrue(defaults.contains { $0.contains("1password") })
        XCTAssertTrue(defaults.contains { $0.contains("bitwarden") })
    }

    // MARK: Deletion

    func testClearUnpinnedKeepsPinned() {
        let store = makeStore()
        store.add("throwaway")
        store.add("keeper")
        store.togglePin(store.items[0])
        store.clearUnpinned()
        XCTAssertEqual(store.items.map(\.text), ["keeper"])
    }

    func testDeleteRemovesOnlyTheGivenItem() {
        let store = makeStore()
        store.add("a")
        store.add("b")
        store.delete(store.items[0])
        XCTAssertEqual(store.items.map(\.text), ["a"])
    }
}

/// Logging must stay diagnostics-only and bounded.
final class LoggingTests: XCTestCase {
    func testLogRotatesPastTheCapAndKeepsOneOldFile() throws {
        let logURL = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ClipStack.log")
        // Write past the 1 MB cap, then log once more to trigger rotation.
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: (1 << 20) + 1024).write(to: logURL)

        log("rotation probe")

        // FileManager rather than URL.resourceValues: URL caches resource values, so
        // re-reading the same URL object returns the pre-rotation size forever.
        func size(_ path: String) -> Int {
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) as? Int ?? 0
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, size(logURL.path) > (1 << 20) { usleep(50_000) }

        let rotated = logURL.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path),
                      "the oversized log should have been rotated aside")
        XCTAssertGreaterThan(size(rotated.path), 1 << 20,
                             "the rotated file should hold the old contents")
        XCTAssertLessThan(size(logURL.path), 1 << 20,
                          "logging should continue into a fresh file")
    }
}

/// Rich-content capture: a paste should reproduce the original copy, not a flattened
/// version of it.
final class RichContentTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClipStackRich-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }
    private func makeStore() -> ClipStore { ClipStore(directory: dir, polling: false) }

    func testFlavoursSurviveSaveAndReload() {
        let store = makeStore()
        let rtf = Data("{\\rtf1 styled}".utf8)
        store.insert(ClipItem(text: "styled",
                              flavours: ["public.rtf": rtf,
                                         "public.utf8-plain-text": Data("styled".utf8)]))
        store.writeNow()

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.items.first?.flavours?["public.rtf"], rtf,
                       "styled content must survive a round trip, not be flattened")
    }

    func testOlderItemsWithoutFlavoursStillLoad() throws {
        // History written before flavours existed has no such key at all. The date must
        // be recent, or retention legitimately expires it before the assertion runs.
        let now = Date().timeIntervalSinceReferenceDate
        let legacy = """
        [{"id":"\(UUID().uuidString)","text":"legacy clip","date":\(now),"pinned":false}]
        """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("history.json"))

        let store = makeStore()
        XCTAssertEqual(store.items.map(\.text), ["legacy clip"])
        XCTAssertNil(store.items.first?.flavours)
    }

    func testDeduplicationComparesContentNotJustText() {
        let store = makeStore()
        let a = ClipItem(text: "same label", flavours: ["public.rtf": Data("A".utf8)])
        let b = ClipItem(text: "same label", flavours: ["public.rtf": Data("B".utf8)])
        store.insert(a)
        store.insert(b)
        XCTAssertEqual(store.items.count, 2,
                       "clips sharing a label but differing in content are distinct")
    }

    func testIdenticalFlavouredClipIsMovedNotDuplicated() {
        let store = makeStore()
        let item = ClipItem(text: "x", flavours: ["public.rtf": Data("A".utf8)])
        store.insert(item)
        store.insert(ClipItem(text: "other"))
        store.insert(ClipItem(text: "x", flavours: ["public.rtf": Data("A".utf8)]))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first?.text, "x")
    }

    func testSizeLimitCountsAllFlavours() {
        let store = makeStore()
        var settings = ClipSettings()
        settings.maxItemKilobytes = 1
        store.apply(settings)

        let big = ClipItem(text: "small label",
                           flavours: ["public.tiff": Data(repeating: 0, count: 2048)])
        XCTAssertFalse(store.isWithinSizeLimit(big),
                       "the limit must cover stored flavours, not just the label")
    }

    func testNonTextClipGetsAReadableLabel() {
        let label = ClipStore.describe(["public.png": Data(repeating: 0, count: 242 * 1024)])
        XCTAssertEqual(label, "PNG content (242 KB)")
    }
}
