package com.monadial.ash.domain.entities

sealed class CeremonyPhase {
    // Role selection (shared)
    data object SelectingRole : CeremonyPhase()

    // Initiator phases
    data object SelectingPadSize : CeremonyPhase()

    data object ConfiguringOptions : CeremonyPhase()

    data object ConfirmingConsent : CeremonyPhase()

    data object CollectingEntropy : CeremonyPhase()

    data object GeneratingPad : CeremonyPhase()

    data class GeneratingQRCodes(val progress: Float, val total: Int) : CeremonyPhase()

    data class Transferring(val currentFrame: Int, val totalFrames: Int) : CeremonyPhase()

    /** Pad and settings going over Bluetooth; progress is in the BLE session */
    data object BluetoothTransfer : CeremonyPhase()

    data class Verifying(val mnemonic: List<String>) : CeremonyPhase()

    data class Completed(val conversation: Conversation) : CeremonyPhase()

    data class Failed(val error: CeremonyError) : CeremonyPhase()

    // Receiver phases
    data object ConfiguringReceiver : CeremonyPhase()

    data object Scanning : CeremonyPhase()
}

/** How the pad travels from one phone to the other */
enum class CeremonyChannel {
    /** 🔴 Maximum: QR codes, nothing goes over the air */
    QR_CODES,

    /** 🟠 Enhanced: Bluetooth, protected by a post-quantum key exchange */
    BLUETOOTH
}

enum class CeremonyError {
    CANCELLED,
    QR_GENERATION_FAILED,
    PAD_RECONSTRUCTION_FAILED,
    CHECKSUM_MISMATCH,
    PASSPHRASE_MISMATCH,
    INVALID_FRAME
}

enum class PadSize(val bytes: Long, val displayName: String, val messageEstimate: Int, val frameCount: Int) {
    TINY(32 * 1024L, "Tiny", 50, 38),
    SMALL(64 * 1024L, "Small", 100, 75),
    MEDIUM(256 * 1024L, "Medium", 500, 296),
    LARGE(512 * 1024L, "Large", 1000, 591),
    HUGE(1024 * 1024L, "Huge", 2000, 1180);

    val subtitle: String
        get() = "~$messageEstimate messages"

    val transferTime: String
        get() =
            when (this) {
                TINY -> "~10 seconds"
                SMALL -> "~15 seconds"
                MEDIUM -> "~45 seconds"
                LARGE -> "~1.5 minutes"
                HUGE -> "~3 minutes"
            }
}

data class ConsentState(
    // Environment
    val noOneWatching: Boolean = false,
    val notUnderSurveillance: Boolean = false,
    // Responsibilities
    val ethicsUnderstood: Boolean = false,
    val keysNotRecoverable: Boolean = false,
    // Limitations
    val relayMayBeUnavailable: Boolean = false,
    val relayDataNotPersisted: Boolean = false,
    val burnDestroysAll: Boolean = false
) {
    val environmentConfirmed: Boolean get() = noOneWatching && notUnderSurveillance
    val responsibilitiesConfirmed: Boolean get() = ethicsUnderstood && keysNotRecoverable
    val limitationsConfirmed: Boolean get() = relayMayBeUnavailable && relayDataNotPersisted && burnDestroysAll
    val allConfirmed: Boolean get() = environmentConfirmed && responsibilitiesConfirmed && limitationsConfirmed

    val confirmedCount: Int get() =
        listOf(
            noOneWatching,
            notUnderSurveillance,
            ethicsUnderstood,
            keysNotRecoverable,
            relayMayBeUnavailable,
            relayDataNotPersisted,
            burnDestroysAll
        ).count { it }

    val totalCount: Int get() = 7
}
