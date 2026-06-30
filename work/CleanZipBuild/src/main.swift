import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

enum L10n {
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: args)
    }

    static func itemCount(_ count: Int) -> String {
        tr(count == 1 ? "count.item.one" : "count.item.other", String(count))
    }

    static func archiveCount(_ count: Int) -> String {
        tr(count == 1 ? "count.archive.one" : "count.archive.other", String(count))
    }

    static func fileCount(_ count: Int) -> String {
        tr(count == 1 ? "count.file.one" : "count.file.other", String(count))
    }
}

struct ArchiveEntry: Identifiable {
    let id = UUID()
    let path: String
    let size: Int64
    let modified: String
    let isDirectory: Bool
}

struct OperationProgress {
    var title: String
    var detail: String
    var fraction: Double?

    var percentText: String {
        guard let fraction else { return "" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}

extension Notification.Name {
    static let cleanZipStateDidChange = Notification.Name("local.codex.cleanzip.stateDidChange")
}

struct SelectedItem: Identifiable {
    let url: URL
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var location: String { url.deletingLastPathComponent().path }
    var isDirectory: Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
    var typeName: String { isDirectory ? L10n.tr("item.type.folder") : (url.pathExtension.isEmpty ? L10n.tr("item.type.file") : url.pathExtension.uppercased()) }
    var sizeText: String {
        if isDirectory { return "--" }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return AppState.formatBytes(size)
    }
}

enum ArchiveFormat: String, CaseIterable, Identifiable {
    case zip = "ZIP"
    case sevenZ = "7Z"
    var id: String { rawValue }
    var fileExtension: String { self == .zip ? "zip" : "7z" }
}

struct SplitPreset: Identifiable, Hashable {
    let id: String
    let titleKey: String
    let spec: String?
    var title: String { L10n.tr(titleKey) }
    static let all: [SplitPreset] = [
        .init(id: "none", titleKey: "split.none", spec: nil),
        .init(id: "10m", titleKey: "split.10mb", spec: "10m"),
        .init(id: "50m", titleKey: "split.50mb", spec: "50m"),
        .init(id: "100m", titleKey: "split.100mb", spec: "100m"),
        .init(id: "500m", titleKey: "split.500mb", spec: "500m"),
        .init(id: "1g", titleKey: "split.1gb", spec: "1g"),
        .init(id: "custom", titleKey: "split.custom", spec: nil)
    ]
}

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private final class DataBuffer {
    private var data = Data()
    private let lock = NSLock()

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }
}

enum ArchiveError: Error, LocalizedError {
    case missingTool(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .missingTool(let tool): return L10n.tr("error.missingTool", tool)
        case .failed(let message): return message
        }
    }
}

