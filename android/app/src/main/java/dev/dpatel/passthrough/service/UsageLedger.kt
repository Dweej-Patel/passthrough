package dev.dpatel.passthrough.service

import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.Calendar

/** Persists cumulative data usage so you can keep an eye on the plan. */
class UsageLedger(private val prefs: SharedPreferences) {
    data class Usage(val monthRx: Long, val monthTx: Long, val monthStart: Long, val allRx: Long, val allTx: Long) {
        val monthTotal get() = monthRx + monthTx
        val allTotal get() = allRx + allTx
    }

    private val _usage = MutableStateFlow(load())
    val usage: StateFlow<Usage> = _usage

    private fun load(): Usage {
        var start = prefs.getLong(MONTH_START, 0)
        if (start == 0L) { start = System.currentTimeMillis(); prefs.edit().putLong(MONTH_START, start).apply() }
        return Usage(prefs.getLong(MONTH_RX, 0), prefs.getLong(MONTH_TX, 0), start, prefs.getLong(ALL_RX, 0), prefs.getLong(ALL_TX, 0))
    }

    @Synchronized
    fun add(rx: Long, tx: Long) {
        if (rx <= 0 && tx <= 0) { rolloverIfNeeded(); return }
        var u = rollover(_usage.value)
        u = u.copy(monthRx = u.monthRx + rx, monthTx = u.monthTx + tx, allRx = u.allRx + rx, allTx = u.allTx + tx)
        persist(u)
    }

    @Synchronized
    fun resetMonth() = persist(_usage.value.copy(monthRx = 0, monthTx = 0, monthStart = System.currentTimeMillis()))

    @Synchronized
    fun rolloverIfNeeded() {
        val u = rollover(_usage.value)
        if (u != _usage.value) persist(u)
    }

    private fun rollover(u: Usage): Usage {
        val now = Calendar.getInstance()
        val start = Calendar.getInstance().apply { timeInMillis = u.monthStart }
        if (now.get(Calendar.YEAR) == start.get(Calendar.YEAR) && now.get(Calendar.MONTH) == start.get(Calendar.MONTH)) return u
        val first = Calendar.getInstance().apply {
            set(Calendar.DAY_OF_MONTH, 1); set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        return u.copy(monthRx = 0, monthTx = 0, monthStart = first.timeInMillis)
    }

    private fun persist(u: Usage) {
        _usage.value = u
        prefs.edit().putLong(MONTH_RX, u.monthRx).putLong(MONTH_TX, u.monthTx).putLong(MONTH_START, u.monthStart)
            .putLong(ALL_RX, u.allRx).putLong(ALL_TX, u.allTx).apply()
    }

    companion object {
        const val MONTH_RX = "usage.month.rx"
        const val MONTH_TX = "usage.month.tx"
        const val MONTH_START = "usage.month.start"
        const val ALL_RX = "usage.all.rx"
        const val ALL_TX = "usage.all.tx"
    }
}
