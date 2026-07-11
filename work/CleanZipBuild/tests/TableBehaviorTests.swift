import AppKit
import SwiftUI

@main
@MainActor
struct TableBehaviorTests {
    private static var failures: [String] = []

    static func main() {
        _ = NSApplication.shared
        testNativeTableConfiguration()
        testArchiveColumnReorderingPolicy()
        testSelectedItemsColumnReorderingPolicy()
        testFinderStyleColumnSizing()
        testSelectedItemMetadataSnapshot()
        testProgressPublishingIsDeduplicated()
        testArchiveDerivedStateIsCached()
        testArchiveEngineRoundTrips()

        if failures.isEmpty {
            print("PASS: CleanZip table behavior tests")
            exit(EXIT_SUCCESS)
        }

        failures.forEach { fputs("FAIL: \($0)\n", stderr) }
        exit(EXIT_FAILURE)
    }

    private static func testNativeTableConfiguration() {
        let table = NSTableView()
        FinderTableBehavior.configure(
            table,
            allowsMultipleSelection: true,
            autosaveName: "local.codex.cleanzip.tests.\(UUID().uuidString)"
        )

        expect(table.allowsColumnReordering, "column reordering should be enabled")
        expect(table.allowsColumnResizing, "column resizing should be enabled")
        expect(!table.allowsColumnSelection, "column headers must never become selected")
        expect(table.allowsMultipleSelection, "selected-items rows should allow multiple selection")
        expect(table.columnAutoresizingStyle == .firstColumnOnlyAutoresizingStyle, "only the first column should autoresize with the window")
    }

    private static func testArchiveColumnReorderingPolicy() {
        let table = makeTable(identifiers: ["name", "size", "modified"])
        let coordinator = ArchiveEntriesTable.Coordinator(entries: [], contentRevision: 0, filter: "")

        expect(!coordinator.tableView(table, shouldSelect: table.tableColumns[0]), "archive headers should not be selectable")
        expect(!coordinator.tableView(table, shouldReorderColumn: 0, toColumn: -1), "archive name column must reject drag initiation")
        expect(!coordinator.tableView(table, shouldReorderColumn: 0, toColumn: 2), "archive name column must stay locked")
        expect(coordinator.tableView(table, shouldReorderColumn: 1, toColumn: -1), "archive size column should start dragging")
        expect(!coordinator.tableView(table, shouldReorderColumn: 1, toColumn: 0), "archive columns must not displace the name column")
        expect(coordinator.tableView(table, shouldReorderColumn: 1, toColumn: 2), "archive non-name columns should reorder")
    }

    private static func testSelectedItemsColumnReorderingPolicy() {
        let table = makeTable(identifiers: ["selectedName", "selectedType", "selectedSize", "selectedLocation"])
        let coordinator = SelectedItemsTable.Coordinator(
            items: [],
            contentRevision: 0,
            selectedIDs: .constant([])
        )

        expect(!coordinator.tableView(table, shouldSelect: table.tableColumns[0]), "selected-item headers should not be selectable")
        expect(!coordinator.tableView(table, shouldReorderColumn: 0, toColumn: -1), "selected-item name column must reject drag initiation")
        expect(coordinator.tableView(table, shouldReorderColumn: 1, toColumn: -1), "selected-item type column should start dragging")
        expect(!coordinator.tableView(table, shouldReorderColumn: 3, toColumn: 0), "selected-item columns must not move before name")
        expect(coordinator.tableView(table, shouldReorderColumn: 3, toColumn: 1), "selected-item non-name columns should reorder")
    }

