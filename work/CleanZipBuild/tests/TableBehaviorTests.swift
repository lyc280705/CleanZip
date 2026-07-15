import AppKit
import SwiftUI

@main
@MainActor
struct TableBehaviorTests {
    private static var failures: [String] = []

    static func main() {
        _ = NSApplication.shared
        testMainMenuConfiguration()
        testNativeTableConfiguration()
        testArchiveColumnReorderingPolicy()
        testSelectedItemsColumnReorderingPolicy()
        testNativeColumnSizing()
        testSelectedItemMetadataSnapshot()
        testProgressPublishingIsDeduplicated()
        testStaleOperationCallbacksAreIgnored()
        testArchiveDerivedStateIsCached()
        testSplitSizeValidation()
        testArchiveEngineRoundTrips()
        testEncryptedArchivePasswordFlow()
        testPreCancelledOperationDoesNotCreateOutput()

        if failures.isEmpty {
            print("PASS: CleanZip table behavior tests")
            exit(EXIT_SUCCESS)
        }

        failures.forEach { fputs("FAIL: \($0)\n", stderr) }
        exit(EXIT_FAILURE)
    }

    private static func testMainMenuConfiguration() {
        let delegate = AppDelegate()
        delegate.configureMainMenu()

        guard let mainMenu = NSApp.mainMenu else {
            failures.append("the app should install a standard main menu")
            return
        }
        expect(mainMenu.items.count == 6, "the main menu should include app, File, Edit, View, Window, and Help menus")
        expect(NSApp.servicesMenu != nil, "the app menu should register a Services submenu")
        expect(NSApp.windowsMenu != nil, "the Window menu should be registered with NSApplication")

        let fileMenu = mainMenu.items.dropFirst().first?.submenu
        let openItem = fileMenu?.items.first
        expect(openItem?.keyEquivalent == "o", "Open Archive should use the standard Command-O shortcut")
        expect(openItem?.keyEquivalentModifierMask == [.command], "Open Archive should use Command-O without extra modifiers")
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
        expect(table.columnAutoresizingStyle == .reverseSequentialColumnAutoresizingStyle, "window resizing should use AppKit's reverse sequential policy")

        let flexibleMask = FinderTableBehavior.resizingMask(isFlexibleColumn: true)
        let fixedMask = FinderTableBehavior.resizingMask(isFlexibleColumn: false)
        expect(flexibleMask.contains(.userResizingMask) && flexibleMask.contains(.autoresizingMask), "the name column should support user and window resizing")
        expect(fixedMask.contains(.userResizingMask) && !fixedMask.contains(.autoresizingMask), "later columns should resize only when their divider is dragged")
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

    private static func testNativeColumnSizing() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 820, height: 400))
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
        for (index, pair) in zip(table.tableColumns.indices, zip(table.tableColumns, widths)) {
            let (column, sizing) = pair
            column.width = sizing.0
            column.minWidth = sizing.1
            column.maxWidth = sizing.2
            column.resizingMask = FinderTableBehavior.resizingMask(isFlexibleColumn: index == 0)
        }
        table.columnAutoresizingStyle = .reverseSequentialColumnAutoresizingStyle
        scroll.documentView = table
        scroll.layoutSubtreeIfNeeded()

        expect(!canScrollHorizontally(scroll), "columns that fit should not scroll horizontally")

        let firstColumn = table.tableColumns[0]
        let typeColumn = table.tableColumns[1]
        let firstBeforeDividerDrag = firstColumn.width
        let typeBeforeDividerDrag = typeColumn.width
        typeColumn.width += 36
        scroll.layoutSubtreeIfNeeded()
        expect(approximately(firstColumn.width, firstBeforeDividerDrag), "resizing one divider must not rewrite another column")
        expect(approximately(typeColumn.width, typeBeforeDividerDrag + 36), "the dragged column should keep its native AppKit width")
        expect(columnsWidth(table) > scroll.contentView.bounds.width, "a wider user-resized column should create native table overflow")

        scroll.setFrameSize(NSSize(width: 980, height: 400))
        scroll.layoutSubtreeIfNeeded()
        expect(!canScrollHorizontally(scroll), "expanding the viewport should naturally remove overflow")

        firstColumn.width = firstColumn.minWidth
        scroll.setFrameSize(NSSize(width: 420, height: 400))
        scroll.layoutSubtreeIfNeeded()
        expect(approximately(firstColumn.width, firstColumn.minWidth), "the first column must respect its minimum width")
        expect(columnsWidth(table) > scroll.contentView.bounds.width + 1, "columns should overflow only when their native minimum widths cannot fit")
        expect(canScrollHorizontally(scroll), "minimum-width overflow should use the standard horizontal scroller")
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

    private static func testStaleOperationCallbacksAreIgnored() {
        let state = AppState()
        let staleOperation = state.beginOperation(title: "Old", detail: "")
        let activeOperation = state.beginOperation(title: "New", detail: "")

        state.updateOperationProgress(0.75, for: staleOperation)
        expect(state.operationProgress?.title == "New", "a stale progress callback must not replace the active operation")
        expect(state.operationProgress?.fraction == 0, "a stale progress callback must not advance the active operation")
        expect(!state.finishOperation(status: "Old finished", for: staleOperation), "a stale completion must be rejected")
        expect(state.isBusy, "a stale completion must not clear the active busy state")
        expect(state.finishOperation(status: "New finished", for: activeOperation), "the active completion should be accepted")
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

    private static func testSplitSizeValidation() {
        let state = AppState()
        guard let customPreset = SplitPreset.all.first(where: { $0.id == "custom" }) else {
            failures.append("the custom split preset should exist")
            return
        }
        state.splitPreset = customPreset

        state.customSplitMB = "100"
        expect(state.isSplitConfigurationValid, "a positive whole-number split size should be valid")
        expect(state.resolvedSplitSpec() == "100m", "a valid custom split size should resolve to a 7-Zip volume spec")

        for invalidValue in ["", "0", "-1", "1.5", "letters", "1048577"] {
            state.customSplitMB = invalidValue
            expect(!state.isSplitConfigurationValid, "custom split size '\(invalidValue)' should be rejected")
            expect(state.resolvedSplitSpec() == nil, "an invalid custom split size must not silently create an unsplit archive")
        }
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

    private static func testEncryptedArchivePasswordFlow() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanzip-password-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("secret.txt")
            let archive = root.appendingPathComponent("encrypted.7z")
            try Data("confidential".utf8).write(to: source)
            guard let sevenZip = ArchiveEngine.shared.sevenZipURL else {
                failures.append("7zz should be available for encrypted archive tests")
                return
            }
            try runTool(sevenZip, arguments: ["a", "-t7z", "-pcorrect-password", "-mhe=on", archive.path, source.lastPathComponent], currentDirectory: root)

            do {
                _ = try ArchiveEngine.shared.listArchive(archive)
                failures.append("a header-encrypted archive should request a password")
            } catch ArchiveError.passwordRequired {
                // Expected.
            } catch {
                failures.append("a missing password should be classified, got: \(error.localizedDescription)")
            }

            do {
                _ = try ArchiveEngine.shared.listArchive(archive, password: "wrong-password")
                failures.append("an incorrect archive password should fail")
            } catch ArchiveError.wrongPassword {
                // Expected.
            } catch {
                failures.append("an incorrect password should be classified, got: \(error.localizedDescription)")
            }

            let entries = try ArchiveEngine.shared.listArchive(archive, password: "correct-password")
            expect(entries.contains { $0.path == "secret.txt" }, "the correct password should reveal encrypted archive entries")
            try ArchiveEngine.shared.testArchive(archive, password: "correct-password")
            let extracted = try ArchiveEngine.shared.extract(archive: archive, password: "correct-password")
            expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("secret.txt").path), "the correct password should extract the encrypted archive")
        } catch {
            failures.append("encrypted archive flow failed: \(error.localizedDescription)")
        }
    }

    private static func testPreCancelledOperationDoesNotCreateOutput() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanzip-cancel-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("cancel-me.txt")
            try Data("cancel".utf8).write(to: source)
            let cancellation = OperationCancellation()
            cancellation.cancel()
            do {
                _ = try ArchiveEngine.shared.compress(urls: [source], format: .zip, splitSpec: nil, cancellation: cancellation)
                failures.append("a pre-cancelled compression should not run")
            } catch ArchiveError.cancelled {
                // Expected.
            }
            expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cancel-me.zip").path), "cancelled compression must not leave a partial archive")
        } catch {
            failures.append("cancellation cleanup test failed: \(error.localizedDescription)")
        }
    }

    private static func runTool(_ executable: URL, arguments: [String], currentDirectory: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ArchiveError.failed(message)
        }
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

    private static func canScrollHorizontally(_ scroll: NSScrollView) -> Bool {
        let clipView = scroll.contentView
        var proposedBounds = clipView.bounds
        proposedBounds.origin.x += 80
        let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
        return abs(constrainedBounds.origin.x - clipView.bounds.origin.x) > 1
    }

    private static func approximately(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 1) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
}
