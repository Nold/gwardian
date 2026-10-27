package com.monadial.ash.ui.state

import android.graphics.Bitmap
import com.monadial.ash.domain.entities.CeremonyChannel
import com.monadial.ash.domain.entities.CeremonyPhase
import com.monadial.ash.domain.entities.ConsentState
import com.monadial.ash.domain.entities.ConversationColor
import com.monadial.ash.domain.entities.DisappearingMessages
import com.monadial.ash.domain.entities.MessageRetention
import com.monadial.ash.domain.entities.PadSize

/**
 * Sealed class representing connection test results.
 */
sealed class ConnectionTestResult {
    data class Success(val version: String) : ConnectionTestResult()
    data class Failure(val error: String) : ConnectionTestResult()
}

/**
 * UI state for the initiator ceremony screen.
 * Consolidates all state into a single immutable data class.
 */
data class InitiatorCeremonyUiState(
    // Phase tracking
    val phase: CeremonyPhase = CeremonyPhase.SelectingPadSize,

    // Pad configuration
    val selectedPadSize: PadSize = PadSize.MEDIUM,
    val selectedColor: ConversationColor = ConversationColor.INDIGO,
    val conversationName: String = "",
    val relayUrl: String = "",

    // Message settings
    val serverRetention: MessageRetention = MessageRetention.ONE_DAY,
    val disappearingMessages: DisappearingMessages = DisappearingMessages.OFF,

    // Consent
    val consent: ConsentState = ConsentState(),

    // Entropy collection
    val entropyProgress: Float = 0f,

    // QR display
    val currentQRBitmap: Bitmap? = null,
    val currentFrameIndex: Int = 0,
    val totalFrames: Int = 0,

    // Connection testing
    val connectionTestResult: ConnectionTestResult? = null,
    val isTestingConnection: Boolean = false,

    // Transfer channel
    val channel: CeremonyChannel = CeremonyChannel.QR_CODES,

    // Six words drawn by the app, read aloud to the other person
    val passphraseWords: List<String> = emptyList(),

    // Playback controls
    val isPaused: Boolean = false,
    val fps: Int = 7
) {
    val canProceedToOptions: Boolean
        get() = true // Pad size is always selected

    val canProceedToConsent: Boolean
        get() = relayUrl.isNotBlank()

    val canConfirmConsent: Boolean
        get() = consent.allConfirmed
}

/**
 * UI state for the receiver ceremony screen.
 */
data class ReceiverCeremonyUiState(
    // Phase tracking
    val phase: CeremonyPhase = CeremonyPhase.ConfiguringReceiver,

    // Conversation setup
    val conversationName: String = "",
    val selectedColor: ConversationColor = ConversationColor.INDIGO,

    // Scanning progress
    val receivedBlocks: Int = 0,
    val totalBlocks: Int = 0,
    val progress: Float = 0f,

    // Transfer channel
    val channel: CeremonyChannel = CeremonyChannel.QR_CODES,

    // The six words typed from the sender's phone
    val passphrase: String = "",
    val isPassphraseValid: Boolean = false,

    /** Many frames failed authentication and none decoded: words mistyped? */
    val passphraseLooksWrong: Boolean = false
) {
    val canStartScanning: Boolean
        get() = channel == CeremonyChannel.BLUETOOTH || isPassphraseValid

    val progressPercentage: Int
        get() = (progress * 100).toInt()
}

/**
 * UI state for the messaging screen.
 */
data class MessagingUiState(
    val isLoading: Boolean = false,
    val isSending: Boolean = false,
    val isGettingLocation: Boolean = false,
    val inputText: String = "",
    val peerBurned: Boolean = false,
    val error: String? = null,

    // Computed from conversation
    val padUsagePercentage: Float = 0f,
    val remainingBytes: Long = 0L
)

/**
 * UI state for the conversations list screen.
 */
data class ConversationsUiState(
    val isRefreshing: Boolean = false,
    val error: String? = null
)

/**
 * UI state for the settings screen.
 */
data class SettingsUiState(
    // Saved relay URL
    val relayUrl: String = "",
    // Edited relay URL (for UI editing)
    val editedRelayUrl: String = "",
    // Biometric settings
    val isBiometricEnabled: Boolean = false,
    val lockOnBackground: Boolean = true,
    // Connection testing
    val isTestingConnection: Boolean = false,
    val connectionTestResult: com.monadial.ash.core.services.ConnectionTestResult? = null,
    // Burn all
    val isBurningAll: Boolean = false,
    // Error
    val error: String? = null
) {
    val hasUnsavedChanges: Boolean
        get() = relayUrl != editedRelayUrl
}
