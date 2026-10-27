package com.monadial.ash.core.services.bletransfer

import com.google.common.truth.Truth.assertThat
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Nested
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import uniffi.ash.BlePacketReassembler
import uniffi.ash.SecurityLevel
import uniffi.ash.bleServiceUuid

@DisplayName("Pad transfer over BLE")
class PadTransferFlowTest {

    @Nested
    @DisplayName("BleSessionCode")
    inner class SessionCode {
        @Test
        fun `generated codes are valid and readable`() {
            repeat(50) {
                val code = BleSessionCode.generate()
                assertThat(code).hasLength(BleSessionCode.LENGTH)
                assertThat(BleSessionCode.isValid(BleSessionCode.PREFIX + code)).isTrue()
            }
        }

        @Test
        fun `invalid names are rejected`() {
            assertThat(BleSessionCode.isValid("GW-ABCI")).isFalse()
            assertThat(BleSessionCode.isValid("XX-ABCD")).isFalse()
            assertThat(BleSessionCode.isValid("GW-ABCDE")).isFalse()
            assertThat(BleSessionCode.isValid(null)).isFalse()
        }
    }

    /**
     * Run against the host build of the Rust bindings (bindings/target/release),
     * which CI builds before the unit tests; skipped when it is missing.
     */
    @Nested
    @DisplayName("Flows through the Rust core")
    inner class Flows {
        @BeforeEach
        fun requireNativeLibrary() {
            assumeTrue(runCatching { bleServiceUuid() }.isSuccess, "host Rust bindings not built")
        }

        private fun overBle(message: List<UByte>, maxPacket: Int = 182): List<UByte> {
            val outbox = BlePacketOutbox()
            outbox.enqueue(message, maxPacket)
            val reassembler = BlePacketReassembler()
            var result: List<UByte>? = null
            while (true) {
                val packet = outbox.next ?: break
                result = reassembler.push(packet.toUBytes())
                outbox.markSent()
            }
            return checkNotNull(result)
        }

        private fun List<PadTransferEvent>.sent(): List<UByte> =
            filterIsInstance<PadTransferEvent.Send>().single().message

        private fun List<PadTransferEvent>.words(): List<String>? =
            filterIsInstance<PadTransferEvent.CompareWords>().singleOrNull()?.words

        @Test
        fun `full transfer delivers the pad at Enhanced level`() {
            val pad = ByteArray(64 * 1024) { (it * 7).toByte() }
            val receiver = PadReceiverFlow()
            val sender = PadSenderFlow(overBle(receiver.offer))

            val nonce = receiver.handle(overBle(sender.response)).sent()
            val senderEvents = sender.handle(overBle(nonce))
            val receiverEvents = receiver.handle(overBle(senderEvents.sent()))

            assertThat(senderEvents.words()).hasSize(6)
            assertThat(receiverEvents.words()).isEqualTo(senderEvents.words())

            // The sender confirms first: the receiver keeps the pad sealed until it confirms too
            val sealed = sender.confirmWordsAndSeal(pad, BlePadSenderSession.LEVEL)
            assertThat(receiver.handle(overBle(sealed))).isEmpty()
            assertThat(receiver.hasSealedPad).isTrue()
            assertThat(receiver.confirmWords())
                .containsExactly(PadTransferEvent.ReceivedPad(pad, SecurityLevel.ENHANCED))
        }

        @Test
        fun `receiver confirming first opens the pad when it arrives`() {
            val receiver = PadReceiverFlow()
            val sender = PadSenderFlow(receiver.offer)
            val reveal = sender.handle(receiver.handle(sender.response).sent()).sent()
            receiver.handle(reveal)

            assertThat(receiver.confirmWords()).isEmpty()
            val sealed = sender.confirmWordsAndSeal(byteArrayOf(1, 2, 3), SecurityLevel.ENHANCED)
            assertThat(receiver.handle(sealed))
                .containsExactly(PadTransferEvent.ReceivedPad(byteArrayOf(1, 2, 3), SecurityLevel.ENHANCED))
        }

        @Test
        fun `confirming before the words is rejected`() {
            val receiver = PadReceiverFlow()
            assertThrows<PadTransferFlowException> { receiver.confirmWords() }
            val sender = PadSenderFlow(receiver.offer)
            assertThrows<PadTransferFlowException> {
                sender.confirmWordsAndSeal(byteArrayOf(1), SecurityLevel.ENHANCED)
            }
        }

        @Test
        fun `maximum level is refused over Bluetooth`() {
            val receiver = PadReceiverFlow()
            val sender = PadSenderFlow(receiver.offer)
            sender.handle(receiver.handle(sender.response).sent())
            assertThrows<Exception> { sender.confirmWordsAndSeal(byteArrayOf(1), SecurityLevel.MAXIMUM) }
        }

        @Test
        fun `outbox numbers messages and respects the packet size`() {
            val outbox = BlePacketOutbox()
            outbox.enqueue(List(100) { 7u }, 20)
            assertThat(outbox.next!!.size).isAtMost(20)
            assertThat(outbox.next!![1]).isEqualTo(0.toByte())
            assertThat(outbox.count).isGreaterThan(5)
            outbox.clear()
            outbox.enqueue(listOf(1u), 20)
            assertThat(outbox.next!![1]).isEqualTo(1.toByte())
        }
    }
}
