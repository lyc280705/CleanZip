@preconcurrency import AppKit
@preconcurrency import Combine
@preconcurrency import QuartzCore
@preconcurrency import SwiftUI
@preconcurrency import UniformTypeIdentifiers
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

struct ArchiveEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let path: String
    let size: Int64
    let modified: String
    let isDirectory: Bool
}

struct OperationProgress: Sendable {
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

struct SelectedItem: Identifiable, Equatable, Sendable {
    let url: URL
    let isDirectory: Bool
    let byteSize: Int64?

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        isDirectory = values?.isDirectory ?? false
        if let fileSize = values?.fileSize {
            byteSize = Int64(fileSize)
        } else {
            byteSize = nil
        }
    }

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var location: String { url.deletingLastPathComponent().path }
    var typeName: String { isDirectory ? L10n.tr("item.type.folder") : (url.pathExtension.isEmpty ? L10n.tr("item.type.file") : url.pathExtension.uppercased()) }
    var sizeText: String {
        if isDirectory { return "--" }
        return AppState.formatBytes(byteSize ?? 0)
    }
}

enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
    case zip = "ZIP"
    case sevenZ = "7Z"
    var id: String { rawValue }
    var fileExtension: String { self == .zip ? "zip" : "7z" }
}

struct SplitPreset: Identifiable, Hashable, Sendable {
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

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

private final class DataBuffer: @unchecked Sendable {
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

final class OperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func register(_ process: Process) {
        let shouldTerminate = lock.withLock {
            self.process = process
            return cancelled
        }
        if shouldTerminate, process.isRunning { process.terminate() }
    }

    func unregister(_ process: Process) {
        lock.withLock {
            if self.process === process { self.process = nil }
        }
    }

    func cancel() {
        let runningProcess = lock.withLock {
            cancelled = true
            return process
        }
        if let runningProcess, runningProcess.isRunning { runningProcess.terminate() }
    }

    func checkCancellation() throws {
        if isCancelled { throw ArchiveError.cancelled }
    }
}

enum ArchiveError: Error, LocalizedError, Sendable {
    case missingTool(String)
    case failed(String)
    case passwordRequired
    case wrongPassword
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingTool(let tool): return L10n.tr("error.missingTool", tool)
        case .failed(let message): return message
        case .passwordRequired: return L10n.tr("error.passwordRequired")
        case .wrongPassword: return L10n.tr("error.wrongPassword")
        case .cancelled: return L10n.tr("error.cancelled")
        }
    }
}

