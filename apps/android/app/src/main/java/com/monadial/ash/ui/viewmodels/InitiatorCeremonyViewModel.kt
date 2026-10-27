package com.monadial.ash.ui.viewmodels

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.monadial.ash.core.services.bletransfer.BlePadSenderSession
import com.monadial.ash.core.services.bletransfer.BleTransferState
import com.monadial.ash.core.services.bletransfer.toUBytes
import com.monadial.ash.domain.services.QRCodeService
import com.monadial.ash.domain.entities.CeremonyChannel
import com.monadial.ash.domain.entities.CeremonyError
import com.monadial.ash.domain.entities.CeremonyPhase
import com.monadial.ash.domain.entities.ConsentState
import com.monadial.ash.domain.entities.Conversation
import com.monadial.ash.domain.entities.ConversationColor
import com.monadial.ash.domain.entities.ConversationRole
import com.monadial.ash.domain.entities.DisappearingMessages
import com.monadial.ash.domain.entities.MessageRetention
import com.monadial.ash.domain.entities.PadSize
import com.monadial.ash.domain.repositories.ConversationRepository
import com.monadial.ash.domain.repositories.PadRepository
import com.monadial.ash.domain.repositories.SettingsRepository
import com.monadial.ash.domain.services.CryptoService
import com.monadial.ash.domain.services.RelayService
import com.monadial.ash.domain.usecases.conversation.RegisterConversationUseCase
import com.monadial.ash.ui.state.ConnectionTestResult
import com.monadial.ash.ui.state.InitiatorCeremonyUiState
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import java.security.SecureRandom
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.ash.CeremonyMetadata
import uniffi.ash.FountainFrameGenerator
import uniffi.ash.TransferMethod
import uniffi.ash.encodeCeremonyPayload

/**
 * ViewModel for the initiator (sender) ceremony flow.
 *
 * Follows Clean Architecture and MVVM patterns:
 * - Single UiState for all screen state (reduces compose recomposition)
 * - Repositories for data access
 * - Domain Services for crypto operations
 * - Use Cases for business logic
 */
