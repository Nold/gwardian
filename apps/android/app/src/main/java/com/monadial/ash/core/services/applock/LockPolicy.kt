package com.monadial.ash.core.services.applock

/**
 * Rules for the app code (docs/app-lock.md): format, delays after wrong
 * codes, and the optional erase after too many failures.
 */
object LockPolicy {
    const val CODE_LENGTH = 6

    /** Wrong codes in a row that erase everything, when erase is enabled. */
    const val ERASE_THRESHOLD = 10

    fun isValidCode(code: String): Boolean = code.length == CODE_LENGTH && code.all { it in '0'..'9' }

    /** Wait required before the next try, after [failures] wrong codes in a row. */
    fun delayMillis(failures: Int): Long = when {
        failures < 5 -> 0L
        failures == 5 -> 30_000L
        failures == 6 -> 60_000L
        failures == 7 -> 5 * 60_000L
        failures == 8 -> 15 * 60_000L
        else -> 60 * 60_000L
    }
}

/** Failed attempts, kept in secure storage outside the vault. */
data class LockAttemptState(
    val failures: Int = 0,
    val lastFailureMillis: Long? = null,
    /** Erase everything after [LockPolicy.ERASE_THRESHOLD] wrong codes. */
    val eraseAfterFailures: Boolean = false
) {
    /** When the next try is allowed, or null if it is allowed now. */
    fun retryAtMillis(nowMillis: Long): Long? {
        val last = lastFailureMillis ?: return null
        val retry = last + LockPolicy.delayMillis(failures)
        return if (retry > nowMillis) retry else null
    }

    /** Wrong codes left before erasing, when erase is enabled. */
    val attemptsBeforeErase: Int?
        get() = if (eraseAfterFailures) maxOf(LockPolicy.ERASE_THRESHOLD - failures, 0) else null
}

interface LockAttemptStore {
    fun load(): LockAttemptState
    fun save(state: LockAttemptState)
}
