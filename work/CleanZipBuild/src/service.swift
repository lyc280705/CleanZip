@preconcurrency import AppKit
@preconcurrency import QuartzCore
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

enum ServiceHandoffError: Error, Sendable {
    case passwordRequired(URL)
}

final class ArchiveEngine: @unchecked Sendable {
    static let shared = ArchiveEngine()
    private static let progressRegex = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,3})%"#)
    typealias ProgressHandler = @Sendable (Double) -> Void
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

    func compress(urls: [URL], cancellation: OperationCancellation? = nil, progressHandler: ProgressHandler? = nil) throws -> URL {
        guard !urls.isEmpty else { throw ArchiveError.failed(L10n.tr("error.noItemsToCompress")) }
        let parent = urls[0].deletingLastPathComponent()
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL }) else {
            throw ArchiveError.failed(L10n.tr("error.sameParentRequired"))
        }
        let baseName = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let output = uniqueFileURL(in: parent, baseName: baseName, extensionName: "zip")
        let itemNames = urls.map { itemNameForProcess($0) }
        do {
            try compressWith7z(parent: parent, output: output, itemNames: itemNames, cancellation: cancellation, progressHandler: progressHandler)
            return output
        } catch {
            removePartialArchive(at: output)
            throw error
        }
    }

    func extract(archive: URL, cancellation: OperationCancellation? = nil, progressHandler: ProgressHandler? = nil) throws -> URL {
        let parent = archive.deletingLastPathComponent()
        let baseName = archiveBaseName(archive)
        let outputDir = uniqueDirectoryURL(in: parent, baseName: baseName)
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        do {
            return try extractWith7z(archive: archive, outputDir: outputDir, cancellation: cancellation, progressHandler: progressHandler)
        } catch {
            try? fileManager.removeItem(at: outputDir)
            throw error
        }
    }

    private func compressWith7z(parent: URL, output: URL, itemNames: [String], cancellation: OperationCancellation?, progressHandler: ProgressHandler?) throws {
        guard let sevenZipURL else { throw ArchiveError.missingTool("7zz") }
        var args = ["a", "-tzip", "-mx=5", "-y", "-bsp1", output.path]
        args.append(contentsOf: itemNames)
        args.append(contentsOf: ["-xr!.DS_Store", "-xr!__MACOSX", "-xr!._*"])
        var env = ProcessInfo.processInfo.environment
        env["COPYFILE_DISABLE"] = "1"
        let result = try runProcess(executable: sevenZipURL, arguments: args, currentDirectory: parent, environment: env, cancellation: cancellation, progressHandler: progressHandler)
        guard result.status == 0 else { throw archiveError(for: result) }
    }

    private func extractWith7z(archive: URL, outputDir: URL, cancellation: OperationCancellation?, progressHandler: ProgressHandler?) throws -> URL {
        guard let sevenZipURL else { throw ArchiveError.missingTool("7zz") }
        let result = try runProcess(executable: sevenZipURL, arguments: ["x", "-y", "-bsp1", "-o\(outputDir.path)", archive.path], cancellation: cancellation, progressHandler: progressHandler)
        guard result.status == 0 else { throw archiveError(for: result) }
        return outputDir
    }

    private func runProcess(executable: URL, arguments: [String], currentDirectory: URL? = nil, environment: [String: String]? = nil, cancellation: OperationCancellation? = nil, progressHandler: ProgressHandler? = nil) throws -> ProcessResult {
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
        process.standardInput = FileHandle.nullDevice
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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 116), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 72))
    }

    private var percentText: String { "\(Int((fraction * 100).rounded()))%" }

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
final class ServiceDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let hud = ServiceProgressHUD()
    private var cancellation: OperationCancellation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    @objc(cleanZip:userData:error:)
    func cleanZip(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboardURLs(pasteboard)
        guard !urls.isEmpty else {
            error.pointee = L10n.tr("error.noFinderItems") as NSString
            NSApp.terminate(nil)
            return
        }

        let shouldExtract = urls.allSatisfy { ArchiveEngine.shared.isArchive($0) }
        let title = shouldExtract ? L10n.tr("operation.extracting") : L10n.tr("operation.compressing")
        let detail = urls.count == 1 ? urls[0].lastPathComponent : (shouldExtract ? L10n.archiveCount(urls.count) : L10n.itemCount(urls.count))
        prepareNotificationsForOperation()
        let cancellation = OperationCancellation()
        self.cancellation = cancellation
        hud.begin(title: title, detail: detail) { cancellation.cancel() }

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
                                    self.hud.update(fraction: base + fraction * scale, detail: url.lastPathComponent)
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
                    let message = outputs.count == 1 ? L10n.tr("notification.extractedTo", outputs[0].lastPathComponent) : L10n.tr("notification.extractedArchives", L10n.archiveCount(outputs.count))
                    DispatchQueue.main.async { self.finish(message: message) }
                } else {
                    let output = try ArchiveEngine.shared.compress(urls: urls, cancellation: cancellation) { fraction in
                        DispatchQueue.main.async { self.hud.update(fraction: fraction) }
                    }
                    DispatchQueue.main.async { self.finish(message: L10n.tr("notification.created", output.lastPathComponent)) }
                }
            } catch ServiceHandoffError.passwordRequired(let url) {
                DispatchQueue.main.async { self.handoffPasswordArchive(url) }
            } catch ArchiveError.cancelled {
                DispatchQueue.main.async { self.finish(message: L10n.tr("status.cancelled")) }
            } catch {
                DispatchQueue.main.async { self.finish(title: L10n.tr("notification.operationFailedTitle"), message: error.localizedDescription) }
            }
        }
    }

    private func finish(title: String = "CleanZip", message: String) {
        cancellation = nil
        hud.finish()
        notify(title: title, message: message) {
            NSApp.terminate(nil)
        }
    }

    private func handoffPasswordArchive(_ url: URL) {
        cancellation = nil
        hud.finish()
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.codex.cleanzip") else {
            finish(title: L10n.tr("notification.operationFailedTitle"), message: L10n.tr("error.mainAppUnavailable"))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, launchError in
            DispatchQueue.main.async {
                if let launchError {
                    self.finish(title: L10n.tr("notification.operationFailedTitle"), message: launchError.localizedDescription)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func notify(title: String, message: String, completion: @escaping @MainActor @Sendable () -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let deliver: @Sendable () -> Void = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = message
                content.sound = .default
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                center.add(request) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completion() }
                }
            }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                deliver()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    granted ? deliver() : DispatchQueue.main.async { completion() }
                }
            case .denied:
                DispatchQueue.main.async { completion() }
            @unknown default:
                DispatchQueue.main.async { completion() }
            }
        }
    }

    private func prepareNotificationsForOperation() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
