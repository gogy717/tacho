import Foundation

/// What `discover` throws when part of a source could not be walked: what was found still counts, and the failure must still show.
struct PartlyWalked: Error {
    var found: [URL]
    var cause: any Error
}

/// How a reader walks the tree it owns, so that a source it cannot walk does not pass for an empty one.
enum SourceWalk {
    /// The first error an enumerator reports. The handler outlives the call that creates it, so this is a class.
    fileprivate final class WalkFailure: @unchecked Sendable {
        var error: (any Error)?
    }
    /// All that `trees` find. One that fails costs the others nothing: this throws at the end, with what they found.
    /// A tree that already walked part of the way keeps what it found. Dropping that list would hide the files beside the failure.
    static func gathering(_ trees: [() throws -> [URL]]) throws -> [URL] {
        var found: [URL] = []
        var failure: (any Error)?
        for tree in trees {
            do {
                found += try tree()
            } catch let partly as PartlyWalked {
                found += partly.found
                if failure == nil { failure = partly.cause }
            } catch {
                if failure == nil { failure = error }
            }
        }
        if let failure { throw PartlyWalked(found: found, cause: failure) }
        return found
    }

    /// `body`'s files that `include` accepts. A partial walk is filtered the same way, so a failure still carries only real logs.
    static func selecting(_ body: () throws -> [URL], where include: (URL) -> Bool) throws -> [URL] {
        do {
            return try body().filter(include)
        } catch let partly as PartlyWalked {
            throw PartlyWalked(found: partly.found.filter(include), cause: partly.cause)
        }
    }

    /// Every file under `directory`, at any depth. Nothing when `directory` is not there, which only means the CLI is not in use.
    /// Throws when it is there and cannot be listed, and when a directory inside it cannot: the files beside that one are in the error.
    static func files(under directory: URL) throws -> [URL] {
        guard let top = try listable(directory) else { return [] }
        // The enumerator otherwise skips a directory it cannot enter and reports no error, so the sessions in it vanish.
        let failure = WalkFailure()
        guard let walker = FileManager.default.enumerator(
            at: top,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                if failure.error == nil { failure.error = error }
                return true
            }
        ) else { return [] }
        let found = walker.compactMap { $0 as? URL }
        if let error = failure.error { throw PartlyWalked(found: found, cause: error) }
        return found
    }

    /// What is directly in `directory`, on the same terms.
    static func children(of directory: URL) throws -> [URL] {
        guard let top = try listable(directory) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: top, includingPropertiesForKeys: nil)
    }

    /// `directory` as it can be walked; nil when it is not there. Only a link needs resolving: the enumerator walks nothing from one,
    /// and gives no error for a directory it may not open, so that is tried here. `lstat` tells a directory that is missing from one
    /// behind a parent that may not be entered, which `fileExists` does not.
    private static func listable(_ directory: URL) throws -> URL? {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var top = directory
        if info.st_mode & S_IFMT == S_IFLNK {
            guard let resolved = realpath(directory.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { free(resolved) }
            top = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
        _ = try FileManager.default.contentsOfDirectory(at: top, includingPropertiesForKeys: nil)
        return top
    }
}