@HiltViewModel
class InitiatorCeremonyViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    private val settingsRepository: SettingsRepository,
    private val qrCodeService: QRCodeService,
    private val conversationRepository: ConversationRepository,
    private val relayService: RelayService,
    private val cryptoService: CryptoService,
    private val padRepository: PadRepository,
    private val registerConversationUseCase: RegisterConversationUseCase
) : ViewModel() {

    companion object {
        private const val TAG = "InitiatorCeremonyVM"
        private const val FOUNTAIN_BLOCK_SIZE = 1500u
        private const val QR_CODE_SIZE = 600
        private const val ENTROPY_TARGET_BYTES = 750
        private const val DEFAULT_FPS = 7
    }

    // Single consolidated UI state
    private val _uiState = MutableStateFlow(InitiatorCeremonyUiState())
    val uiState: StateFlow<InitiatorCeremonyUiState> = _uiState.asStateFlow()

    // Internal state (not exposed to UI)
    private val collectedEntropy = mutableListOf<Byte>()
    private var generatedPadBytes: ByteArray? = null
    private var preGeneratedQRImages: List<Bitmap> = emptyList()
    private var displayJob: Job? = null
    private var mnemonic: List<String> = emptyList()
    private var fountainGenerator: FountainFrameGenerator? = null
    private var isGeneratingPad: Boolean = false

    /** Bluetooth sending session, while the channel is Bluetooth */
    private val _bleSender = MutableStateFlow<BlePadSenderSession?>(null)
    val bleSender: StateFlow<BlePadSenderSession?> = _bleSender.asStateFlow()
    private var bleJob: Job? = null

    init {
        loadInitialSettings()
        regeneratePassphrase()
    }

    private fun loadInitialSettings() {
        viewModelScope.launch {
            val relayUrl = settingsRepository.relayServerUrl.first()
            _uiState.update { it.copy(relayUrl = relayUrl) }
        }
    }

    // MARK: - Pad Size Selection

    fun selectPadSize(size: PadSize) {
        _uiState.update { it.copy(selectedPadSize = size) }
    }

    fun setChannel(channel: CeremonyChannel) {
        _uiState.update { it.copy(channel = channel) }
    }

    /** Draw new words, for instance if they were overheard. */
    fun regeneratePassphrase() {
        _uiState.update { it.copy(passphraseWords = cryptoService.generateQrPassphrase()) }
    }

    fun proceedToOptions() {
        _uiState.update { it.copy(phase = CeremonyPhase.ConfiguringOptions) }
    }

    // MARK: - Options Configuration

    fun setConversationName(name: String) {
        _uiState.update { it.copy(conversationName = name) }
    }

    fun setRelayUrl(url: String) {
        _uiState.update {
            it.copy(
                relayUrl = url,
                connectionTestResult = null
            )
        }
    }

    fun setSelectedColor(color: ConversationColor) {
        _uiState.update { it.copy(selectedColor = color) }
    }

    fun setServerRetention(retention: MessageRetention) {
        _uiState.update { it.copy(serverRetention = retention) }
    }

    fun setDisappearingMessages(setting: DisappearingMessages) {
        _uiState.update { it.copy(disappearingMessages = setting) }
    }

    fun testRelayConnection() {
        viewModelScope.launch {
            _uiState.update { it.copy(isTestingConnection = true, connectionTestResult = null) }
            try {
                val result = relayService.testConnection(_uiState.value.relayUrl)
                val testResult = if (result.success) {
                    ConnectionTestResult.Success(result.version ?: "OK")
                } else {
                    ConnectionTestResult.Failure(result.error ?: "Connection failed")
                }
                _uiState.update { it.copy(connectionTestResult = testResult) }
            } catch (e: Exception) {
                _uiState.update {
                    it.copy(connectionTestResult = ConnectionTestResult.Failure(e.message ?: "Unknown error"))
                }
            } finally {
                _uiState.update { it.copy(isTestingConnection = false) }
            }
        }
    }

    fun proceedToConsent() {
        _uiState.update { it.copy(phase = CeremonyPhase.ConfirmingConsent) }
    }

    // MARK: - Consent

    fun updateConsent(consent: ConsentState) {
        _uiState.update { it.copy(consent = consent) }
    }

    fun confirmConsent() {
        if (_uiState.value.canConfirmConsent) {
            _uiState.update { it.copy(phase = CeremonyPhase.CollectingEntropy) }
        }
    }

    // MARK: - Entropy Collection

    fun addEntropy(x: Float, y: Float) {
        if (isGeneratingPad) return

        val timestamp = System.currentTimeMillis()
        val nanoTime = System.nanoTime()

        collectedEntropy.add((x * 256).toInt().toByte())
        collectedEntropy.add((y * 256).toInt().toByte())
        collectedEntropy.add((timestamp and 0xFF).toByte())
        collectedEntropy.add(((timestamp shr 8) and 0xFF).toByte())
        collectedEntropy.add((nanoTime and 0xFF).toByte())

        val progress = minOf(1f, collectedEntropy.size / ENTROPY_TARGET_BYTES.toFloat())
        _uiState.update { it.copy(entropyProgress = progress) }

        if (progress >= 1f && !isGeneratingPad) {
            isGeneratingPad = true
            generatePad()
        }
    }

    // MARK: - Pad Generation

    private fun generatePad() {
        val entropySnapshot = collectedEntropy.toList()
        val padSize = _uiState.value.selectedPadSize.bytes.toInt()

        viewModelScope.launch {
            _uiState.update { it.copy(phase = CeremonyPhase.GeneratingPad) }

            try {
                val padBytes = withContext(Dispatchers.Default) {
                    generatePadBytes(entropySnapshot.toByteArray(), padSize)
                }
                generatedPadBytes = padBytes

                Log.d(TAG, "Generated pad: ${padBytes.size} bytes")
                logPadDebugInfo(padBytes)

                mnemonic = cryptoService.generateMnemonic(padBytes)
                Log.d(TAG, "Generated mnemonic: ${mnemonic.joinToString(" ")}")

                if (_uiState.value.channel == CeremonyChannel.BLUETOOTH) {
                    startBluetooth(padBytes)
                } else {
                    preGenerateQRCodes(padBytes)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to generate pad: ${e.message}", e)
                _uiState.update { it.copy(phase = CeremonyPhase.Failed(CeremonyError.QR_GENERATION_FAILED)) }
            }
        }
    }

    private fun generatePadBytes(entropy: ByteArray, sizeBytes: Int): ByteArray {
        val secureRandom = SecureRandom()
        val systemEntropy = ByteArray(32)
        secureRandom.nextBytes(systemEntropy)

        val combinedEntropy = entropy + systemEntropy
        val seededRandom = SecureRandom(combinedEntropy)
        return ByteArray(sizeBytes).also { seededRandom.nextBytes(it) }
    }

    private fun logPadDebugInfo(padBytes: ByteArray) {
        val firstBytes = padBytes.take(16).joinToString("") { String.format("%02X", it) }
        val lastBytes = padBytes.takeLast(16).joinToString("") { String.format("%02X", it) }
        Log.d(TAG, "Pad first 16 bytes: $firstBytes")
        Log.d(TAG, "Pad last 16 bytes: $lastBytes")

        try {
            val tokens = cryptoService.deriveAllTokens(padBytes)
            Log.d(TAG, "Derived conversation ID: ${tokens.conversationId}")
            Log.d(TAG, "Derived auth token: ${tokens.authToken.take(16)}...")
        } catch (e: Exception) {
            Log.w(TAG, "Could not derive tokens for debug: ${e.message}")
        }
    }

    private suspend fun preGenerateQRCodes(padBytes: ByteArray) {
        val state = _uiState.value

        try {
            val metadata = buildMetadata(state)

            val passphraseToUse = state.passphraseWords.joinToString(" ")

            Log.d(TAG, "Creating fountain generator: blockSize=$FOUNTAIN_BLOCK_SIZE")

            val generator = withContext(Dispatchers.Default) {
                cryptoService.createFountainGenerator(metadata, padBytes, FOUNTAIN_BLOCK_SIZE, passphraseToUse)
            }
            fountainGenerator = generator

            val sourceCount = generator.sourceCount().toInt()
            _uiState.update { it.copy(totalFrames = sourceCount) }

            Log.d(TAG, "Fountain generator created: sourceCount=$sourceCount")

            val images = generateQRImages(generator, sourceCount)

            if (images.size == sourceCount) {
                Log.d(TAG, "Successfully generated ${images.size} QR codes")
                preGeneratedQRImages = images
                _uiState.update {
                    it.copy(phase = CeremonyPhase.Transferring(currentFrame = 0, totalFrames = sourceCount))
                }
                startDisplayCycling()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to generate QR codes: ${e.message}", e)
            _uiState.update { it.copy(phase = CeremonyPhase.Failed(CeremonyError.QR_GENERATION_FAILED)) }
        }
    }

    private fun buildMetadata(state: InitiatorCeremonyUiState) = CeremonyMetadata(
        version = 1u,
        ttlSeconds = state.serverRetention.seconds.toULong(),
        disappearingMessagesSeconds = (state.disappearingMessages.seconds ?: 0).toUInt(),
        notificationFlags = buildNotificationFlags(state.selectedColor),
        transferMethod = TransferMethod.RAPTOR,
        relayUrl = state.relayUrl
    )

    // MARK: - Bluetooth

    /** Send the pad and settings over Bluetooth instead of QR codes. */
    private fun startBluetooth(padBytes: ByteArray) {
        val payload = encodeCeremonyPayload(buildMetadata(_uiState.value), padBytes.toUBytes())
        val session = BlePadSenderSession(context, ByteArray(payload.size) { payload[it].toByte() })
        _bleSender.value = session
        _uiState.update { it.copy(phase = CeremonyPhase.BluetoothTransfer) }
        bleJob?.cancel()
        bleJob = viewModelScope.launch {
            session.state.first { it is BleTransferState.Completed }
            _bleSender.value = null
            // No mnemonic step: the six words already ruled out anyone in the
            // middle, and the sealed transfer rejects any altered byte
            confirmVerification()
        }
        Log.d(TAG, "Sending pad over Bluetooth (${payload.size} bytes)")
        session.start()
    }

    /** The six words differed: the exchange may be intercepted. */
    fun bluetoothWordsRejected() {
        stopBluetooth()
        rejectVerification()
    }

    /** Start looking for the other phone again after a failure. */
    fun retryBluetooth() {
        _bleSender.value?.start()
    }

    private fun stopBluetooth() {
        bleJob?.cancel()
        bleJob = null
        _bleSender.value?.cancel()
        _bleSender.value = null
    }

    private suspend fun generateQRImages(generator: FountainFrameGenerator, sourceCount: Int): List<Bitmap> {
        val images = mutableListOf<Bitmap>()

        withContext(Dispatchers.Default) {
            for (index in 0 until sourceCount) {
                _uiState.update {
                    it.copy(
                        phase = CeremonyPhase.GeneratingQRCodes(
                            progress = (index + 1).toFloat() / sourceCount,
                            total = sourceCount
                        )
                    )
                }

                val frameBytes = cryptoService.generateFrameBytes(generator, index.toUInt())
                val bitmap = qrCodeService.generate(frameBytes, QR_CODE_SIZE)

                if (bitmap != null) {
                    images.add(bitmap)
                } else {
                    Log.e(TAG, "Failed to generate QR code for frame $index")
                    withContext(Dispatchers.Main) {
                        _uiState.update { it.copy(phase = CeremonyPhase.Failed(CeremonyError.QR_GENERATION_FAILED)) }
                    }
                    return@withContext
                }
            }
        }

        return images
    }

    private fun buildNotificationFlags(color: ConversationColor): UShort {
        val colorIndex = color.ordinal
        val flags = (colorIndex shl 12) or 0x0103
        return flags.toUShort()
    }

    // MARK: - QR Display Cycling

    private fun startDisplayCycling() {
        displayJob?.cancel()
        _uiState.update {
            it.copy(
                currentFrameIndex = 0,
                isPaused = false,
                currentQRBitmap = preGeneratedQRImages.firstOrNull()
            )
        }

        displayJob = viewModelScope.launch {
            while (isActive && preGeneratedQRImages.isNotEmpty()) {
                val delayMs = 1000L / _uiState.value.fps
                delay(delayMs)

                if (!_uiState.value.isPaused) {
                    advanceFrame()
                }
            }
        }
    }

    private fun advanceFrame() {
        val nextIndex = (_uiState.value.currentFrameIndex + 1) % preGeneratedQRImages.size
        updateFrame(nextIndex)
    }

    private fun updateFrame(index: Int) {
        val totalFrames = _uiState.value.totalFrames
        _uiState.update {
            it.copy(
                currentFrameIndex = index,
                currentQRBitmap = preGeneratedQRImages.getOrNull(index),
                phase = if (it.phase is CeremonyPhase.Transferring) {
                    CeremonyPhase.Transferring(currentFrame = index % totalFrames, totalFrames = totalFrames)
                } else it.phase
            )
        }
    }

    fun stopDisplayCycling() {
        displayJob?.cancel()
        displayJob = null
    }

    // MARK: - Playback Controls

    fun togglePause() {
        _uiState.update { it.copy(isPaused = !it.isPaused) }
    }

    fun setFps(newFps: Int) {
        _uiState.update { it.copy(fps = newFps.coerceIn(1, 10)) }
    }

    fun previousFrame() {
        if (preGeneratedQRImages.isEmpty()) return
        val current = _uiState.value.currentFrameIndex
        val prevIndex = if (current > 0) current - 1 else preGeneratedQRImages.size - 1
        updateFrame(prevIndex)
    }

    fun nextFrame() {
        if (preGeneratedQRImages.isEmpty()) return
        val nextIndex = (_uiState.value.currentFrameIndex + 1) % preGeneratedQRImages.size
        updateFrame(nextIndex)
    }

    fun firstFrame() {
        if (preGeneratedQRImages.isEmpty()) return
        updateFrame(0)
    }

    fun lastFrame() {
        if (preGeneratedQRImages.isEmpty()) return
        updateFrame(preGeneratedQRImages.size - 1)
    }

    fun resetFrames() {
        _uiState.update { it.copy(isPaused = false) }
        updateFrame(0)
    }

    // MARK: - Verification

    fun finishSending() {
        stopDisplayCycling()
        _uiState.update { it.copy(phase = CeremonyPhase.Verifying(mnemonic = mnemonic)) }
    }

    fun confirmVerification(): Conversation? {
        val padBytes = generatedPadBytes ?: return null
        val state = _uiState.value

        try {
            val tokens = cryptoService.deriveAllTokens(padBytes)

            val conversation = Conversation(
                id = tokens.conversationId,
                name = state.conversationName.ifBlank { null },
                relayUrl = state.relayUrl,
                authToken = tokens.authToken,
                burnToken = tokens.burnToken,
                role = ConversationRole.INITIATOR,
                color = state.selectedColor,
                createdAt = System.currentTimeMillis(),
                padTotalSize = padBytes.size.toLong(),
                mnemonic = mnemonic,
                messageRetention = state.serverRetention,
                disappearingMessages = state.disappearingMessages
            )

            viewModelScope.launch {
                conversationRepository.saveConversation(conversation)
                padRepository.storePad(conversation.id, padBytes)
                registerConversationUseCase(conversation)
            }

            _uiState.update { it.copy(phase = CeremonyPhase.Completed(conversation)) }
            return conversation
        } catch (e: Exception) {
            Log.e(TAG, "Failed to confirm verification: ${e.message}", e)
            _uiState.update { it.copy(phase = CeremonyPhase.Failed(CeremonyError.QR_GENERATION_FAILED)) }
            return null
        }
    }

    fun rejectVerification() {
        _uiState.update { it.copy(phase = CeremonyPhase.Failed(CeremonyError.CHECKSUM_MISMATCH)) }
    }

    // MARK: - Reset & Cancel

    fun reset() {
        stopDisplayCycling()
        cleanupResources()

        viewModelScope.launch {
            val relayUrl = settingsRepository.relayServerUrl.first()
            _uiState.value = InitiatorCeremonyUiState(
                relayUrl = relayUrl,
                passphraseWords = cryptoService.generateQrPassphrase()
            )
        }

        collectedEntropy.clear()
        generatedPadBytes = null
        preGeneratedQRImages = emptyList()
        mnemonic = emptyList()
        isGeneratingPad = false
    }

    fun cancel() {
        stopDisplayCycling()
        cleanupResources()
        _uiState.update { it.copy(phase = CeremonyPhase.Failed(CeremonyError.CANCELLED)) }
    }

    private fun cleanupResources() {
        fountainGenerator?.close()
        fountainGenerator = null
        stopBluetooth()
    }

    override fun onCleared() {
        super.onCleared()
        stopDisplayCycling()
        cleanupResources()
    }
}