final class ArchiveEngine: @unchecked Sendable {
    static let shared = ArchiveEngine()
    static let supportedFilenameExtensions = [
        "zip", "7z", "rar", "tar", "tar.gz", "tgz", "tar.bz2", "tbz", "tbz2",
        "tar.xz", "txz", "tar.zst", "tzst", "gz", "bz2", "xz", "zst",
        "iso", "cab", "dmg", "xar", "jar", "war", "apk", "zip.001", "7z.001"
    ]
    private static let progressRegex = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,3})%"#)
    typealias ProgressHandler = @Sendable (Double) -> Void
    private let fileManager = FileManager.default

    var sevenZipURL: URL? {
#if CLEANZIP_TESTING
        if let testPath = ProcessInfo.processInfo.environment["CLEANZIP_7ZZ_PATH"],
           fileManager.isExecutableFile(atPath: testPath) {
            return URL(fileURLWithPath: testPath)
        }
#endif
        if let bundled = Bundle.main.url(forResource: "7zz", withExtension: nil),
           fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if Self.supportedFilenameExtensions.contains(where: { name.hasSuffix(".\($0)") }) { return true }
        if name.range(of: #"\.z\d{2}$"#, options: .regularExpression) != nil { return true }
        if name.range(of: #"\.r\d{2}$"#, options: .regularExpression) != nil { return true }
        return false
    }

    func listArchive(_ archive: URL, password: String? = nil, cancellation: OperationCancellation? = nil) throws -> [ArchiveEntry] {
        guard let sevenZipURL else { throw ArchiveError.missingTool("7zz") }
        let result = try runProcess(
            executable: sevenZipURL,
            arguments: ["l", "-slt", archive.path],
            password: password,
            cancellation: cancellation
        )
        guard result.status == 0 else { throw archiveError(for: result) }
        return parseSevenZipList(result.stdout)
    }

    @concurrent
    func listArchiveInBackground(_ archive: URL, password: String? = nil, cancellation: OperationCancellation? = nil) async throws -> [ArchiveEntry] {
        try listArchive(archive, password: password, cancellation: cancellation)
    }

    func testArchive(_ archive: URL, password: String? = nil, cancellation: OperationCancellation? = nil) throws {
        guard let sevenZipURL else { throw ArchiveError.missingTool("7zz") }
        let result = try runProcess(
            executable: sevenZipURL,
            arguments: ["t", "-y", archive.path],
            password: password,
            cancellation: cancellation
        )
        guard result.status == 0 else { throw archiveError(for: result) }
    }

    @concurrent
    func testArchiveInBackground(_ archive: URL, password: String? = nil, cancellation: OperationCancellation? = nil) async throws {
        try testArchive(archive, password: password, cancellation: cancellation)
    }

    func compress(
        urls: [URL],
        format: ArchiveFormat,
        splitSpec: String?,
        cancellation: OperationCancellation? = nil,
        progressHandler: ProgressHandler? = nil
    ) throws -> URL {
        guard !urls.isEmpty else { throw ArchiveError.failed(L10n.tr("error.noItemsToCompress")) }
        let parent = urls[0].deletingLastPathComponent()
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL }) else {
            throw ArchiveError.failed(L10n.tr("error.sameParentRequired"))
        }
        let baseName = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let output = uniqueFileURL(in: parent, baseName: baseName, extensionName: format.fileExtension, splitSpec: splitSpec)
        let itemNames = urls.map { itemNameForProcess($0) }
        do {
            try compressWith7z(
                parent: parent,
                output: output,
                itemNames: itemNames,
                archiveType: format == .zip ? "zip" : "7z",
                splitSpec: splitSpec,
                cancellation: cancellation,
                progressHandler: progressHandler
            )
            return output
        } catch {
            removePartialArchive(at: output)
            throw error
        }
    }

    @concurrent
    func compressInBackground(
        urls: [URL],
        format: ArchiveFormat,
        splitSpec: String?,
        cancellation: OperationCancellation? = nil,
        progressHandler: ProgressHandler? = nil
    ) async throws -> URL {
        try compress(
            urls: urls,
            format: format,
            splitSpec: splitSpec,
            cancellation: cancellation,
            progressHandler: progressHandler
        )
    }

    func extract(
        archive: URL,
        password: String? = nil,
        cancellation: OperationCancellation? = nil,
        progressHandler: ProgressHandler? = nil
    ) throws -> URL {
        let parent = archive.deletingLastPathComponent()
        let baseName = archiveBaseName(archive)
        let outputDir = uniqueDirectoryURL(in: parent, baseName: baseName)
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        do {
            if progressHandler != nil || password != nil {
                return try extractWith7z(
                    archive: archive,
                    outputDir: outputDir,
                    password: password,
                    cancellation: cancellation,
                    progressHandler: progressHandler
                )
            }
            if archive.lastPathComponent.lowercased().hasSuffix(".zip") {
                let result = try runProcess(
                    executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                    arguments: ["-x", "-k", archive.path, outputDir.path],
                    cancellation: cancellation
                )
                if result.status == 0 { return outputDir }
                try? fileManager.removeItem(at: outputDir)
                let fallbackDir = uniqueDirectoryURL(in: parent, baseName: baseName)
                try fileManager.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
                do {
                    return try extractWith7z(
                        archive: archive,
                        outputDir: fallbackDir,
                        password: password,
                        cancellation: cancellation,
                        progressHandler: progressHandler
                    )
                } catch {
                    try? fileManager.removeItem(at: fallbackDir)
                    throw error
                }
            }
            return try extractWith7z(
                archive: archive,
                outputDir: outputDir,
                password: password,
                cancellation: cancellation,
                progressHandler: progressHandler
            )
        } catch {
            try? fileManager.removeItem(at: outputDir)
            throw error
        }
    }

    @concurrent
    func extractInBackground(
        archive: URL,
        password: String? = nil,
        cancellation: OperationCancellation? = nil,
        progressHandler: ProgressHandler? = nil
    ) async throws -> URL {
        try extract(
            archive: archive,
            password: password,
            cancellation: cancellation,
            progressHandler: progressHandler
        )
    }

    private func compressWith7z(
        parent: URL,
        output: URL,
        itemNames: [String],
        archiveType: String,
        splitSpec: String?,
        cancellation: OperationCancellation?,
        progressHandler: ProgressHandler?
    ) throws {
        guard let sevenZipURL else { throw ArchiveError.missingTool("7zz") }
        var args = ["a", "-t\(archiveType)", "-mx=5", "-y"]
        if progressHandler != nil { args.append("-bsp1") }
        if let splitSpec, !splitSpec.isEmpty { args.append("-v\(splitSpec)") }
        args.append(output.path)
        args.append(contentsOf: itemNames)
        args.append(contentsOf: ["-xr!.DS_Store", "-xr!__MACOSX", "-xr!._*"])
        var env = ProcessInfo.processInfo.environment
        env["COPYFILE_DISABLE"] = "1"
        let result = try runProcess(
            executable: sevenZipURL,
            arguments: args,
            currentDirectory: parent,
            environment: env,
            cancellation: cancellation,
            progressHandler: progressHandler
        )
        guard result.status == 0 else { throw archiveError(for: result) }
    }

    private func extractWith7z(
        archive: URL,
        outputDir: URL,
        password: String?,
        cancellation: OperationCancellation?,
        progressHandler: ProgressHandler?
    ) throws -> URL {
        guard let sevenZipURL else { throw ArchiveError.missingTool("7zz") }
        var args = ["x", "-y"]
        if progressHandler != nil { args.append("-bsp1") }
        args.append("-o\(outputDir.path)")
        args.append(archive.path)
        let result = try runProcess(
            executable: sevenZipURL,
            arguments: args,
            password: password,
            cancellation: cancellation,
            progressHandler: progressHandler
        )
        guard result.status == 0 else {
            try? fileManager.removeItem(at: outputDir)
            throw archiveError(for: result)
        }
        return outputDir
    }

    private func removePartialArchive(at output: URL) {
        try? fileManager.removeItem(at: output)
        let directory = output.deletingLastPathComponent()
        let volumePrefix = output.lastPathComponent + "."
        guard let candidates = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for candidate in candidates {
            let name = candidate.lastPathComponent
            guard name.hasPrefix(volumePrefix) else { continue }
            let suffix = name.dropFirst(volumePrefix.count)
            if suffix.count == 3, suffix.allSatisfy(\.isNumber) {
                try? fileManager.removeItem(at: candidate)
            }
        }
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        password: String? = nil,
        cancellation: OperationCancellation? = nil,
        progressHandler: ProgressHandler? = nil
    ) throws -> ProcessResult {
        try cancellation?.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment { process.environment = environment }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe: Pipe?
        if password != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }
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
        cancellation?.register(process)
        defer { cancellation?.unregister(process) }
        if let password, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data("\(password)\n".utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        readers.wait()
        try cancellation?.checkCancellation()
        return ProcessResult(status: process.terminationStatus, stdout: stdoutBuffer.string, stderr: stderrBuffer.string)
    }

    private func archiveError(for result: ProcessResult) -> ArchiveError {
        let message = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        let lowercased = message.lowercased()
        if lowercased.contains("wrong password") { return .wrongPassword }
        if lowercased.contains("enter password") || lowercased.contains("password is required") {
            return .passwordRequired
        }
        return .failed(message.isEmpty ? L10n.tr("error.unknownArchiveFailure") : message)
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
            guard let path = current["Path"], !path.isEmpty, current["Size"] != nil else { return }
            let size = Int64(current["Size"] ?? "0") ?? 0
            let attributes = current["Attributes"] ?? ""
            let isDirectory = current["Folder"] == "+" || attributes.hasPrefix("D") || path.hasSuffix("/")
            entries.append(ArchiveEntry(path: path, size: size, modified: formatArchiveTimestamp(current["Modified"] ?? ""), isDirectory: isDirectory))
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

enum PendingPasswordAction: Sendable {
    case preview(URL, generation: Int)
    case extract(URL)
    case test(URL)
}

enum ServiceHandoffError: Error, Sendable {
    case passwordRequired(URL)
}

struct PasswordPrompt: Identifiable, Sendable {
    let id = UUID()
    let archiveName: String
    let isRetry: Bool
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var selectedURLs: [URL] = [] {
        didSet {
            selectedItems = selectedURLs.map(SelectedItem.init(url:))
            selectedItemsRevision &+= 1
        }
    }
    @Published var selectedItemIDs: Set<String> = []
    @Published var archiveURL: URL?
    @Published var entries: [ArchiveEntry] = [] {
        didSet {
            entriesRevision &+= 1
            refreshEntryDerivedState()
        }
    }
    @Published var searchText = "" {
        didSet {
            if searchText != oldValue { refreshFilteredEntries() }
        }
    }
    @Published var status = L10n.tr("status.empty")
    @Published var isBusy = false
    @Published var operationProgress: OperationProgress?
    @Published var showingCompressSheet = false
    @Published var format: ArchiveFormat = .zip
    @Published var splitPreset: SplitPreset = SplitPreset.all[0]
    @Published var customSplitMB = "100"
    @Published var passwordPrompt: PasswordPrompt?
    private(set) var selectedItems: [SelectedItem] = []
    private(set) var selectedItemsRevision = 0
    private(set) var entriesRevision = 0
    private(set) var filteredEntries: [ArchiveEntry] = []
    private(set) var totalFiles = 0
    private(set) var totalBytes: Int64 = 0
    private var previewGeneration = 0
    private var previewCancellation: OperationCancellation?
    private var operationCancellation: OperationCancellation?
    private var pendingPasswordAction: PendingPasswordAction?
    private var archivePassword: String?

    func handle(urls: [URL]) {
        guard !urls.isEmpty else { return }
        previewCancellation?.cancel()
        previewCancellation = nil
        archivePassword = nil
        pendingPasswordAction = nil
        passwordPrompt = nil
        previewGeneration &+= 1
        searchText = ""
        if urls.count == 1, ArchiveEngine.shared.isArchive(urls[0]) {
            archiveURL = urls[0]
            selectedURLs = []
            selectedItemIDs = []
            operationProgress = nil
            previewArchive(urls[0], generation: previewGeneration, password: nil)
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
        previewCancellation?.cancel()
        previewCancellation = nil
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

    private func previewArchive(_ url: URL, generation: Int, password: String?) {
        previewCancellation?.cancel()
        let cancellation = OperationCancellation()
        previewCancellation = cancellation
        isBusy = true
        status = L10n.tr("status.reading", url.lastPathComponent)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let list = try await ArchiveEngine.shared.listArchiveInBackground(url, password: password, cancellation: cancellation)
                guard self.previewGeneration == generation, self.archiveURL?.standardizedFileURL == url.standardizedFileURL else { return }
                self.previewCancellation = nil
                self.entries = list
                self.status = L10n.tr("status.previewComplete", L10n.fileCount(self.totalFiles), Self.formatBytes(self.totalBytes))
                self.isBusy = false
                self.notifyStateDidChange()
            } catch {
                guard self.previewGeneration == generation, self.archiveURL?.standardizedFileURL == url.standardizedFileURL else { return }
                self.previewCancellation = nil
                if self.isPasswordError(error) {
                    self.requestPassword(for: .preview(url, generation: generation), archiveName: url.lastPathComponent, retry: self.isWrongPassword(error))
                    return
                }
                guard !self.isCancellation(error) else { return }
                self.entries = []
                self.status = L10n.tr("status.previewFailed", error.localizedDescription)
                self.isBusy = false
                self.notifyStateDidChange()
            }
        }
        notifyStateDidChange()
    }

    func compressSelected() {
        let urls = selectedURLs
        guard !urls.isEmpty, isSplitConfigurationValid else { return }
        Self.prepareNotificationsForOperation()
        let split = resolvedSplitSpec()
        let selectedFormat = format
        let cancellation = beginOperation(title: L10n.tr("operation.compressing"), detail: L10n.itemCount(urls.count))
        showingCompressSheet = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let output = try await ArchiveEngine.shared.compressInBackground(
                    urls: urls,
                    format: selectedFormat,
                    splitSpec: split,
                    cancellation: cancellation
                ) { fraction in
                    Task { @MainActor in AppState.shared.updateOperationProgress(fraction, for: cancellation) }
                }
                guard self.finishOperation(status: L10n.tr("status.created", output.lastPathComponent), for: cancellation) else { return }
                Self.notify(title: "CleanZip", message: L10n.tr("notification.created", output.lastPathComponent))
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                self.finishOperation(
                    status: self.isCancellation(error) ? L10n.tr("status.cancelled") : L10n.tr("status.compressFailed", error.localizedDescription),
                    for: cancellation
                )
            }
        }
    }

    func extractCurrentArchive() {
        guard let archiveURL else { return }
        Self.prepareNotificationsForOperation()
        let password = archivePassword
        let cancellation = beginOperation(title: L10n.tr("operation.extracting"), detail: archiveURL.lastPathComponent)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let output = try await ArchiveEngine.shared.extractInBackground(
                    archive: archiveURL,
                    password: password,
                    cancellation: cancellation
                ) { fraction in
                    Task { @MainActor in AppState.shared.updateOperationProgress(fraction, for: cancellation) }
                }
                guard self.finishOperation(status: L10n.tr("status.extractedTo", output.lastPathComponent), for: cancellation) else { return }
                Self.notify(title: "CleanZip", message: L10n.tr("notification.extractedTo", output.lastPathComponent))
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                if self.isPasswordError(error) {
                    guard self.finishOperation(status: error.localizedDescription, for: cancellation) else { return }
                    self.requestPassword(for: .extract(archiveURL), archiveName: archiveURL.lastPathComponent, retry: self.isWrongPassword(error))
                } else {
                    self.finishOperation(
                        status: self.isCancellation(error) ? L10n.tr("status.cancelled") : L10n.tr("status.extractFailed", error.localizedDescription),
                        for: cancellation
                    )
                }
            }
        }
    }

    func testCurrentArchive() {
        guard let archiveURL else { return }
        let password = archivePassword
        let cancellation = beginOperation(title: L10n.tr("status.testing"), detail: archiveURL.lastPathComponent, fraction: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await ArchiveEngine.shared.testArchiveInBackground(archiveURL, password: password, cancellation: cancellation)
                self.finishOperation(status: L10n.tr("status.testPassed"), for: cancellation)
            } catch {
                if self.isPasswordError(error) {
                    guard self.finishOperation(status: error.localizedDescription, for: cancellation) else { return }
                    self.requestPassword(for: .test(archiveURL), archiveName: archiveURL.lastPathComponent, retry: self.isWrongPassword(error))
                } else {
                    self.finishOperation(
                        status: self.isCancellation(error) ? L10n.tr("status.cancelled") : L10n.tr("status.testFailed", error.localizedDescription),
                        for: cancellation
                    )
                }
            }
        }
    }

    func openArchivePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var seenTypeIdentifiers = Set<String>()
        panel.allowedContentTypes = ArchiveEngine.supportedFilenameExtensions.compactMap { extensionName in
            let filenameExtension = extensionName.split(separator: ".").last.map(String.init) ?? extensionName
            guard let type = UTType(filenameExtension: filenameExtension), seenTypeIdentifiers.insert(type.identifier).inserted else { return nil }
            return type
        }
        if panel.runModal() == .OK, let url = panel.url { handle(urls: [url]) }
    }

    func openItemsPanel(append: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { append ? appendItems(panel.urls) : handle(urls: panel.urls) }
    }

    var isSplitConfigurationValid: Bool {
        guard splitPreset.id == "custom" else { return true }
        let trimmed = customSplitMB.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else { return false }
        return (1...1_048_576).contains(value)
    }

    func resolvedSplitSpec() -> String? {
        if splitPreset.id == "custom" {
            let trimmed = customSplitMB.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSplitConfigurationValid else { return nil }
            return "\(trimmed)m"
        }
        return splitPreset.spec
    }

    nonisolated static func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func prepareNotificationsForOperation() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func notify(title: String, message: String, completion: (@MainActor @Sendable () -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let deliver: @Sendable () -> Void = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = message
                content.sound = .default
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                center.add(request) { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completion?() } }
            }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                deliver()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    granted ? deliver() : DispatchQueue.main.async { completion?() }
                }
            case .denied:
                DispatchQueue.main.async { completion?() }
            @unknown default:
                DispatchQueue.main.async { completion?() }
            }
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

    private func refreshEntryDerivedState() {
        var files = 0
        var bytes: Int64 = 0
        for entry in entries where !entry.isDirectory {
            files += 1
            bytes += max(entry.size, 0)
        }
        totalFiles = files
        totalBytes = bytes
        refreshFilteredEntries()
    }

    private func refreshFilteredEntries() {
        if searchText.isEmpty {
            filteredEntries = entries
        } else {
            filteredEntries = entries.filter { $0.path.localizedCaseInsensitiveContains(searchText) }
        }
    }

    func prepareArchiveOperation(urls: [URL], title: String, detail: String) {
        searchText = ""
        archiveURL = urls.count == 1 ? urls[0] : nil
        entries = []
        selectedURLs = []
        selectedItemIDs = []
        beginOperation(title: title, detail: detail)
    }

    @discardableResult
    func beginOperation(title: String, detail: String, fraction: Double? = 0) -> OperationCancellation {
        operationCancellation?.cancel()
        let cancellation = OperationCancellation()
        operationCancellation = cancellation
        isBusy = true
        operationProgress = OperationProgress(title: title, detail: detail, fraction: fraction)
        status = fraction == nil ? title : L10n.tr("status.progress", title, "0")
        notifyStateDidChange()
        return cancellation
    }

    func updateOperationProgress(_ fraction: Double, for operation: OperationCancellation? = nil) {
        if let operation, operationCancellation !== operation { return }
        let clamped = min(max(fraction, 0), 1)
        let previous = operationProgress?.fraction ?? -1
        let percent = Int((clamped * 100).rounded())
        let previousPercent = Int((previous * 100).rounded())
        guard clamped >= 1 || percent != previousPercent else { return }
        if operationProgress == nil {
            operationProgress = OperationProgress(title: L10n.tr("operation.processing"), detail: "", fraction: clamped)
        } else {
            operationProgress?.fraction = clamped
        }
        let title = operationProgress?.title ?? L10n.tr("operation.processing")
        status = L10n.tr("status.progress", title, String(percent))
    }

    @discardableResult
    func finishOperation(status: String, for operation: OperationCancellation? = nil) -> Bool {
        if let operation, operationCancellation !== operation { return false }
        self.status = status
        isBusy = false
        operationProgress = nil
        operationCancellation = nil
        notifyStateDidChange()
        return true
    }

    func cancelCurrentOperation() {
        guard let operationCancellation, isBusy else { return }
        status = L10n.tr("status.cancelling")
        operationCancellation.cancel()
        notifyStateDidChange()
    }

    func submitPassword(_ password: String) {
        let password = password.trimmingCharacters(in: .newlines)
        guard !password.isEmpty, let action = pendingPasswordAction else { return }
        archivePassword = password
        pendingPasswordAction = nil
        passwordPrompt = nil
        switch action {
        case .preview(let url, let generation):
            previewArchive(url, generation: generation, password: password)
        case .extract:
            extractCurrentArchive()
        case .test:
            testCurrentArchive()
        }
    }

    func cancelPasswordPrompt() {
        pendingPasswordAction = nil
        passwordPrompt = nil
        isBusy = false
        operationProgress = nil
        operationCancellation = nil
        status = L10n.tr("status.passwordCancelled")
        notifyStateDidChange()
    }

    private func requestPassword(for action: PendingPasswordAction, archiveName: String, retry: Bool) {
        pendingPasswordAction = action
        passwordPrompt = PasswordPrompt(archiveName: archiveName, isRetry: retry)
        isBusy = false
        operationProgress = nil
        operationCancellation = nil
        status = L10n.tr(retry ? "error.wrongPassword" : "error.passwordRequired")
        notifyStateDidChange()
    }

    private func isPasswordError(_ error: Error) -> Bool {
        guard let archiveError = error as? ArchiveError else { return false }
        switch archiveError {
        case .passwordRequired, .wrongPassword: return true
        default: return false
        }
    }

    private func isWrongPassword(_ error: Error) -> Bool {
        guard case ArchiveError.wrongPassword = error else { return false }
        return true
    }

    private func isCancellation(_ error: Error) -> Bool {
        guard case ArchiveError.cancelled = error else { return false }
        return true
    }

    private func notifyStateDidChange() {
        NotificationCenter.default.post(name: .cleanZipStateDidChange, object: self)
    }
}