final class ArchiveEngine {
    static let shared = ArchiveEngine()
    private static let progressRegex = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,3})%"#)
    typealias ProgressHandler = (Double) -> Void
    private let fileManager = FileManager.default

    var sevenZipURL: URL? {
        if let bundled = Bundle.main.url(forResource: "7zz", withExtension: nil),
           fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let extensions = [
            ".zip", ".7z", ".rar", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2",
            ".tar.xz", ".txz", ".tar.zst", ".tzst", ".gz", ".bz2", ".xz", ".zst",
            ".iso", ".cab", ".dmg", ".xar", ".jar", ".war", ".apk", ".zip.001", ".7z.001"
        ]
        if extensions.contains(where: { name.hasSuffix($0) }) { return true }
        if name.range(of: #"\.z\d{2}$"#, options: .regularExpression) != nil { return true }
        if name.range(of: #"\.r\d{2}$"#, options: .regularExpression) != nil { return true }
        return false
    }

    func listArchive(_ archive: URL) throws -> [ArchiveEntry] {
        guard let sevenZipURL else { throw ArchiveError.missingTool("7zz") }
        let result = try runProcess(executable: sevenZipURL, arguments: ["l", "-slt", archive.path])
        guard result.status == 0 else { throw ArchiveError.failed(result.stderr.isEmpty ? result.stdout : result.stderr) }
        return parseSevenZipList(result.stdout)
    }

    func testArchive(_ archive: URL) throws {
        guard let sevenZipURL else { throw ArchiveError.missingTool("7zz") }
        let result = try runProcess(executable: sevenZipURL, arguments: ["t", "-y", archive.path])
        guard result.status == 0 else { throw ArchiveError.failed(result.stderr.isEmpty ? result.stdout : result.stderr) }
    }

    func compress(urls: [URL], format: ArchiveFormat, splitSpec: String?, progressHandler: ProgressHandler? = nil) throws -> URL {
        guard !urls.isEmpty else { throw ArchiveError.failed(L10n.tr("error.noItemsToCompress")) }
        let parent = urls[0].deletingLastPathComponent()
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL }) else {
            throw ArchiveError.failed(L10n.tr("error.sameParentRequired"))
        }
        let baseName = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let output = uniqueFileURL(in: parent, baseName: baseName, extensionName: format.fileExtension, splitSpec: splitSpec)
        let itemNames = urls.map { itemNameForProcess($0) }
        try compressWith7z(parent: parent, output: output, itemNames: itemNames, archiveType: format == .zip ? "zip" : "7z", splitSpec: splitSpec, progressHandler: progressHandler)
        return output
    }

    func extract(archive: URL, progressHandler: ProgressHandler? = nil) throws -> URL {
        let parent = archive.deletingLastPathComponent()
        let baseName = archiveBaseName(archive)
        let outputDir = uniqueDirectoryURL(in: parent, baseName: baseName)
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        if progressHandler != nil {
            return try extractWith7z(archive: archive, outputDir: outputDir, progressHandler: progressHandler)
        }
        if archive.lastPathComponent.lowercased().hasSuffix(".zip") {
            let result = try runProcess(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, outputDir.path])
            if result.status == 0 { return outputDir }
            try? fileManager.removeItem(at: outputDir)
            let fallbackDir = uniqueDirectoryURL(in: parent, baseName: baseName)
            try fileManager.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
            return try extractWith7z(archive: archive, outputDir: fallbackDir, progressHandler: progressHandler)
        }
        return try extractWith7z(archive: archive, outputDir: outputDir, progressHandler: progressHandler)
    }

    private func compressWith7z(parent: URL, output: URL, itemNames: [String], archiveType: String, splitSpec: String?, progressHandler: ProgressHandler?) throws {
        guard let sevenZipURL else { throw ArchiveError.missingTool("7zz") }
        var args = ["a", "-t\(archiveType)", "-mx=5", "-y"]
        if progressHandler != nil { args.append("-bsp1") }
        if let splitSpec, !splitSpec.isEmpty { args.append("-v\(splitSpec)") }
        args.append(output.path)
        args.append(contentsOf: itemNames)
        args.append(contentsOf: ["-xr!.DS_Store", "-xr!__MACOSX", "-xr!._*"])
        var env = ProcessInfo.processInfo.environment
        env["COPYFILE_DISABLE"] = "1"
        let result = try runProcess(executable: sevenZipURL, arguments: args, currentDirectory: parent, environment: env, progressHandler: progressHandler)
        guard result.status == 0 else { throw ArchiveError.failed(result.stderr.isEmpty ? result.stdout : result.stderr) }
    }

    private func extractWith7z(archive: URL, outputDir: URL, progressHandler: ProgressHandler?) throws -> URL {
        guard let sevenZipURL else { throw ArchiveError.missingTool("7zz") }
        var args = ["x", "-y"]
        if progressHandler != nil { args.append("-bsp1") }
        args.append("-o\(outputDir.path)")
        args.append(archive.path)
        let result = try runProcess(executable: sevenZipURL, arguments: args, progressHandler: progressHandler)
        guard result.status == 0 else { throw ArchiveError.failed(result.stderr.isEmpty ? result.stdout : result.stderr) }
        return outputDir
    }

    private func runProcess(executable: URL, arguments: [String], currentDirectory: URL? = nil, environment: [String: String]? = nil, progressHandler: ProgressHandler? = nil) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment { process.environment = environment }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutBuffer = DataBuffer()
        let stderrBuffer = DataBuffer()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            self.readPipe(stdoutPipe, into: stdoutBuffer, progressHandler: progressHandler)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            self.readPipe(stderrPipe, into: stderrBuffer, progressHandler: progressHandler)
            readers.leave()
        }
        try process.run()
        process.waitUntilExit()
        readers.wait()
        return ProcessResult(status: process.terminationStatus, stdout: stdoutBuffer.string, stderr: stderrBuffer.string)
    }

    private func readPipe(_ pipe: Pipe, into buffer: DataBuffer, progressHandler: ProgressHandler?) {
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            buffer.append(data)
            if let text = String(data: data, encoding: .utf8) {
                reportProgress(from: text, progressHandler: progressHandler)
            }
        }
    }

    private func reportProgress(from text: String, progressHandler: ProgressHandler?) {
        guard let progressHandler else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in Self.progressRegex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range(at: 1), in: text),
                  let value = Double(text[matchRange]),
                  value >= 0, value <= 100 else { continue }
            progressHandler(value / 100)
        }
    }

    private func parseSevenZipList(_ output: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var current: [String: String] = [:]
        func flush() {
            guard let path = current["Path"], !path.isEmpty, current["Folder"] != nil else { return }
            let size = Int64(current["Size"] ?? "0") ?? 0
            entries.append(ArchiveEntry(path: path, size: size, modified: formatArchiveTimestamp(current["Modified"] ?? ""), isDirectory: (current["Folder"] ?? "-") == "+"))
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flush()
                current.removeAll()
                continue
            }
            guard let range = text.range(of: " = ") else { continue }
            current[String(text[..<range.lowerBound])] = String(text[range.upperBound...])
        }
        flush()
        return entries.filter { $0.path != "." }
    }

    private func formatArchiveTimestamp(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let pattern = #"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
              let dateRange = Range(match.range(at: 1), in: trimmed),
              let timeRange = Range(match.range(at: 2), in: trimmed) else {
            return trimmed
        }
        return "\(trimmed[dateRange]) \(trimmed[timeRange])"
    }

    private func itemNameForProcess(_ url: URL) -> String {
        let name = url.lastPathComponent
        return name.hasPrefix("-") ? "./\(name)" : name
    }

    private func archiveBaseName(_ url: URL) -> String {
        var name = url.lastPathComponent
        let suffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".zip.001", ".7z.001", ".tgz", ".tbz2", ".tbz", ".txz", ".tzst", ".zip", ".7z", ".rar", ".tar", ".gz", ".bz2", ".xz", ".zst", ".iso", ".cab", ".dmg", ".xar"]
        for suffix in suffixes where name.lowercased().hasSuffix(suffix) {
            name.removeLast(suffix.count)
            return name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func uniqueFileURL(in directory: URL, baseName: String, extensionName: String, splitSpec: String?) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(extensionName)")
        var index = 2
        while outputExists(candidate, splitSpec: splitSpec, extensionName: extensionName) {
            candidate = directory.appendingPathComponent("\(baseName) \(index).\(extensionName)")
            index += 1
        }
        return candidate
    }

    private func outputExists(_ url: URL, splitSpec: String?, extensionName: String) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        if splitSpec != nil, extensionName == "zip" || extensionName == "7z" { return fileManager.fileExists(atPath: "\(url.path).001") }
        return false
    }

    private func uniqueDirectoryURL(in directory: URL, baseName: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(index)")
            index += 1
        }
        return candidate
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var selectedURLs: [URL] = []
    @Published var selectedItemIDs: Set<String> = []
    @Published var archiveURL: URL?
    @Published var entries: [ArchiveEntry] = []
    @Published var searchText = ""
    @Published var status = L10n.tr("status.empty")
    @Published var isBusy = false
    @Published var operationProgress: OperationProgress?
    @Published var showingCompressSheet = false
    @Published var format: ArchiveFormat = .zip
    @Published var splitPreset: SplitPreset = SplitPreset.all[0]
    @Published var customSplitMB = "100"
    var selectedItems: [SelectedItem] { selectedURLs.map(SelectedItem.init(url:)) }
    var totalFiles: Int { entries.filter { !$0.isDirectory }.count }
    var totalBytes: Int64 { entries.reduce(0) { $0 + max($1.size, 0) } }

    func handle(urls: [URL]) {
        guard !urls.isEmpty else { return }
        searchText = ""
        if urls.count == 1, ArchiveEngine.shared.isArchive(urls[0]) {
            archiveURL = urls[0]
            selectedURLs = []
            selectedItemIDs = []
            operationProgress = nil
            previewArchive(urls[0])
        } else {
            archiveURL = nil
            entries = []
            selectedURLs = uniqued(urls)
            selectedItemIDs = []
            operationProgress = nil
            status = L10n.tr("status.selectedItems", L10n.itemCount(selectedURLs.count))
        }
        notifyStateDidChange()
    }

    func appendItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        archiveURL = nil
        entries = []
        selectedURLs = uniqued(selectedURLs + urls)
        selectedItemIDs = selectedItemIDs.filter { id in selectedURLs.contains { $0.path == id } }
        operationProgress = nil
        status = L10n.tr("status.selectedItems", L10n.itemCount(selectedURLs.count))
        notifyStateDidChange()
    }

    func removeSelectedItems() {
        guard !selectedItemIDs.isEmpty else { return }
        selectedURLs.removeAll { selectedItemIDs.contains($0.path) }
        selectedItemIDs.removeAll()
        status = selectedURLs.isEmpty ? L10n.tr("status.empty") : L10n.tr("status.selectedItems", L10n.itemCount(selectedURLs.count))
        notifyStateDidChange()
    }

    func clearSelectedItems() {
        selectedURLs.removeAll()
        selectedItemIDs.removeAll()
        operationProgress = nil
        status = L10n.tr("status.empty")
        notifyStateDidChange()
    }

    func previewArchive(_ url: URL) {
        isBusy = true
        status = L10n.tr("status.reading", url.lastPathComponent)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let list = try ArchiveEngine.shared.listArchive(url)
                DispatchQueue.main.async {
                    self.entries = list
                    self.status = L10n.tr("status.previewComplete", L10n.fileCount(self.totalFiles), Self.formatBytes(self.totalBytes))
                    self.isBusy = false
                    self.notifyStateDidChange()
                }
            } catch {
                DispatchQueue.main.async {
                    self.entries = []
                    self.status = L10n.tr("status.previewFailed", error.localizedDescription)
                    self.isBusy = false
                    self.notifyStateDidChange()
                }
            }
        }
        notifyStateDidChange()
    }

    func compressSelected() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let split = resolvedSplitSpec()
        let selectedFormat = format
        beginOperation(title: L10n.tr("operation.compressing"), detail: L10n.itemCount(urls.count))
        showingCompressSheet = false
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try ArchiveEngine.shared.compress(urls: urls, format: selectedFormat, splitSpec: split) { fraction in
                    DispatchQueue.main.async {
                        self.updateOperationProgress(fraction)
                    }
                }
                DispatchQueue.main.async {
                    self.status = L10n.tr("status.created", output.lastPathComponent)
                    self.isBusy = false
                    self.operationProgress = nil
                    self.notifyStateDidChange()
                    Self.notify(title: "CleanZip", message: L10n.tr("notification.created", output.lastPathComponent))
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = L10n.tr("status.compressFailed", error.localizedDescription)
                    self.isBusy = false
                    self.operationProgress = nil
                    self.notifyStateDidChange()
                }
            }
        }
    }

    func extractCurrentArchive() {
        guard let archiveURL else { return }
        beginOperation(title: L10n.tr("operation.extracting"), detail: archiveURL.lastPathComponent)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try ArchiveEngine.shared.extract(archive: archiveURL) { fraction in
                    DispatchQueue.main.async {
                        self.updateOperationProgress(fraction)
                    }
                }
                DispatchQueue.main.async {
                    self.status = L10n.tr("status.extractedTo", output.lastPathComponent)
                    self.isBusy = false
                    self.operationProgress = nil
                    self.notifyStateDidChange()
                    Self.notify(title: "CleanZip", message: L10n.tr("notification.extractedTo", output.lastPathComponent))
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = L10n.tr("status.extractFailed", error.localizedDescription)
                    self.isBusy = false
                    self.operationProgress = nil
                    self.notifyStateDidChange()
                }
            }
        }
    }

    func testCurrentArchive() {
        guard let archiveURL else { return }
        isBusy = true
        status = L10n.tr("status.testing")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ArchiveEngine.shared.testArchive(archiveURL)
                DispatchQueue.main.async {
                    self.status = L10n.tr("status.testPassed")
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = L10n.tr("status.testFailed", error.localizedDescription)
                    self.isBusy = false
                }
            }
        }
    }

    func openArchivePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { handle(urls: [url]) }
    }

    func openItemsPanel(append: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { append ? appendItems(panel.urls) : handle(urls: panel.urls) }
    }

    func resolvedSplitSpec() -> String? {
        if splitPreset.id == "custom" {
            let trimmed = customSplitMB.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return "\(trimmed)m"
        }
        return splitPreset.spec
    }

    nonisolated static func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func notify(title: String, message: String, completion: (() -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completion?() } }
        }
    }

    private func uniqued(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(url)
        }
        return result
    }

    func prepareArchiveOperation(urls: [URL], title: String, detail: String) {
        searchText = ""
        archiveURL = urls.count == 1 ? urls[0] : nil
        entries = []
        selectedURLs = []
        selectedItemIDs = []
        beginOperation(title: title, detail: detail)
    }

    func beginOperation(title: String, detail: String) {
        isBusy = true
        operationProgress = OperationProgress(title: title, detail: detail, fraction: 0)
        status = L10n.tr("status.progress", title, "0")
        notifyStateDidChange()
    }

    func updateOperationProgress(_ fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        let previous = operationProgress?.fraction ?? -1
        guard clamped >= 1 || abs(clamped - previous) >= 0.005 else { return }
        if operationProgress == nil {
            operationProgress = OperationProgress(title: L10n.tr("operation.processing"), detail: "", fraction: clamped)
        } else {
            operationProgress?.fraction = clamped
        }
        let title = operationProgress?.title ?? L10n.tr("operation.processing")
        let percent = Int((clamped * 100).rounded())
        status = L10n.tr("status.progress", title, String(percent))
        notifyStateDidChange()
    }

    func finishOperation(status: String) {
        self.status = status
        isBusy = false
        operationProgress = nil
        notifyStateDidChange()
    }

    private func notifyStateDidChange() {
        NotificationCenter.default.post(name: .cleanZipStateDidChange, object: self)
    }
}

