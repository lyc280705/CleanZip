import Foundation
import Darwin

enum ArchiveFileSafety {
    static func isRegularArchiveCandidate(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    static func isCompressedTar(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return [".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz", ".tar.zst", ".tzst"]
            .contains { name.hasSuffix($0) }
    }

    static func propagateQuarantine(from archive: URL, to directory: URL, checkCancellation: () throws -> Void) throws {
        guard let quarantine = try archive.resolvingSymlinksInPath()
            .resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties else { return }
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw CocoaError(.fileReadUnknown) }
        var values = URLResourceValues()
        values.quarantineProperties = quarantine
        for case var item as URL in enumerator {
            try checkCancellation()
            // Never write attributes through an archive-provided symbolic link.
            if try item.resourceValues(forKeys: keys).isSymbolicLink == true { continue }
            try item.setResourceValues(values)
        }
        if let enumerationError { throw enumerationError }
        try checkCancellation()
        var root = directory
        try root.setResourceValues(values)
    }
}

/// Owns only its private workspace, never files found by matching a user-directory prefix.
final class ArchiveWorkspace {
    let directory: URL
    private let parent: URL
    private let fileManager = FileManager.default

    init(in parent: URL) throws {
        self.parent = parent
        directory = parent.appendingPathComponent(".cleanzip-work-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    deinit { try? fileManager.removeItem(at: directory) }

    func makeDirectory(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func publishArchive(_ output: URL, baseName: String, extensionName: String, split: Bool, checkCancellation: () throws -> Void) throws -> URL {
        let files: [URL]
        if split {
            let prefix = output.lastPathComponent + "."
            files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { isVolume($0.lastPathComponent, prefix: prefix) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard files.first?.lastPathComponent == prefix + "001" else { throw CocoaError(.fileNoSuchFile) }
        } else {
            files = [output]
        }
        return try publish(files, baseName: baseName, extensionName: extensionName, sourcePrefix: output.lastPathComponent, checkCancellation: checkCancellation)
    }

    func publishDirectory(_ output: URL, baseName: String, checkCancellation: () throws -> Void) throws -> URL {
        try publish([output], baseName: baseName, extensionName: nil, sourcePrefix: output.lastPathComponent, checkCancellation: checkCancellation)
    }

    private func publish(_ files: [URL], baseName: String, extensionName: String?, sourcePrefix: String, checkCancellation: () throws -> Void) throws -> URL {
        var index = 1
        while true {
            try checkCancellation()
            let stem = index == 1 ? baseName : "\(baseName) (\(index))"
            let name = extensionName.map { stem + "." + $0 } ?? stem
            index += 1
            let siblings = try fileManager.contentsOfDirectory(atPath: parent.path)
            if siblings.contains(name) || (extensionName != nil && siblings.contains(where: { isVolume($0, prefix: name + ".") })) { continue }
            let destinations = files.map { parent.appendingPathComponent(name + $0.lastPathComponent.dropFirst(sourcePrefix.count)) }
            var moved: [(URL, URL)] = []
            do {
                for (source, destination) in zip(files, destinations) {
                    try checkCancellation()
                    try moveExclusively(source, to: destination)
                    moved.append((source, destination))
                }
                return destinations[0]
            } catch {
                // Roll back only the exact files this operation just published.
                for (source, destination) in moved.reversed() {
                    try moveExclusively(destination, to: source)
                }
                let failure = error as NSError
                if failure.domain == NSPOSIXErrorDomain && failure.code == Int(EEXIST) { continue }
                throw error
            }
        }
    }

    private func isVolume(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return suffix.count >= 3 && suffix.utf8.allSatisfy { (48...57).contains($0) }
    }

    private func moveExclusively(_ source: URL, to destination: URL) throws {
        // The workspace is on the destination volume; exclusive rename closes the check/move race.
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