    private static func testFinderStyleColumnSizing() {
        let scroll = FinderTableScrollView(frame: NSRect(x: 0, y: 0, width: 820, height: 400))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        let table = makeTable(identifiers: ["name", "type", "size", "location"])
        let widths: [(CGFloat, CGFloat, CGFloat)] = [
            (280, 180, .greatestFiniteMagnitude),
            (90, 70, 160),
            (120, 90, 220),
            (260, 220, 2_000)
        ]
        for (column, sizing) in zip(table.tableColumns, widths) {
            column.width = sizing.0
            column.minWidth = sizing.1
            column.maxWidth = sizing.2
            column.resizingMask = [.userResizingMask, .autoresizingMask]
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        scroll.documentView = table
        scroll.layoutSubtreeIfNeeded()
        scroll.rebalanceColumnsToViewport()

        let fixedWidths = Array(table.tableColumns.dropFirst().map(\.width))
        expect(isFitted(table, in: scroll), "initial columns should snap to the viewport")
        expect(!canScrollHorizontally(scroll), "a fitted table must not scroll horizontally")

        let firstBeforeGrow = table.tableColumns[0].width
        scroll.setFrameSize(NSSize(width: 980, height: 400))
        scroll.layoutSubtreeIfNeeded()
        scroll.rebalanceColumnsToViewport()
        expect(table.tableColumns[0].width > firstBeforeGrow, "growing the window should grow the first column")
        expect(equalWidths(Array(table.tableColumns.dropFirst().map(\.width)), fixedWidths), "growing the window must not resize later columns")
        expect(isFitted(table, in: scroll), "grown columns should remain fitted")
        expect(!canScrollHorizontally(scroll), "a grown fitted table must not scroll horizontally")

        let firstBeforeShrink = table.tableColumns[0].width
        scroll.setFrameSize(NSSize(width: 860, height: 400))
        scroll.layoutSubtreeIfNeeded()
        scroll.rebalanceColumnsToViewport()
        expect(table.tableColumns[0].width < firstBeforeShrink, "shrinking the window should shrink the first column")
        expect(equalWidths(Array(table.tableColumns.dropFirst().map(\.width)), fixedWidths), "shrinking the window must not resize later columns")
        expect(isFitted(table, in: scroll), "shrunk columns should remain fitted while the first column has room")
        expect(!canScrollHorizontally(scroll), "a shrunk fitted table must not scroll horizontally")

        let typeColumn = table.tableColumns[1]
        let firstBeforeDividerDrag = table.tableColumns[0].width
        typeColumn.width += 36
        scroll.rebalanceColumnsToViewport(resizedColumn: typeColumn)
        expect(approximately(table.tableColumns[0].width, firstBeforeDividerDrag - 36), "resizing a later divider should absorb the delta in the first column")
        expect(isFitted(table, in: scroll), "later-column resizing should snap back to the viewport")

        table.tableColumns[0].width = table.tableColumns[0].minWidth
        scroll.setFrameSize(NSSize(width: 420, height: 400))
        scroll.layoutSubtreeIfNeeded()
        scroll.rebalanceColumnsToViewport(resizedColumn: table.tableColumns[0])
        expect(approximately(table.tableColumns[0].width, table.tableColumns[0].minWidth), "the first column must respect its minimum width")
        expect(columnsWidth(table) > scroll.contentView.bounds.width + 1, "the table should overflow only after the first column reaches its minimum")
        expect(canScrollHorizontally(scroll), "horizontal scrolling should become available after minimum-width overflow")
    }

    private static func testSelectedItemMetadataSnapshot() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cleanzip-table-tests-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("sample.txt")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: directory) }

        let item = SelectedItem(url: file)
        expect(!item.isDirectory, "file metadata should identify a regular file")
        expect(item.byteSize == 5, "file metadata should be captured once with the correct size")
    }

    private static func testProgressPublishingIsDeduplicated() {
        let state = AppState()
        state.beginOperation(title: "Test", detail: "")
        state.updateOperationProgress(0.001)
        expect(state.operationProgress?.fraction == 0, "sub-percent progress should not trigger a redundant UI update")
        state.updateOperationProgress(0.006)
        expect(state.operationProgress?.fraction == 0.006, "a new displayed percent should update progress")
        state.updateOperationProgress(0.009)
        expect(state.operationProgress?.fraction == 0.006, "progress within the same displayed percent should be deduplicated")
    }

    private static func testArchiveDerivedStateIsCached() {
        let state = AppState()
        state.entries = [
            ArchiveEntry(path: "Folder", size: 0, modified: "", isDirectory: true),
            ArchiveEntry(path: "Folder/keep.txt", size: 5, modified: "", isDirectory: false),
            ArchiveEntry(path: "Folder/other.txt", size: 7, modified: "", isDirectory: false)
        ]
        expect(state.totalFiles == 2, "archive file count should be cached when entries change")
        expect(state.totalBytes == 12, "archive byte count should be cached when entries change")
        expect(state.filteredEntries.count == 3, "empty search should reuse all archive entries")

        state.searchText = "keep"
        expect(state.filteredEntries.map(\.path) == ["Folder/keep.txt"], "search results should refresh only when the query changes")
        state.beginOperation(title: "Test", detail: "")
        state.updateOperationProgress(0.5)
        expect(state.filteredEntries.map(\.path) == ["Folder/keep.txt"], "progress updates must not rebuild archive search results")
    }

    private static func testArchiveEngineRoundTrips() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanzip-engine-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try testArchiveFormat(.zip, in: root.appendingPathComponent("zip"))
            try testArchiveFormat(.sevenZ, in: root.appendingPathComponent("7z"))
            try testSplitArchiveFormat(.zip, in: root.appendingPathComponent("split-zip"))
            try testSplitArchiveFormat(.sevenZ, in: root.appendingPathComponent("split-7z"))
        } catch {
            failures.append("archive round-trip failed: \(error.localizedDescription)")
        }
    }

    private static func testArchiveFormat(_ format: ArchiveFormat, in directory: URL) throws {
        let payload = try makePayload(in: directory)
        let archive = try ArchiveEngine.shared.compress(urls: [payload], format: format, splitSpec: nil)
        try ArchiveEngine.shared.testArchive(archive)

        let entries = try ArchiveEngine.shared.listArchive(archive)
        expect(entries.contains { $0.path.hasSuffix("keep.txt") }, "\(format.rawValue) should contain ordinary files")
        expect(entries.contains { $0.path.hasSuffix("中文文件.txt") }, "\(format.rawValue) should preserve Unicode names")
        expect(entries.allSatisfy { isCleanArchivePath($0.path) }, "\(format.rawValue) should exclude macOS metadata")

        let extracted = try ArchiveEngine.shared.extract(archive: archive)
        let extractedFile = extracted.appendingPathComponent(payload.lastPathComponent).appendingPathComponent("keep.txt")
        expect(FileManager.default.fileExists(atPath: extractedFile.path), "\(format.rawValue) should extract ordinary files")
    }

    private static func testSplitArchiveFormat(_ format: ArchiveFormat, in directory: URL) throws {
        let payload = try makePayload(in: directory)
        let archive = try ArchiveEngine.shared.compress(urls: [payload], format: format, splitSpec: "1k")
        let firstVolume = URL(fileURLWithPath: archive.path + ".001")
        expect(FileManager.default.fileExists(atPath: firstVolume.path), "split \(format.rawValue) should create a .001 volume")
        try ArchiveEngine.shared.testArchive(firstVolume)
        let entries = try ArchiveEngine.shared.listArchive(firstVolume)
        expect(entries.allSatisfy { isCleanArchivePath($0.path) }, "split \(format.rawValue) should exclude macOS metadata")
    }

    private static func makePayload(in directory: URL) throws -> URL {
        let payload = directory.appendingPathComponent("Payload")
        try FileManager.default.createDirectory(at: payload.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: payload.appendingPathComponent("keep.txt"))
        try Data("unicode".utf8).write(to: payload.appendingPathComponent("中文文件.txt"))
        try Data("metadata".utf8).write(to: payload.appendingPathComponent(".DS_Store"))
        try Data("metadata".utf8).write(to: payload.appendingPathComponent("._keep.txt"))
        try Data("metadata".utf8).write(to: payload.appendingPathComponent("__MACOSX/metadata"))

        var bytes = [UInt8](repeating: 0, count: 8_192)
        for index in bytes.indices { bytes[index] = UInt8((index * 31 + 17) % 251) }
        try Data(bytes).write(to: payload.appendingPathComponent("data.bin"))
        return payload
    }

    private static func isCleanArchivePath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        return !components.contains(".DS_Store") &&
            !components.contains("__MACOSX") &&
            !components.contains { $0.hasPrefix("._") }
    }

    private static func makeTable(identifiers: [String]) -> NSTableView {
        let table = NSTableView()
        for identifier in identifiers {
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier)))
        }
        return table
    }

    private static func columnsWidth(_ table: NSTableView) -> CGFloat {
        guard table.numberOfColumns > 0 else { return 0 }
        return table.rect(ofColumn: table.numberOfColumns - 1).maxX
    }

    private static func isFitted(_ table: NSTableView, in scroll: NSScrollView) -> Bool {
        approximately(columnsWidth(table), scroll.contentView.bounds.width, tolerance: 1.5)
    }

    private static func canScrollHorizontally(_ scroll: NSScrollView) -> Bool {
        let clipView = scroll.contentView
        var proposedBounds = clipView.bounds
        proposedBounds.origin.x += 80
        let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
        return abs(constrainedBounds.origin.x - clipView.bounds.origin.x) > 1
    }

    private static func equalWidths(_ lhs: [CGFloat], _ rhs: [CGFloat]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { approximately($0, $1) }
    }

    private static func approximately(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 1) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
}
