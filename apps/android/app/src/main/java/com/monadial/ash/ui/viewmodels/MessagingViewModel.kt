package com.monadial.ash.ui.viewmodels

import android.util.Log
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.monadial.ash.core.common.AppResult
import com.monadial.ash.domain.services.LocationError
import com.monadial.ash.domain.services.LocationService
import com.monadial.ash.core.services.SSEEvent
import com.monadial.ash.domain.entities.Conversation
import com.monadial.ash.domain.entities.DeliveryStatus
import com.monadial.ash.domain.entities.DisappearingMessages
import com.monadial.ash.domain.entities.Message
import com.monadial.ash.domain.entities.MessageContent
import com.monadial.ash.domain.entities.MessageDirection
import com.monadial.ash.domain.repositories.ConversationRepository
import com.monadial.ash.domain.repositories.PadRepository
import com.monadial.ash.domain.services.RealtimeService
import com.monadial.ash.domain.services.RelayService
import com.monadial.ash.domain.usecases.conversation.CheckBurnStatusUseCase
import com.monadial.ash.domain.usecases.conversation.RegisterConversationUseCase
import com.monadial.ash.domain.usecases.messaging.ReceivedMessageData
import com.monadial.ash.domain.usecases.messaging.ReceiveMessageResult
import com.monadial.ash.domain.usecases.messaging.ReceiveMessageUseCase
import com.monadial.ash.domain.usecases.messaging.EncryptedFrame
import com.monadial.ash.domain.usecases.messaging.SendMessageUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

private const val TAG = "MessagingViewModel"

/**
 * ViewModel for the messaging screen.
 *
 * Follows Clean Architecture by:
 * - Using Use Cases for business logic (send/receive messages, burn, registration)
 * - Using Repositories for data access (ConversationRepository)
 * - Using Domain Services for relay/realtime communication
 * - Only handling UI state and user interactions
 */