final class LockedHorizontalClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin.x = 0
        return bounds
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(NSPoint(x: 0, y: newOrigin.y))
    }
}

final class VerticalOnlyScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        lockHorizontalOrigin()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        lockHorizontalOrigin()
        super.reflectScrolledClipView(clipView)
    }

    func lockHorizontalOrigin() {
        let origin = contentView.bounds.origin
        if origin.x != 0 {
            contentView.setBoundsOrigin(NSPoint(x: 0, y: origin.y))
        }
        if let table = documentView as? NSTableView {
            table.frame.size.width = contentView.bounds.width
        }
    }
}

final class ServiceProgressHUD {
    private var panel: NSPanel?
    private var titleField: NSTextField?
    private var detailField: NSTextField?
    private var percentField: NSTextField?
    private var progressIndicator: NSProgressIndicator?
    private var scheduledShow: DispatchWorkItem?
    private var title = L10n.tr("operation.processing")
    private var detail = ""
    private var fraction = 0.0
    private var finished = false

    func begin(title: String, detail: String) {
        scheduledShow?.cancel()
        self.title = title
        self.detail = detail
        fraction = 0
        finished = false
        updateVisibleControls()

        let workItem = DispatchWorkItem { [weak self] in
            self?.showIfNeeded()
        }
        scheduledShow = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    func update(fraction newFraction: Double, detail newDetail: String? = nil) {
        guard !finished else { return }
        fraction = min(max(newFraction, 0), 1)
        if let newDetail, !newDetail.isEmpty { detail = newDetail }
        updateVisibleControls()
    }

    func finish() {
        finished = true
        scheduledShow?.cancel()
        scheduledShow = nil
        fraction = 1
        updateVisibleControls()

        guard let panel else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.panel = nil
        }
    }