@MainActor
enum FinderTableBehavior {
    static func configure(_ table: NSTableView, allowsMultipleSelection: Bool, autosaveName: String) {
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsColumnSelection = false
        table.allowsMultipleSelection = allowsMultipleSelection
        table.rowHeight = 26
        table.headerView = NSTableHeaderView()
        table.columnAutoresizingStyle = .reverseSequentialColumnAutoresizingStyle
        table.autosaveName = autosaveName
        table.autosaveTableColumns = true
        table.backgroundColor = .clear
    }

    static func resizingMask(isFlexibleColumn: Bool) -> NSTableColumn.ResizingOptions {
        isFlexibleColumn ? [.userResizingMask, .autoresizingMask] : [.userResizingMask]
    }

    static func shouldReorderColumn(
        in tableView: NSTableView,
        columnIndex: Int,
        newColumnIndex: Int,
        lockedIdentifier: String
    ) -> Bool {
        guard tableView.tableColumns.indices.contains(columnIndex) else { return false }
        let column = tableView.tableColumns[columnIndex]
        guard column.identifier.rawValue != lockedIdentifier else { return false }

        // AppKit first proposes -1 when a header drag begins. Other columns may
        // start dragging, but index 0 remains reserved for the name column.
        return newColumnIndex == -1 || newColumnIndex > 0
    }
}

