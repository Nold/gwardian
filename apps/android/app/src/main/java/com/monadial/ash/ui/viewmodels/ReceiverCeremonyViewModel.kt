package com.monadial.ash.ui.viewmodels

import android.content.Context
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.monadial.ash.core.services.bletransfer.BlePadReceiverSession
import com.monadial.ash.core.services.bletransfer.BleTransferState
import com.monadial.ash.core.services.bletransfer.toUBytes
import com.monadial.ash.domain.services.QRCodeService
import com.monadial.ash.domain.entities.CeremonyChannel
import com.monadial.ash.domain.entities.CeremonyError
import com.monadial.ash.domain.entities.CeremonyPhase
import com.monadial.ash.domain.entities.Conversation
import com.monadial.ash.domain.entities.ConversationColor
import com.monadial.ash.domain.entities.ConversationRole
import com.monadial.ash.domain.entities.DisappearingMessages
import com.monadial.ash.domain.entities.MessageRetention
import com.monadial.ash.domain.repositories.ConversationRepository
import com.monadial.ash.domain.repositories.PadRepository
import com.monadial.ash.domain.services.CryptoService
import com.monadial.ash.domain.usecases.conversation.RegisterConversationUseCase
import com.monadial.ash.ui.state.ReceiverCeremonyUiState
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import uniffi.ash.AshException
import uniffi.ash.CeremonyMetadata
import uniffi.ash.FountainFrameReceiver
import uniffi.ash.decodeCeremonyPayload

/**
 * ViewModel for the receiver (scanner) ceremony flow.
 *
 * Follows Clean Architecture and MVVM patterns:
 * - Single UiState for all screen state
 * - Repositories for data access
 * - Domain Services for crypto operations
 * - Use Cases for business logic
 */
