import Foundation
import CoreServices

/// FSEventStream-based recursive watcher. Coalesces events with a 0.5 s latency and
/// emits a callback (without payload — caller re-scans the tree).
public final class FolderWatcher: @unchecked Sendable {
    private let url: URL
    private var stream: FSEventStreamRef?
    private let callback: @Sendable () -> Void
    private let queue: DispatchQueue

    public init(url: URL, queue: DispatchQueue = .main, callback: @escaping @Sendable () -> Void) {
        self.url = url
        self.callback = callback
        self.queue = queue
    }

    public func start() {
        guard stream == nil else { return }

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.callback()
        }

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            cb,
            &ctx,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseExtendedData
                | kFSEventStreamCreateFlagNoDefer
            )
        ) else { return }

        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
