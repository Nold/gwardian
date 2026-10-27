package com.monadial.ash.core.services.bletransfer

import java.security.SecureRandom
import uniffi.ash.PadTransferReceiver
import uniffi.ash.PadTransferSender
import uniffi.ash.SecurityLevel
import uniffi.ash.splitIntoBlePackets

/**
 * Transport-independent steps of a pad transfer (docs/ble-transfer.md).
 *
 * The Bluetooth sessions feed received messages in and carry out the resulting
 * events; keeping this logic apart makes it testable without radios. Mirrors
 * the iOS PadTransferFlow so both platforms behave the same.
 */

/** Errors raised by the transfer flows, beyond those of the Rust core. */
class PadTransferFlowException(message: String) : IllegalStateException(message)

internal fun ByteArray.toUBytes(): List<UByte> = map { it.toUByte() }

internal fun List<UByte>.toBytes(): ByteArray = ByteArray(size) { this[it].toByte() }

/** Bytes from the platform's secure random number generator. */
internal object SecureBytes {
    private val random = SecureRandom()

    fun next(count: Int): List<UByte> = ByteArray(count).also(random::nextBytes).toUBytes()
}

/**
 * Short code shown on the receiver and advertised so people pick the right
 * phone. Not a secret: the six words protect the transfer.
 */
object BleSessionCode {
    const val PREFIX = "GW-"

    /** Crockford base32: no I, L, O or U, so the code is easy to read aloud. */
    const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    const val LENGTH = 4

    /** Returns the 4 code characters, without the prefix. */
    fun generate(): String =
        // 256 is a multiple of 32, so the modulo introduces no bias
        SecureBytes.next(LENGTH).joinToString("") { ALPHABET[it.toInt() % ALPHABET.length].toString() }

    fun isValid(name: String?): Boolean =
        name != null &&
            name.startsWith(PREFIX) &&
            name.length == PREFIX.length + LENGTH &&
            name.drop(PREFIX.length).all { it in ALPHABET }
}

/** What a flow asks its transport or its UI to do. */
sealed interface PadTransferEvent {
    /** Send this protocol message to the other phone. */
    data class Send(val message: List<UByte>) : PadTransferEvent

    /** Show these words; both people must confirm they match. */
    data class CompareWords(val words: List<String>) : PadTransferEvent

    /** The pad arrived and was authenticated. */
    data class ReceivedPad(val pad: ByteArray, val level: SecurityLevel) : PadTransferEvent {
        override fun equals(other: Any?): Boolean =
            other is ReceivedPad && level == other.level && pad.contentEquals(other.pad)

        override fun hashCode(): Int = 31 * pad.contentHashCode() + level.hashCode()
    }
}

/** Packets waiting to go out, one protocol message after another. */
class BlePacketOutbox {
    private var nextMessageId: UByte = 0u
    private val packets = ArrayDeque<ByteArray>()

    val next: ByteArray? get() = packets.firstOrNull()
    val count: Int get() = packets.size
    val isEmpty: Boolean get() = packets.isEmpty()

    fun enqueue(message: List<UByte>, maxPacket: Int) {
        val size = maxOf(maxPacket, MIN_PACKET_SIZE).toUInt()
        splitIntoBlePackets(message, nextMessageId, size).forEach { packets.addLast(it.toBytes()) }
        nextMessageId++
    }

    fun markSent() {
        packets.removeFirst()
    }

    fun clear() {
        packets.clear()
    }

    companion object {
        const val MIN_PACKET_SIZE = 20
    }
}

/** Receiving side: the phone getting a copy of someone's pad. */
class PadReceiverFlow {
    private enum class Step { AWAITING_RESPONSE, AWAITING_REVEAL, AWAITING_PAD, DONE }

    private val transfer = PadTransferReceiver(SecureBytes.next(32))
    val offer: List<UByte> = transfer.offer()
    private var step = Step.AWAITING_RESPONSE
    private var wordsConfirmed = false
    private var pendingSealedPad: List<UByte>? = null

    /** The sealed pad arrived and waits for this person to confirm the words. */
    val hasSealedPad: Boolean get() = pendingSealedPad != null

    fun handle(message: List<UByte>): List<PadTransferEvent> =
        when (step) {
            Step.AWAITING_RESPONSE -> {
                val nonce = transfer.onResponse(message, SecureBytes.next(32))
                step = Step.AWAITING_REVEAL
                listOf(PadTransferEvent.Send(nonce))
            }
            Step.AWAITING_REVEAL -> {
                val words = transfer.onReveal(message)
                step = Step.AWAITING_PAD
                listOf(PadTransferEvent.CompareWords(words))
            }
            Step.AWAITING_PAD -> {
                if (pendingSealedPad != null) throw PadTransferFlowException("unexpected message")
                // The sender may confirm first; keep the pad sealed until this person confirms too
                pendingSealedPad = message
                openIfReady()
            }
            Step.DONE -> throw PadTransferFlowException("unexpected message")
        }

    /** The person confirmed the words match. */
    fun confirmWords(): List<PadTransferEvent> {
        if (step != Step.AWAITING_PAD) throw PadTransferFlowException("words not shown yet")
        wordsConfirmed = true
        return openIfReady()
    }

    private fun openIfReady(): List<PadTransferEvent> {
        val sealed = pendingSealedPad
        if (!wordsConfirmed || sealed == null) return emptyList()
        pendingSealedPad = null
        step = Step.DONE
        val received = transfer.openPad(sealed)
        return listOf(PadTransferEvent.ReceivedPad(received.pad.toBytes(), received.level))
    }
}

/** Sending side: the pad owner handing over a copy. */
class PadSenderFlow(offer: List<UByte>) {
    private enum class Step { AWAITING_NONCE, AWAITING_CONFIRMATION, DONE }

    private val transfer = PadTransferSender(offer, SecureBytes.next(64), SecureBytes.next(32))
    val response: List<UByte> = transfer.response()
    private var step = Step.AWAITING_NONCE

    fun handle(message: List<UByte>): List<PadTransferEvent> {
        if (step != Step.AWAITING_NONCE) throw PadTransferFlowException("unexpected message")
        val reveal = transfer.onNonce(message)
        step = Step.AWAITING_CONFIRMATION
        return listOf(PadTransferEvent.Send(reveal.reveal), PadTransferEvent.CompareWords(reveal.words))
    }

    /** The person confirmed the words match: returns the sealed pad to send. */
    fun confirmWordsAndSeal(pad: ByteArray, level: SecurityLevel): List<UByte> {
        if (step != Step.AWAITING_CONFIRMATION) throw PadTransferFlowException("words not shown yet")
        step = Step.DONE
        return transfer.sealPad(pad.toUBytes(), level)
    }
}
