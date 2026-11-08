import Foundation

// File work off the main thread. The music folders are on network shares and the iPod is a slow USB disk
// that may have to spin up: a single stat or copy on the main thread there froze the window for seconds.

func offMain<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
    await Task.detached(operation: work).value
}

func offMain<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
    try await Task.detached(operation: work).value
}
