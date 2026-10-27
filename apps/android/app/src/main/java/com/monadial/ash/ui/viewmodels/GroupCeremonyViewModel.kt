package com.monadial.ash.ui.viewmodels

import android.graphics.Bitmap
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.monadial.ash.data.repositories.GroupRepository
import com.monadial.ash.domain.entities.ConversationColor
import com.monadial.ash.domain.entities.DisappearingMessages
import com.monadial.ash.domain.entities.GroupConversation
import com.monadial.ash.domain.entities.GroupMember
import com.monadial.ash.domain.entities.MessageRetention
import com.monadial.ash.domain.entities.PadSize
import com.monadial.ash.domain.repositories.SettingsRepository
import com.monadial.ash.domain.services.CryptoService
import com.monadial.ash.domain.services.QRCodeService
import com.monadial.ash.domain.services.RelayService
import dagger.hilt.android.lifecycle.HiltViewModel
import java.security.SecureRandom
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.ash.AshException
import uniffi.ash.CeremonyMetadata
import uniffi.ash.FountainFrameGenerator
import uniffi.ash.FountainFrameReceiver
import uniffi.ash.GroupMemberCard
import uniffi.ash.PadGroup
import uniffi.ash.SecurityLevel
import uniffi.ash.TransferMethod
import uniffi.ash.decodeMemberCard
import uniffi.ash.encodeMemberCard
import uniffi.ash.getMaxGroupMembers

enum class GroupRole {
    /** Member 0: chooses the settings and shows the first card */
    CREATOR,

    /** Scans the creator's card first */
    JOINER
}

sealed interface GroupStep {
    data object Setup : GroupStep
    data object CollectingEntropy : GroupStep
    data object Generating : GroupStep

    /** Showing this phone's card while the others scan it */
    data object Showing : GroupStep

    /** Scanning another member's card */
    data object Scanning : GroupStep

    /** Between turns: scan the next card, or take this phone's turn */
    data object Waiting : GroupStep
    data class Completed(val group: GroupConversation) : GroupStep
    data class Failed(val message: String) : GroupStep
}

/** A card scanned from another member, without its pad. */
data class ScannedMember(val index: Int, val name: String)

data class GroupCeremonyUiState(
    val role: GroupRole = GroupRole.CREATOR,
    val step: GroupStep = GroupStep.Setup,
    val myName: String = "",
    val memberCount: Int = 3,
    val padSize: PadSize = PadSize.MEDIUM,
    val serverRetention: MessageRetention = MessageRetention.ONE_DAY,
    val disappearingMessages: DisappearingMessages = DisappearingMessages.OFF,
    val color: ConversationColor = ConversationColor.INDIGO,
    val relayUrl: String = "",
    val isFamilyConversation: Boolean = false,
    val usesPassphrase: Boolean = true,
    val passphraseWords: List<String> = emptyList(),
    val typedPassphrase: String = "",
    val entropyProgress: Float = 0f,
    /** This phone's place, once taken */
    val me: Int? = null,
    /** Members in the group, known from the creator's card for a joiner */
    val totalMembers: Int = 0,
    val scanned: List<ScannedMember> = emptyList(),
    val scanProgress: Float = 0f,
    val passphraseRequired: Boolean = false,
    val passphraseLooksWrong: Boolean = false,
    val scanMessage: String? = null,
    val currentQRBitmap: Bitmap? = null
) {
    val trimmedName: String get() = myName.trim()

    /** Places this phone knows: its own and the scanned cards */
    val knownCount: Int get() = scanned.size + (if (me == null) 0 else 1)

    /** The smallest place not known yet: the next card to scan */
    val nextPlaceToScan: Int?
        get() = if (totalMembers == 0) 0 else (0 until totalMembers).firstOrNull { it != me && scanned.none { s -> s.index == it } }

    /** A joiner takes the next place once it scanned every earlier card */
    val canTakeTurn: Boolean
        get() = role == GroupRole.JOINER && me == null && totalMembers > 0 && scanned.size < totalMembers &&
            scanned.all { it.index < scanned.size }
}

/**
 * Group ceremony around the table (docs/group-ceremony.md): one phone shows
 * its card as QR codes and all the others scan it. A card holds the member's
 * place, name and sending pad. Each phone takes its place from the number of
 * cards it scanned. Once a phone holds every card, the group is formed.
 */
