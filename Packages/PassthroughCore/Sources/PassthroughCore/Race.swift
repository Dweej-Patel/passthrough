import Foundation

/// Runs operations side by side and settles on the first answer without waiting
/// for the rest. A task group can't do that here: it waits for every child
/// before it returns, even after `cancelAll()`, and iroh's dials don't stop
/// when their task is cancelled (they run to iroh's own 30 s limit). The
/// others are cancelled; nothing waits for them.
public enum Race {
    /// The first operation to finish, whatever it returns.
    public static func first<T: Sendable>(_ operations: [@Sendable () async -> T]) async -> T {
        precondition(!operations.isEmpty, "Race.first needs an operation")
        let state = RaceState<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
                state.start(done)
                for operation in operations {
                    state.add(Task {
                        let value = await operation()
                        state.settle(value)
                    })
                }
            }
        } onCancel: {
            state.cancelAll()
        }
    }

    /// The first operation to succeed, by its index. A success that comes
    /// after it goes to `discard` (close it there). When every operation
    /// fails: the failure of `preferredFailure` if it has one, else the first.
    /// Cancelling the caller cancels them all and fails with `CancellationError`.
    public static func firstSuccess<T: Sendable>(
        _ operations: [@Sendable () async throws -> T],
        preferredFailure: Int = 0,
        discard: @escaping @Sendable (T) -> Void
    ) async -> (index: Int, result: Result<T, Error>) {
        precondition(!operations.isEmpty, "Race.firstSuccess needs an operation")
        let state = RaceState<(index: Int, result: Result<T, Error>)>()
        let failures = FailureTally<T>(count: operations.count, preferred: preferredFailure)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<(index: Int, result: Result<T, Error>), Never>) in
                state.start(done)
                for (index, operation) in operations.enumerated() {
                    state.add(Task {
                        do {
                            let value = try await operation()
                            if !state.settle((index, .success(value))) { discard(value) }
                        } catch {
                            if let last = failures.record(index, error) { state.settle(last) }
                        }
                    })
                }
            }
        } onCancel: {
            state.settleAndCancel((0, .failure(CancellationError())))
        }
    }
}

/// The continuation, resumed once, and the tasks to cancel when it is.
private final class RaceState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done: CheckedContinuation<T, Never>?
    private var settled: T?
    private var tasks: [Task<Void, Never>] = []
    private var cancelled = false

    /// Settled already (the caller was cancelled before this ran): resumes at once.
    func start(_ continuation: CheckedContinuation<T, Never>) {
        let early: T? = lock.withLock {
            if let settled { return settled }
            done = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func add(_ task: Task<Void, Never>) {
        let cancelNow = lock.withLock { () -> Bool in
            tasks.append(task)
            return cancelled
        }
        if cancelNow { task.cancel() }
    }

    /// Resumes with `value` if nothing has yet, then cancels the rest. False when too late.
    @discardableResult
    func settle(_ value: T) -> Bool {
        let (won, continuation, rest): (Bool, CheckedContinuation<T, Never>?, [Task<Void, Never>]) = lock.withLock {
            guard settled == nil else { return (false, nil, []) }
            settled = value
            cancelled = true
            defer { done = nil }
            return (true, done, tasks)
        }
        guard won else { return false }
        continuation?.resume(returning: value)
        for task in rest { task.cancel() }
        return true
    }

    func settleAndCancel(_ value: T) {
        if !settle(value) { cancelAll() }
    }

    func cancelAll() {
        let rest = lock.withLock { () -> [Task<Void, Never>] in
            cancelled = true
            return tasks
        }
        for task in rest { task.cancel() }
    }
}

/// Counts failures; hands back the one to report once every operation has failed.
private final class FailureTally<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let count: Int
    private let preferred: Int
    private var errors: [Int: Error] = [:]
    private var firstIndex: Int?

    init(count: Int, preferred: Int) {
        self.count = count
        self.preferred = preferred
    }

    func record(_ index: Int, _ error: Error) -> (index: Int, result: Result<T, Error>)? {
        lock.withLock {
            errors[index] = error
            if firstIndex == nil { firstIndex = index }
            guard errors.count == count else { return nil }
            let pick = errors[preferred] != nil ? preferred : firstIndex!
            return (pick, .failure(errors[pick]!))
        }
    }
}