    private func showIfNeeded() {
        guard !finished else { return }
        if panel == nil { panel = makePanel() }
        updateVisibleControls()
        panel?.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 116),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.tr("window.progressTitle")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let rootView: NSView
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.style = .regular
            glassView.cornerRadius = 24
            glassView.contentView = contentView
            rootView = glassView
        } else {
            let visualEffectView = NSVisualEffectView()
            visualEffectView.material = .hudWindow
            visualEffectView.blendingMode = .behindWindow
            visualEffectView.state = .active
            visualEffectView.wantsLayer = true
            visualEffectView.layer?.cornerRadius = 24
            visualEffectView.layer?.masksToBounds = true
            visualEffectView.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
            ])
            rootView = visualEffectView
        }

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.textColor = .labelColor

        let detailField = NSTextField(labelWithString: detail)
        detailField.font = .systemFont(ofSize: 12)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingMiddle

        let progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = fraction
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let percentField = NSTextField(labelWithString: percentText)
        percentField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percentField.textColor = .secondaryLabelColor
        percentField.alignment = .right

        let textStack = NSStackView(views: [titleField, detailField])
        textStack.orientation = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let bottomStack = NSStackView(views: [progressIndicator, percentField])
        bottomStack.orientation = .horizontal
        bottomStack.spacing = 10
        bottomStack.alignment = .centerY
        bottomStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(textStack)
        contentView.addSubview(bottomStack)
        panel.contentView = rootView

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),

            bottomStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            bottomStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            bottomStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            progressIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            percentField.widthAnchor.constraint(equalToConstant: 42)
        ])

        self.titleField = titleField
        self.detailField = detailField
        self.percentField = percentField
        self.progressIndicator = progressIndicator
        position(panel)
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 72
        )
        panel.setFrameOrigin(origin)
    }

    private var percentText: String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func updateVisibleControls() {
        titleField?.stringValue = title
        detailField?.stringValue = detail
        progressIndicator?.doubleValue = fraction
        percentField?.stringValue = percentText
    }
}

struct ArchiveEntriesTable: NSViewRepresentable {
    let entries: [ArchiveEntry]

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var entries: [ArchiveEntry]
        private var isFittingColumns = false
        private var lastVisibleWidth: CGFloat = 0
        init(entries: [ArchiveEntry]) { self.entries = entries }
        deinit { NotificationCenter.default.removeObserver(self) }
        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < entries.count, let tableColumn else { return nil }
            let entry = entries[row]
            let identifier = tableColumn.identifier.rawValue
            if identifier == "name" {
                return nameCell(tableView: tableView, entry: entry)
            }
            return textCell(tableView: tableView, identifier: identifier, text: text(for: entry, identifier: identifier), alignment: identifier == "size" ? .right : .left)
        }

        private func text(for entry: ArchiveEntry, identifier: String) -> String {
            switch identifier {
            case "size": return entry.isDirectory ? "--" : AppState.formatBytes(entry.size)
            case "modified": return entry.modified
            default: return ""
            }
        }

        private func nameCell(tableView: NSTableView, entry: ArchiveEntry) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier("ArchiveNameCell")
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = cellID

            let imageView: NSImageView
            if let existing = cell.imageView {
                imageView = existing
            } else {
                imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                imageView.symbolConfiguration = .init(pointSize: 13, weight: .regular)
                cell.addSubview(imageView)
                cell.imageView = imageView
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 18),
                    imageView.heightAnchor.constraint(equalToConstant: 18)
                ])
            }

            let textField: NSTextField
            if let existing = cell.textField {
                textField = existing
            } else {
                textField = NSTextField(labelWithString: "")
                textField.lineBreakMode = .byTruncatingMiddle
                textField.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(textField)
                cell.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }

            imageView.image = NSImage(systemSymbolName: entry.isDirectory ? "folder" : "doc", accessibilityDescription: nil)
            imageView.contentTintColor = .secondaryLabelColor
            textField.stringValue = entry.path
            textField.alignment = .left
            return cell
        }

        private func textCell(tableView: NSTableView, identifier: String, text: String, alignment: NSTextAlignment) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier("ArchiveTextCell-\(identifier)")
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = cellID

            let textField: NSTextField
            if let existing = cell.textField {
                textField = existing
            } else {
                textField = NSTextField(labelWithString: "")
                textField.lineBreakMode = .byTruncatingMiddle
                textField.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(textField)
                cell.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            textField.stringValue = text
            textField.alignment = alignment
            return cell
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            fitColumns(in: tableView)
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            fitColumns(in: tableView)
        }

        @objc func clipBoundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let tableView = clipView.documentView as? NSTableView else { return }
            let visibleWidth = floor(clipView.bounds.width)
            if abs(visibleWidth - lastVisibleWidth) > 1 {
                fitColumns(in: tableView)
            } else {
                (tableView.enclosingScrollView as? VerticalOnlyScrollView)?.lockHorizontalOrigin()
            }
        }

        func fitColumns(in tableView: NSTableView) {
            guard !isFittingColumns,
                  let scrollView = tableView.enclosingScrollView else { return }

            isFittingColumns = true
            defer { isFittingColumns = false }

            let visibleWidth = max(420, floor(scrollView.contentView.bounds.width))
            tableView.frame.size.width = visibleWidth
            lastVisibleWidth = visibleWidth
            updateColumnResizingMasks(in: tableView)
            tableView.sizeLastColumnToFit()
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: scrollView.contentView.bounds.origin.y))
            (scrollView as? VerticalOnlyScrollView)?.lockHorizontalOrigin()
        }

        private func updateColumnResizingMasks(in tableView: NSTableView) {
            guard let lastColumn = tableView.tableColumns.last else { return }
            for column in tableView.tableColumns {
                column.resizingMask = column === lastColumn ? [.autoresizingMask] : [.userResizingMask, .autoresizingMask]
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(entries: entries) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = false
        table.rowHeight = 26
        table.headerView = NSTableHeaderView()
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autosaveName = "local.codex.cleanzip.archiveEntriesTable"
        table.autosaveTableColumns = true
        let columns: [(String, String, CGFloat, CGFloat, CGFloat)] = [
            ("name", L10n.tr("column.name"), 380, 180, 1200),
            ("size", L10n.tr("column.size"), 140, 96, 280),
            ("modified", L10n.tr("column.modified"), 240, 190, 2000)
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.0))
            column.title = spec.1
            column.width = spec.2
            column.minWidth = spec.3
            column.maxWidth = spec.4
            column.resizingMask = [.userResizingMask, .autoresizingMask]
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        let scroll = VerticalOnlyScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentView = LockedHorizontalClipView()
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.documentView = table
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        context.coordinator.fitColumns(in: table)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.entries = entries
        if let table = scrollView.documentView as? NSTableView {
            context.coordinator.fitColumns(in: table)
            table.reloadData()
        }
        (scrollView as? VerticalOnlyScrollView)?.lockHorizontalOrigin()
    }
}

