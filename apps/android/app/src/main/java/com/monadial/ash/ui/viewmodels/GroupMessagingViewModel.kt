package com.monadial.ash.ui.viewmodels

import android.util.Log
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.monadial.ash.core.common.AppError
import com.monadial.ash.core.common.AppResult
import com.monadial.ash.data.repositories.GroupReadOutcome
import com.monadial.ash.data.repositories.GroupRepository
import com.monadial.ash.data.repositories.GroupSessions
import com.monadial.ash.domain.entities.GroupChatMessage
import com.monadial.ash.domain.entities.GroupConversation
import com.monadial.ash.domain.entities.GroupMessageStore
import com.monadial.ash.domain.services.RelayService
import dagger.hilt.android.lifecycle.HiltViewModel
import java.time.Instant
import javax.inject.Inject
import kotlinx.coroutines.Job
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

data class GroupMessagingUiState(
    val group: GroupConversation? = null,
    val isLoaded: Boolean = false,
    val loadError: String? = null,
    /** Share of this phone's pad still available for sending */
    val remainingFraction: Float = 1f,
    val canSendAny: Boolean = true,
    val draftFits: Boolean = false,
    val draft: String = ""
)

/**
 * Messaging in a group (core/src/group.rs): each member sends with their own
 * pad; the relay keeps a message until every other member acknowledged it.
 * The pads live in [GroupSessions], shared by every screen of the group.
 */