@HiltViewModel
class ReceiverCeremonyViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    private val qrCodeService: QRCodeService,
    private val conversationRepository: ConversationRepository,
    private val cryptoService: CryptoService,
    private val padRepository: PadRepository,
    private val registerConversationUseCase: RegisterConversationUseCase
) : ViewModel() {

    companion object {
        private const val TAG = "ReceiverCeremonyVM"
    }

    // Single consolidated UI state
    private val _uiState = MutableStateFlow(ReceiverCeremonyUiState())
    val uiState: StateFlow<ReceiverCeremonyUiState> = _uiState.asStateFlow()

    // Internal state (not exposed to UI)
    private var fountainReceiver: FountainFrameReceiver? = null
    private var receivedMetadata: CeremonyMetadata? = null
    private var receivedPad: List<UByte>? = null
    private var mnemonic: List<String> = emptyList()

    /** Bluetooth receiving session, while the channel is Bluetooth */
    private val _bleReceiver = MutableStateFlow<BlePadReceiverSession?>(null)
    val bleReceiver: StateFlow<BlePadReceiverSession?> = _bleReceiver.asStateFlow()
    private var bleJob: Job? = null

    // MARK: - Configuration

    fun setChannel(channel: CeremonyChannel) {
        _uiState.update { it.copy(channel = channel) }
    }

    fun setConversationName(name: String) {
        _uiState.update { it.copy(conversationName = name) }
    }

    fun setPassphrase(value: String) {
        _uiState.update {
            it.copy(passphrase = value, isPassphraseValid = cryptoService.validatePassphrase(value))
        }
    }

    fun setSelectedColor(color: ConversationColor) {
        _uiState.update { it.copy(selectedColor = color) }
    }

    // MARK: - Scanning

    fun startScanning() {
        val state = _uiState.value
        // Create a new fountain receiver
        fountainReceiver?.close()
        fountainReceiver = try {
            cryptoService.createFountainReceiver(passphrase = state.passphrase.trim().ifEmpty { null })
        } catch (e: Exception) {
            Log.w(TAG, "Invalid passphrase: ${e.message}")
            return
        }

        // Reset internal state
        receivedMetadata = null
        receivedPad = null
        mnemonic = emptyList()

        // Update UI state
        _uiState.update {
            it.copy(
                phase = CeremonyPhase.Scanning,
                passphraseLooksWrong = false,
                passphraseRequired = false,
                receivedBlocks = 0,
                totalBlocks = 0,
                progress = 0f
            )
        }

        Log.d(TAG, "Started scanning with new fountain receiver")
    }

    // MARK: - Bluetooth

    /** Advertise a code and wait for the other phone to send the pad. */
    fun startBluetooth() {
        val session = BlePadReceiverSession(context)
        _bleReceiver.value = session
        _uiState.update { it.copy(phase = CeremonyPhase.BluetoothTransfer) }
        bleJob?.cancel()
        bleJob = viewModelScope.launch {
            session.state.first { it is BleTransferState.Completed }
            val received = session.receivedPad
            _bleReceiver.value = null
            if (received == null) {
                _uiState.update { it.copy(phase = CeremonyPhase.Failed(CeremonyError.PAD_RECONSTRUCTION_FAILED)) }
                return@launch
            }
            try {
                val payload = decodeCeremonyPayload(received.pad.toUBytes())
                // No mnemonic step: the six words already ruled out anyone in the
                // middle, and the sealed transfer rejects any altered byte
                applyReceived(payload.metadata, payload.pad, showVerification = false)
                confirmVerification()
            } catch (e: Exception) {
                Log.e(TAG, "Invalid Bluetooth payload: ${e.message}", e)
                _uiState.update { it.copy(phase = CeremonyPhase.Failed(CeremonyError.PAD_RECONSTRUCTION_FAILED)) }
            }
        }
        session.start()
    }

    /** The six words differed: the exchange may be intercepted. */
    fun bluetoothWordsRejected() {
        stopBluetooth()
        rejectVerification()
    }

    /** Advertise a new code after a failure. */
    fun retryBluetooth() {
        _bleReceiver.value?.start()
    }

    private fun stopBluetooth() {
        bleJob?.cancel()
        bleJob = null
        _bleReceiver.value?.cancel()
        _bleReceiver.value = null
    }

    fun processScannedFrame(base64String: String) {
        val receiver = fountainReceiver ?: return
        val frameBytes = qrCodeService.decodeBase64(base64String) ?: return

        if (frameBytes.isEmpty()) return

        try {
            val isComplete = cryptoService.addFrameBytes(receiver, frameBytes)

            val uniqueBlocks = receiver.uniqueBlocksReceived().toInt()
            val sourceCount = receiver.sourceCount().toInt()
            val progress = receiver.progress().toFloat()

            _uiState.update {
                it.copy(
                    receivedBlocks = uniqueBlocks,
                    totalBlocks = sourceCount,
                    progress = progress,
                    phase = CeremonyPhase.Transferring(
                        currentFrame = uniqueBlocks,
                        totalFrames = sourceCount
                    )
                )
            }

            Log.d(TAG, "Frame processed: unique=$uniqueBlocks, sourceCount=$sourceCount, progress=${(progress * 100).toInt()}%")

            if (isComplete || receiver.isComplete()) {
                reconstructAndVerify()
            }
        } catch (e: Exception) {
            // Misread or wrong passphrase: keep scanning, but say so when
            // nothing has decoded after many frames
            Log.e(TAG, "Failed to process frame: ${e.message}", e)
            if (e is AshException.PassphraseRequired) {
                _uiState.update { it.copy(passphraseRequired = true) }
            } else if (receiver.uniqueBlocksReceived() == 0u && receiver.rejectedFrames() >= 8u) {
                _uiState.update { it.copy(passphraseLooksWrong = true) }
            }
        }
    }

    // MARK: - Reconstruction

    private fun reconstructAndVerify() {
        val receiver = fountainReceiver ?: run {
            _uiState.update { it.copy(phase = CeremonyPhase.Failed(CeremonyError.PAD_RECONSTRUCTION_FAILED)) }
            return
        }

        try {
            val result = receiver.getResult()
            if (result == null) {
                Log.e(TAG, "Receiver reported complete but getResult() returned null")
                _uiState.update { it.copy(phase = CeremonyPhase.Failed(CeremonyError.PAD_RECONSTRUCTION_FAILED)) }
                return
            }

            Log.d(TAG, "Reconstructed pad: ${result.pad.size} bytes, blocks used: ${result.blocksUsed}")
            applyReceived(result.metadata, result.pad)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to reconstruct ceremony: ${e.message}", e)
            _uiState.update { it.copy(phase = CeremonyPhase.Failed(CeremonyError.PAD_RECONSTRUCTION_FAILED)) }
        }
    }

    /** Take the settings chosen by the initiator, then show the words to compare. */
    private fun applyReceived(metadata: CeremonyMetadata, padUBytes: List<UByte>, showVerification: Boolean = true) {
        Log.d(TAG, "Metadata: ttl=${metadata.ttlSeconds}, relayUrl=${metadata.relayUrl}")

        // Extract color from notification flags
        val colorIndex = ((metadata.notificationFlags.toInt()) shr 12) and 0x0F
        val decodedColor = ConversationColor.entries.getOrElse(colorIndex) { ConversationColor.INDIGO }
        _uiState.update { it.copy(selectedColor = decodedColor) }

        logPadDebugInfo(padUBytes)

        // Generate mnemonic using FFI (takes List<UByte>)
        mnemonic = uniffi.ash.generateMnemonic(padUBytes)
        receivedMetadata = metadata
        receivedPad = padUBytes

        if (showVerification) {
            _uiState.update { it.copy(phase = CeremonyPhase.Verifying(mnemonic = mnemonic)) }
        }
    }

    private fun logPadDebugInfo(padUBytes: List<UByte>) {
        val firstBytes = padUBytes.take(16).joinToString("") { String.format("%02X", it.toInt()) }
        val lastBytes = padUBytes.takeLast(16).joinToString("") { String.format("%02X", it.toInt()) }
        Log.d(TAG, "Pad first 16 bytes: $firstBytes")
        Log.d(TAG, "Pad last 16 bytes: $lastBytes")
    }

    // MARK: - Verification

    fun confirmVerification(): Conversation? {
        val padUBytes = receivedPad ?: return null
        val metadata = receivedMetadata ?: return null
        val state = _uiState.value

        try {
            // Derive tokens using FFI directly (takes List<UByte>)
            val tokens = uniffi.ash.deriveAllTokens(padUBytes)

            val messageRetention = MessageRetention.fromSeconds(metadata.ttlSeconds.toLong())
            val disappearingMessages = DisappearingMessages.fromSeconds(metadata.disappearingMessagesSeconds.toInt())

            val conversation = Conversation(
                id = tokens.conversationId,
                name = state.conversationName.ifBlank { null },
                relayUrl = metadata.relayUrl,
                authToken = tokens.authToken,
                burnToken = tokens.burnToken,
                role = ConversationRole.RESPONDER,
                color = state.selectedColor,
                createdAt = System.currentTimeMillis(),
                padTotalSize = padUBytes.size.toLong(),
                mnemonic = mnemonic,
                messageRetention = messageRetention,
                disappearingMessages = disappearingMessages
            )

            val padBytes = padUBytes.map { it.toByte() }.toByteArray()
            viewModelScope.launch {
                conversationRepository.saveConversation(conversation)
                padRepository.storePad(conversation.id, padBytes)
                registerConversationUseCase(conversation)
            }

            _uiState.update { it.copy(phase = CeremonyPhase.Completed(conversation)) }
            return conversation
        } catch (e: Exception) {
            Log.e(TAG, "Failed to confirm verification: ${e.message}", e)
            _uiState.update { it.copy(phase = CeremonyPhase.Failed(CeremonyError.PAD_RECONSTRUCTION_FAILED)) }
            return null
        }
    }

    fun rejectVerification() {
        _uiState.update { it.copy(phase = CeremonyPhase.Failed(CeremonyError.CHECKSUM_MISMATCH)) }
    }

    // MARK: - Reset & Cancel

    fun reset() {
        cleanupResources()

        _uiState.value = ReceiverCeremonyUiState()
        receivedMetadata = null
        receivedPad = null
        mnemonic = emptyList()
    }

    fun cancel() {
        cleanupResources()
        _uiState.update { it.copy(phase = CeremonyPhase.Failed(CeremonyError.CANCELLED)) }
    }

    private fun cleanupResources() {
        fountainReceiver?.close()
        fountainReceiver = null
        stopBluetooth()
    }

    override fun onCleared() {
        super.onCleared()
        cleanupResources()
    }
}