@MainActor
struct SystemContentBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .contentBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.state = .followsWindowActiveState
    }
}

@MainActor
final class ServiceProgressHUD: NSObject {
    private var panel: NSPanel?
    private var titleField: NSTextField?
    private var detailField: NSTextField?
    private var percentField: NSTextField?
    private var progressIndicator: NSProgressIndicator?
    private var cancelButton: NSButton?
    private var scheduledShow: DispatchWorkItem?
    private var cancelHandler: (() -> Void)?
    private var title = L10n.tr("operation.processing")
    private var detail = ""
    private var fraction = 0.0
    private var finished = false

    func begin(title: String, detail: String, onCancel: (() -> Void)? = nil) {
        scheduledShow?.cancel()
        self.title = title
        self.detail = detail
        cancelHandler = onCancel
        fraction = 0
        finished = false
        cancelButton?.isEnabled = true
        updateVisibleControls()

        let workItem = DispatchWorkItem { [weak self] in
            self?.showIfNeeded()
        }
        scheduledShow = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    func update(fraction newFraction: Double, detail newDetail: String? = nil) {
        guard !finished else { return }
        let clamped = min(max(newFraction, 0), 1)
        let percentChanged = Int((clamped * 100).rounded()) != Int((fraction * 100).rounded())
        let detailChanged = newDetail.map { !$0.isEmpty && $0 != detail } ?? false
        guard percentChanged || detailChanged else { return }

        fraction = clamped
        if let newDetail, !newDetail.isEmpty { detail = newDetail }
        updateVisibleControls()
    }

    func finish() {
        finished = true
        cancelHandler = nil
        scheduledShow?.cancel()
        scheduledShow = nil
        fraction = 1
        updateVisibleControls()

        guard let panel else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak panel] in
            guard let panel else { return }
            self?.hide(panel)
        }
    }

    private func showIfNeeded() {
        guard !finished else { return }
        let created = panel == nil
        if panel == nil { panel = makePanel() }
        updateVisibleControls()
        guard let panel else { return }
        if created && !shouldReduceMotion {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        if created && !shouldReduceMotion {
            animate(panel, alpha: 1, duration: 0.18)
        } else {
            panel.alphaValue = 1
        }
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
        panel.alphaValue = shouldReduceMotion ? 1 : 0

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

        let cancelButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.tr("button.cancelOperation")) ?? NSImage(),
            target: self,
            action: #selector(cancelOperation(_:))
        )
        cancelButton.bezelStyle = .circular
        cancelButton.controlSize = .small
        cancelButton.toolTip = L10n.tr("button.cancelOperation")
        cancelButton.isHidden = cancelHandler == nil

        let textStack = NSStackView(views: [titleField, detailField])
        textStack.orientation = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let bottomStack = NSStackView(views: [progressIndicator, percentField, cancelButton])
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
            progressIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            percentField.widthAnchor.constraint(equalToConstant: 42)
        ])

        self.titleField = titleField
        self.detailField = detailField
        self.percentField = percentField
        self.progressIndicator = progressIndicator
        self.cancelButton = cancelButton
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

    private var shouldReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func hide(_ panel: NSPanel) {
        if shouldReduceMotion {
            panel.orderOut(nil)
            if self.panel === panel { self.panel = nil }
            return
        }
        animate(panel, alpha: 0, duration: 0.16) { [weak self, weak panel] in
            panel?.orderOut(nil)
            if let panel, self?.panel === panel { self?.panel = nil }
        }
    }

    private func animate(_ panel: NSPanel, alpha: CGFloat, duration: TimeInterval, completion: (@MainActor @Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: alpha > panel.alphaValue ? .easeOut : .easeIn)
            panel.animator().alphaValue = alpha
        } completionHandler: {
            Task { @MainActor in completion?() }
        }
    }

    private var percentText: String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func updateVisibleControls() {
        titleField?.stringValue = title
        detailField?.stringValue = detail
        progressIndicator?.doubleValue = fraction
        percentField?.stringValue = percentText
        cancelButton?.isHidden = cancelHandler == nil
    }

    @objc private func cancelOperation(_ sender: NSButton) {
        sender.isEnabled = false
        title = L10n.tr("status.cancelling")
        updateVisibleControls()
        cancelHandler?()
    }
}

