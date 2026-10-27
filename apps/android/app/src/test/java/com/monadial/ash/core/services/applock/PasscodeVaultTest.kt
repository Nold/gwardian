package com.monadial.ash.core.services.applock

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Nested
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

/** In-memory vault key store; the code copy opens only with the same code. */
class FakeVaultKeyStore : VaultKeyStore {
    private var codeCopy: Pair<ByteArray, String>? = null
    private var biometricCopy: ByteArray? = null
    var biometricsFail = false

    override val hasCodeCopy get() = codeCopy != null
    override val hasBiometricCopy get() = biometricCopy != null

    override fun storeCodeCopy(key: ByteArray, code: String) {
        codeCopy = key.copyOf() to code
    }

    override fun loadCodeCopy(code: String): ByteArray {
        val (key, stored) = codeCopy ?: throw VaultKeyStoreException.NotFound()
        if (stored != code) throw VaultKeyStoreException.WrongCode()
        return key.copyOf()
    }

    override suspend fun storeBiometricCopy(key: ByteArray, authenticate: BiometricAuthenticator) {
        biometricCopy = key.copyOf()
    }

    override suspend fun loadBiometricCopy(authenticate: BiometricAuthenticator): ByteArray {
        val copy = biometricCopy
        if (copy == null || biometricsFail) throw VaultKeyStoreException.BiometricsUnavailable()
        return copy.copyOf()
    }

    override fun deleteBiometricCopy() {
        biometricCopy = null
    }

    override fun deleteAll() {
        codeCopy = null
        biometricCopy = null
    }
}

class FakeLockAttemptStore : LockAttemptStore {
    var state = LockAttemptState()
    override fun load() = state
    override fun save(state: LockAttemptState) {
        this.state = state
    }
}

private val noPrompt: BiometricAuthenticator = { it }

@DisplayName("App lock")
class PasscodeVaultTest {
    private val store = FakeVaultKeyStore()
    private val attempts = FakeLockAttemptStore()
    private var now = 1_800_000_000_000L
    private val vault = PasscodeVault(store, attempts, clock = { now })

    /** Enter a wrong code, waiting out any delay first. */
    private fun failOnce() {
        attempts.state.retryAtMillis(now)?.let { now = it }
        runCatching { vault.unlock("000000") }
    }

    private fun configuredAndLocked() {
        vault.configure("123456")
        vault.lock()
    }

    @Nested
    @DisplayName("Policy")
    inner class Policy {
        @Test
        fun `valid and invalid codes`() {
            assertThat(LockPolicy.isValidCode("123456")).isTrue()
            assertThat(LockPolicy.isValidCode("000000")).isTrue()
            listOf("", "12345", "1234567", "12a456", "12 456", "١٢٣٤٥٦").forEach {
                assertThat(LockPolicy.isValidCode(it)).isFalse()
            }
        }

        @Test
        fun `delays follow the table`() {
            assertThat((0..9).map { LockPolicy.delayMillis(it) / 1000 })
                .containsExactly(0L, 0L, 0L, 0L, 0L, 30L, 60L, 300L, 900L, 3600L).inOrder()
            assertThat(LockPolicy.delayMillis(25)).isEqualTo(3_600_000L)
        }

        @Test
        fun `retry time and attempts left`() {
            val state = LockAttemptState(failures = 5, lastFailureMillis = 1000)
            assertThat(state.retryAtMillis(11_000)).isEqualTo(31_000)
            assertThat(state.retryAtMillis(31_000)).isNull()
            assertThat(LockAttemptState(failures = 3).attemptsBeforeErase).isNull()
            assertThat(LockAttemptState(failures = 3, eraseAfterFailures = true).attemptsBeforeErase).isEqualTo(7)
            assertThat(LockAttemptState(failures = 12, eraseAfterFailures = true).attemptsBeforeErase).isEqualTo(0)
        }
    }

    @Nested
    @DisplayName("Code")
    inner class Code {
        @Test
        fun `configure unlocks the vault`() {
            assertThat(vault.isConfigured).isFalse()
            vault.configure("123456")
            assertThat(vault.isConfigured).isTrue()
            assertThat(vault.isUnlocked).isTrue()
        }

        @Test
        fun `configure rejects invalid code and second setup`() {
            assertThrows<PasscodeVaultException.InvalidCode> { vault.configure("1234") }
            vault.configure("123456")
            assertThrows<PasscodeVaultException.AlreadyConfigured> { vault.configure("654321") }
        }

        @Test
        fun `unlock before setup fails`() {
            assertThrows<PasscodeVaultException.NotConfigured> { vault.unlock("123456") }
        }

        @Test
        fun `lock and unlock with code`() {
            vault.configure("123456")
            val sealed = vault.seal("pad".toByteArray())
            vault.lock()
            assertThat(vault.isUnlocked).isFalse()
            assertThrows<PasscodeVaultException.Locked> { vault.open(sealed) }

            vault.unlock("123456")
            assertThat(String(vault.open(sealed))).isEqualTo("pad")
        }

        @Test
        fun `wrong code counts failures`() {
            configuredAndLocked()
            val error = assertThrows<PasscodeVaultException.WrongCode> { vault.unlock("111111") }
            assertThat(error.attemptsBeforeErase).isNull()
            assertThat(vault.isUnlocked).isFalse()
            assertThat(attempts.state.failures).isEqualTo(1)
        }

        @Test
        fun `correct code resets failures`() {
            configuredAndLocked()
            repeat(3) { failOnce() }
            vault.unlock("123456")
            assertThat(attempts.state.failures).isEqualTo(0)
            assertThat(attempts.state.lastFailureMillis).isNull()
        }

        @Test
        fun `fifth wrong code imposes a delay even for the right code`() {
            configuredAndLocked()
            repeat(5) { failOnce() }
            val error = assertThrows<PasscodeVaultException.RetryLater> { vault.unlock("123456") }
            assertThat(error.untilMillis).isEqualTo(now + 30_000)
            assertThat(attempts.state.failures).isEqualTo(5)

            now += 30_000
            vault.unlock("123456")
            assertThat(vault.isUnlocked).isTrue()
        }

        @Test
        fun `change code keeps the vault key`() {
            vault.configure("123456")
            val sealed = vault.seal("pad".toByteArray())
            vault.changeCode("123456", "654321")
            vault.lock()

            assertThrows<PasscodeVaultException.WrongCode> { vault.unlock("123456") }
            vault.unlock("654321")
            assertThat(String(vault.open(sealed))).isEqualTo("pad")
        }

        @Test
        fun `change code needs the current code`() {
            vault.configure("123456")
            assertThrows<PasscodeVaultException.WrongCode> { vault.changeCode("111111", "654321") }
            assertThrows<PasscodeVaultException.InvalidCode> { vault.changeCode("123456", "12") }
        }
    }

