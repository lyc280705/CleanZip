import AppKit
@preconcurrency import UserNotifications

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
        case .missingTool(let tool): return "找不到工具：\(tool)"
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

    func compress(urls: [URL], progressHandler: ProgressHandler? = nil) throws -> URL {
        guard !urls.isEmpty else { throw ArchiveError.failed("没有选择要压缩的项目。") }
        let parent = urls[0].deletingLastPathComponent()
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL }) else {
            throw ArchiveError.failed("请一次只压缩同一个文件夹里的项目。")
        }
        let baseName = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let output = uniqueFileURL(in: parent, baseName: baseName, extensionName: "zip")
        let itemNames = urls.map { itemNameForProcess($0) }
        try compressWith7z(parent: parent, output: output, itemNames: itemNames, progressHandler: progressHandler)
        return output
    }

    func extract(archive: URL, progressHandler: ProgressHandler? = nil) throws -> URL {
        let parent = archive.deletingLastPathComponent()
        let baseName = archiveBaseName(archive)
        let outputDir = uniqueDirectoryURL(in: parent, baseName: baseName)
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        return try extractWith7z(archive: archive, outputDir: outputDir, progressHandler: progressHandler)
    }

    private func compressWith7z(parent: URL, output: URL, itemNames: [String], progressHandler: ProgressHandler?) throws {
        guard let sevenZipURL else { throw ArchiveError.missingTool("7zz") }
        var args = ["a", "-tzip", "-mx=5", "-y", "-bsp1", output.path]
        args.append(contentsOf: itemNames)
        args.append(contentsOf: ["-xr!.DS_Store", "-xr!__MACOSX", "-xr!._*"])
        var env = ProcessInfo.processInfo.environment
        env["COPYFILE_DISABLE"] = "1"
        let result = try runProcess(executable: sevenZipURL, arguments: args, currentDirectory: parent, environment: env, progressHandler: progressHandler)
        guard result.status == 0 else { throw ArchiveError.failed(result.stderr.isEmpty ? result.stdout : result.stderr) }
    }

    private func extractWith7z(archive: URL, outputDir: URL, progressHandler: ProgressHandler?) throws -> URL {
        guard let sevenZipURL else { throw ArchiveError.missingTool("7zz") }
        let result = try runProcess(executable: sevenZipURL, arguments: ["x", "-y", "-bsp1", "-o\(outputDir.path)", archive.path], progressHandler: progressHandler)
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

    private func uniqueFileURL(in directory: URL, baseName: String, extensionName: String) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(extensionName)")
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(index).\(extensionName)")
            index += 1
        }
        return candidate
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

final class ServiceProgressHUD {
    private var panel: NSPanel?
    private var titleField: NSTextField?
    private var detailField: NSTextField?
    private var percentField: NSTextField?
    private var progressIndicator: NSProgressIndicator?
    private var scheduledShow: DispatchWorkItem?
    private var title = "正在处理"
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
        let workItem = DispatchWorkItem { [weak self] in self?.showIfNeeded() }
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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 116), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "CleanZip 进度"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let glassView = NSGlassEffectView()
        glassView.style = .regular
        glassView.cornerRadius = 24
        glassView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView = contentView

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail

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
        panel.contentView = glassView

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
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 72))
    }

    private var percentText: String { "\(Int((fraction * 100).rounded()))%" }

    private func updateVisibleControls() {
        titleField?.stringValue = title
        detailField?.stringValue = detail
        progressIndicator?.doubleValue = fraction
        percentField?.stringValue = percentText
    }
}

@MainActor
final class ServiceDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let hud = ServiceProgressHUD()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    @objc(cleanZip:userData:error:)
    func cleanZip(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboardURLs(pasteboard)
        guard !urls.isEmpty else {
            error.pointee = "没有收到 Finder 选中的文件或文件夹。" as NSString
            NSApp.terminate(nil)
            return
        }

        let shouldExtract = urls.allSatisfy { ArchiveEngine.shared.isArchive($0) }
        let title = shouldExtract ? "正在解压" : "正在压缩"
        let detail = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个项目"
        hud.begin(title: title, detail: detail)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if shouldExtract {
                    var outputs: [URL] = []
                    for (index, url) in urls.enumerated() {
                        let base = Double(index) / Double(urls.count)
                        let scale = 1 / Double(urls.count)
                        outputs.append(try ArchiveEngine.shared.extract(archive: url) { fraction in
                            DispatchQueue.main.async {
                                self.hud.update(fraction: base + fraction * scale, detail: url.lastPathComponent)
                            }
                        })
                    }
                    let message = outputs.count == 1 ? "已解压到：\(outputs[0].lastPathComponent)" : "已解压 \(outputs.count) 个压缩包"
                    DispatchQueue.main.async { self.finish(message: message) }
                } else {
                    let output = try ArchiveEngine.shared.compress(urls: urls) { fraction in
                        DispatchQueue.main.async { self.hud.update(fraction: fraction) }
                    }
                    DispatchQueue.main.async { self.finish(message: "已生成：\(output.lastPathComponent)") }
                }
            } catch {
                DispatchQueue.main.async { self.finish(title: "CleanZip 操作失败", message: error.localizedDescription) }
            }
        }
    }

    private func finish(title: String = "CleanZip", message: String) {
        hud.finish()
        notify(title: title, message: message) {
            NSApp.terminate(nil)
        }
    }

    private func notify(title: String, message: String, completion: @escaping () -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: completion)
        }
    }

    private func pasteboardURLs(_ pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls
        }
        if let filenames = pasteboard.propertyList(forType: .fileURL) as? [String] {
            return filenames.map { URL(fileURLWithPath: $0) }
        }
        if let filenames = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return filenames.map { URL(fileURLWithPath: $0) }
        }
        return []
    }
}

@main
@MainActor
struct CleanZipServiceMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = ServiceDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
