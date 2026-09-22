import Foundation
import os

/// Lock-free-ish byte counters updated from network queues and read from the UI.
public final class ByteCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (rx: Int64(0), tx: Int64(0), active: Int(0), total: Int(0)))

    public init() {}

    public func addRx(_ n: Int) { lock.withLock { $0.rx += Int64(n) } }
    public func addTx(_ n: Int) { lock.withLock { $0.tx += Int64(n) } }
    public func connectionOpened() { lock.withLock { $0.active += 1; $0.total += 1 } }
    public func connectionClosed() { lock.withLock { $0.active = max(0, $0.active - 1) } }

    public struct Snapshot: Sendable, Equatable {
        public var rx: Int64
        public var tx: Int64
        public var active: Int
        public var totalConnections: Int
        public init(rx: Int64, tx: Int64, active: Int, totalConnections: Int) {
            self.rx = rx; self.tx = tx; self.active = active; self.totalConnections = totalConnections
        }
        public static let zero = Snapshot(rx: 0, tx: 0, active: 0, totalConnections: 0)
    }

    public func snapshot() -> Snapshot {
        lock.withLock { Snapshot(rx: $0.rx, tx: $0.tx, active: $0.active, totalConnections: $0.total) }
    }

    public func reset() { lock.withLock { $0 = (0, 0, $0.active, 0) } }
}

/// One second of throughput, used for sparkline charts.
public struct ThroughputSample: Identifiable, Sendable, Equatable {
    public let id: Int
    public let date: Date
    /// Bytes per second.
    public let down: Double
    public let up: Double
    public init(id: Int, date: Date, down: Double, up: Double) {
        self.id = id; self.date = date; self.down = down; self.up = up
    }
}

/// Turns raw byte counters into rates and a short history window.
public struct TrafficMeter: Sendable, Equatable {
    public private(set) var history: [ThroughputSample] = []
    public private(set) var downRate: Double = 0
    public private(set) var upRate: Double = 0
    public private(set) var last: ByteCounter.Snapshot = .zero
    public private(set) var lastDate: Date?
    public let windowSize: Int
    private var counter = 0

    public init(windowSize: Int = 60) {
        self.windowSize = windowSize
        let now = Date()
        history = (0..<windowSize).map { i in
            ThroughputSample(id: i - windowSize, date: now.addingTimeInterval(Double(i - windowSize)), down: 0, up: 0)
        }
        counter = 0
    }

    public mutating func record(_ snapshot: ByteCounter.Snapshot, at date: Date = Date()) {
        defer { last = snapshot; lastDate = date }
        guard let lastDate else { return }
        let dt = max(0.05, date.timeIntervalSince(lastDate))
        downRate = max(0, Double(snapshot.rx - last.rx) / dt)
        upRate = max(0, Double(snapshot.tx - last.tx) / dt)
        history.append(ThroughputSample(id: counter, date: date, down: downRate, up: upRate))
        counter += 1
        if history.count > windowSize { history.removeFirst(history.count - windowSize) }
    }

    public mutating func reset() {
        self = TrafficMeter(windowSize: windowSize)
    }

    public var peakRate: Double {
        history.reduce(0) { max($0, max($1.down, $1.up)) }
    }
}

public enum ByteFormat {
    public static func bytes(_ value: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: value)
    }

    /// e.g. "12.4 MB/s"; always two significant components for stable layout.
    public static func rate(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = bytesPerSecond
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        let text = i == 0 ? String(format: "%.0f", v) : (v < 10 ? String(format: "%.2f", v) : (v < 100 ? String(format: "%.1f", v) : String(format: "%.0f", v)))
        return (text, units[i])
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 3600 { return String(format: "%02d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
