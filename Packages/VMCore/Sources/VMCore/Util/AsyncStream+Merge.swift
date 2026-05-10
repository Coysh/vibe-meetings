import Foundation

public extension AsyncStream where Element: Sendable {
    /// Merges two `AsyncStream`s into one. Order is interleaved as elements arrive.
    /// The merged stream finishes once both inputs finish.
    static func merge(_ a: AsyncStream<Element>, _ b: AsyncStream<Element>) -> AsyncStream<Element> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await el in a { continuation.yield(el) }
                    }
                    group.addTask {
                        for await el in b { continuation.yield(el) }
                    }
                    await group.waitForAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
