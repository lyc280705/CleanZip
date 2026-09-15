import AppKit
import CoreServices

@MainActor
enum ArchiveSafetyTests {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() async -> [String] {
        let cases: [(String, (URL) throws -> Void)] = [
            ("literal filenames", literalFilenames),
            ("cancelled and failed compression", preserveExistingVolumes),
            ("in-flight cancellation", inFlightCancellation),
            ("publication conflicts", publicationConflicts),
            ("partial publication rollback", publicationRollback),
            ("compressed TAR extraction", compressedTar),
            ("quarantine propagation", quarantine),
            ("symlink quarantine isolation", quarantineSymlink),
            ("directory classification", directoryClassification),
            ("file URL pasteboard", filePasteboard),
            ("failed extraction cleanup", failedExtraction)
        ]
        var failures: [String] = []
        for (name, test) in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanzip-safety-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try test(root)
                try expectNoWorkspace(root)
                print("PASS: \(name)")
            } catch { failures.append("\(name): \(error)") }
        }
#if !CLEANZIP_SERVICE_TESTING
        do { try await previewReplacement() }
        catch { failures.append("preview replacement: \(error)") }
#endif
        return failures
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    private static func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url)
    }

    private static func compress(_ urls: [URL], cancellation: OperationCancellation? = nil) throws -> URL {
#if CLEANZIP_SERVICE_TESTING
        try ArchiveEngine.shared.compress(urls: urls, cancellation: cancellation)
#else
        try ArchiveEngine.shared.compress(urls: urls, format: .zip, splitSpec: nil, cancellation: cancellation)
#endif
    }

    private static func literalFilenames(_ root: URL) throws {
        let names = ["file*.txt", "question?.txt", "@manifest", "-option.txt"]
        try write("private", to: root.appendingPathComponent("private.txt"))
        try write("neighbor", to: root.appendingPathComponent("file-neighbor.txt"))
        try write("neighbor", to: root.appendingPathComponent("question1.txt"))
        for name in names {
            let source = root.appendingPathComponent(name)
            try write("private.txt", to: source)
            let archive = try compress([source])
            let output = try ArchiveEngine.shared.extract(archive: archive)
            let contents = try FileManager.default.contentsOfDirectory(atPath: output.path)
            try expect(contents == [name], "Expected only literal \(name), got \(contents)")
        }
        let folder = root.appendingPathComponent("metadata")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested/__MACOSX"), withIntermediateDirectories: true)
        for name in [".DS_Store", "._file", "keep.txt", "nested/._file", "nested/__MACOSX/file"] {
            try write("payload", to: folder.appendingPathComponent(name))
        }
        let archive = try compress([folder])
        let output = try ArchiveEngine.shared.extract(archive: archive).appendingPathComponent("metadata")
        try expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("keep.txt").path), "Missing ordinary file")
        for name in [".DS_Store", "._file", "nested/._file", "nested/__MACOSX"] {
            try expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent(name).path), "Metadata exclusion failed: \(name)")
        }
    }

    private static func preserveExistingVolumes(_ root: URL) throws {
        let source = root.appendingPathComponent("report.txt")
        try write("source", to: source)
        let volumes = ["report.zip.001", "report.zip.002"]
        for name in volumes { try write(name, to: root.appendingPathComponent(name)) }
        let cancellation = OperationCancellation()
        cancellation.cancel()
        do {
            _ = try compress([source], cancellation: cancellation)
            throw Failure(description: "Cancelled operation succeeded")
        } catch ArchiveError.cancelled { }
        // 7-Zip writes a partial archive but returns a warning for the missing selected item.
        do {
            _ = try compress([source, root.appendingPathComponent("missing.txt")])
            throw Failure(description: "Missing input unexpectedly succeeded")
        } catch is ArchiveError { }
        for name in volumes {
            try expect(String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) == name, "Existing volume changed: \(name)")
        }
        try expect(Set(FileManager.default.contentsOfDirectory(atPath: root.path)) == Set(volumes + ["report.txt"]), "Failed operation left output")
    }

    private static func publicationConflicts(_ root: URL) throws {
        let source = root.appendingPathComponent("report.txt")
        try write("payload", to: source)
        try write("existing volume", to: root.appendingPathComponent("report.zip.001"))
        let link = root.appendingPathComponent("report (2).zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("nonexistent"))
        let output = try compress([source])
        try expect(output.lastPathComponent == "report (3).zip", "Output should skip existing volumes and dangling links")
        try expect(FileManager.default.destinationOfSymbolicLink(atPath: link.path).hasSuffix("nonexistent"), "Existing symlink was replaced")
        try expect(String(contentsOf: root.appendingPathComponent("report.zip.001"), encoding: .utf8) == "existing volume", "Existing volume was modified")
    }

    private static func inFlightCancellation(_ root: URL) throws {
        let source = root.appendingPathComponent("report.bin")
        try Data(repeating: 65, count: 16 * 1_024 * 1_024).write(to: source)
        let existing = root.appendingPathComponent("report.zip.001")
        try write("keep existing", to: existing)
        let cancellation = OperationCancellation()
        do {
#if CLEANZIP_SERVICE_TESTING
            _ = try ArchiveEngine.shared.compress(urls: [source], cancellation: cancellation) { _ in cancellation.cancel() }
#else
            _ = try ArchiveEngine.shared.compress(urls: [source], format: .zip, splitSpec: "1k", cancellation: cancellation) { _ in cancellation.cancel() }
#endif
            throw Failure(description: "Cancelled in-flight operation published an archive")
        } catch ArchiveError.cancelled { }
        try expect(String(contentsOf: existing, encoding: .utf8) == "keep existing", "In-flight cleanup changed existing volume")
        try expect(Set(FileManager.default.contentsOfDirectory(atPath: root.path)) == ["report.bin", "report.zip.001"], "In-flight cancellation left staged or partial output")
    }

    private static func publicationRollback(_ root: URL) throws {
        let workspace = try ArchiveWorkspace(in: root)
        let output = workspace.directory.appendingPathComponent("report.zip")
        for suffix in ["001", "002"] { try write(suffix, to: URL(fileURLWithPath: output.path + "." + suffix)) }
        var checks = 0
        do {
            _ = try workspace.publishArchive(output, baseName: "report", extensionName: "zip", split: true) {
                checks += 1
                if checks == 3 { throw ArchiveError.cancelled }
            }
            throw Failure(description: "Publication should cancel between volumes")
        } catch ArchiveError.cancelled { }
        for suffix in ["001", "002"] {
            try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("report.zip." + suffix).path), "Published partial volume not rolled back")
            try expect(FileManager.default.fileExists(atPath: output.path + "." + suffix), "Staged volume lost")
        }
        // Inject a destination between the name check and rename to test the exclusive rename.
        var inserted = false
        let published = try workspace.publishArchive(output, baseName: "report", extensionName: "zip", split: true) {
            if !inserted {
                inserted = true
            } else if !FileManager.default.fileExists(atPath: root.appendingPathComponent("report.zip.001").path) {
                try write("racing writer", to: root.appendingPathComponent("report.zip.001"))
            }
        }
        try expect(published.lastPathComponent == "report (2).zip.001", "Name collision must retry without overwriting")
        try expect(String(contentsOf: root.appendingPathComponent("report.zip.001"), encoding: .utf8) == "racing writer", "Racing file was overwritten")
    }

    private static func run7z(_ arguments: [String], at directory: URL) throws {
        guard let tool = ArchiveEngine.shared.sevenZipURL else { throw Failure(description: "7zz unavailable") }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "Fixture creation failed: \(arguments)")
    }

    private static func compressedTar(_ root: URL) throws {
        try write("tar payload", to: root.appendingPathComponent("payload.txt"))
        try run7z(["a", "-ttar", "payload.tar", "payload.txt"], at: root)
        for (suffix, type) in [("tar.gz", "gzip"), ("tgz", "gzip"), ("tar.bz2", "bzip2"), ("tbz2", "bzip2"), ("tar.xz", "xz"), ("txz", "xz")] {
            let archive = root.appendingPathComponent("fixture." + suffix)
            try run7z(["a", "-t" + type, archive.path, "payload.tar"], at: root)
            let output = try ArchiveEngine.shared.extract(archive: archive)
            try expect(String(contentsOf: output.appendingPathComponent("payload.txt"), encoding: .utf8) == "tar payload", "\(suffix) did not extract the TAR contents")
        }
        // A zstd-compressed TAR containing payload.txt; 7-Zip reads but does not write zstd.
        let zstd = Data(base64Encoded: "KLUv/QRYnQIAFANwYXlsb2FkLnR4dAAwMDAwNjQ0MDAwMDAxMwAAMDEwMTMxACAwAHVzdGFyADB0YXIgCwBfJecBEjIUHBAZQYAC4g2pASA5wABaDXCsXKYmkASxaV+w")!
        for suffix in ["tar.zst", "tzst"] {
            let archive = root.appendingPathComponent("fixture." + suffix)
            try zstd.write(to: archive)
            let output = try ArchiveEngine.shared.extract(archive: archive)
            try expect(String(contentsOf: output.appendingPathComponent("payload.txt"), encoding: .utf8) == "tar payload", "\(suffix) did not extract the TAR contents")
        }
    }

    private static func markQuarantine(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "CleanZip Regression Tests",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
            kLSQuarantineDataURLKey as String: URL(string: "https://example.com/download.zip")!
        ]
        try target.setResourceValues(values)
        try expect(isQuarantined(url), "Fixture quarantine was not applied")
    }

    private static func isQuarantined(_ url: URL) throws -> Bool {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil
    }

    private static func quarantine(_ root: URL) throws {
        let source = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try write("executable", to: source.appendingPathComponent("Contents/MacOS/example"))
        try write("hidden", to: source.appendingPathComponent(".hidden"))
        let archive = try compress([source])
        let unmarked = try ArchiveEngine.shared.extract(archive: archive)
        try expect(!isQuarantined(unmarked), "Local archive acquired quarantine unexpectedly")
        try markQuarantine(archive)
        let output = try ArchiveEngine.shared.extract(archive: archive)
        for path in ["", "Example.app", "Example.app/.hidden", "Example.app/Contents/MacOS/example"] {
            try expect(isQuarantined(output.appendingPathComponent(path)), "Quarantine missing: \(path)")
        }
    }

    private static func quarantineSymlink(_ root: URL) throws {
        let archive = root.appendingPathComponent("marked.zip")
        try write("fixture", to: archive)
        try markQuarantine(archive)
        let output = root.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        try write("outside", to: outside)
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("link"), withDestinationURL: outside)
        try ArchiveFileSafety.propagateQuarantine(from: archive, to: output, checkCancellation: {})
        try expect(!isQuarantined(outside), "Quarantine followed a symlink outside extraction root")
        try expect(isQuarantined(output), "Output root quarantine missing")
    }

    private static func directoryClassification(_ root: URL) throws {
        for name in ["folder.zip", "folder.7z", "folder.tar.gz"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try expect(!ArchiveEngine.shared.isArchive(folder), "Directory classified as archive: \(name)")
        }
        let file = root.appendingPathComponent("file.7z")
        try write("fixture", to: file)
        try expect(ArchiveEngine.shared.isArchive(file), "Regular archive file not recognized")
        let link = root.appendingPathComponent("link.7z")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        try expect(ArchiveEngine.shared.isArchive(link), "Valid symlink to archive should remain supported")
        try expect(!ArchiveEngine.shared.isArchive(root.appendingPathComponent("missing.zip")), "Missing file classified as archive")
    }

    private static func filePasteboard(_ root: URL) throws {
        let pasteboard = NSPasteboard(name: .init("cleanzip.tests." + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
#if CLEANZIP_SERVICE_TESTING
        let delegate = ServiceDelegate()
#else
        let delegate = AppDelegate()
#endif
        let files = [root.appendingPathComponent("space and #%.txt"), root.appendingPathComponent("second.zip")]
        pasteboard.writeObjects(files.map { $0 as NSURL })
        try expect(delegate.pasteboardURLs(pasteboard) == files, "File URL pasteboard changed paths")
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(string: "https://example.com/file.zip")! as NSURL])
        try expect(delegate.pasteboardURLs(pasteboard).isEmpty, "Network URL accepted as local file")
    }

    private static func failedExtraction(_ root: URL) throws {
        let archive = root.appendingPathComponent("broken.zip")
        try write("not an archive", to: archive)
        let existing = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try write("keep", to: existing.appendingPathComponent("keep.txt"))
        do {
            _ = try ArchiveEngine.shared.extract(archive: archive)
            throw Failure(description: "Corrupt archive extraction succeeded")
        } catch is ArchiveError { }
        try expect(Set(FileManager.default.contentsOfDirectory(atPath: root.path)) == ["broken.zip", "broken"], "Failed extraction left output")
        try expect(String(contentsOf: existing.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep", "Existing extraction directory changed")
    }

    private static func expectNoWorkspace(_ root: URL) throws {
        try expect(!FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".cleanzip-work-") }, "Private workspace leaked")
    }

#if !CLEANZIP_SERVICE_TESTING
    private static func previewReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanzip-preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        try write("payload", to: source)
        let archive = try compress([source])
        for append in [false, true] {
            let state = AppState()
            state.handle(urls: [archive])
            try expect(state.isBusy, "Preview should start busy")
            if append { state.appendItems([source]) } else { state.handle(urls: [source]) }
            try expect(!state.isBusy && state.archiveURL == nil, "Replacing preview left UI busy")
            let status = state.status
            try await Task.sleep(for: .milliseconds(150))
            try expect(!state.isBusy && state.status == status && state.entries.isEmpty && state.selectedURLs == [source], "Stale preview callback overwrote new selection")
        }
        print("PASS: preview replacement")
    }
#endif
}