@HiltViewModel
class MessagingViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val conversationRepository: ConversationRepository,
    private val padRepository: PadRepository,
    private val relayService: RelayService,
    private val realtimeService: RealtimeService,
    private val locationService: LocationService,
    private val sendMessageUseCase: SendMessageUseCase,
    private val receiveMessageUseCase: ReceiveMessageUseCase,
    private val registerConversationUseCase: RegisterConversationUseCase,
    private val checkBurnStatusUseCase: CheckBurnStatusUseCase
) : ViewModel() {

    private val conversationId: String = savedStateHandle["conversationId"]!!

    private val _conversation = MutableStateFlow<Conversation?>(null)
    val conversation: StateFlow<Conversation?> = _conversation.asStateFlow()

    private val _messages = MutableStateFlow<List<Message>>(emptyList())
    val messages: StateFlow<List<Message>> = _messages.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _isSending = MutableStateFlow(false)
    val isSending: StateFlow<Boolean> = _isSending.asStateFlow()

    private val _isGettingLocation = MutableStateFlow(false)
    val isGettingLocation: StateFlow<Boolean> = _isGettingLocation.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _inputText = MutableStateFlow("")
    val inputText: StateFlow<String> = _inputText.asStateFlow()

    private val _peerBurned = MutableStateFlow(false)
    val peerBurned: StateFlow<Boolean> = _peerBurned.asStateFlow()

    /** Lifetime of the next text message, chosen by its author */
    private val _lifetime = MutableStateFlow(DisappearingMessages.OFF)
    val lifetime: StateFlow<DisappearingMessages> = _lifetime.asStateFlow()

    /** Messages whose delete-for-everyone request failed: offered again */
    private val _deleteFailedIds = MutableStateFlow<Set<String>>(emptySet())
    val deleteFailedIds: StateFlow<Set<String>> = _deleteFailedIds.asStateFlow()

    private var sseJob: Job? = null
    private var pollingJob: Job? = null
    private var hasAttemptedRegistration: Boolean = false

    /** Serializes pad use: sends and receives each read and publish the latest conversation */
    private val stateLock = Mutex()

    /** Frames whose sending failed, resent as they are on retry */
    private val pendingFrames = mutableMapOf<String, EncryptedFrame>()
    private val pendingDeletes = mutableMapOf<String, EncryptedFrame>()

    // Track sent messages to filter out own message echoes from SSE
    private val sentSequences = mutableSetOf<Long>()
    private val sentBlobIds = mutableSetOf<String>()
    private val processedBlobIds = mutableSetOf<String>()

    private val logId: String get() = conversationId.take(8)

    init {
        loadConversation()
        // Any message can carry its own lifetime, so expiry always runs
        viewModelScope.launch {
            while (isActive) {
                delay(1_000)
                val now = System.currentTimeMillis()
                removeMessages { (it.expiresAt ?: Long.MAX_VALUE) <= now }
            }
        }
    }

    fun setLifetime(lifetime: DisappearingMessages) {
        _lifetime.value = lifetime
    }

    private fun loadConversation() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                when (val result = conversationRepository.getConversation(conversationId)) {
                    is AppResult.Success -> {
                        val conv = result.data
                        _conversation.value = conv
                        _lifetime.value = conv.disappearingMessages

                        if (conv.peerBurnedAt != null) {
                            _peerBurned.value = true
                        } else {
                            registerAndConnect(conv)
                        }
                    }
                    is AppResult.Error -> {
                        _error.value = "Failed to load conversation: ${result.error.message}"
                    }
                }
            } finally {
                _isLoading.value = false
            }
        }
    }

    private suspend fun registerAndConnect(conv: Conversation) {
        // Register conversation with relay (fire-and-forget)
        registerConversationUseCase(conv)

        // Start SSE and polling
        startSSE(conv)
        startPollingMessages()
        checkBurnStatus(conv)
    }

    private fun startSSE(conv: Conversation) {
        sseJob?.cancel()
        sseJob = viewModelScope.launch {
            realtimeService.connect(
                relayUrl = conv.relayUrl,
                conversationId = conversationId,
                authToken = conv.authToken
            )

            realtimeService.events.collect { event ->
                handleSSEEvent(event, conv)
            }
        }
    }

    private suspend fun handleSSEEvent(event: SSEEvent, conv: Conversation) {
        when (event) {
            is SSEEvent.Connected -> {
                Log.i(TAG, "[$logId] SSE connected")
            }
            is SSEEvent.MessageReceived -> {
                handleSSEMessage(event)
            }
            is SSEEvent.DeliveryConfirmed -> {
                Log.i(TAG, "[$logId] Delivery confirmed for ${event.blobIds.size} messages")
                event.blobIds.forEach { handleDeliveryConfirmation(it) }
            }
            is SSEEvent.BurnSignal -> {
                Log.w(TAG, "[$logId] Peer burned conversation")
                handlePeerBurn()
            }
            is SSEEvent.NotFound -> {
                Log.w(TAG, "[$logId] Conversation not found on relay")
                if (!hasAttemptedRegistration) {
                    hasAttemptedRegistration = true
                    val result = registerConversationUseCase(conv)
                    if (result is AppResult.Success && result.data) {
                        startSSE(conv)
                    }
                }
            }
            is SSEEvent.Error -> {
                Log.e(TAG, "[$logId] SSE error: ${event.message}")
            }
            else -> { /* Ignore ping, disconnected */ }
        }
    }

    private suspend fun handleSSEMessage(event: SSEEvent.MessageReceived) {
        handleIncoming(
            ReceivedMessageData(
                id = event.id,
                ciphertext = event.ciphertext,
                sequence = event.sequence,
                receivedAt = event.receivedAt
            )
        )
    }

    private fun startPollingMessages() {
        pollingJob?.cancel()
        pollingJob = viewModelScope.launch {
            val conv = _conversation.value ?: return@launch

            relayService.pollMessages(
                conversationId = conversationId,
                authToken = conv.authToken,
                cursor = conv.relayCursor,
                relayUrl = conv.relayUrl
            ).collect { result ->
                if (result.success) {
                    result.messages.forEach { received ->
                        handleIncoming(
                            ReceivedMessageData(
                                id = received.id,
                                ciphertext = received.ciphertext,
                                sequence = received.sequence,
                                receivedAt = received.receivedAt
                            )
                        )
                    }
                }
            }
        }
    }

    /**
     * One path for SSE and polling. The relay returns this phone's own frames
     * too, and they would decrypt like the peer's (same pad): they are skipped
     * by blob ID and sequence, and the use case checks the latest
     * conversation, read under the lock, never a copy taken earlier.
     */
    private suspend fun handleIncoming(received: ReceivedMessageData) {
        if (received.id in sentBlobIds || received.id in processedBlobIds) return
        if (received.sequence != null && received.sequence in sentSequences) {
            sentBlobIds.add(received.id)
            return
        }
        if (_messages.value.any { it.blobId == received.id }) return

        stateLock.withLock {
            val conv = _conversation.value ?: return
            when (val result = receiveMessageUseCase(conv, received)) {
                is ReceiveMessageResult.Success -> {
                    _conversation.value = result.updatedConversation
                    _messages.value = _messages.value + result.message
                    sendAck(received.id)
                }
                is ReceiveMessageResult.DeleteRequest -> {
                    // Only the peer's own messages: ours are outgoing
                    _conversation.value = result.updatedConversation
                    removeMessages { !it.isOutgoing && it.sequence == result.sequence }
                    sendAck(received.id)
                }
                is ReceiveMessageResult.Ignored -> {
                    _conversation.value = result.updatedConversation
                    sendAck(received.id)
                }
                is ReceiveMessageResult.Skipped -> {
                    Log.d(TAG, "[$logId] Message skipped: ${result.reason}")
                }
                is ReceiveMessageResult.Error -> {
                    Log.e(TAG, "[$logId] Message processing failed: ${result.error.message}")
                }
            }
        }
        processedBlobIds.add(received.id)
    }

    private fun handleDeliveryConfirmation(messageId: String) {
        _messages.value = _messages.value.map { msg ->
            if (msg.blobId == messageId) {
                msg.withDeliveryStatus(DeliveryStatus.DELIVERED)
            } else {
                msg
            }
        }
    }

    private fun handlePeerBurn() {
        _peerBurned.value = true
        viewModelScope.launch {
            val conv = _conversation.value ?: return@launch
            conversationRepository.markPeerBurned(conv.id, System.currentTimeMillis())
            _conversation.value = conv.copy(peerBurnedAt = System.currentTimeMillis())
        }
    }

    private suspend fun checkBurnStatus(conv: Conversation) {
        when (val result = checkBurnStatusUseCase(conv)) {
            is AppResult.Success -> {
                if (result.data.burned) {
                    handlePeerBurn()
                }
            }
            is AppResult.Error -> {
                Log.w(TAG, "[$logId] Failed to check burn status: ${result.error.message}")
            }
        }
    }

    private suspend fun sendAck(messageId: String) {
        val conv = _conversation.value ?: return
        relayService.acknowledgeMessages(
            conversationId = conversationId,
            authToken = conv.authToken,
            blobIds = listOf(messageId),
            relayUrl = conv.relayUrl
        )
    }

    fun setInputText(text: String) {
        _inputText.value = text
    }

    fun sendMessage() {
        val text = _inputText.value.trim()
        if (text.isEmpty()) return

        val content = MessageContent.Text(text)
        sendMessageContent(content)
        _inputText.value = ""
    }

    fun sendLocation() {
        viewModelScope.launch {
            _isGettingLocation.value = true
            try {
                val result = locationService.getCurrentLocation()
                result.onSuccess { locationResult ->
                    val content = MessageContent.Location(locationResult.latitude, locationResult.longitude)
                    sendMessageContent(content)
                }.onFailure { e ->
                    _error.value = when (e) {
                        is LocationError.PermissionDenied -> "Location permission required"
                        is LocationError.Unavailable -> "Location unavailable"
                        else -> "Failed to get location: ${e.message}"
                    }
                }
            } finally {
                _isGettingLocation.value = false
            }
        }
    }

    private fun sendMessageContent(content: MessageContent) {
        viewModelScope.launch {
            _isSending.value = true
            try {
                val lifetimeSeconds = if (content is MessageContent.Text) _lifetime.value.seconds else null
                // Pad consumption under the lock, published at once: a frame
                // echoed back by the relay is recognized as ours
                val prepared = stateLock.withLock {
                    val conv = _conversation.value ?: return@launch
                    when (val result = sendMessageUseCase.prepare(conv, content, lifetimeSeconds)) {
                        is AppResult.Error -> {
                            _error.value = result.error.message
                            Log.e(TAG, "[$logId] Send failed: ${result.error.message}")
                            return@launch
                        }
                        is AppResult.Success -> result.data.also {
                            _conversation.value = it.frame.updatedConversation
                            sentSequences.add(it.frame.sequence)
                            pendingFrames[it.message.id] = it.frame
                            _messages.value = _messages.value + it.message
                        }
                    }
                }
                submit(prepared.message.id, prepared.frame)
            } catch (e: Exception) {
                _error.value = "Failed to send message: ${e.message}"
                Log.e(TAG, "[$logId] Send exception: ${e.message}", e)
            } finally {
                _isSending.value = false
            }
        }
    }

    /** Send a prepared frame; on failure the message offers a retry with the same frame. */
    private suspend fun submit(messageId: String, frame: EncryptedFrame) {
        val conv = _conversation.value ?: return
        when (val result = sendMessageUseCase.submit(conv, frame)) {
            is AppResult.Success -> {
                sentBlobIds.add(result.data)
                pendingFrames.remove(messageId)
                updateMessage(messageId) { it.copy(status = DeliveryStatus.SENT, blobId = result.data) }
                Log.i(TAG, "[$logId] Message sent: blobId=${result.data.take(8)}")
            }
            is AppResult.Error -> {
                updateMessage(messageId) { it.withDeliveryStatus(DeliveryStatus.FAILED(result.error.message)) }
                _error.value = result.error.message
                Log.e(TAG, "[$logId] Send failed: ${result.error.message}")
            }
        }
    }

    private fun updateMessage(id: String, change: (Message) -> Message) {
        _messages.value = _messages.value.map { if (it.id == id) change(it) else it }
    }

    // Deletion

    /** Remove the message from this phone only, and wipe its pad bytes. */
    fun deleteForMe(message: Message) {
        removeMessages { it.id == message.id }
    }

    /** Only the author can ask the other phone to delete a message; a failed request is offered again. */
    fun canDeleteForEveryone(message: Message): Boolean =
        message.isOutgoing && message.sequence != null &&
            (message.status == DeliveryStatus.SENT || message.status == DeliveryStatus.DELIVERED)

    /**
     * A request: a modified app or an earlier screenshot can keep the message.
     * The message stays until the relay accepts the request; a retry sends the
     * same frame again.
     */
    fun deleteForEveryone(message: Message) {
        val sequence = message.sequence ?: return
        if (!canDeleteForEveryone(message)) return
        viewModelScope.launch {
            val frame = pendingDeletes[message.id] ?: stateLock.withLock {
                val conv = _conversation.value ?: return@launch
                when (val result = sendMessageUseCase.prepareDelete(conv, sequence)) {
                    is AppResult.Error -> {
                        _error.value = result.error.message
                        return@launch
                    }
                    is AppResult.Success -> result.data.also {
                        _conversation.value = it.updatedConversation
                        sentSequences.add(it.sequence)
                        pendingDeletes[message.id] = it
                    }
                }
            }
            val conv = _conversation.value ?: return@launch
            when (val result = sendMessageUseCase.submit(conv, frame)) {
                is AppResult.Success -> {
                    sentBlobIds.add(result.data)
                    pendingDeletes.remove(message.id)
                    _deleteFailedIds.value = _deleteFailedIds.value - message.id
                    deleteForMe(message)
                }
                is AppResult.Error -> {
                    _deleteFailedIds.value = _deleteFailedIds.value + message.id
                    _error.value = result.error.message
                }
            }
        }
    }

    private fun removeMessages(predicate: (Message) -> Boolean) {
        val removed = _messages.value.filter(predicate)
        if (removed.isEmpty()) return
        _messages.value = _messages.value.filterNot(predicate)
        // Zero exactly the bytes these messages used, so a later pad
        // compromise cannot decrypt them; wiping more could zero the key of a
        // message not decrypted yet
        viewModelScope.launch {
            removed.forEach { message ->
                val sequence = message.sequence ?: return@forEach
                val length = message.padLength ?: return@forEach
                padRepository.zeroPadBytes(conversationId, sequence, length.toInt())
            }
        }
    }

    fun clearError() {
        _error.value = null
    }

    /** Send the same frame again: same keys, same lifetime, no pad reused. */
    fun retryMessage(messageId: String) {
        val message = _messages.value.find { it.id == messageId } ?: return
        if (!message.status.isFailed) return
        val frame = pendingFrames[messageId] ?: return
        updateMessage(messageId) { it.withDeliveryStatus(DeliveryStatus.SENDING) }
        viewModelScope.launch { submit(messageId, frame) }
    }

    val padUsagePercentage: Float
        get() {
            val conv = _conversation.value ?: return 0f
            val total = conv.padTotalSize
            if (total == 0L) return 0f
            return ((conv.padConsumedFront + conv.padConsumedBack).toFloat() / total) * 100
        }

    val remainingBytes: Long
        get() {
            val conv = _conversation.value ?: return 0L
            return conv.padTotalSize - conv.padConsumedFront - conv.padConsumedBack
        }

    override fun onCleared() {
        super.onCleared()
        sseJob?.cancel()
        pollingJob?.cancel()
        realtimeService.disconnect()
    }
}