@HiltViewModel
class GroupMessagingViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val groupRepository: GroupRepository,
    private val sessions: GroupSessions,
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

    private var pollJob: Job? = null
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
        if (runCatching { sessions.open(group) }.isFailure) {
            _uiState.update { it.copy(loadError = "The pads of this group cannot be read.") }
            return
        }
        _uiState.update { it.copy(isLoaded = true) }
        refreshPadState(group)
        startPolling()
        if (group.disappearingMessages.seconds != null) {
            viewModelScope.launch {
                while (isActive) {
                    store.removeExpired(groupId)
                    delay(1_000)
                }
            }
        }
    }

    // MARK: - Polling, while the screen is resumed

    fun startPolling() {
        if (pollJob?.isActive == true || !_uiState.value.isLoaded) return
        pollJob = viewModelScope.launch {
            while (isActive) {
                pollOnce()
                delay(POLL_INTERVAL_MS)
            }
        }
    }

    fun stopPolling() {
        pollJob?.cancel()
        pollJob = null
    }

    // MARK: - Sending

    fun setDraft(text: String) {
        _uiState.update { it.copy(draft = text) }
        val group = _uiState.value.group ?: return
        viewModelScope.launch {
            val fits = text.isNotBlank() && sessions.canSend(group, text.trim().encodeToByteArray().size)
            _uiState.update { if (it.draft == text) it.copy(draftFits = fits) else it }
        }
    }

    fun canSend(state: GroupMessagingUiState = _uiState.value): Boolean =
        state.isLoaded && state.draft.isNotBlank() && state.draftFits

    fun send() {
        val state = _uiState.value
        val group = state.group ?: return
        if (!canSend(state)) return
        val text = state.draft.trim()
        // Cleared now, so a second tap cannot send the same text again
        _uiState.update { it.copy(draft = "", draftFits = false) }

        // The send outlives this screen: leaving it does not strand the message
        sessions.scope.launch {
            val frame = try {
                // Saved before returning: nothing is sent with unrecorded keys
                sessions.encrypt(group, TEXT_TYPE, text)
            } catch (e: Exception) {
                Log.e(TAG, "Group message not sent: ${e.message}")
                return@launch
            }
            val message = GroupChatMessage(
                sender = group.me,
                text = text,
                timestamp = System.currentTimeMillis(),
                status = GroupChatMessage.Status.SENDING
            )
            store.append(group.id, message)
            sessions.setPending(group.id, message.id, frame)
            refreshPadState(group)
            submit(group, message.id)
        }
    }

    /** Send a failed message again, with the same ciphertext: no key reuse. */
    fun retry(message: GroupChatMessage) {
        val group = _uiState.value.group ?: return
        if (message.status != GroupChatMessage.Status.FAILED) return
        sessions.scope.launch {
            if (sessions.pendingFrame(group.id, message.id) == null) return@launch
            setStatus(message.id, GroupChatMessage.Status.SENDING)
            submit(group, message.id)
        }
    }

    private suspend fun submit(group: GroupConversation, id: String) {
        val frame = sessions.pendingFrame(group.id, id) ?: return setStatus(id, GroupChatMessage.Status.FAILED)
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
                sessions.clearPending(group.id, id)
                setStatus(id, GroupChatMessage.Status.SENT)
            }
            is AppResult.Error -> {
                if (isNotFound(result.error) && !hasReregistered) {
                    hasReregistered = true
                    if (reregister(group)) return submit(group, id)
                }
                Log.w(TAG, "Group submit failed: ${result.error.message}")
                setStatus(id, GroupChatMessage.Status.FAILED)
            }
        }
    }

    // MARK: - Receiving

    fun poll() {
        viewModelScope.launch { pollOnce() }
    }

    /**
     * Fetch what the other members sent, decrypt it, then acknowledge it so the
     * relay can delete it once everyone has it.
     */
    private suspend fun pollOnce() {
        val group = _uiState.value.group ?: return
        val generation = store.generation
        val result = relayService.fetchMessages(
            conversationId = group.id,
            authToken = group.authToken,
            relayUrl = group.relayUrl,
            member = group.me
        )
        if (result is AppResult.Error) {
            if (isNotFound(result.error) && !hasReregistered) {
                hasReregistered = true
                reregister(group)
            }
            return
        }
        val polled = (result as AppResult.Success).data
        if (polled.messages.isEmpty()) return

        val toAck = try {
            sessions.read(group, polled.messages.map { it.ciphertext }) { outcomes ->
                // Still under the pad lock: shown only if the pads were saved
                val acked = mutableListOf<String>()
                val now = System.currentTimeMillis()
                polled.messages.zip(outcomes).forEach { (received, outcome) ->
                    when (outcome) {
                        is GroupReadOutcome.Message -> {
                            acked += received.id
                            val message = outcome.message
                            if (message.sender.toInt() != group.me && message.msgType == TEXT_TYPE) {
                                store.append(
                                    group.id,
                                    GroupChatMessage(
                                        sender = message.sender.toInt(),
                                        text = message.plaintext.map { it.toByte() }.toByteArray().decodeToString(),
                                        timestamp = runCatching { Instant.parse(received.receivedAt).toEpochMilli() }
                                            .getOrDefault(now),
                                        status = GroupChatMessage.Status.RECEIVED,
                                        expiresAt = group.disappearingMessages.seconds?.let { now + it * 1_000L }
                                    ),
                                    generation
                                )
                            }
                        }
                        GroupReadOutcome.Duplicate, GroupReadOutcome.Rejected -> acked += received.id
                        GroupReadOutcome.Keep -> Log.w(TAG, "Group message kept on the relay: pad needs repair")
                    }
                }
                acked
            }
        } catch (e: Exception) {
            // Locked, deleted or not saved: nothing shown, the relay keeps them
            Log.w(TAG, "Group messages left on the relay: ${e.message}")
            return
        }
        refreshPadState(group)
        relayService.acknowledgeMessages(
            conversationId = group.id,
            authToken = group.authToken,
            blobIds = toAck,
            relayUrl = group.relayUrl,
            member = group.me
        )
    }

    // MARK: - Deletion

    /** Delete the group, its pads and its messages from this phone only. */
    fun delete(onDeleted: () -> Unit) {
        stopPolling()
        viewModelScope.launch {
            try {
                sessions.delete(groupId)
            } catch (e: Exception) {
                Log.e(TAG, "Group deletion failed: ${e.message}")
            }
            store.clear(groupId)
            onDeleted()
        }
    }

    // MARK: - Helpers

    /** The relay forgot the group (restarted): register again once */
    private fun isNotFound(error: AppError) = error.message.contains("404")

    private suspend fun reregister(group: GroupConversation): Boolean =
        relayService.registerConversation(
            conversationId = group.id,
            authTokenHash = relayService.hashToken(group.authToken),
            burnTokenHash = relayService.hashToken(group.burnToken),
            relayUrl = group.relayUrl,
            ttlSeconds = group.messageRetention.seconds,
            members = group.members.size
        ) is AppResult.Success

    private suspend fun refreshPadState(group: GroupConversation) {
        val fraction = sessions.remainingFraction(group)
        val canSendAny = sessions.canSend(group, 1)
        _uiState.update { it.copy(remainingFraction = fraction, canSendAny = canSendAny) }
    }

    private fun setStatus(id: String, status: GroupChatMessage.Status) {
        store.update(groupId, id) { it.copy(status = status) }
    }
}
