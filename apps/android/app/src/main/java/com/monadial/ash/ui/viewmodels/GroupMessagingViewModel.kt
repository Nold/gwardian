package com.monadial.ash.ui.viewmodels

import android.util.Log
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.monadial.ash.core.common.AppResult
import com.monadial.ash.data.repositories.GroupRepository
import com.monadial.ash.domain.entities.GroupChatMessage
import com.monadial.ash.domain.entities.GroupConversation
import com.monadial.ash.domain.entities.GroupMessageStore
import com.monadial.ash.domain.services.RelayService
import dagger.hilt.android.lifecycle.HiltViewModel
import java.time.Instant
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import uniffi.ash.AshException
import uniffi.ash.PadGroup

data class GroupMessagingUiState(
    val group: GroupConversation? = null,
    val isLoaded: Boolean = false,
    val loadError: String? = null,
    /** Share of this phone's pad still available for sending */
    val remainingFraction: Float = 1f,
    val canSendAny: Boolean = true,
    val draft: String = ""
)

/**
 * Messaging in a group (core/src/group.rs): each member sends with their own
 * pad; the relay keeps a message until every other member acknowledged it.
 */
@HiltViewModel
class GroupMessagingViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val groupRepository: GroupRepository,
    private val relayService: RelayService,
    private val store: GroupMessageStore
) : ViewModel() {

    companion object {
        private const val TAG = "GroupMessagingVM"
        private const val POLL_INTERVAL_MS = 5_000L

        /** Wire type of a text message (core MessageType::Text) */
        private const val TEXT_TYPE: UByte = 0x01u
    }

    private val groupId: String = savedStateHandle.get<String>("groupId").orEmpty()

    private val _uiState = MutableStateFlow(GroupMessagingUiState())
    val uiState: StateFlow<GroupMessagingUiState> = _uiState.asStateFlow()

    val messages: StateFlow<List<GroupChatMessage>> =
        store.messages.map { it[groupId].orEmpty() }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private var pads: PadGroup? = null

    /** Encrypt, decrypt and save never run at the same time on the pads */
    private val padLock = Mutex()

    /** Frames not yet accepted by the relay; resending the same ciphertext reuses no key */
    private val pendingFrames = mutableMapOf<String, ByteArray>()
    private var hasReregistered = false

    init {
        viewModelScope.launch { load() }
    }

    private suspend fun load() {
        val group = runCatching { groupRepository.load().firstOrNull { it.id == groupId } }.getOrNull()
        if (group == null) {
            _uiState.update { it.copy(loadError = "This group no longer exists.") }
            return
        }
        _uiState.update { it.copy(group = group) }
        val loaded = runCatching { groupRepository.loadPads(group) }.getOrNull()
        if (loaded == null) {
            _uiState.update { it.copy(loadError = "The pads of this group cannot be read.") }
            return
        }
        pads = loaded
        updateRemaining(group)
        _uiState.update { it.copy(isLoaded = true) }

        // Poll while the screen is open; disappearing messages expire meanwhile
        viewModelScope.launch {
            while (isActive) {
                poll()
                delay(POLL_INTERVAL_MS)
            }
        }
        if (group.disappearingMessages.seconds != null) {
            viewModelScope.launch {
                while (isActive) {
                    store.removeExpired(groupId)
                    delay(1_000)
                }
            }
        }
    }

    // MARK: - Sending

    fun setDraft(text: String) = _uiState.update { it.copy(draft = text) }

    fun canSend(state: GroupMessagingUiState = _uiState.value): Boolean {
        val text = state.draft.trim()
        val pads = pads ?: return false
        return state.isLoaded && text.isNotEmpty() && pads.canSend(text.encodeToByteArray().size.toUInt())
    }

    fun send() {
        val state = _uiState.value
        val group = state.group ?: return
        val text = state.draft.trim()
        if (!canSend(state)) return
        val pads = pads ?: return

        viewModelScope.launch {
            val frame = try {
                padLock.withLock {
                    withContext(Dispatchers.Default) {
                        val frame = pads.encrypt(TEXT_TYPE, text.encodeToByteArray().map { it.toUByte() })
                        // The keys are burned: persist before anything else can fail
                        groupRepository.savePads(group.id, pads.exportState())
                        frame
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Group encryption failed: ${e.message}")
                return@launch
            }
            updateRemaining(group)
            _uiState.update { it.copy(draft = "") }

            val message = GroupChatMessage(
                sender = group.me,
                text = text,
                timestamp = System.currentTimeMillis(),
                status = GroupChatMessage.Status.SENDING
            )
            store.append(group.id, message)
            pendingFrames[message.id] = frame.map { it.toByte() }.toByteArray()
            submit(group, message.id)
        }
    }

    /** Send a failed message again, with the same ciphertext. */
    fun retry(message: GroupChatMessage) {
        val group = _uiState.value.group ?: return
        if (message.status != GroupChatMessage.Status.FAILED || message.id !in pendingFrames) return
        setStatus(message.id, GroupChatMessage.Status.SENDING)
        viewModelScope.launch { submit(group, message.id) }
    }

    private suspend fun submit(group: GroupConversation, id: String) {
        val frame = pendingFrames[id] ?: return setStatus(id, GroupChatMessage.Status.FAILED)
        val result = relayService.submitMessage(
            conversationId = group.id,
            authToken = group.authToken,
            ciphertext = frame,
            ttlSeconds = group.messageRetention.seconds,
            relayUrl = group.relayUrl,
            sender = group.me
        )
        when (result) {
            is AppResult.Success -> {
                pendingFrames.remove(id)
                setStatus(id, GroupChatMessage.Status.SENT)
            }
            is AppResult.Error -> {
                // Not registered yet (relay restarted): register once and retry
                if (!hasReregistered) {
                    hasReregistered = true
                    if (reregister(group)) return submit(group, id)
                }
                Log.w(TAG, "Group submit failed: ${result.error.message}")
                setStatus(id, GroupChatMessage.Status.FAILED)
            }
        }
    }

    // MARK: - Receiving

    /**
     * Fetch what the other members sent, decrypt it, then acknowledge it so the
     * relay can delete it once everyone has it.
     */
    fun poll() {
        viewModelScope.launch { pollOnce() }
    }

    private suspend fun pollOnce() {
        val group = _uiState.value.group ?: return
        val pads = pads ?: return
        val result = relayService.fetchMessages(
            conversationId = group.id,
            authToken = group.authToken,
            relayUrl = group.relayUrl,
            member = group.me
        )
        val polled = (result as? AppResult.Success)?.data ?: return
        if (polled.messages.isEmpty()) return

        val processed = mutableListOf<String>()
        var decrypted = false
        padLock.withLock {
            withContext(Dispatchers.Default) {
                for (received in polled.messages) {
                    try {
                        val message = pads.decrypt(received.ciphertext.map { it.toUByte() })
                        decrypted = true
                        processed += received.id
                        if (message.sender.toInt() == group.me || message.msgType != TEXT_TYPE) continue
                        val now = System.currentTimeMillis()
                        store.append(
                            group.id,
                            GroupChatMessage(
                                sender = message.sender.toInt(),
                                text = message.plaintext.map { it.toByte() }.toByteArray().decodeToString(),
                                timestamp = runCatching { Instant.parse(received.receivedAt).toEpochMilli() }
                                    .getOrDefault(now),
                                status = GroupChatMessage.Status.RECEIVED,
                                expiresAt = group.disappearingMessages.seconds?.let { now + it * 1_000L }
                            )
                        )
                    } catch (e: AshException.PadRangeAlreadyUsed) {
                        // Already read: acknowledge again so the relay can drop it
                        processed += received.id
                    } catch (e: Exception) {
                        // Unreadable (tampered or damaged): acknowledged so it
                        // does not come back on every poll
                        Log.w(TAG, "Group message rejected: ${e.message}")
                        processed += received.id
                    }
                }
                if (decrypted) groupRepository.savePads(group.id, pads.exportState())
            }
        }
        if (decrypted) updateRemaining(group)
        relayService.acknowledgeMessages(
            conversationId = group.id,
            authToken = group.authToken,
            blobIds = processed,
            relayUrl = group.relayUrl,
            member = group.me
        )
    }

    /** Delete the group, its pads and its messages from this phone only. */
    fun delete(onDeleted: () -> Unit) {
        viewModelScope.launch {
            groupRepository.delete(groupId)
            store.clear(groupId)
            onDeleted()
        }
    }

    // MARK: - Helpers

    private suspend fun reregister(group: GroupConversation): Boolean =
        relayService.registerConversation(
            conversationId = group.id,
            authTokenHash = relayService.hashToken(group.authToken),
            burnTokenHash = relayService.hashToken(group.burnToken),
            relayUrl = group.relayUrl,
            ttlSeconds = group.messageRetention.seconds,
            members = group.members.size
        ) is AppResult.Success

    private suspend fun updateRemaining(group: GroupConversation) {
        val pads = pads ?: return
        val (fraction, canSendAny) = withContext(Dispatchers.Default) {
            val own = pads.exportState().firstOrNull { it.member.toInt() == group.me }
            val fraction = if (own == null || own.pad.isEmpty()) {
                0f
            } else {
                val used = own.used.sumOf { (it.end - it.start).toLong() }
                (1f - used.toFloat() / own.pad.size).coerceAtLeast(0f)
            }
            fraction to pads.canSend(1u)
        }
        _uiState.update { it.copy(remainingFraction = fraction, canSendAny = canSendAny) }
    }

    private fun setStatus(id: String, status: GroupChatMessage.Status) {
        store.update(groupId, id) { it.copy(status = status) }
    }

    // The pads are not closed in onCleared: a decrypt may still be running on
    // another thread, and UniFFI frees the object once it is unreachable
}
