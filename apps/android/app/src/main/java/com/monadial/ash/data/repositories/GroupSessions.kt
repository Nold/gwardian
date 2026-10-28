package com.monadial.ash.data.repositories

import com.monadial.ash.domain.entities.GroupConversation
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import uniffi.ash.AshException
import uniffi.ash.GroupMessage
import uniffi.ash.PadGroup

/** Result of reading one message from the relay. */
sealed interface GroupReadOutcome {
    data class Message(val message: GroupMessage) : GroupReadOutcome

    /** Already read: acknowledge so the relay can drop it */
    data object Duplicate : GroupReadOutcome

    /** Never readable (tampered or not for this group): acknowledge */
    data object Rejected : GroupReadOutcome

    /** May become readable once the pad is repaired: leave on the relay */
    data object Keep : GroupReadOutcome
}

class GroupDeletedException : IllegalStateException("group deleted")

/**
 * The single in-memory copy of each group's pads. Every screen goes through
 * it, so two copies can never send from the same offset or overwrite each
 * other's saved state. Each pad operation and its save run under one lock.
 */
@Singleton
class GroupSessions @Inject constructor(
    private val repository: GroupRepository
) {
    private val lock = Mutex()
    private val pads = mutableMapOf<String, PadGroup>()
    private val deleted = mutableSetOf<String>()

    /** Ciphertexts not yet accepted by the relay, by group and message */
    private val pending = mutableMapOf<String, MutableMap<String, ByteArray>>()

    /** Sends outlive the screen that started them */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private suspend fun padsFor(group: GroupConversation): PadGroup {
        if (group.id in deleted) throw GroupDeletedException()
        pads[group.id]?.let { return it }
        val loaded = repository.loadPads(group) ?: throw IllegalStateException("pads missing")
        pads[group.id] = loaded
        return loaded
    }

    /** Load the pads now, to report a damaged group on opening. */
    suspend fun open(group: GroupConversation) = lock.withLock { padsFor(group) }

    suspend fun canSend(group: GroupConversation, length: Int): Boolean = lock.withLock {
        runCatching { padsFor(group).canSend(length.toUInt()) }.getOrDefault(false)
    }

    /** Share of this phone's pad still available for sending. */
    suspend fun remainingFraction(group: GroupConversation): Float = lock.withLock {
        withContext(Dispatchers.Default) {
            val own = runCatching { padsFor(group).exportState() }.getOrNull()
                ?.firstOrNull { it.member.toInt() == group.me }
            if (own == null || own.pad.isEmpty()) {
                0f
            } else {
                val used = own.used.sumOf { (it.end - it.start).toLong() }
                (1f - used.toFloat() / own.pad.size).coerceAtLeast(0f)
            }
        }
    }

    private suspend fun save(group: GroupConversation, pads: PadGroup) {
        if (group.id in deleted) throw GroupDeletedException()
        repository.savePads(group.id, pads.exportState())
    }

    /**
     * Encrypt and save before returning: a frame is never sent unless its keys
     * are recorded as used. If saving fails the keys stay burned in memory,
     * which is safe, and nothing is sent.
     */
    suspend fun encrypt(group: GroupConversation, msgType: UByte, text: String): ByteArray = lock.withLock {
        withContext(Dispatchers.Default) {
            val pads = padsFor(group)
            val frame = pads.encrypt(msgType, text.encodeToByteArray().map { it.toUByte() })
            save(group, pads)
            frame.map { it.toByte() }.toByteArray()
        }
    }

    /**
     * Read frames, then save once, then hand the results to [deliver] while
     * still holding the lock, so a lock or a deletion cannot slip in between.
     * If saving fails nothing is delivered and the relay keeps the messages.
     */
    suspend fun <T> read(
        group: GroupConversation,
        frames: List<ByteArray>,
        deliver: (List<GroupReadOutcome>) -> T
    ): T = lock.withLock {
        withContext(Dispatchers.Default) {
            val pads = padsFor(group)
            var burned = false
            val outcomes = frames.map { frame ->
                try {
                    GroupReadOutcome.Message(pads.decrypt(frame.map { it.toUByte() })).also { burned = true }
                } catch (e: AshException.PadRangeAlreadyUsed) {
                    GroupReadOutcome.Duplicate
                } catch (e: AshException.PadCorrupted) {
                    GroupReadOutcome.Keep
                } catch (e: AshException.UnknownMember) {
                    GroupReadOutcome.Keep
                } catch (e: AshException) {
                    GroupReadOutcome.Rejected
                }
            }
            if (burned) save(group, pads)
            deliver(outcomes)
        }
    }

    // Pending frames

    suspend fun setPending(groupId: String, id: String, frame: ByteArray) = lock.withLock {
        pending.getOrPut(groupId) { mutableMapOf() }[id] = frame
    }

    suspend fun pendingFrame(groupId: String, id: String): ByteArray? = lock.withLock { pending[groupId]?.get(id) }

    suspend fun clearPending(groupId: String, id: String) = lock.withLock { pending[groupId]?.remove(id) }

    // Lifecycle

    /**
     * Forget the group and erase its pads. Later saves from work still in
     * flight are refused, so the pads are not written back.
     */
    suspend fun delete(groupId: String) = lock.withLock {
        deleted += groupId
        pads.remove(groupId)
        pending.remove(groupId)
        repository.delete(groupId)
    }

    /** Drop every pad from memory when the app locks. */
    suspend fun lockAll() = lock.withLock {
        pads.clear()
        pending.clear()
    }
}