@MainActor
struct ArchiveEntriesTable: NSViewRepresentable {
    let entries: [ArchiveEntry]
    let contentRevision: Int
    let filter: String

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var entries: [ArchiveEntry]
        var contentRevision: Int
        var filter: String

        init(entries: [ArchiveEntry], contentRevision: Int, filter: String) {
            self.entries = entries
            self.contentRevision = contentRevision
            self.filter = filter
        }
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

            imageView.image = NSImage(
                systemSymbolName: entry.isDirectory ? "folder" : "doc",
                accessibilityDescription: L10n.tr(entry.isDirectory ? "item.type.folder" : "item.type.file")
            )
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

        func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
            FinderTableBehavior.shouldReorderColumn(
                in: tableView,
                columnIndex: columnIndex,
                newColumnIndex: newColumnIndex,
                lockedIdentifier: "name"
            )
        }

        func tableView(_ tableView: NSTableView, shouldSelect tableColumn: NSTableColumn?) -> Bool { false }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(entries: entries, contentRevision: contentRevision, filter: filter)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        FinderTableBehavior.configure(
            table,
            allowsMultipleSelection: false,
            autosaveName: "local.codex.cleanzip.archiveEntriesTable.v13"
        )
        let columns: [(String, String, CGFloat, CGFloat, CGFloat)] = [
            ("name", L10n.tr("column.name"), 360, 180, .greatestFiniteMagnitude),
            ("size", L10n.tr("column.size"), 140, 96, 280),
            ("modified", L10n.tr("column.modified"), 240, 190, 2000)
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.0))
            column.title = spec.1
            column.width = spec.2
            column.minWidth = spec.3
            column.maxWidth = spec.4
            column.resizingMask = FinderTableBehavior.resizingMask(isFlexibleColumn: spec.0 == "name")
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let contentChanged = context.coordinator.contentRevision != contentRevision || context.coordinator.filter != filter
        if contentChanged, let table = scrollView.documentView as? NSTableView {
            context.coordinator.entries = entries
            context.coordinator.contentRevision = contentRevision
            context.coordinator.filter = filter
            table.reloadData()
        }
    }
}