struct SelectedItemsTable: NSViewRepresentable {
    let items: [SelectedItem]
    @Binding var selectedIDs: Set<String>

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var items: [SelectedItem]
        var selectedIDs: Binding<Set<String>>
        private var isFittingColumns = false
        private var isApplyingSelection = false
        private var lastVisibleWidth: CGFloat = 0

        init(items: [SelectedItem], selectedIDs: Binding<Set<String>>) {
            self.items = items
            self.selectedIDs = selectedIDs
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < items.count, let tableColumn else { return nil }
            let item = items[row]
            switch tableColumn.identifier.rawValue {
            case "selectedName":
                return nameCell(tableView: tableView, item: item)
            case "selectedType":
                return textCell(tableView: tableView, identifier: "selectedType", text: item.typeName, alignment: .left)
            case "selectedSize":
                return textCell(tableView: tableView, identifier: "selectedSize", text: item.sizeText, alignment: .left)
            case "selectedLocation":
                return textCell(tableView: tableView, identifier: "selectedLocation", text: item.location, alignment: .left)
            default:
                return nil
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection,
                  let tableView = notification.object as? NSTableView else { return }
            let ids = tableView.selectedRowIndexes.compactMap { row in
                row < items.count ? items[row].id : nil
            }
            selectedIDs.wrappedValue = Set(ids)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            fitColumns(in: tableView)
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            fitColumns(in: tableView)
        }

        @objc func clipBoundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let tableView = clipView.documentView as? NSTableView else { return }
            let visibleWidth = floor(clipView.bounds.width)
            if abs(visibleWidth - lastVisibleWidth) > 1 {
                fitColumns(in: tableView)
            } else {
                (tableView.enclosingScrollView as? VerticalOnlyScrollView)?.lockHorizontalOrigin()
            }
        }

        func applySelection(to tableView: NSTableView) {
            isApplyingSelection = true
            defer { isApplyingSelection = false }
            let indexes = IndexSet(items.enumerated().compactMap { index, item in
                selectedIDs.wrappedValue.contains(item.id) ? index : nil
            })
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }

