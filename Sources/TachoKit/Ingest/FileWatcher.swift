import CoreServices
import Foundation

/// Tells `handler` which files changed under `paths`, in batches at most `latency` seconds apart.
///
/// FSEvents reports resolved paths ("/private/var/…", not "/var/…") and can drop events under load, so the caller has to compare
/// resolved paths and to look again now and then. It also reports directories, and files nobody asked about: the caller filters.
final class FileWatcher: @unchecked Sendable {
    private let paths: [String]
    private let latency: TimeInterval
    private let handler: @Sendable ([String]) -> Void
    /// The stream calls back on this queue, and `start` and `stop` run on it, so a stop cannot overlap a callback.
    /// It is what makes the type Sendable: the two properties below are touched only on it.
    private let queue = DispatchQueue(label: "io.github.gogy717.tacho.file-watcher")
    private var stream: FSEventStreamRef?
    private var delivery: Unmanaged<Delivery>?

    init(paths: [String], latency: TimeInterval = 0.5, handler: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        queue.sync {
            guard stream == nil, !paths.isEmpty else { return }
            let delivery = Unmanaged.passRetained(Delivery(handler: handler))
            var context = FSEventStreamContext(version: 0, info: delivery.toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault, deliverEvents, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
            ) else {
                delivery.release()
                return
            }
            FSEventStreamSetDispatchQueue(stream, queue)
            self.stream = stream
            self.delivery = delivery
            if !FSEventStreamStart(stream) {
                tearDown()
            }
        }
    }

    func stop() {
        queue.sync { tearDown() }
    }

    /// Runs on `queue`.
    private func tearDown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        delivery?.release()
        delivery = nil
    }
}

/// What the stream calls back into. It is its own object so that the stream never points at the watcher: a watcher can go away with its
/// stream running, and its `deinit` stops the stream.
private final class Delivery {
    let handler: @Sendable ([String]) -> Void

    init(handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
    }
}

private func deliverEvents(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    // `kFSEventStreamCreateFlagUseCFTypes` makes this a CFArray of CFStrings.
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
    Unmanaged<Delivery>.fromOpaque(info).takeUnretainedValue().handler(paths)
}