@MainActor
struct SelectedItemsTable: NSViewRepresentable {
    let items: [SelectedItem]
    let contentRevision: Int
    @Binding var selectedIDs: Set<String>

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var items: [SelectedItem]
        var contentRevision: Int
        var selectedIDs: Binding<Set<String>>
        var appliedSelection: Set<String>
        private var isApplyingSelection = false

        init(items: [SelectedItem], contentRevision: Int, selectedIDs: Binding<Set<String>>) {
            self.items = items
            self.contentRevision = contentRevision
            self.selectedIDs = selectedIDs
            appliedSelection = selectedIDs.wrappedValue
        }

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
            let selection = Set(ids)
            appliedSelection = selection
            if selectedIDs.wrappedValue != selection {
                selectedIDs.wrappedValue = selection
            }
        }

        func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
            FinderTableBehavior.shouldReorderColumn(
                in: tableView,
                columnIndex: columnIndex,
                newColumnIndex: newColumnIndex,
                lockedIdentifier: "selectedName"
            )
        }

        func tableView(_ tableView: NSTableView, shouldSelect tableColumn: NSTableColumn?) -> Bool { false }

        func applySelection(to tableView: NSTableView) {
            isApplyingSelection = true
            defer { isApplyingSelection = false }
            let indexes = IndexSet(items.enumerated().compactMap { index, item in
                selectedIDs.wrappedValue.contains(item.id) ? index : nil
            })
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            appliedSelection = selectedIDs.wrappedValue
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

            imageView.image = NSImage(
                systemSymbolName: item.isDirectory ? "folder" : "doc",
                accessibilityDescription: L10n.tr(item.isDirectory ? "item.type.folder" : "item.type.file")
            )
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
        Coordinator(items: items, contentRevision: contentRevision, selectedIDs: $selectedIDs)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        FinderTableBehavior.configure(
            table,
            allowsMultipleSelection: true,
            autosaveName: "local.codex.cleanzip.selectedItemsTable.v13"
        )

        let columns: [(String, String, CGFloat, CGFloat, CGFloat)] = [
            ("selectedName", L10n.tr("column.name"), 230, 180, .greatestFiniteMagnitude),
            ("selectedType", L10n.tr("column.type"), 80, 70, 160),
            ("selectedSize", L10n.tr("column.size"), 100, 90, 220),
            ("selectedLocation", L10n.tr("column.location"), 330, 220, 2000)
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.0))
            column.title = spec.1
            column.width = spec.2
            column.minWidth = spec.3
            column.maxWidth = spec.4
            column.resizingMask = FinderTableBehavior.resizingMask(isFlexibleColumn: spec.0 == "selectedName")
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = table
        context.coordinator.applySelection(to: table)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let contentChanged = context.coordinator.contentRevision != contentRevision
        let selectionChanged = context.coordinator.appliedSelection != selectedIDs
        context.coordinator.selectedIDs = $selectedIDs
        if let table = scrollView.documentView as? NSTableView {
            if contentChanged {
                context.coordinator.items = items
                context.coordinator.contentRevision = contentRevision
                table.reloadData()
            }
            if contentChanged || selectionChanged {
                context.coordinator.applySelection(to: table)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropIsTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                mainContent
                    .id(contentIdentity)
                    .transition(contentTransition)
            }
            .overlay(alignment: .center) {
                if dropIsTargeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.55), lineWidth: 2)
                        .padding(10)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(SystemContentBackground().ignoresSafeArea())
        .animation(contentAnimation, value: contentIdentity)
        .animation(dropAnimation, value: dropIsTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            state.handle(urls: urls)
            return true
        } isTargeted: { isTargeted in
            dropIsTargeted = isTargeted
        }
        .sheet(isPresented: $state.showingCompressSheet) { CompressSheet().environmentObject(state) }
        .sheet(item: $state.passwordPrompt) { prompt in
            PasswordSheet(prompt: prompt).environmentObject(state)
        }
    }

    private var contentIdentity: String {
        if state.archiveURL != nil { return "archive" }
        if !state.selectedURLs.isEmpty { return "selectedItems" }
        return "empty"
    }

    private var contentAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.16)
    }

    private var dropAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.18, extraBounce: 0)
    }

    private var contentTransition: AnyTransition {
        .opacity
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
                HStack(spacing: 12) {
                    Button { state.openArchivePanel() } label: {
                        Label(L10n.tr("button.chooseArchive"), systemImage: "doc.zipper")
                    }
                    Button { state.openItemsPanel() } label: {
                        Label(L10n.tr("button.chooseItems"), systemImage: "folder.badge.plus")
                    }
                }
                .controlSize(.large)
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
            ArchiveEntriesTable(
                entries: state.filteredEntries,
                contentRevision: state.entriesRevision,
                filter: state.searchText
            )
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
            SelectedItemsTable(
                items: state.selectedItems,
                contentRevision: state.selectedItemsRevision,
                selectedIDs: $state.selectedItemIDs
            )
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
                if let fraction = progress.fraction {
                    ProgressView(value: fraction, total: 1)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                        .accessibilityLabel(progress.title)
                        .accessibilityValue(progress.percentText)
                    Text(progress.percentText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                        .contentTransition(.numericText())
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(progress.title)
                }
                Button { state.cancelCurrentOperation() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("button.cancelOperation"))
                .accessibilityLabel(L10n.tr("button.cancelOperation"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.bar)
    }

}

struct PasswordSheet: View {
    @EnvironmentObject private var state: AppState
    let prompt: PasswordPrompt
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("password.title"))
                .font(.title2.weight(.semibold))
            Text(L10n.tr(prompt.isRetry ? "password.incorrect" : "password.message", prompt.archiveName))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(L10n.tr("password.placeholder"), text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($passwordFocused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button(L10n.tr("button.cancel")) { state.cancelPasswordPrompt() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.tr("password.unlock"), action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .interactiveDismissDisabled()
        .onAppear { passwordFocused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        state.submitPassword(password)
    }
}

struct CompressSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            TextField(L10n.tr("settings.sizePlaceholder"), text: $state.customSplitMB)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Text("MB").foregroundStyle(.secondary)
                        }
                        if !state.isSplitConfigurationValid {
                            Text(L10n.tr("settings.invalidSplitSize"))
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
            .formStyle(.grouped)
            .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: state.splitPreset.id)
            Text(L10n.tr("settings.cleanMetadataNote")).foregroundStyle(.secondary).font(.footnote)
            HStack {
                Spacer()
                Button(L10n.tr("button.cancel")) { dismiss() }
                Button { state.compressSelected() } label: { Label(L10n.tr("button.startCompress"), systemImage: "archivebox") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.isSplitConfigurationValid || state.isBusy)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, UNUserNotificationCenterDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    private var window: NSWindow?
    private var serviceInvoked = false
    private var openedFromFile = false
    private var openedFromUntitledLaunch = false
    private var stateObserver: AnyCancellable?
    private var searchExpanded = false
    private let serviceProgressHUD = ServiceProgressHUD()
    private var serviceCancellation: OperationCancellation?
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        configureMainMenu()
    }

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

    func configureMainMenu() {
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "CleanZip"
        let mainMenu = NSMenu(title: appName)

        let appMenu = NSMenu(title: appName)
        appMenu.addItem(menuItem(
            title: L10n.tr("menu.about", appName),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            target: NSApp
        ))
        appMenu.addItem(.separator())
        let servicesMenu = NSMenu(title: L10n.tr("menu.services"))
        let servicesItem = menuItem(title: L10n.tr("menu.services"), action: nil)
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem(
            title: L10n.tr("menu.hide", appName),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h",
            target: NSApp
        ))
        appMenu.addItem(menuItem(
            title: L10n.tr("menu.hideOthers"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h",
            modifiers: [.command, .option],
            target: NSApp
        ))
        appMenu.addItem(menuItem(
            title: L10n.tr("menu.showAll"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            target: NSApp
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem(
            title: L10n.tr("menu.quit", appName),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q",
            target: NSApp
        ))
        mainMenu.addItem(topLevelItem(title: appName, submenu: appMenu))

        let fileMenu = NSMenu(title: L10n.tr("menu.file"))
        fileMenu.addItem(menuItem(
            title: L10n.tr("toolbar.chooseArchive") + "\u{2026}",
            action: #selector(openArchiveFromToolbar(_:)),
            keyEquivalent: "o",
            target: self
        ))
        fileMenu.addItem(menuItem(
            title: L10n.tr("toolbar.chooseItems") + "\u{2026}",
            action: #selector(openItemsFromToolbar(_:)),
            keyEquivalent: "o",
            modifiers: [.command, .shift],
            target: self
        ))
        fileMenu.addItem(menuItem(
            title: L10n.tr("toolbar.add") + "\u{2026}",
            action: #selector(addItemsFromToolbar(_:)),
            keyEquivalent: "o",
            modifiers: [.command, .option],
            target: self
        ))
        fileMenu.addItem(.separator())
        fileMenu.addItem(menuItem(title: L10n.tr("toolbar.test"), action: #selector(testArchiveFromToolbar(_:)), target: self))
        fileMenu.addItem(menuItem(title: L10n.tr("toolbar.extract"), action: #selector(extractArchiveFromToolbar(_:)), target: self))
        fileMenu.addItem(menuItem(title: L10n.tr("toolbar.compressSettings") + "\u{2026}", action: #selector(compressSettingsFromToolbar(_:)), target: self))
        fileMenu.addItem(.separator())
        fileMenu.addItem(menuItem(
            title: L10n.tr("menu.close"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        mainMenu.addItem(topLevelItem(title: L10n.tr("menu.file"), submenu: fileMenu))

        let editMenu = NSMenu(title: L10n.tr("menu.edit"))
        editMenu.addItem(menuItem(title: L10n.tr("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(menuItem(title: L10n.tr("menu.redo"), action: Selector(("redo:")), keyEquivalent: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem(title: L10n.tr("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(menuItem(title: L10n.tr("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(menuItem(title: L10n.tr("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem(
            title: L10n.tr("toolbar.remove"),
            action: #selector(removeItemsFromToolbar(_:)),
            keyEquivalent: "\u{8}",
            modifiers: [],
            target: self
        ))
        editMenu.addItem(menuItem(title: L10n.tr("toolbar.clear"), action: #selector(clearItemsFromToolbar(_:)), target: self))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem(title: L10n.tr("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        mainMenu.addItem(topLevelItem(title: L10n.tr("menu.edit"), submenu: editMenu))

        let viewMenu = NSMenu(title: L10n.tr("menu.view"))
        viewMenu.addItem(menuItem(
            title: L10n.tr("toolbar.search"),
            action: #selector(beginSearchFromToolbar(_:)),
            keyEquivalent: "f",
            target: self
        ))
        viewMenu.addItem(.separator())
        viewMenu.addItem(menuItem(
            title: L10n.tr("menu.enterFullScreen"),
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f",
            modifiers: [.command, .control]
        ))
        mainMenu.addItem(topLevelItem(title: L10n.tr("menu.view"), submenu: viewMenu))

        let windowMenu = NSMenu(title: L10n.tr("menu.window"))
        windowMenu.addItem(menuItem(
            title: L10n.tr("menu.minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        windowMenu.addItem(menuItem(title: L10n.tr("menu.zoom"), action: #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(menuItem(title: L10n.tr("menu.bringAllToFront"), action: #selector(NSApplication.arrangeInFront(_:))))
        mainMenu.addItem(topLevelItem(title: L10n.tr("menu.window"), submenu: windowMenu))
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: L10n.tr("menu.help"))
        helpMenu.addItem(menuItem(title: L10n.tr("menu.helpItem", appName), action: #selector(showHelp(_:)), target: self))
        mainMenu.addItem(topLevelItem(title: L10n.tr("menu.help"), submenu: helpMenu))

        NSApp.mainMenu = mainMenu
    }

    private func topLevelItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func menuItem(
        title: String,
        action: Selector?,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        if !keyEquivalent.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
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
        AppState.prepareNotificationsForOperation()
        let cancellation = OperationCancellation()
        serviceCancellation = cancellation
        serviceProgressHUD.begin(title: operationTitle, detail: operationDetail) { cancellation.cancel() }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if shouldExtract {
                    var outputs: [URL] = []
                    for (index, url) in urls.enumerated() {
                        let base = Double(index) / Double(urls.count)
                        let scale = 1 / Double(urls.count)
                        do {
                            outputs.append(try ArchiveEngine.shared.extract(archive: url, cancellation: cancellation) { fraction in
                                DispatchQueue.main.async {
                                    self.serviceProgressHUD.update(fraction: base + fraction * scale, detail: url.lastPathComponent)
                                }
                            })
                        } catch let archiveError as ArchiveError {
                            switch archiveError {
                            case .passwordRequired, .wrongPassword:
                                throw ServiceHandoffError.passwordRequired(url)
                            default:
                                throw archiveError
                            }
                        }
                    }
                    DispatchQueue.main.async {
                        self.serviceCancellation = nil
                        self.serviceProgressHUD.finish()
                        let message = outputs.count == 1 ? L10n.tr("notification.extractedTo", outputs[0].lastPathComponent) : L10n.tr("notification.extractedArchives", L10n.archiveCount(outputs.count))
                        AppState.notify(title: "CleanZip", message: message) { self.terminateIfServiceOnly() }
                    }
                } else {
                    let output = try ArchiveEngine.shared.compress(urls: urls, format: .zip, splitSpec: nil, cancellation: cancellation) { fraction in
                        DispatchQueue.main.async {
                            self.serviceProgressHUD.update(fraction: fraction)
                        }
                    }
                    DispatchQueue.main.async {
                        self.serviceCancellation = nil
                        self.serviceProgressHUD.finish()
                        let message = L10n.tr("notification.created", output.lastPathComponent)
                        AppState.notify(title: "CleanZip", message: message) { self.terminateIfServiceOnly() }
                    }
                }
            } catch ServiceHandoffError.passwordRequired(let url) {
                DispatchQueue.main.async {
                    self.serviceCancellation = nil
                    self.serviceProgressHUD.finish()
                    self.showWindow()
                    AppState.shared.handle(urls: [url])
                }
            } catch ArchiveError.cancelled {
                DispatchQueue.main.async {
                    self.serviceCancellation = nil
                    self.serviceProgressHUD.finish()
                    AppState.notify(title: "CleanZip", message: L10n.tr("status.cancelled")) { self.terminateIfServiceOnly() }
                }
            } catch {
                DispatchQueue.main.async {
                    self.serviceCancellation = nil
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
            compressSettingsItemID,
            .space
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
        identifiers.append(.space)
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
    @objc private func showHelp(_ sender: Any?) {
        guard let url = URL(string: "https://lyc280705.github.io/CleanZip/") else { return }
        NSWorkspace.shared.open(url)
    }
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        let state = AppState.shared
        switch action {
        case #selector(openArchiveFromToolbar(_:)), #selector(openItemsFromToolbar(_:)):
            return !state.isBusy
        case #selector(addItemsFromToolbar(_:)), #selector(clearItemsFromToolbar(_:)), #selector(compressSettingsFromToolbar(_:)):
            return !state.selectedURLs.isEmpty && !state.isBusy
        case #selector(removeItemsFromToolbar(_:)):
            return !state.selectedItemIDs.isEmpty && !state.isBusy
        case #selector(testArchiveFromToolbar(_:)), #selector(extractArchiveFromToolbar(_:)), #selector(beginSearchFromToolbar(_:)):
            return state.archiveURL != nil && !state.isBusy
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
    }
    private func pasteboardURLs(_ pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { return urls }
        if let filenames = pasteboard.propertyList(forType: .fileURL) as? [String] { return filenames.map { URL(fileURLWithPath: $0) } }
        if let filenames = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] { return filenames.map { URL(fileURLWithPath: $0) } }
        return []
    }
}

#if !CLEANZIP_TESTING
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
#endif