        func fitColumns(in tableView: NSTableView) {
            guard !isFittingColumns,
                  let scrollView = tableView.enclosingScrollView else { return }

            isFittingColumns = true
            defer { isFittingColumns = false }

            let visibleWidth = max(560, floor(scrollView.contentView.bounds.width))
            tableView.frame.size.width = visibleWidth
            lastVisibleWidth = visibleWidth
            updateColumnResizingMasks(in: tableView)
            tableView.sizeLastColumnToFit()
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: scrollView.contentView.bounds.origin.y))
            (scrollView as? VerticalOnlyScrollView)?.lockHorizontalOrigin()
        }

        private func updateColumnResizingMasks(in tableView: NSTableView) {
            guard let lastColumn = tableView.tableColumns.last else { return }
            for column in tableView.tableColumns {
                column.resizingMask = column === lastColumn ? [.autoresizingMask] : [.userResizingMask, .autoresizingMask]
            }
        }

        private func nameCell(tableView: NSTableView, item: SelectedItem) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier("SelectedNameCell")
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = cellID

            let imageView: NSImageView
            if let existing = cell.imageView {
                imageView = existing
            } else {
                imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                imageView.symbolConfiguration = .init(pointSize: 13, weight: .regular)
                cell.addSubview(imageView)
                cell.imageView = imageView
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 18),
                    imageView.heightAnchor.constraint(equalToConstant: 18)
                ])
            }

            let textField: NSTextField
            if let existing = cell.textField {
                textField = existing
            } else {
                textField = NSTextField(labelWithString: "")
                textField.lineBreakMode = .byTruncatingMiddle
                textField.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(textField)
                cell.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }

            imageView.image = NSImage(systemSymbolName: item.isDirectory ? "folder" : "doc", accessibilityDescription: nil)
            imageView.contentTintColor = .secondaryLabelColor
            textField.stringValue = item.name
            textField.alignment = .left
            return cell
        }

        private func textCell(tableView: NSTableView, identifier: String, text: String, alignment: NSTextAlignment) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier("SelectedTextCell-\(identifier)")
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = cellID

            let textField: NSTextField
            if let existing = cell.textField {
                textField = existing
            } else {
                textField = NSTextField(labelWithString: "")
                textField.lineBreakMode = identifier == "selectedLocation" ? .byTruncatingMiddle : .byTruncatingTail
                textField.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(textField)
                cell.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            textField.stringValue = text
            textField.alignment = alignment
            return cell
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items, selectedIDs: $selectedIDs)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = true
        table.rowHeight = 26
        table.headerView = NSTableHeaderView()
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autosaveName = "local.codex.cleanzip.selectedItemsTable"
        table.autosaveTableColumns = true

        let columns: [(String, String, CGFloat, CGFloat, CGFloat)] = [
            ("selectedName", L10n.tr("column.name"), 260, 180, 900),
            ("selectedType", L10n.tr("column.type"), 90, 70, 160),
            ("selectedSize", L10n.tr("column.size"), 120, 90, 220),
            ("selectedLocation", L10n.tr("column.location"), 360, 220, 2000)
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.0))
            column.title = spec.1
            column.width = spec.2
            column.minWidth = spec.3
            column.maxWidth = spec.4
            column.resizingMask = [.userResizingMask, .autoresizingMask]
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator

        let scroll = VerticalOnlyScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentView = LockedHorizontalClipView()
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.documentView = table

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        context.coordinator.fitColumns(in: table)
        context.coordinator.applySelection(to: table)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.items = items
        context.coordinator.selectedIDs = $selectedIDs
        if let table = scrollView.documentView as? NSTableView {
            context.coordinator.fitColumns(in: table)
            table.reloadData()
            context.coordinator.applySelection(to: table)
        }
        (scrollView as? VerticalOnlyScrollView)?.lockHorizontalOrigin()
    }
}

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    private var filteredEntries: [ArchiveEntry] {
        guard !state.searchText.isEmpty else { return state.entries }
        return state.entries.filter { $0.path.localizedCaseInsensitiveContains(state.searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            mainContent
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .sheet(isPresented: $state.showingCompressSheet) { CompressSheet().environmentObject(state) }
    }

    @ViewBuilder
    private var mainContent: some View {
        if let archive = state.archiveURL {
            archivePreview(archive)
        } else if !state.selectedURLs.isEmpty {
            selectedItemsView
        } else {
            ContentUnavailableView {
                Label(L10n.tr("empty.title"), systemImage: "shippingbox")
            } description: {
                Text(L10n.tr("empty.description"))
            } actions: {
                HStack {
                    Button(L10n.tr("button.chooseArchive")) { state.openArchivePanel() }
                    Button(L10n.tr("button.chooseItems")) { state.openItemsPanel() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func archivePreview(_ archive: URL) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(archive.lastPathComponent).font(.headline).lineLimit(1)
                    Text(L10n.tr("archive.summary", L10n.fileCount(state.totalFiles), AppState.formatBytes(state.totalBytes))).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            ArchiveEntriesTable(entries: filteredEntries)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }

    private var selectedItemsView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("selected.title", L10n.itemCount(state.selectedURLs.count))).font(.headline)
                    Text(L10n.tr("selected.description")).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            SelectedItemsTable(items: state.selectedItems, selectedIDs: $state.selectedItemIDs)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(state.status)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            if let progress = state.operationProgress {
                ProgressView(value: progress.fraction ?? 0, total: 1)
                    .progressViewStyle(.linear)
                    .frame(width: 180)
                    .accessibilityLabel(progress.title)
                    .accessibilityValue(progress.percentText)
                Text(progress.percentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.bar)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                urls.append(url)
            }
        }
        group.notify(queue: .main) { state.handle(urls: urls) }
        return true
    }
}

struct CompressSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("settings.title")).font(.title2.weight(.semibold))
            Form {
                Picker(L10n.tr("settings.format"), selection: $state.format) {
                    ForEach(ArchiveFormat.allCases) { format in Text(format.rawValue).tag(format) }
                }
                .pickerStyle(.segmented)
                Picker(L10n.tr("settings.splitSize"), selection: $state.splitPreset) {
                    ForEach(SplitPreset.all) { preset in Text(preset.title).tag(preset) }
                }
                if state.splitPreset.id == "custom" {
                    HStack {
                        TextField(L10n.tr("settings.sizePlaceholder"), text: $state.customSplitMB).textFieldStyle(.roundedBorder).frame(width: 90)
                        Text("MB").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Text(L10n.tr("settings.cleanMetadataNote")).foregroundStyle(.secondary).font(.footnote)
            HStack {
                Spacer()
                Button(L10n.tr("button.cancel")) { dismiss() }
                Button { state.compressSelected() } label: { Label(L10n.tr("button.startCompress"), systemImage: "archivebox") }.buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, UNUserNotificationCenterDelegate, NSSearchFieldDelegate {
    private var window: NSWindow?
    private var serviceInvoked = false
    private var openedFromFile = false
    private var openedFromUntitledLaunch = false
    private var stateObserver: AnyCancellable?
    private var searchExpanded = false
    private let serviceProgressHUD = ServiceProgressHUD()
    private let chooseArchiveItemID = NSToolbarItem.Identifier("local.codex.cleanzip.chooseArchive")
    private let chooseItemsItemID = NSToolbarItem.Identifier("local.codex.cleanzip.chooseItems")
    private let addItemsItemID = NSToolbarItem.Identifier("local.codex.cleanzip.addItems")
    private let removeItemsItemID = NSToolbarItem.Identifier("local.codex.cleanzip.removeItems")
    private let clearItemsItemID = NSToolbarItem.Identifier("local.codex.cleanzip.clearItems")
    private let compressSettingsItemID = NSToolbarItem.Identifier("local.codex.cleanzip.compressSettings")
    private let testArchiveItemID = NSToolbarItem.Identifier("local.codex.cleanzip.testArchive")
    private let extractArchiveItemID = NSToolbarItem.Identifier("local.codex.cleanzip.extractArchive")
    private let compactSearchItemID = NSToolbarItem.Identifier("local.codex.cleanzip.compactSearch")
    private let searchItemID = NSToolbarItem.Identifier("local.codex.cleanzip.search")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        configureNotifications()
        stateObserver = NotificationCenter.default.publisher(for: .cleanZipStateDidChange).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshToolbar() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !self.serviceInvoked && !self.openedFromFile && !self.openedFromUntitledLaunch && self.window == nil && NSApp.isActive {
                self.showWindow()
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        openedFromUntitledLaunch = true
        NSApp.setActivationPolicy(.regular)
        showWindow()
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) {
        openedFromFile = true
        showWindow()
        AppState.shared.handle(urls: urls)
        refreshToolbar()
    }

    @objc(cleanZip:userData:error:)
    func cleanZip(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        serviceInvoked = true
        let urls = pasteboardURLs(pasteboard)
        guard !urls.isEmpty else {
            error.pointee = L10n.tr("error.noFinderItems") as NSString
            terminateIfServiceOnly()
            return
        }
        let shouldExtract = urls.allSatisfy { ArchiveEngine.shared.isArchive($0) }
        let operationTitle = shouldExtract ? L10n.tr("operation.extracting") : L10n.tr("operation.compressing")
        let operationDetail = shouldExtract
            ? (urls.count == 1 ? urls[0].lastPathComponent : L10n.archiveCount(urls.count))
            : (urls.count == 1 ? urls[0].lastPathComponent : L10n.itemCount(urls.count))
        serviceProgressHUD.begin(title: operationTitle, detail: operationDetail)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if shouldExtract {
                    var outputs: [URL] = []
                    for (index, url) in urls.enumerated() {
                        let base = Double(index) / Double(urls.count)
                        let scale = 1 / Double(urls.count)
                        outputs.append(try ArchiveEngine.shared.extract(archive: url) { fraction in
                            DispatchQueue.main.async {
                                self.serviceProgressHUD.update(fraction: base + fraction * scale, detail: url.lastPathComponent)
                            }
                        })
                    }
                    DispatchQueue.main.async {
                        self.serviceProgressHUD.finish()
                        let message = outputs.count == 1 ? L10n.tr("notification.extractedTo", outputs[0].lastPathComponent) : L10n.tr("notification.extractedArchives", L10n.archiveCount(outputs.count))
                        AppState.notify(title: "CleanZip", message: message) { self.terminateIfServiceOnly() }
                    }
                } else {
                    let output = try ArchiveEngine.shared.compress(urls: urls, format: .zip, splitSpec: nil) { fraction in
                        DispatchQueue.main.async {
                            self.serviceProgressHUD.update(fraction: fraction)
                        }
                    }
                    DispatchQueue.main.async {
                        self.serviceProgressHUD.finish()
                        let message = L10n.tr("notification.created", output.lastPathComponent)
                        AppState.notify(title: "CleanZip", message: message) { self.terminateIfServiceOnly() }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.serviceProgressHUD.finish()
                    AppState.notify(title: L10n.tr("notification.operationFailedTitle"), message: error.localizedDescription) {
                        self.terminateIfServiceOnly()
                    }
                }
            }
        }
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let hosting = NSHostingView(rootView: ContentView().environmentObject(AppState.shared))
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            newWindow.title = "CleanZip"
            newWindow.titlebarAppearsTransparent = false
            newWindow.toolbarStyle = .unified
            newWindow.isOpaque = true
            newWindow.backgroundColor = .windowBackgroundColor
            newWindow.toolbar = makeToolbar()
            newWindow.contentView = hosting
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            newWindow.center()
            window = newWindow
            refreshToolbar()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refreshToolbar()
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window { window = nil }
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "local.codex.cleanzip.toolbar.native")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if #available(macOS 15.0, *) { return allToolbarItemIdentifiers }
        return visibleToolbarItemIdentifiers()
    }

    private var allToolbarItemIdentifiers: [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            compactSearchItemID,
            searchItemID,
            testArchiveItemID,
            addItemsItemID,
            removeItemsItemID,
            clearItemsItemID,
            chooseArchiveItemID,
            chooseItemsItemID,
            extractArchiveItemID,
            compressSettingsItemID
        ]
    }

    private func visibleToolbarItemIdentifiers() -> [NSToolbarItem.Identifier] {
        let state = AppState.shared
        let showingArchive = state.archiveURL != nil
        let showingSelectedItems = !state.selectedURLs.isEmpty
        let showExpandedSearch = showingArchive && (searchExpanded || !state.searchText.isEmpty)

        var identifiers: [NSToolbarItem.Identifier] = [.flexibleSpace]
        if showingArchive {
            identifiers.append(showExpandedSearch ? searchItemID : compactSearchItemID)
            identifiers.append(testArchiveItemID)
        }
        if showingSelectedItems {
            identifiers.append(contentsOf: [addItemsItemID, removeItemsItemID, clearItemsItemID])
        }
        identifiers.append(contentsOf: [chooseArchiveItemID, chooseItemsItemID])
        if showingArchive {
            identifiers.append(extractArchiveItemID)
        }
        if showingSelectedItems {
            identifiers.append(compressSettingsItemID)
        }
        return identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            chooseArchiveItemID,
            chooseItemsItemID,
            compactSearchItemID,
            searchItemID,
            testArchiveItemID,
            extractArchiveItemID,
            addItemsItemID,
            removeItemsItemID,
            clearItemsItemID,
            compressSettingsItemID,
            .flexibleSpace,
            .space
        ]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case chooseArchiveItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.tr("toolbar.chooseArchive")
            item.paletteLabel = L10n.tr("toolbar.chooseArchive")
            item.toolTip = L10n.tr("toolbar.chooseArchive.tooltip")
            item.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: L10n.tr("toolbar.chooseArchive"))
            item.visibilityPriority = .high
            item.target = self
            item.action = #selector(openArchiveFromToolbar(_:))
            return item
        case chooseItemsItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.tr("toolbar.chooseItems")
            item.paletteLabel = L10n.tr("toolbar.chooseItems")
            item.toolTip = L10n.tr("toolbar.chooseItems.tooltip")
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: L10n.tr("toolbar.chooseItems"))
            item.visibilityPriority = .high
            item.target = self
            item.action = #selector(openItemsFromToolbar(_:))
            return item
        case compactSearchItemID:
            let item = toolbarItem(
                identifier: itemIdentifier,
                label: L10n.tr("toolbar.search"),
                symbol: "magnifyingglass",
                tooltip: L10n.tr("toolbar.search.tooltip"),
                action: #selector(beginSearchFromToolbar(_:))
            )
            item.visibilityPriority = .high
            return item
        case searchItemID:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.tr("toolbar.search")
            item.paletteLabel = L10n.tr("toolbar.search.palette")
            item.toolTip = L10n.tr("toolbar.search.tooltip")
            item.searchField.placeholderString = L10n.tr("toolbar.search.placeholder")
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.sendsWholeSearchString = false
            item.preferredWidthForSearchField = 280
            item.resignsFirstResponderWithCancel = true
            item.searchField.target = self
            item.searchField.action = #selector(searchFromToolbar(_:))
            item.visibilityPriority = .high
            return item
        case testArchiveItemID:
            return toolbarItem(
                identifier: itemIdentifier,
                label: L10n.tr("toolbar.test"),
                symbol: "checkmark.shield",
                tooltip: L10n.tr("toolbar.test.tooltip"),
                action: #selector(testArchiveFromToolbar(_:))
            )
        case extractArchiveItemID:
            let item = toolbarItem(
                identifier: itemIdentifier,
                label: L10n.tr("toolbar.extract"),
                symbol: "arrow.down.doc",
                tooltip: L10n.tr("toolbar.extract.tooltip"),
                action: #selector(extractArchiveFromToolbar(_:))
            )
            if #available(macOS 26.0, *) { item.style = .prominent }
            item.visibilityPriority = .high
            return item
        case addItemsItemID:
            return toolbarItem(
                identifier: itemIdentifier,
                label: L10n.tr("toolbar.add"),
                symbol: "plus",
                tooltip: L10n.tr("toolbar.add.tooltip"),
                action: #selector(addItemsFromToolbar(_:))
            )
        case removeItemsItemID:
            return toolbarItem(
                identifier: itemIdentifier,
                label: L10n.tr("toolbar.remove"),
                symbol: "minus",
                tooltip: L10n.tr("toolbar.remove.tooltip"),
                action: #selector(removeItemsFromToolbar(_:))
            )
        case clearItemsItemID:
            return toolbarItem(
                identifier: itemIdentifier,
                label: L10n.tr("toolbar.clear"),
                symbol: "trash",
                tooltip: L10n.tr("toolbar.clear.tooltip"),
                action: #selector(clearItemsFromToolbar(_:))
            )
        case compressSettingsItemID:
            let item = toolbarItem(
                identifier: itemIdentifier,
                label: L10n.tr("toolbar.compressSettings"),
                symbol: "archivebox",
                tooltip: L10n.tr("toolbar.compressSettings.tooltip"),
                action: #selector(compressSettingsFromToolbar(_:))
            )
            if #available(macOS 26.0, *) { item.style = .prominent }
            item.visibilityPriority = .high
            return item
        default:
            return nil
        }
    }

    @objc private func openArchiveFromToolbar(_ sender: Any?) { showWindow(); AppState.shared.openArchivePanel() }
    @objc private func openItemsFromToolbar(_ sender: Any?) { showWindow(); AppState.shared.openItemsPanel() }
    @objc private func addItemsFromToolbar(_ sender: Any?) { showWindow(); AppState.shared.openItemsPanel(append: true); refreshToolbar() }
    @objc private func removeItemsFromToolbar(_ sender: Any?) { AppState.shared.removeSelectedItems(); refreshToolbar() }
    @objc private func clearItemsFromToolbar(_ sender: Any?) { AppState.shared.clearSelectedItems(); refreshToolbar() }
    @objc private func compressSettingsFromToolbar(_ sender: Any?) { AppState.shared.showingCompressSheet = true; refreshToolbar() }
    @objc private func testArchiveFromToolbar(_ sender: Any?) { AppState.shared.testCurrentArchive(); refreshToolbar() }
    @objc private func extractArchiveFromToolbar(_ sender: Any?) { AppState.shared.extractCurrentArchive(); refreshToolbar() }
    @objc private func searchFromToolbar(_ sender: NSSearchField) { AppState.shared.searchText = sender.stringValue; refreshToolbar() }
    @objc private func beginSearchFromToolbar(_ sender: Any?) {
        searchExpanded = true
        refreshToolbar()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let searchItem = self.window?.toolbar?.items.first(where: { $0.itemIdentifier == self.searchItemID }) as? NSSearchToolbarItem else { return }
            searchItem.beginSearchInteraction()
        }
    }

    nonisolated func controlTextDidEndEditing(_ obj: Notification) {
        Task { @MainActor in
            guard AppState.shared.searchText.isEmpty else { return }
            searchExpanded = false
            refreshToolbar()
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case removeItemsItemID:
            return !AppState.shared.selectedItemIDs.isEmpty && !AppState.shared.isBusy
        case clearItemsItemID, compressSettingsItemID, addItemsItemID:
            return !AppState.shared.selectedURLs.isEmpty && !AppState.shared.isBusy
        case testArchiveItemID, extractArchiveItemID:
            return AppState.shared.archiveURL != nil && !AppState.shared.isBusy
        case compactSearchItemID, searchItemID:
            return AppState.shared.archiveURL != nil && !AppState.shared.isBusy
        default:
            return true
        }
    }

    private func toolbarItem(identifier: NSToolbarItem.Identifier, label: String, symbol: String, tooltip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tooltip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.visibilityPriority = .standard
        item.target = self
        item.action = action
        return item
    }

    private func refreshToolbar() {
        guard let toolbar = window?.toolbar else { return }
        let state = AppState.shared
        let showingArchive = state.archiveURL != nil
        let showingSelectedItems = !state.selectedURLs.isEmpty
        let showExpandedSearch = showingArchive && (searchExpanded || !state.searchText.isEmpty)
        if #available(macOS 15.0, *) {
            for item in toolbar.items {
                switch item.itemIdentifier {
                case compactSearchItemID:
                    item.isHidden = !showingArchive || showExpandedSearch
                case searchItemID:
                    item.isHidden = !showExpandedSearch
                    if let searchItem = item as? NSSearchToolbarItem, searchItem.searchField.stringValue != state.searchText {
                        searchItem.searchField.stringValue = state.searchText
                    }
                case testArchiveItemID, extractArchiveItemID:
                    item.isHidden = !showingArchive
                case addItemsItemID, removeItemsItemID, clearItemsItemID, compressSettingsItemID:
                    item.isHidden = !showingSelectedItems
                default:
                    break
                }
            }
        } else {
            refreshLegacyToolbarItems(toolbar)
            if let searchItem = toolbar.items.first(where: { $0.itemIdentifier == searchItemID }) as? NSSearchToolbarItem,
               searchItem.searchField.stringValue != state.searchText {
                searchItem.searchField.stringValue = state.searchText
            }
        }
        toolbar.validateVisibleItems()
    }

    private func refreshLegacyToolbarItems(_ toolbar: NSToolbar) {
        let desired = visibleToolbarItemIdentifiers()
        let current = toolbar.items.map(\.itemIdentifier)
        guard current != desired else { return }
        if !toolbar.items.isEmpty {
            for index in stride(from: toolbar.items.count - 1, through: 0, by: -1) {
                toolbar.removeItem(at: index)
            }
        }
        for (index, identifier) in desired.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
    }

    private func terminateIfServiceOnly() { if serviceInvoked && window == nil { NSApp.terminate(nil) } }
    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    private func pasteboardURLs(_ pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { return urls }
        if let filenames = pasteboard.propertyList(forType: .fileURL) as? [String] { return filenames.map { URL(fileURLWithPath: $0) } }
        if let filenames = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] { return filenames.map { URL(fileURLWithPath: $0) } }
        return []
    }
}

@main
@MainActor
struct CleanZipMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
