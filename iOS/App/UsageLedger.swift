import Foundation
import PassthroughCore

/// Persists cumulative data usage so you can keep an eye on the plan.
struct UsageLedger {
    private let defaults: UserDefaults
    private(set) var monthRx: Int64
    private(set) var monthTx: Int64
    private(set) var monthStart: Date
    private(set) var allRx: Int64
    private(set) var allTx: Int64

    init(defaults: UserDefaults) {
        self.defaults = defaults
        monthRx = Int64(defaults.integer(forKey: SharedKeys.usageMonthRx))
        monthTx = Int64(defaults.integer(forKey: SharedKeys.usageMonthTx))
        allRx = Int64(defaults.integer(forKey: SharedKeys.usageAllTimeRx))
        allTx = Int64(defaults.integer(forKey: SharedKeys.usageAllTimeTx))
        let start = defaults.double(forKey: SharedKeys.usageMonthStart)
        monthStart = start > 0 ? Date(timeIntervalSince1970: start) : Date()
        if start == 0 { defaults.set(monthStart.timeIntervalSince1970, forKey: SharedKeys.usageMonthStart) }
        rolloverIfNeeded()
    }

    mutating func add(rx: Int64, tx: Int64) {
        rolloverIfNeeded()
        monthRx += rx; monthTx += tx; allRx += rx; allTx += tx
        persist()
    }

    mutating func resetMonth() {
        monthRx = 0; monthTx = 0; monthStart = Date()
        persist()
    }

    private mutating func rolloverIfNeeded() {
        let cal = Calendar.current
        if !cal.isDate(monthStart, equalTo: Date(), toGranularity: .month) {
            monthRx = 0; monthTx = 0; monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
            persist()
        }
    }

    private func persist() {
        defaults.set(monthRx, forKey: SharedKeys.usageMonthRx)
        defaults.set(monthTx, forKey: SharedKeys.usageMonthTx)
        defaults.set(allRx, forKey: SharedKeys.usageAllTimeRx)
        defaults.set(allTx, forKey: SharedKeys.usageAllTimeTx)
        defaults.set(monthStart.timeIntervalSince1970, forKey: SharedKeys.usageMonthStart)
    }

    var monthTotal: Int64 { monthRx + monthTx }
    var allTotal: Int64 { allRx + allTx }
}
