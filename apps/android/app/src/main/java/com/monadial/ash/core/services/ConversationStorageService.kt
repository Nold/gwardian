package com.monadial.ash.core.services

import android.content.Context
import androidx.core.content.edit
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.monadial.ash.core.services.applock.PasscodeVault
import com.monadial.ash.core.services.applock.PasscodeVaultException
import com.monadial.ash.domain.entities.Conversation
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Pad storage data matching iOS PadStorageData structure.
 * Stores pad bytes together with consumption state for atomic persistence.
 */
@Serializable
data class PadStorageData(val bytes: String, val consumedFront: Long, val consumedBack: Long)

@Singleton
class ConversationStorageService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val vault: PasscodeVault
) {
    private val masterKey =
        MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()

    private val encryptedPrefs =
        EncryptedSharedPreferences.create(
            context,
            "ash_conversations",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )

    private val json = Json { ignoreUnknownKeys = true }

    private val _conversations = MutableStateFlow<List<Conversation>>(emptyList())
    val conversations: StateFlow<List<Conversation>> = _conversations.asStateFlow()

    suspend fun loadConversations() {
        withContext(Dispatchers.IO) {
            val all = encryptedPrefs.all
            val loaded =
                all.mapNotNull { (key, value) ->
                    if (key.startsWith("conversation_") && value is String) {
                        try {
                            json.decodeFromString<Conversation>(readRecord(key, value))
                        } catch (e: Exception) {
                            null
                        }
                    } else {
                        null
                    }
                }.sortedByDescending { it.lastMessageAt ?: it.createdAt }
            _conversations.value = loaded
        }
    }

    suspend fun saveConversation(conversation: Conversation) {
        withContext(Dispatchers.IO) {
            val serialized = json.encodeToString(conversation)
            encryptedPrefs.edit {
                putString("conversation_${conversation.id}", vault.sealString(serialized))
            }
            loadConversations()
        }
    }

    suspend fun deleteConversation(conversationId: String) {
        withContext(Dispatchers.IO) {
            encryptedPrefs.edit {
                remove("conversation_$conversationId")
            }
            loadConversations()
        }
    }

    suspend fun getConversation(conversationId: String): Conversation? = withContext(Dispatchers.IO) {
        val serialized = readRecord("conversation_$conversationId")
        serialized?.let {
            try {
                json.decodeFromString<Conversation>(it)
            } catch (e: Exception) {
                null
            }
        }
    }

    // === Pad Storage (matching iOS PadStorageData) ===
    // Pad bytes and consumption state are stored together atomically

    /**
     * Save pad with initial state (after ceremony).
     * Matching iOS: PadManager.storePad
     */
    suspend fun savePadBytes(conversationId: String, padBytes: ByteArray) {
        withContext(Dispatchers.IO) {
            val storageData =
                PadStorageData(
                    bytes = android.util.Base64.encodeToString(padBytes, android.util.Base64.NO_WRAP),
                    consumedFront = 0,
                    consumedBack = 0
                )
            val serialized = json.encodeToString(storageData)
            encryptedPrefs.edit {
                putString("pad_$conversationId", vault.sealString(serialized))
            }
        }
    }

    /**
     * Save pad with current consumption state.
     * Matching iOS: PadManager.savePadState
     */
    suspend fun savePadState(conversationId: String, padBytes: ByteArray, consumedFront: Long, consumedBack: Long) {
        withContext(Dispatchers.IO) {
            val storageData =
                PadStorageData(
                    bytes = android.util.Base64.encodeToString(padBytes, android.util.Base64.NO_WRAP),
                    consumedFront = consumedFront,
                    consumedBack = consumedBack
                )
            val serialized = json.encodeToString(storageData)
            encryptedPrefs.edit {
                putString("pad_$conversationId", vault.sealString(serialized))
            }
        }
    }

    /**
     * Get pad bytes only (for decryption/token derivation).
     */
    suspend fun getPadBytes(conversationId: String): ByteArray? = withContext(Dispatchers.IO) {
        val serialized = readRecord("pad_$conversationId") ?: return@withContext null
        try {
            val storageData = json.decodeFromString<PadStorageData>(serialized)
            android.util.Base64.decode(storageData.bytes, android.util.Base64.NO_WRAP)
        } catch (e: Exception) {
            try {
                android.util.Base64.decode(serialized, android.util.Base64.NO_WRAP)
            } catch (ignored: Exception) {
                null
            }
        }
    }

    /**
     * Get full pad storage data (bytes + consumption state).
     * Matching iOS: PadManager.loadPad reading from Keychain
     */
    suspend fun getPadStorageData(conversationId: String): PadStorageData? = withContext(Dispatchers.IO) {
        val serialized = readRecord("pad_$conversationId") ?: return@withContext null
        try {
            json.decodeFromString<PadStorageData>(serialized)
        } catch (e: Exception) {
            try {
                val bytes = android.util.Base64.decode(serialized, android.util.Base64.NO_WRAP)
                val conversation = getConversation(conversationId)
                PadStorageData(
                    bytes = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP),
                    consumedFront = conversation?.padConsumedFront ?: 0,
                    consumedBack = conversation?.padConsumedBack ?: 0
                )
            } catch (ignored: Exception) {
                null
            }
        }
    }

    suspend fun deletePadBytes(conversationId: String) {
        withContext(Dispatchers.IO) {
            encryptedPrefs.edit {
                remove("pad_$conversationId")
            }
        }
    }

    /**
     * Update consumption state in pad storage.
     * Matching iOS: PadManager.savePadState
     */
    suspend fun updatePadConsumption(conversationId: String, consumedFront: Long, consumedBack: Long) {
        withContext(Dispatchers.IO) {
            val existing = getPadStorageData(conversationId) ?: return@withContext

            val updated =
                existing.copy(
                    consumedFront = consumedFront,
                    consumedBack = consumedBack
                )
            val serialized = json.encodeToString(updated)
            encryptedPrefs.edit {
                putString("pad_$conversationId", vault.sealString(serialized))
            }
        }
    }

    // === App lock (docs/app-lock.md) ===

    /**
     * Seal every record still stored in plaintext; run once after the app
     * code is set up. Returns how many records were sealed.
     */
    suspend fun sealLegacyRecords(): Int = withContext(Dispatchers.IO) {
        var sealed = 0
        encryptedPrefs.all.forEach { (key, value) ->
            if (value is String && !PasscodeVault.isSealedString(value)) {
                encryptedPrefs.edit(commit = true) { putString(key, vault.sealString(value)) }
                sealed++
            }
        }
        sealed
    }

    // === Sealed Records (groups) ===

    /** Store a record sealed with the vault key, like conversations. */
    suspend fun putSealed(key: String, value: String) {
        withContext(Dispatchers.IO) {
            encryptedPrefs.edit(commit = true) { putString(key, vault.sealString(value)) }
        }
    }

    suspend fun getSealed(key: String): String? = withContext(Dispatchers.IO) { readRecord(key) }

    /** Open every record whose key starts with `prefix`, skipping unreadable ones. */
    suspend fun getAllSealed(prefix: String): List<String> = withContext(Dispatchers.IO) {
        encryptedPrefs.all.mapNotNull { (key, value) ->
            if (key.startsWith(prefix) && value is String) runCatching { readRecord(key, value) }.getOrNull() else null
        }
    }

    suspend fun removeSealed(vararg keys: String) {
        withContext(Dispatchers.IO) {
            encryptedPrefs.edit(commit = true) { keys.forEach { remove(it) } }
        }
    }

    /** Delete every pad and conversation, after the vault was erased. */
    fun wipeAll() {
        encryptedPrefs.edit(commit = true) { clear() }
        _conversations.value = emptyList()
    }

    /** Drop decrypted conversations from memory when the app locks. */
    fun clearCache() {
        _conversations.value = emptyList()
    }

    private fun readRecord(key: String): String? = encryptedPrefs.getString(key, null)?.let { readRecord(key, it) }

    /** Open a sealed record; a plaintext one from before the lock is sealed now. */
    private fun readRecord(key: String, stored: String): String {
        if (PasscodeVault.isSealedString(stored)) return vault.openString(stored)
        if (!vault.isUnlocked) throw PasscodeVaultException.Locked()
        encryptedPrefs.edit { putString(key, vault.sealString(stored)) }
        return stored
    }
}
