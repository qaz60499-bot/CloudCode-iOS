import Foundation

@MainActor
public final class StreamingUIFlushCoordinator {
    private struct PendingFlush {
        let generation: UUID
        let task: Task<Void, Never>
    }

    private let intervalNanoseconds: UInt64
    private let publish: @MainActor (UUID) -> Void
    private var pendingFlushes: [UUID: PendingFlush] = [:]

    public init(
        intervalNanoseconds: UInt64 = 33_000_000,
        publish: @escaping @MainActor (UUID) -> Void
    ) {
        self.intervalNanoseconds = intervalNanoseconds
        self.publish = publish
    }

    /// Schedules one delayed publish for this session. Repeated calls while it is pending are coalesced.
    public func schedule(sessionID: UUID) {
        guard pendingFlushes[sessionID] == nil else { return }

        let generation = UUID()
        let intervalNanoseconds = self.intervalNanoseconds
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: intervalNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled, let self else { return }
            self.complete(sessionID: sessionID, generation: generation)
        }
        pendingFlushes[sessionID] = PendingFlush(generation: generation, task: task)
    }

    /// Cancels a pending delay and publishes immediately, including when no delay is pending.
    public func flush(sessionID: UUID) {
        pendingFlushes.removeValue(forKey: sessionID)?.task.cancel()
        publish(sessionID)
    }

    /// Cancels a pending delayed publish without publishing.
    public func cancel(sessionID: UUID) {
        pendingFlushes.removeValue(forKey: sessionID)?.task.cancel()
    }

    private func complete(sessionID: UUID, generation: UUID) {
        guard pendingFlushes[sessionID]?.generation == generation else { return }
        pendingFlushes.removeValue(forKey: sessionID)
        publish(sessionID)
    }
}