@HiltViewModel
class GroupCeremonyViewModel @Inject constructor(
    private val cryptoService: CryptoService,
    private val qrCodeService: QRCodeService,
    private val relayService: RelayService,
    private val settingsRepository: SettingsRepository,
    private val groupRepository: GroupRepository
) : ViewModel() {

    companion object {
        private const val TAG = "GroupCeremonyVM"
        private const val FOUNTAIN_BLOCK_SIZE = 1500u
        private const val QR_CODE_SIZE = 600
        private const val ENTROPY_TARGET_BYTES = 750
        private const val FPS = 8
        const val MAX_NAME_BYTES = 32
        val maxMembers: Int = getMaxGroupMembers().toInt()
    }

    private val _uiState = MutableStateFlow(GroupCeremonyUiState())
    val uiState: StateFlow<GroupCeremonyUiState> = _uiState.asStateFlow()

    private val collectedEntropy = mutableListOf<Byte>()
    private var isGenerating = false
    private val cards = mutableMapOf<Int, GroupMemberCard>()
    private var groupMetadata: CeremonyMetadata? = null
    private var ownPad: ByteArray? = null
    private var receiver: FountainFrameReceiver? = null
    private var generator: FountainFrameGenerator? = null
    private var displayJob: Job? = null

    init {
        viewModelScope.launch {
            val url = settingsRepository.getRelayUrl()
            _uiState.update { it.copy(relayUrl = url) }
        }
    }

    // MARK: - Setup

    fun begin(role: GroupRole) {
        if (_uiState.value.role == role && _uiState.value.passphraseWords.isNotEmpty()) return
        _uiState.update {
            it.copy(role = role, passphraseWords = if (role == GroupRole.CREATOR) drawWords() else emptyList())
        }
    }

    private fun drawWords(): List<String> = runCatching { cryptoService.generateQrPassphrase() }.getOrDefault(emptyList())

    fun regeneratePassphrase() = _uiState.update { it.copy(passphraseWords = drawWords()) }
    fun setName(name: String) = _uiState.update { it.copy(myName = name) }
    fun setMemberCount(count: Int) = _uiState.update { it.copy(memberCount = count.coerceIn(2, maxMembers)) }
    fun setPadSize(size: PadSize) = _uiState.update { it.copy(padSize = size) }
    fun setServerRetention(value: MessageRetention) = _uiState.update { it.copy(serverRetention = value) }
    fun setDisappearingMessages(value: DisappearingMessages) = _uiState.update { it.copy(disappearingMessages = value) }
    fun setColor(color: ConversationColor) = _uiState.update { it.copy(color = color) }
    fun setRelayUrl(url: String) = _uiState.update { it.copy(relayUrl = url) }
    fun setUsesPassphrase(enabled: Boolean) = _uiState.update { it.copy(usesPassphrase = enabled) }
    fun setTypedPassphrase(value: String) = _uiState.update { it.copy(typedPassphrase = value) }

    /** Family group: done at home, so the six words start off */
    fun setFamilyConversation(enabled: Boolean) =
        _uiState.update { it.copy(isFamilyConversation = enabled, usesPassphrase = !enabled) }

    fun canStart(state: GroupCeremonyUiState = _uiState.value): Boolean {
        val name = state.trimmedName
        if (name.isEmpty() || name.toByteArray(Charsets.UTF_8).size > MAX_NAME_BYTES) return false
        return when (state.role) {
            GroupRole.CREATOR ->
                state.memberCount in 2..maxMembers && (!state.usesPassphrase || state.passphraseWords.isNotEmpty())
            GroupRole.JOINER -> {
                val words = state.typedPassphrase.trim()
                words.isEmpty() || cryptoService.validatePassphrase(words)
            }
        }
    }

    /** Words sealing every card of this ceremony */
    private fun passphrase(state: GroupCeremonyUiState = _uiState.value): String? = when (state.role) {
        GroupRole.CREATOR -> if (state.usesPassphrase) state.passphraseWords.joinToString(" ") else null
        GroupRole.JOINER -> state.typedPassphrase.trim().ifEmpty { null }
    }

    fun start() {
        val state = _uiState.value
        if (!canStart(state)) return
        when (state.role) {
            GroupRole.CREATOR -> _uiState.update {
                it.copy(me = 0, totalMembers = it.memberCount, step = GroupStep.CollectingEntropy)
            }
            GroupRole.JOINER -> startScanning()
        }
    }

    /** Joiner: every earlier card is scanned, so this phone takes the next place. */
    fun takeTurn() {
        val state = _uiState.value
        if (!state.canTakeTurn) return
        Log.d(TAG, "Taking place ${state.scanned.size} of ${state.totalMembers}")
        _uiState.update { it.copy(me = state.scanned.size, step = GroupStep.CollectingEntropy) }
    }

    // MARK: - Entropy and Card

    fun addEntropy(x: Float, y: Float) {
        if (isGenerating || _uiState.value.step != GroupStep.CollectingEntropy) return
        val timestamp = System.currentTimeMillis()
        val nanoTime = System.nanoTime()
        collectedEntropy.add((x * 256).toInt().toByte())
        collectedEntropy.add((y * 256).toInt().toByte())
        collectedEntropy.add((timestamp and 0xFF).toByte())
        collectedEntropy.add(((timestamp shr 8) and 0xFF).toByte())
        collectedEntropy.add((nanoTime and 0xFF).toByte())
        val progress = minOf(1f, collectedEntropy.size / ENTROPY_TARGET_BYTES.toFloat())
        _uiState.update { it.copy(entropyProgress = progress) }
        if (progress >= 1f) {
            isGenerating = true
            generateCard()
        }
    }

    private fun generateCard() {
        val entropy = collectedEntropy.toByteArray()
        collectedEntropy.clear()
        viewModelScope.launch {
            val state = _uiState.value
            val me = state.me ?: return@launch
            _uiState.update { it.copy(step = GroupStep.Generating) }
            try {
                // Every pad has the creator's size
                val size = if (state.role == GroupRole.CREATOR) state.padSize.bytes.toInt() else cards[0]?.pad?.size ?: 0
                val metadata = if (state.role == GroupRole.CREATOR) creatorMetadata(state) else groupMetadata
                require(size > 0 && metadata != null) { "missing creator settings" }
                groupMetadata = metadata

                val pad = withContext(Dispatchers.Default) { generatePadBytes(entropy, size) }
                ownPad = pad
                val card = encodeMemberCard(
                    GroupMemberCard(
                        member = me.toUByte(),
                        members = state.totalMembers.toUByte(),
                        name = state.trimmedName,
                        pad = pad.map { it.toUByte() }
                    )
                )
                generator?.close()
                generator = withContext(Dispatchers.Default) {
                    cryptoService.createFountainGenerator(
                        metadata,
                        card.map { it.toByte() }.toByteArray(),
                        FOUNTAIN_BLOCK_SIZE,
                        passphrase(state)
                    )
                }
                Log.d(TAG, "Group card ready: place $me, pad ${pad.size} bytes")
                startShowing()
            } catch (e: Exception) {
                Log.e(TAG, "Group card generation failed: ${e.message}", e)
                _uiState.update { it.copy(step = GroupStep.Failed("The card could not be created. Start again.")) }
            } finally {
                isGenerating = false
            }
        }
    }

    private fun generatePadBytes(entropy: ByteArray, sizeBytes: Int): ByteArray {
        val systemEntropy = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val seededRandom = SecureRandom(entropy + systemEntropy)
        return ByteArray(sizeBytes).also { seededRandom.nextBytes(it) }
    }

    private fun creatorMetadata(state: GroupCeremonyUiState) = CeremonyMetadata(
        version = 1u,
        ttlSeconds = state.serverRetention.seconds.toULong(),
        disappearingMessagesSeconds = (state.disappearingMessages.seconds ?: 0).toUInt(),
        notificationFlags = ((state.color.ordinal shl 12) or 0x0103).toUShort(),
        transferMethod = TransferMethod.RAPTOR,
        relayUrl = state.relayUrl
    )

    // MARK: - Showing

    private fun startShowing() {
        val generator = generator ?: return
        _uiState.update { it.copy(step = GroupStep.Showing) }
        displayJob?.cancel()
        displayJob = viewModelScope.launch {
            var index = 0u
            while (isActive) {
                val bitmap = withContext(Dispatchers.Default) {
                    qrCodeService.generate(cryptoService.generateFrameBytes(generator, index), QR_CODE_SIZE)
                }
                _uiState.update { it.copy(currentQRBitmap = bitmap) }
                index++
                delay(1000L / FPS)
            }
        }
    }

    /** Show this phone's card again, for a phone that missed it. */
    fun showCardAgain() {
        if (_uiState.value.me == null || generator == null || _uiState.value.step != GroupStep.Waiting) return
        startShowing()
    }

    /** Everyone scanned this phone's card. */
    fun finishShowing() {
        stopShowing()
        advance()
    }

    private fun stopShowing() {
        displayJob?.cancel()
        displayJob = null
        _uiState.update { it.copy(currentQRBitmap = null) }
    }

    // MARK: - Scanning

    fun startScanning() {
        receiver?.close()
        receiver = try {
            cryptoService.createFountainReceiver(passphrase())
        } catch (e: Exception) {
            Log.w(TAG, "Invalid passphrase: ${e.message}")
            return
        }
        _uiState.update {
            it.copy(
                step = GroupStep.Scanning,
                scanProgress = 0f,
                passphraseRequired = false,
                passphraseLooksWrong = false,
                scanMessage = null
            )
        }
    }

    /** Back to the turn choice without a card, for instance to take a turn. */
    fun stopScanning() {
        receiver?.close()
        receiver = null
        _uiState.update { it.copy(step = GroupStep.Waiting) }
    }

    fun processScannedFrame(base64String: String) {
        if (_uiState.value.step != GroupStep.Scanning) return
        val receiver = receiver ?: return
        val frameBytes = qrCodeService.decodeBase64(base64String) ?: return
        if (frameBytes.isEmpty()) return
        try {
            val isComplete = cryptoService.addFrameBytes(receiver, frameBytes)
            _uiState.update { it.copy(scanProgress = receiver.progress().toFloat()) }
            if (isComplete || receiver.isComplete()) {
                val result = receiver.getResult() ?: return
                receiver.close()
                this.receiver = null
                accept(result.pad, result.metadata)
            }
        } catch (e: Exception) {
            if (e is AshException.PassphraseRequired) {
                _uiState.update { it.copy(passphraseRequired = true) }
            } else if (receiver.uniqueBlocksReceived() == 0u && receiver.rejectedFrames() >= 8u) {
                _uiState.update { it.copy(passphraseLooksWrong = true) }
            }
        }
    }

    private fun accept(cardBytes: List<UByte>, metadata: CeremonyMetadata) {
        val card = try {
            decodeMemberCard(cardBytes)
        } catch (e: Exception) {
            Log.w(TAG, "Invalid group card: ${e.message}")
            rescan("This is not a group card. Scan the card of the member showing it.")
            return
        }
        val problem = check(card)
        if (problem == CardProblem.PLACE_TAKEN) {
            _uiState.update { it.copy(step = GroupStep.Failed(problem.message)) }
            return
        }
        if (problem != null) {
            rescan(problem.message)
            return
        }

        val index = card.member.toInt()
        cards[index] = card
        if (index == 0) groupMetadata = metadata
        _uiState.update {
            it.copy(
                totalMembers = card.members.toInt(),
                scanned = (it.scanned + ScannedMember(index, card.name)).sortedBy { s -> s.index }
            )
        }
        Log.d(TAG, "Scanned card of place $index (${_uiState.value.knownCount}/${card.members})")
        advance()
    }

    private fun rescan(message: String) {
        startScanning()
        _uiState.update { it.copy(scanMessage = message) }
    }

    private enum class CardProblem(val message: String) {
        CREATOR_FIRST("Scan the card of the person who created the group first."),
        OTHER_GROUP("This card belongs to another group."),
        ALREADY_SCANNED("This card was already scanned. Scan the next member's card."),
        PLACE_TAKEN("Two phones took the same place. Start again on every phone, one turn at a time.")
    }

    private fun check(card: GroupMemberCard): CardProblem? {
        val state = _uiState.value
        val index = card.member.toInt()
        return when {
            // A joiner must start with the creator's card
            cards.isEmpty() && state.me == null && index != 0 -> CardProblem.CREATOR_FIRST
            state.totalMembers > 0 && card.members.toInt() != state.totalMembers -> CardProblem.OTHER_GROUP
            // Two phones took the same place at the same time
            index == state.me -> CardProblem.PLACE_TAKEN
            // Same place with another pad: two phones took the same turn
            cards[index]?.let { it.pad != card.pad } == true -> CardProblem.PLACE_TAKEN
            cards.containsKey(index) -> CardProblem.ALREADY_SCANNED
            cards[0]?.let { it.pad.size != card.pad.size } == true -> CardProblem.OTHER_GROUP
            else -> null
        }
    }

    // MARK: - Turns

    /** Form the group once every card is known, otherwise wait for the next turn. */
    private fun advance() {
        val state = _uiState.value
        if (state.me != null && state.knownCount == state.totalMembers) {
            formGroup()
        } else if (state.me == null && state.totalMembers > 0 && state.scanned.size >= state.totalMembers) {
            // Every place is taken by another phone
            _uiState.update { it.copy(step = GroupStep.Failed(CardProblem.PLACE_TAKEN.message)) }
        } else {
            _uiState.update { it.copy(step = GroupStep.Waiting) }
        }
    }

    private fun formGroup() {
        val state = _uiState.value
        val me = state.me
        val pad = ownPad
        val metadata = groupMetadata
        if (me == null || pad == null || metadata == null) {
            _uiState.update { it.copy(step = GroupStep.Failed("The group could not be created. Start again.")) }
            return
        }
        _uiState.update { it.copy(step = GroupStep.Generating) }

        viewModelScope.launch {
            try {
                val (group, members, tokens) = withContext(Dispatchers.Default) {
                    val padGroup = PadGroup(me.toUByte(), pad.map { it.toUByte() }, SecurityLevel.MAXIMUM)
                    for (card in cards.values) {
                        padGroup.addMember(card.member, card.pad, SecurityLevel.MAXIMUM)
                    }
                    val tokens = padGroup.takeRelayTokens()
                    val members = (cards.values.map { GroupMember(it.member.toInt(), it.name) } +
                        GroupMember(me, state.trimmedName)).sortedBy { it.index }
                    Triple(padGroup, members, tokens)
                }

                val conversation = GroupConversation(
                    id = tokens.conversationId,
                    authToken = tokens.authToken,
                    burnToken = tokens.burnToken,
                    relayUrl = metadata.relayUrl,
                    me = me,
                    members = members,
                    createdAt = System.currentTimeMillis(),
                    messageRetention = MessageRetention.fromSeconds(metadata.ttlSeconds.toLong()),
                    disappearingMessages = DisappearingMessages.fromSeconds(metadata.disappearingMessagesSeconds.toInt()),
                    color = ConversationColor.entries.getOrElse((metadata.notificationFlags.toInt() shr 12) and 0x0F) {
                        ConversationColor.INDIGO
                    },
                    isFamilyConversation = passphrase(state) == null
                )

                groupRepository.savePads(conversation.id, group.exportState())
                group.close()
                groupRepository.save(conversation)
                // Not fatal: the group is registered again on first use
                register(conversation)

                ownPad = null
                cards.clear()
                Log.d(TAG, "Group formed: ${members.size} members, place $me")
                _uiState.update { it.copy(step = GroupStep.Completed(conversation)) }
            } catch (e: Exception) {
                Log.e(TAG, "Group formation failed: ${e.message}", e)
                _uiState.update {
                    it.copy(step = GroupStep.Failed("The group could not be created. Start again on every phone."))
                }
            }
        }
    }

    /** Every member registers; the relay accepts the same tokens again. */
    private suspend fun register(group: GroupConversation) {
        relayService.registerConversation(
            conversationId = group.id,
            authTokenHash = relayService.hashToken(group.authToken),
            burnTokenHash = relayService.hashToken(group.burnToken),
            relayUrl = group.relayUrl,
            ttlSeconds = group.messageRetention.seconds,
            members = group.members.size
        )
    }

    // MARK: - Cancel

    fun cancel() {
        stopShowing()
        receiver?.close()
        receiver = null
        generator?.close()
        generator = null
        ownPad = null
        cards.clear()
        collectedEntropy.clear()
    }

    override fun onCleared() {
        super.onCleared()
        cancel()
    }
}
