import XCTest
@testable import PassthroughCore

/// `Race` settles on the first answer without waiting for operations that
/// ignore cancellation, as iroh's dials do.
final class RaceTests: XCTestCase {
    struct Failed: Error, Equatable { let n: Int }

    /// Ignores cancellation, like an iroh dial: only the clock ends it.
    private static func hang(_ seconds: TimeInterval) async {
        await withCheckedContinuation { done in DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.resume() } }
    }

    func testFirstSuccessDoesNotWaitForAHungOperation() async {
        let started = Date()
        let found = await Race.firstSuccess([
            { @Sendable () async throws -> Int in await Self.hang(10); return 0 },
            { @Sendable () async throws -> Int in try await Task.sleep(nanoseconds: 100_000_000); return 1 },
        ], discard: { _ in })
        XCTAssertEqual(found.index, 1)
        XCTAssertEqual(try? found.result.get(), 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testALateSuccessIsDiscarded() async {
        let discarded = Locked<[Int]>([])
        let found = await Race.firstSuccess([
            { @Sendable () async throws -> Int in 0 },
            { @Sendable () async throws -> Int in await Self.hang(0.3); return 1 },
        ], discard: { value in discarded.set(discarded.get() + [value]) })
        XCTAssertEqual(found.index, 0)
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(discarded.get(), [1])
    }

    func testWhenAllFailThePreferredFailureIsReported() async {
        let found = await Race.firstSuccess([
            { @Sendable () async throws -> Int in try await Task.sleep(nanoseconds: 200_000_000); throw Failed(n: 0) },
            { @Sendable () async throws -> Int in throw Failed(n: 1) },
        ], preferredFailure: 0, discard: { _ in })
        XCTAssertEqual(found.index, 0)
        guard case .failure(let error) = found.result else { return XCTFail("expected a failure") }
        XCTAssertEqual(error as? Failed, Failed(n: 0))
    }

    func testCancellingTheCallerEndsTheRaceAtOnce() async {
        let started = Date()
        let race = Task {
            await Race.firstSuccess([{ @Sendable () async throws -> Int in await Self.hang(10); return 0 }], discard: { _ in })
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        race.cancel()
        let found = await race.value
        guard case .failure(let error) = found.result else { return XCTFail("expected a failure") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testFirstReturnsTheTimerWhenTheOtherHangs() async {
        let started = Date()
        let value = await Race.first([
            { @Sendable in await Self.hang(10); return "answered" },
            { @Sendable in try? await Task.sleep(nanoseconds: 300_000_000); return "timed out" },
        ])
        XCTAssertEqual(value, "timed out")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
