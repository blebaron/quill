import Darwin
import Foundation

/// Stage the complete output before publishing it. Each rename is atomic;
/// if a later rename fails, restore the earlier files from their backups.
/// A process crash between renames is not a multi-file atomic transaction.
enum GeneratedArtifacts {
    static func publish(
        in dir: URL, transcriptJSON: Data, transcriptMarkdown: Data, speakersJSON: Data?,
        promote: (URL, URL) throws -> Void = atomicRename
    ) throws {
        let fm = FileManager.default
        let staging = dir.appendingPathComponent(".quill-artifacts-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let artifacts: [(name: String, data: Data?)] = [
            ("transcript.json", transcriptJSON),
            ("transcript.md", transcriptMarkdown),
            ("speakers.json", speakersJSON),
        ]
        for artifact in artifacts {
            let destination = dir.appendingPathComponent(artifact.name)
            if fm.fileExists(atPath: destination.path) {
                let attributes = try fm.attributesOfItem(atPath: destination.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw NSError(domain: "quill.artifacts", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "refusing to replace non-file artifact at \(destination.path)"
                    ])
                }
                try fm.copyItem(at: destination, to: staging.appendingPathComponent("old-\(artifact.name)"))
            }
            if let data = artifact.data {
                try data.write(to: staging.appendingPathComponent(artifact.name))
            }
        }

        var promoted: [String] = []
        do {
            for artifact in artifacts {
                let destination = dir.appendingPathComponent(artifact.name)
                if artifact.data != nil {
                    try promote(staging.appendingPathComponent(artifact.name), destination)
                } else if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                promoted.append(artifact.name)
            }
        } catch {
            let publishError = error
            do {
                for name in promoted.reversed() {
                    let destination = dir.appendingPathComponent(name)
                    let backup = staging.appendingPathComponent("old-\(name)")
                    if fm.fileExists(atPath: backup.path) {
                        try atomicRename(backup, to: destination)
                    } else if fm.fileExists(atPath: destination.path) {
                        try fm.removeItem(at: destination)
                    }
                }
            } catch {
                throw NSError(domain: "quill.artifacts", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "publishing failed (\(publishError)); rollback failed (\(error))"
                ])
            }
            throw publishError
        }
    }

    static func atomicRename(_ source: URL, to destination: URL) throws {
        if Darwin.rename(source.path, destination.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSFilePathErrorKey: destination.path
            ])
        }
    }
}