    @Nested
    @DisplayName("Erase option")
    inner class Erase {
        @Test
        fun `ten wrong codes without the option keep everything`() {
            configuredAndLocked()
            repeat(12) { failOnce() }
            assertThat(vault.isConfigured).isTrue()
            now += 3_600_000
            vault.unlock("123456")
        }

        @Test
        fun `ten wrong codes with the option erase everything`() = runTest {
            var erased = false
            vault.onErase = { erased = true }
            vault.configure("123456")
            vault.setEraseAfterFailures(true)
            vault.setBiometricUnlock(true, noPrompt)
            vault.lock()

            repeat(9) { failOnce() }
            assertThat(vault.isConfigured).isTrue()
            assertThat(attempts.state.attemptsBeforeErase).isEqualTo(1)

            now += 3_600_000
            assertThrows<PasscodeVaultException.Erased> { vault.unlock("000000") }
            assertThat(vault.isConfigured).isFalse()
            assertThat(vault.isBiometricUnlockEnabled).isFalse()
            assertThat(vault.isUnlocked).isFalse()
            assertThat(erased).isTrue()
            assertThat(attempts.state).isEqualTo(LockAttemptState())
        }

        @Test
        fun `wrong code reports attempts left`() {
            vault.configure("123456")
            vault.setEraseAfterFailures(true)
            vault.lock()
            val error = assertThrows<PasscodeVaultException.WrongCode> { vault.unlock("111111") }
            assertThat(error.attemptsBeforeErase).isEqualTo(9)
        }

        @Test
        fun `option requires an unlocked vault`() {
            configuredAndLocked()
            assertThrows<PasscodeVaultException.Locked> { vault.setEraseAfterFailures(true) }
        }
    }

    @Nested
    @DisplayName("Biometrics")
    inner class Biometrics {
        @Test
        fun `biometric unlock`() = runTest {
            vault.configure("123456")
            val sealed = vault.seal("pad".toByteArray())
            vault.setBiometricUnlock(true, noPrompt)
            assertThat(vault.isBiometricUnlockEnabled).isTrue()
            vault.lock()

            vault.unlockWithBiometrics(noPrompt)
            assertThat(String(vault.open(sealed))).isEqualTo("pad")
        }

        @Test
        fun `fails when disabled or invalidated`() = runTest {
            configuredAndLocked()
            assertThrows<PasscodeVaultException.BiometricsUnavailable> { vault.unlockWithBiometrics(noPrompt) }

            vault.unlock("123456")
            vault.setBiometricUnlock(true, noPrompt)
            vault.lock()
            store.biometricsFail = true
            assertThrows<PasscodeVaultException.BiometricsUnavailable> { vault.unlockWithBiometrics(noPrompt) }
            assertThat(vault.isUnlocked).isFalse()
        }

        @Test
        fun `enabling requires an unlocked vault`() = runTest {
            configuredAndLocked()
            assertThrows<PasscodeVaultException.Locked> { vault.setBiometricUnlock(true, noPrompt) }
        }
    }

    @Nested
    @DisplayName("Sealing")
    inner class Sealing {
        @Test
        fun `sealed records are marked and authenticated`() {
            vault.configure("123456")
            val plaintext = "secret pad bytes".toByteArray()
            val sealed = vault.seal(plaintext)

            assertThat(PasscodeVault.isSealed(sealed)).isTrue()
            assertThat(PasscodeVault.isSealed(plaintext)).isFalse()

            val tampered = sealed.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }
            assertThrows<PasscodeVaultException.CorruptedRecord> { vault.open(tampered) }
            assertThrows<PasscodeVaultException.CorruptedRecord> { vault.open(plaintext) }
        }

        @Test
        fun `strings round trip`() {
            vault.configure("123456")
            val sealed = vault.sealString("{\"id\":\"é\"}")
            assertThat(PasscodeVault.isSealedString(sealed)).isTrue()
            assertThat(sealed).doesNotContain("id")
            assertThat(vault.openString(sealed)).isEqualTo("{\"id\":\"é\"}")
            assertThrows<PasscodeVaultException.CorruptedRecord> { vault.openString("GWV1:!!!") }
        }

        @Test
        fun `records from another vault do not open`() {
            val other = PasscodeVault(FakeVaultKeyStore(), FakeLockAttemptStore())
            vault.configure("123456")
            other.configure("123456")
            val sealed = vault.seal("pad".toByteArray())
            assertThrows<PasscodeVaultException.CorruptedRecord> { other.open(sealed) }
        }
    }
}
