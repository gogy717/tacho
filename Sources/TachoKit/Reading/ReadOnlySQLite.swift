import Foundation
import GRDB

/// Read-only access to another app's SQLite database (OpenCode's `opencode.db`, oh-my-pi's `agent.db`) that changes no file:
/// not the database, and not the `-wal` and `-shm` files SQLite keeps beside it.
///
/// An ordinary read-only connection would: it creates a missing `-wal` and `-shm`, writes its read marks into `-shm` (or rebuilds
/// it when no other connection has it open), and gives any empty file it opens the database's mode. `open` avoids all of that;
/// `journalIsUsable` says how, and names the one race it leaves.
public enum ReadOnlySQLite {
    /// How long a read of the journal waits on the owning app's lock.
    private static let busyTimeout: TimeInterval = 0.1

    /// A fresh connection to the database at `url`, with its journal when `journalIsUsable`, else to the database file alone.
    /// It closes when the queue is released.
    ///
    /// GRDB does not pass `SQLITE_OPEN_URI`; the URI is parsed because the system SQLite is built with `SQLITE_USE_URI`.
    /// A SQLite without it would look for a file of that name, and fail: the open throws, it never falls back to a plain read.
    public static func open(_ url: URL) throws -> DatabaseQueue {
        // SQLite would change the mode of an empty database too, and an empty file has no tables to read anyway.
        guard let database = FileStatus(url.path), database.size > 0 else {
            throw DatabaseError(resultCode: .SQLITE_CANTOPEN, message: "no database in \(url.path)")
        }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(busyTimeout)
        let parameters = journalIsUsable(url.path, database: database) ? "mode=ro&readonly_shm=1" : "immutable=1"
        return try DatabaseQueue(path: "\(url.absoluteString)?\(parameters)", configuration: configuration)
    }

    /// Whether the `-wal` journal can be read along with the database (the owning app keeps its newest data there) without SQLite
    /// changing a file: the journal holds pages, and it and `-shm` both exist with the database's mode.
    ///
    /// Matching modes matter because the app may empty its journal (a checkpoint) between this check and the open, and SQLite gives
    /// an empty file it opens the database's mode. `-shm` is opened `readonly_shm`, so it is only ever read. Any other state is read
    /// `immutable`: the database file alone, which lacks whatever the app has not checkpointed yet.
    ///
    /// A journal the app deletes in the instant between this check and the open (its last connection closing) would be created
    /// again, empty and in the database's mode, as the app itself does on its next start; that read then fails once. SQLite has no
    /// way to forbid it.
    private static func journalIsUsable(_ path: String, database: FileStatus) -> Bool {
        guard let wal = FileStatus(path + "-wal"), let shm = FileStatus(path + "-shm") else { return false }
        return wal.size > 0 && wal.mode == database.mode && shm.mode == database.mode
    }
}

/// The two things `ReadOnlySQLite` looks at before it opens a file.
private struct FileStatus {
    var size: off_t
    /// The permission bits.
    var mode: mode_t

    /// nil when there is no file at `path`, or it cannot be inspected.
    init?(_ path: String) {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        size = status.st_size
        mode = status.st_mode & 0o777
    }
}
