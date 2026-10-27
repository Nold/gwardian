package com.monadial.ash.ui.screens

import android.app.Activity
import android.view.WindowManager
import android.widget.Toast
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.QrCode2
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Cloud
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.TouchApp
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.monadial.ash.domain.entities.CeremonyChannel
import com.monadial.ash.domain.entities.CeremonyError
import com.monadial.ash.domain.entities.CeremonyPhase
import com.monadial.ash.domain.entities.ConsentState
import com.monadial.ash.domain.entities.ConversationColor
import com.monadial.ash.domain.entities.DisappearingMessages
import com.monadial.ash.domain.entities.MessageRetention
import com.monadial.ash.domain.entities.PadSize
import com.monadial.ash.ui.components.EntropyCollectionView
import com.monadial.ash.ui.components.QRCodeView
import com.monadial.ash.ui.components.QRScannerView
import com.monadial.ash.ui.components.ScanProgressOverlay
import com.monadial.ash.ui.components.ceremony.BluetoothReceiveContent
import com.monadial.ash.ui.components.ceremony.BluetoothSendContent
import com.monadial.ash.ui.components.ceremony.ChannelSelector
import com.monadial.ash.ui.components.ceremony.rememberBluetoothPermissionRequest
import com.monadial.ash.ui.state.ConnectionTestResult
import com.monadial.ash.ui.viewmodels.InitiatorCeremonyViewModel
import com.monadial.ash.ui.viewmodels.ReceiverCeremonyViewModel

/**
 * Ceremony Screen - Material Design 3
 * Handles the complete key exchange ceremony flow
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CeremonyScreen(onComplete: (String) -> Unit, onCancel: () -> Unit) {
    var selectedRole by remember { mutableStateOf<CeremonyRole?>(null) }

    when (selectedRole) {
        null -> {
            RoleSelectionScreen(
                onRoleSelected = { role -> selectedRole = role },
                onCancel = onCancel
            )
        }
        CeremonyRole.INITIATOR -> {
            InitiatorCeremonyScreen(
                onComplete = onComplete,
                onCancel = { selectedRole = null }
            )
        }
        CeremonyRole.RECEIVER -> {
            ReceiverCeremonyScreen(
                onComplete = onComplete,
                onCancel = { selectedRole = null }
            )
        }
    }
}

enum class CeremonyRole {
    INITIATOR,
    RECEIVER
}

// ============================================================================
// Role Selection Screen
// ============================================================================

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RoleSelectionScreen(onRoleSelected: (CeremonyRole) -> Unit, onCancel: () -> Unit) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("New Conversation") },
                navigationIcon = {
                    IconButton(onClick = onCancel) {
                        Icon(Icons.Default.Close, contentDescription = "Cancel")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier =
            Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(modifier = Modifier.weight(0.2f))

            // Hero icon
            Surface(
                modifier = Modifier.size(96.dp),
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primaryContainer
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = Icons.Outlined.Sync,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onPrimaryContainer,
                        modifier = Modifier.size(48.dp)
                    )
                }
            }

            Spacer(modifier = Modifier.height(24.dp))

            Text(
                text = "Choose Your Role",
                style = MaterialTheme.typography.headlineMedium
            )

            Spacer(modifier = Modifier.height(8.dp))

            Text(
                text = "One device creates the conversation,\nthe other joins by scanning",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )

            Spacer(modifier = Modifier.weight(0.3f))

            // Create option
            ElevatedCard(
                onClick = { onRoleSelected(CeremonyRole.INITIATOR) },
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier =
                    Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Surface(
                        modifier = Modifier.size(48.dp),
                        shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.primaryContainer
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(
                                imageVector = Icons.Default.QrCode2,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onPrimaryContainer
                            )
                        }
                    }
                    Spacer(modifier = Modifier.width(16.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "Create",
                            style = MaterialTheme.typography.titleMedium
                        )
                        Text(
                            text = "Generate pad and display QR codes",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Surface(
                        shape = RoundedCornerShape(4.dp),
                        color = MaterialTheme.colorScheme.primary
                    ) {
                        Text(
                            text = "Initiator",
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onPrimary
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            // Join option
            ElevatedCard(
                onClick = { onRoleSelected(CeremonyRole.RECEIVER) },
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier =
                    Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Surface(
                        modifier = Modifier.size(48.dp),
                        shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.tertiaryContainer
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(
                                imageVector = Icons.Default.CameraAlt,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onTertiaryContainer
                            )
                        }
                    }
                    Spacer(modifier = Modifier.width(16.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "Join",
                            style = MaterialTheme.typography.titleMedium
                        )
                        Text(
                            text = "Scan QR codes from other device",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Surface(
                        shape = RoundedCornerShape(4.dp),
                        color = MaterialTheme.colorScheme.tertiary
                    ) {
                        Text(
                            text = "Receiver",
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onTertiary
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.weight(0.3f))
        }
    }
}

// ============================================================================
// Initiator Ceremony Screen
// ============================================================================

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun InitiatorCeremonyScreen(
    viewModel: InitiatorCeremonyViewModel = hiltViewModel(),
    onComplete: (String) -> Unit,
    onCancel: () -> Unit
) {
    // Single consolidated state collection (principal developer pattern)
    val uiState by viewModel.uiState.collectAsState()

    // Extract values for readability
    val phase = uiState.phase
    val bleSender by viewModel.bleSender.collectAsState()
    val context = LocalContext.current
    val requestBluetooth = rememberBluetoothPermissionRequest { granted ->
        if (granted) {
            viewModel.setChannel(CeremonyChannel.BLUETOOTH)
        } else {
            Toast.makeText(context, "Bluetooth permission is needed to transfer over Bluetooth", Toast.LENGTH_LONG).show()
        }
    }
    val selectedPadSize = uiState.selectedPadSize
    val selectedColor = uiState.selectedColor
    val conversationName = uiState.conversationName
    val relayUrl = uiState.relayUrl
    val serverRetention = uiState.serverRetention
    val disappearingMessages = uiState.disappearingMessages
    val consent = uiState.consent
    val entropyProgress = uiState.entropyProgress
    val currentQRBitmap = uiState.currentQRBitmap
    val currentFrameIndex = uiState.currentFrameIndex
    val totalFrames = uiState.totalFrames
    val connectionTestResult = uiState.connectionTestResult
    val isTestingConnection = uiState.isTestingConnection
    val passphraseWords = uiState.passphraseWords
    val isPaused = uiState.isPaused
    val fps = uiState.fps

    val accentColor = Color(selectedColor.toColorLong())

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("New Conversation") },
                navigationIcon = {
                    IconButton(onClick = {
                        viewModel.cancel()
                        onCancel()
                    }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { padding ->
        AnimatedContent(
            targetState = phase,
            transitionSpec = { fadeIn() togetherWith fadeOut() },
            modifier =
            Modifier
                .fillMaxSize()
                .padding(padding),
            label = "ceremony_phase",
            contentKey = { phaseToContentKey(it) }
        ) { currentPhase ->
            when (currentPhase) {
                is CeremonyPhase.SelectingPadSize -> {
                    PadSizeSelectionContent(
                        selectedSize = selectedPadSize,
                        onSizeSelected = viewModel::selectPadSize,
                        channel = uiState.channel,
                        onChannelChange = { channel ->
                            if (channel == CeremonyChannel.BLUETOOTH) {
                                requestBluetooth()
                            } else {
                                viewModel.setChannel(channel)
                            }
                        },
                        usesPassphrase = uiState.usesPassphrase,
                        onUsesPassphraseChange = viewModel::setUsesPassphrase,
                        passphraseWords = passphraseWords,
                        onRegeneratePassphrase = viewModel::regeneratePassphrase,
                        onProceed = viewModel::proceedToOptions,
                        accentColor = accentColor
                    )
                }

                is CeremonyPhase.ConfiguringOptions -> {
                    OptionsConfigurationContent(
                        conversationName = conversationName,
                        onNameChange = viewModel::setConversationName,
                        relayUrl = relayUrl,
                        onRelayUrlChange = viewModel::setRelayUrl,
                        selectedColor = selectedColor,
                        onColorChange = viewModel::setSelectedColor,
                        serverRetention = serverRetention,
                        onRetentionChange = viewModel::setServerRetention,
                        disappearingMessages = disappearingMessages,
                        onDisappearingChange = viewModel::setDisappearingMessages,
                        onTestConnection = viewModel::testRelayConnection,
                        isTestingConnection = isTestingConnection,
                        connectionTestResult = connectionTestResult,
                        onProceed = viewModel::proceedToConsent,
                        accentColor = accentColor
                    )
                }

                is CeremonyPhase.ConfirmingConsent -> {
                    ConsentContent(
                        consent = consent,
                        onConsentChange = viewModel::updateConsent,
                        onConfirm = viewModel::confirmConsent,
                        accentColor = accentColor
                    )
                }

                is CeremonyPhase.CollectingEntropy -> {
                    EntropyCollectionContent(
                        progress = entropyProgress,
                        onPointCollected = viewModel::addEntropy,
                        accentColor = accentColor
                    )
                }

                is CeremonyPhase.GeneratingPad -> {
                    LoadingContent(
                        title = "Generating Pad",
                        message = "Creating your secure one-time pad..."
                    )
                }

                is CeremonyPhase.GeneratingQRCodes -> {
                    LoadingContent(
                        title = "Preparing Transfer",
                        message = "Generating QR codes...",
                        progress = currentPhase.progress
                    )
                }

                is CeremonyPhase.Transferring -> {
                    TransferringContent(
                        bitmap = currentQRBitmap,
                        currentFrame = currentFrameIndex,
                        totalFrames = totalFrames,
                        isPaused = isPaused,
                        fps = fps,
                        onTogglePause = viewModel::togglePause,
                        onPreviousFrame = viewModel::previousFrame,
                        onNextFrame = viewModel::nextFrame,
                        onFirstFrame = viewModel::firstFrame,
                        onLastFrame = viewModel::lastFrame,
                        onReset = viewModel::resetFrames,
                        onFpsChange = viewModel::setFps,
                        onDone = viewModel::finishSending,
                        accentColor = accentColor
                    )
                }

                is CeremonyPhase.BluetoothTransfer -> {
                    bleSender?.let { session ->
                        BluetoothSendContent(
                            session = session,
                            accentColor = accentColor,
                            onWordsRejected = viewModel::bluetoothWordsRejected,
                            onRetry = viewModel::retryBluetooth
                        )
                    }
                }

                is CeremonyPhase.Verifying -> {
                    VerificationContent(
                        mnemonic = currentPhase.mnemonic,
                        conversationName = conversationName,
                        onNameChange = viewModel::setConversationName,
                        onConfirm = {
                            val conversation = viewModel.confirmVerification()
                            conversation?.let { onComplete(it.id) }
                        },
                        onReject = viewModel::rejectVerification,
                        accentColor = accentColor
                    )
                }

                is CeremonyPhase.Completed -> {
                    CompletedContent(
                        conversationId = currentPhase.conversation.id,
                        onDismiss = { onComplete(currentPhase.conversation.id) }
                    )
                }

                is CeremonyPhase.Failed -> {
                    FailedContent(
                        error = currentPhase.error,
                        onRetry = viewModel::reset,
                        onCancel = onCancel
                    )
                }

                else -> { /* Receiver phases not used here */ }
            }
        }
    }
}

// ============================================================================
// Receiver Ceremony Screen
// ============================================================================

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ReceiverCeremonyScreen(
    viewModel: ReceiverCeremonyViewModel = hiltViewModel(),
    onComplete: (String) -> Unit,
    onCancel: () -> Unit
) {
    // Single consolidated state collection (principal developer pattern)
    val uiState by viewModel.uiState.collectAsState()

    // Extract values for readability
    val phase = uiState.phase
    val bleReceiver by viewModel.bleReceiver.collectAsState()
    // Without the permissions the session reports it, with a way to retry
    val requestBluetooth = rememberBluetoothPermissionRequest { viewModel.startBluetooth() }
    val conversationName = uiState.conversationName
    val selectedColor = uiState.selectedColor
    val receivedBlocks = uiState.receivedBlocks
    val totalBlocks = uiState.totalBlocks
    val passphrase = uiState.passphrase

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("New Conversation") },
                navigationIcon = {
                    IconButton(onClick = {
                        viewModel.cancel()
                        onCancel()
                    }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { padding ->
        AnimatedContent(
            targetState = phase,
            transitionSpec = { fadeIn() togetherWith fadeOut() },
            modifier =
            Modifier
                .fillMaxSize()
                .padding(padding),
            label = "receiver_ceremony_phase",
            contentKey = { phaseToContentKey(it) }
        ) { currentPhase ->
            when (currentPhase) {
                is CeremonyPhase.ConfiguringReceiver -> {
                    ReceiverSetupContent(
                        channel = uiState.channel,
                        onChannelChange = viewModel::setChannel,
                        passphrase = passphrase,
                        passphraseValid = uiState.isPassphraseValid,
                        canStart = uiState.canStartScanning,
                        onPassphraseChange = viewModel::setPassphrase,
                        selectedColor = selectedColor,
                        onColorChange = viewModel::setSelectedColor,
                        onStartScanning = {
                            if (uiState.channel == CeremonyChannel.BLUETOOTH) {
                                requestBluetooth()
                            } else {
                                viewModel.startScanning()
                            }
                        }
                    )
                }

                is CeremonyPhase.BluetoothTransfer -> {
                    bleReceiver?.let { session ->
                        BluetoothReceiveContent(
                            session = session,
                            accentColor = Color(selectedColor.toColorLong()),
                            onWordsRejected = viewModel::bluetoothWordsRejected,
                            onRetry = viewModel::retryBluetooth
                        )
                    }
                }

                is CeremonyPhase.Scanning, is CeremonyPhase.Transferring -> {
                    ScanningContent(
                        receivedBlocks = receivedBlocks,
                        totalBlocks = totalBlocks,
                        passphraseLooksWrong = uiState.passphraseLooksWrong,
                        passphraseRequired = uiState.passphraseRequired,
                        onFrameScanned = viewModel::processScannedFrame
                    )
                }

                is CeremonyPhase.Verifying -> {
                    VerificationContent(
                        mnemonic = currentPhase.mnemonic,
                        conversationName = conversationName,
                        onNameChange = viewModel::setConversationName,
                        onConfirm = {
                            val conversation = viewModel.confirmVerification()
                            conversation?.let { onComplete(it.id) }
                        },
                        onReject = viewModel::rejectVerification,
                        accentColor = Color(selectedColor.toColorLong())
                    )
                }

                is CeremonyPhase.Completed -> {
                    CompletedContent(
                        conversationId = currentPhase.conversation.id,
                        onDismiss = { onComplete(currentPhase.conversation.id) }
                    )
                }

                is CeremonyPhase.Failed -> {
                    FailedContent(
                        error = currentPhase.error,
                        onRetry = viewModel::reset,
                        onCancel = onCancel
                    )
                }

                else -> { /* Initiator phases not used here */ }
            }
        }
    }
}

// ============================================================================
// Pad Size Selection
// ============================================================================

@Composable
private fun PadSizeSelectionContent(
    selectedSize: PadSize,
    onSizeSelected: (PadSize) -> Unit,
    channel: CeremonyChannel,
    onChannelChange: (CeremonyChannel) -> Unit,
    usesPassphrase: Boolean,
    onUsesPassphraseChange: (Boolean) -> Unit,
    passphraseWords: List<String>,
    onRegeneratePassphrase: () -> Unit,
    onProceed: () -> Unit,
    accentColor: Color
) {
    val accentContainer = accentColor.copy(alpha = 0.15f)

    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // Header
        Surface(
            modifier = Modifier.size(72.dp),
            shape = CircleShape,
            color = accentContainer
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = Icons.Default.Tune,
                    contentDescription = null,
                    tint = accentColor,
                    modifier = Modifier.size(36.dp)
                )
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        Text(
            text = "Pad Size",
            style = MaterialTheme.typography.headlineSmall
        )

        Text(
            text = "Larger pads allow more messages but take longer to transfer",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(24.dp))

        // Pad size options
        PadSize.entries.forEach { size ->
            PadSizeCard(
                size = size,
                isSelected = size == selectedSize,
                onClick = { onSizeSelected(size) },
                accentColor = accentColor
            )
            Spacer(modifier = Modifier.height(8.dp))
        }

        Spacer(modifier = Modifier.height(16.dp))

        ChannelSelector(channel = channel, onChannelChange = onChannelChange)

        Spacer(modifier = Modifier.height(16.dp))

        if (channel == CeremonyChannel.QR_CODES) {
            // Passphrase section
            OutlinedCard(
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            imageVector = Icons.Outlined.Lock,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Spacer(modifier = Modifier.width(12.dp))
                        Text(
                            text = "Protect with Six Words",
                            style = MaterialTheme.typography.titleSmall,
                            modifier = Modifier.weight(1f)
                        )
                        Switch(
                            checked = usesPassphrase,
                            onCheckedChange = onUsesPassphraseChange,
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = Color.White,
                                checkedTrackColor = accentColor,
                                checkedBorderColor = accentColor
                            )
                        )
                    }
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = if (usesPassphrase) {
                            "Read them to your contact, out of earshot of others. They encrypt the QR codes, " +
                                "so filming the screen reveals nothing."
                        } else {
                            "Without the words, anyone who films the screen during the transfer can copy the pad. " +
                                "Make sure no camera can see it."
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = if (usesPassphrase) {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        } else {
                            MaterialTheme.colorScheme.error
                        }
                    )
                    if (usesPassphrase) {
                        Spacer(modifier = Modifier.height(12.dp))
                        PassphraseWords(passphraseWords)
                        TextButton(onClick = onRegeneratePassphrase) {
                            Text("New Words", color = accentColor)
                        }
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(24.dp))

        Button(
            onClick = onProceed,
            modifier = Modifier.fillMaxWidth(),
            colors =
            ButtonDefaults.buttonColors(
                containerColor = accentColor
            )
        ) {
            Text("Continue")
        }
    }
}

@Composable
private fun PadSizeCard(size: PadSize, isSelected: Boolean, onClick: () -> Unit, accentColor: Color) {
    val accentContainer = accentColor.copy(alpha = 0.15f)
    val containerColor =
        if (isSelected) {
            accentContainer
        } else {
            MaterialTheme.colorScheme.surfaceVariant
        }

    Card(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = containerColor),
        border =
        if (isSelected) {
            androidx.compose.foundation.BorderStroke(2.dp, accentColor)
        } else {
            null
        }
    ) {
        Row(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = size.displayName,
                    style = MaterialTheme.typography.titleMedium
                )
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.ChatBubbleOutline,
                            contentDescription = null,
                            modifier = Modifier.size(14.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            text = "~${size.messageEstimate} msgs",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.QrCode2,
                            contentDescription = null,
                            modifier = Modifier.size(14.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            text = "${size.frameCount} frames",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
            RadioButton(
                selected = isSelected,
                onClick = onClick,
                colors =
                RadioButtonDefaults.colors(
                    selectedColor = accentColor,
                    unselectedColor = MaterialTheme.colorScheme.onSurfaceVariant
                )
            )
        }
    }
}

// ============================================================================
// Options Configuration
// ============================================================================

@OptIn(ExperimentalLayoutApi::class)
@Suppress("UnusedParameter")
@Composable
private fun OptionsConfigurationContent(
    conversationName: String,
    onNameChange: (String) -> Unit,
    relayUrl: String,
    onRelayUrlChange: (String) -> Unit,
    selectedColor: ConversationColor,
    onColorChange: (ConversationColor) -> Unit,
    serverRetention: MessageRetention,
    onRetentionChange: (MessageRetention) -> Unit,
    disappearingMessages: DisappearingMessages,
    onDisappearingChange: (DisappearingMessages) -> Unit,
    onTestConnection: () -> Unit,
    isTestingConnection: Boolean,
    connectionTestResult: ConnectionTestResult?,
    onProceed: () -> Unit,
    accentColor: Color
) {
    var showRetentionMenu by remember { mutableStateOf(false) }
    var showDisappearingMenu by remember { mutableStateOf(false) }

    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text(
            text = "Settings",
            style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier.fillMaxWidth(),
            textAlign = TextAlign.Center
        )

        Text(
            text = "Configure message handling and delivery",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )

        // Message Timing Section
        OutlinedCard(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Outlined.Schedule,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Message Timing",
                        style = MaterialTheme.typography.titleSmall
                    )
                }

                Spacer(modifier = Modifier.height(12.dp))

                // Server Retention
                Row(
                    modifier =
                    Modifier
                        .fillMaxWidth()
                        .clickable { showRetentionMenu = true }
                        .padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Server Retention", style = MaterialTheme.typography.bodyMedium)
                        Text(
                            "How long unread messages wait",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Box {
                        TextButton(
                            onClick = { showRetentionMenu = true },
                            colors = ButtonDefaults.textButtonColors(contentColor = accentColor)
                        ) {
                            Text(serverRetention.shortName)
                        }
                        DropdownMenu(
                            expanded = showRetentionMenu,
                            onDismissRequest = { showRetentionMenu = false }
                        ) {
                            MessageRetention.entries.forEach { retention ->
                                DropdownMenuItem(
                                    text = { Text(retention.displayName) },
                                    onClick = {
                                        onRetentionChange(retention)
                                        showRetentionMenu = false
                                    }
                                )
                            }
                        }
                    }
                }

                HorizontalDivider()

                // Disappearing Messages
                Row(
                    modifier =
                    Modifier
                        .fillMaxWidth()
                        .clickable { showDisappearingMenu = true }
                        .padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Disappearing Messages", style = MaterialTheme.typography.bodyMedium)
                        Text(
                            "Auto-delete after viewing",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Box {
                        TextButton(
                            onClick = { showDisappearingMenu = true },
                            colors = ButtonDefaults.textButtonColors(contentColor = accentColor)
                        ) {
                            Text(disappearingMessages.displayName)
                        }
                        DropdownMenu(
                            expanded = showDisappearingMenu,
                            onDismissRequest = { showDisappearingMenu = false }
                        ) {
                            DisappearingMessages.entries.forEach { option ->
                                DropdownMenuItem(
                                    text = { Text(option.displayName) },
                                    onClick = {
                                        onDisappearingChange(option)
                                        showDisappearingMenu = false
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }

        // Relay Server Section
        OutlinedCard(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Outlined.Cloud,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Relay Server",
                        style = MaterialTheme.typography.titleSmall
                    )
                }

                Spacer(modifier = Modifier.height(12.dp))

                OutlinedTextField(
                    value = relayUrl,
                    onValueChange = onRelayUrlChange,
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text("Server URL") }
                )

                Spacer(modifier = Modifier.height(8.dp))

                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    FilledTonalButton(
                        onClick = onTestConnection,
                        enabled = !isTestingConnection,
                        colors =
                        ButtonDefaults.filledTonalButtonColors(
                            containerColor = accentColor.copy(alpha = 0.15f),
                            contentColor = accentColor
                        )
                    ) {
                        if (isTestingConnection) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                                color = accentColor
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                        }
                        Text(if (isTestingConnection) "Testing..." else "Test Connection")
                    }

                    connectionTestResult?.let { result ->
                        when (result) {
                            is ConnectionTestResult.Success ->
                                Text("Connected", color = MaterialTheme.colorScheme.primary)
                            is ConnectionTestResult.Failure ->
                                Text("Failed", color = MaterialTheme.colorScheme.error)
                        }
                    }
                }
            }
        }

        // Conversation Color Section
        OutlinedCard(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Outlined.Palette,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Conversation Color",
                        style = MaterialTheme.typography.titleSmall
                    )
                }

                Spacer(modifier = Modifier.height(12.dp))

                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    ConversationColor.entries.forEach { color ->
                        ColorButton(
                            color = Color(color.toColorLong()),
                            isSelected = color == selectedColor,
                            onClick = { onColorChange(color) }
                        )
                    }
                }
            }
        }

        Spacer(modifier = Modifier.weight(1f))

        Button(
            onClick = onProceed,
            modifier = Modifier.fillMaxWidth(),
            colors =
            ButtonDefaults.buttonColors(
                containerColor = accentColor
            )
        ) {
            Text("Continue")
        }
    }
}

@Composable
private fun ColorButton(color: Color, isSelected: Boolean, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        modifier = Modifier.size(44.dp),
        shape = CircleShape,
        color = color,
        border =
        if (isSelected) {
            androidx.compose.foundation.BorderStroke(3.dp, MaterialTheme.colorScheme.outline)
        } else {
            null
        }
    ) {
        if (isSelected) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    Icons.Default.Check,
                    contentDescription = "Selected",
                    tint = Color.White,
                    modifier = Modifier.size(22.dp)
                )
            }
        }
    }
}

// ============================================================================
// Consent Screen
// ============================================================================

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConsentContent(
    consent: ConsentState,
    onConsentChange: (ConsentState) -> Unit,
    onConfirm: () -> Unit,
    accentColor: Color
) {
    var showEthicsSheet by remember { mutableStateOf(false) }
    val sheetState = rememberModalBottomSheetState()
    val accentContainer = accentColor.copy(alpha = 0.15f)

    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // Header
        Surface(
            modifier = Modifier.size(72.dp),
            shape = CircleShape,
            color = accentContainer
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = Icons.Default.Shield,
                    contentDescription = null,
                    tint = accentColor,
                    modifier = Modifier.size(36.dp)
                )
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        Text(
            text = "Security Verification",
            style = MaterialTheme.typography.headlineSmall
        )

        Text(
            text = "Confirm you understand before proceeding",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(modifier = Modifier.height(8.dp))

        // Progress bar
        LinearProgressIndicator(
            progress = { consent.confirmedCount.toFloat() / consent.totalCount },
            modifier =
            Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(RoundedCornerShape(2.dp)),
            color = accentColor,
            trackColor = accentContainer
        )

        Text(
            text = "${consent.confirmedCount} of ${consent.totalCount} confirmed",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(modifier = Modifier.height(16.dp))

        // Environment Section
        ConsentSection(
            title = "Environment",
            icon = Icons.Default.Warning
        ) {
            ConsentCheckItem(
                title = "No one is watching my screen",
                subtitle = "No cameras, mirrors, or people can see your display",
                checked = consent.noOneWatching,
                onCheckedChange = { onConsentChange(consent.copy(noOneWatching = it)) },
                accentColor = accentColor
            )
            ConsentCheckItem(
                title = "I am not under surveillance or coercion",
                subtitle = "Do not proceed if being forced or monitored",
                checked = consent.notUnderSurveillance,
                onCheckedChange = { onConsentChange(consent.copy(notUnderSurveillance = it)) },
                accentColor = accentColor
            )
        }

        Spacer(modifier = Modifier.height(12.dp))

        // Responsibilities Section
        ConsentSection(
            title = "Responsibilities",
            icon = Icons.Outlined.TouchApp
        ) {
            ConsentCheckItem(
                title = "I understand the ethical responsibilities",
                subtitle = "This tool is for legitimate private communication",
                checked = consent.ethicsUnderstood,
                onCheckedChange = { onConsentChange(consent.copy(ethicsUnderstood = it)) },
                accentColor = accentColor
            )
            ConsentCheckItem(
                title = "Keys cannot be recovered",
                subtitle = "If you lose access, messages are gone forever",
                checked = consent.keysNotRecoverable,
                onCheckedChange = { onConsentChange(consent.copy(keysNotRecoverable = it)) },
                accentColor = accentColor
            )
        }

        Spacer(modifier = Modifier.height(12.dp))

        // Limitations Section
        ConsentSection(
            title = "Limitations",
            icon = Icons.Default.Info
        ) {
            ConsentCheckItem(
                title = "Relay server may be unavailable",
                subtitle = "Messages won't deliver without connectivity",
                checked = consent.relayMayBeUnavailable,
                onCheckedChange = { onConsentChange(consent.copy(relayMayBeUnavailable = it)) },
                accentColor = accentColor
            )
            ConsentCheckItem(
                title = "Relay data is not persisted",
                subtitle = "Server restarts may cause unread message loss",
                checked = consent.relayDataNotPersisted,
                onCheckedChange = { onConsentChange(consent.copy(relayDataNotPersisted = it)) },
                accentColor = accentColor
            )
            ConsentCheckItem(
                title = "Burn destroys all key material",
                subtitle = "Either party can burn, it cannot be undone",
                checked = consent.burnDestroysAll,
                onCheckedChange = { onConsentChange(consent.copy(burnDestroysAll = it)) },
                accentColor = accentColor,
                icon = Icons.Default.LocalFireDepartment,
                iconTint = MaterialTheme.colorScheme.error
            )
        }

        Spacer(modifier = Modifier.height(12.dp))

        TextButton(
            onClick = { showEthicsSheet = true },
            colors = ButtonDefaults.textButtonColors(contentColor = accentColor)
        ) {
            Icon(
                imageVector = Icons.Outlined.Description,
                contentDescription = null,
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(4.dp))
            Text("Read Ethics Guidelines")
        }

        Spacer(modifier = Modifier.height(16.dp))

        Button(
            onClick = onConfirm,
            modifier = Modifier.fillMaxWidth(),
            enabled = consent.allConfirmed,
            colors =
            ButtonDefaults.buttonColors(
                containerColor = accentColor
            )
        ) {
            Text("I Understand & Proceed")
        }
    }

    if (showEthicsSheet) {
        ModalBottomSheet(
            onDismissRequest = { showEthicsSheet = false },
            sheetState = sheetState
        ) {
            EthicsGuidelinesContent(onDismiss = { showEthicsSheet = false })
        }
    }
}

@Composable
private fun ConsentSection(title: String, icon: ImageVector, content: @Composable () -> Unit) {
    OutlinedCard(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleSmall
                )
            }
            Spacer(modifier = Modifier.height(8.dp))
            content()
        }
    }
}

@Composable
private fun ConsentCheckItem(
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    accentColor: Color,
    icon: ImageVector? = null,
    iconTint: Color? = null
) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .clickable { onCheckedChange(!checked) }
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.Top
    ) {
        Checkbox(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors =
            CheckboxDefaults.colors(
                checkedColor = accentColor,
                checkmarkColor = Color.White
            )
        )
        Spacer(modifier = Modifier.width(8.dp))
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (icon != null && iconTint != null) {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = iconTint,
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(modifier = Modifier.width(4.dp))
                }
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodyMedium
                )
            }
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun EthicsGuidelinesContent(onDismiss: () -> Unit) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(24.dp)
    ) {
        Text(
            text = "Ethics Guidelines",
            style = MaterialTheme.typography.headlineSmall
        )

        Spacer(modifier = Modifier.height(16.dp))

        EthicsItem(1, "Lawful Use Only", "ASH is designed for legitimate privacy needs.")
        EthicsItem(2, "No Exploitation", "Never use ASH to exploit or harm others.")
        EthicsItem(3, "Responsible Communication", "Use ASH for genuine private communication.")
        EthicsItem(4, "Transparency with Partners", "Be honest with your communication partners.")
        EthicsItem(5, "Report Misuse", "Consider reporting harmful use of ASH.")

        Spacer(modifier = Modifier.height(24.dp))

        Button(
            onClick = onDismiss,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("I Understand")
        }

        Spacer(modifier = Modifier.height(32.dp))
    }
}

@Composable
private fun EthicsItem(number: Int, title: String, description: String) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp)
    ) {
        Surface(
            modifier = Modifier.size(28.dp),
            shape = CircleShape,
            color = MaterialTheme.colorScheme.primary
        ) {
            Box(contentAlignment = Alignment.Center) {
                Text(
                    text = number.toString(),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onPrimary
                )
            }
        }
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(text = title, style = MaterialTheme.typography.titleSmall)
            Text(
                text = description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

// ============================================================================
// Entropy Collection
// ============================================================================

@Composable
private fun EntropyCollectionContent(progress: Float, onPointCollected: (Float, Float) -> Unit, accentColor: Color) {
    val accentContainer = accentColor.copy(alpha = 0.15f)

    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = "Generate Entropy",
            style = MaterialTheme.typography.titleLarge
        )

        Text(
            text = "Draw random patterns below",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(modifier = Modifier.height(12.dp))

        // Large entropy drawing area - takes most of the screen
        EntropyCollectionView(
            progress = progress,
            onPointCollected = onPointCollected,
            accentColor = accentColor,
            modifier =
            Modifier
                .fillMaxWidth()
                .weight(1f)
        )

        Spacer(modifier = Modifier.height(12.dp))

        // Compact progress indicator
        LinearProgressIndicator(
            progress = { progress },
            modifier =
            Modifier
                .fillMaxWidth()
                .height(8.dp)
                .clip(RoundedCornerShape(4.dp)),
            color = accentColor,
            trackColor = accentContainer
        )

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            text = if (progress < 1f) "${(progress * 100).toInt()}% - Keep drawing" else "Complete!",
            style = MaterialTheme.typography.titleMedium,
            color = if (progress < 1f) MaterialTheme.colorScheme.onSurfaceVariant else accentColor
        )
    }
}

// ============================================================================
// Loading Content
// ============================================================================

@Composable
private fun LoadingContent(title: String, message: String, progress: Float? = null) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            if (progress != null) {
                CircularProgressIndicator(progress = { progress })
                Text("${(progress * 100).toInt()}%")
            } else {
                CircularProgressIndicator()
            }

            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium
            )

            Text(
                text = message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

// ============================================================================
// Transfer Content
// ============================================================================

@Composable
private fun TransferringContent(
    bitmap: android.graphics.Bitmap?,
    currentFrame: Int,
    totalFrames: Int,
    isPaused: Boolean,
    fps: Int,
    onTogglePause: () -> Unit,
    onPreviousFrame: () -> Unit,
    onNextFrame: () -> Unit,
    onFirstFrame: () -> Unit,
    onLastFrame: () -> Unit,
    onReset: () -> Unit,
    onFpsChange: (Int) -> Unit,
    onDone: () -> Unit,
    accentColor: Color
) {
    val accentContainer = accentColor.copy(alpha = 0.15f)
    val context = LocalContext.current
    DisposableEffect(Unit) {
        val window = (context as? Activity)?.window
        val originalBrightness = window?.attributes?.screenBrightness ?: -1f

        window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window?.attributes =
            window?.attributes?.apply {
                screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_FULL
            }

        onDispose {
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            window?.attributes =
                window?.attributes?.apply {
                    screenBrightness = originalBrightness
                }
        }
    }

    var showFpsMenu by remember { mutableStateOf(false) }
    val progressAnimation by animateFloatAsState(
        targetValue = if (totalFrames > 0) (currentFrame + 1).toFloat() / totalFrames else 0f,
        label = "progress"
    )

    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = "Streaming QR Codes",
            style = MaterialTheme.typography.titleLarge
        )

        Text(
            text = "Let the other device scan continuously",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(modifier = Modifier.height(16.dp))

        // Larger QR code for better scanning - 320dp display size
        QRCodeView(bitmap = bitmap, size = 320.dp)

        Spacer(modifier = Modifier.height(12.dp))

        // Progress
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = "Frame ${currentFrame + 1} of $totalFrames",
                style = MaterialTheme.typography.bodyMedium
            )
            Spacer(modifier = Modifier.height(4.dp))
            LinearProgressIndicator(
                progress = { progressAnimation },
                modifier =
                Modifier
                    .fillMaxWidth()
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp)),
                strokeCap = StrokeCap.Round,
                color = accentColor,
                trackColor = accentContainer
            )
        }

        Spacer(modifier = Modifier.weight(1f))

        // Playback controls
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onFirstFrame) {
                Icon(Icons.Default.SkipPrevious, contentDescription = "First")
            }
            IconButton(onClick = onPreviousFrame) {
                Icon(Icons.Default.FastRewind, contentDescription = "Previous")
            }
            FilledIconButton(
                onClick = onTogglePause,
                modifier = Modifier.size(56.dp),
                colors =
                IconButtonDefaults.filledIconButtonColors(
                    containerColor = accentColor
                )
            ) {
                Icon(
                    imageVector = if (isPaused) Icons.Default.PlayArrow else Icons.Default.Pause,
                    contentDescription = if (isPaused) "Play" else "Pause",
                    modifier = Modifier.size(28.dp)
                )
            }
            IconButton(onClick = onNextFrame) {
                Icon(Icons.Default.FastForward, contentDescription = "Next")
            }
            IconButton(onClick = onLastFrame) {
                Icon(Icons.Default.SkipNext, contentDescription = "Last")
            }
        }

        Spacer(modifier = Modifier.height(12.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton(
                onClick = onReset,
                colors = ButtonDefaults.outlinedButtonColors(contentColor = accentColor)
            ) {
                Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.width(4.dp))
                Text("Reset")
            }

            Box {
                OutlinedButton(
                    onClick = { showFpsMenu = true },
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = accentColor)
                ) {
                    Icon(Icons.Default.Speed, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("$fps fps")
                }
                DropdownMenu(
                    expanded = showFpsMenu,
                    onDismissRequest = { showFpsMenu = false }
                ) {
                    listOf(2, 3, 4, 5, 6, 8).forEach { fpsOption ->
                        DropdownMenuItem(
                            text = { Text("$fpsOption fps") },
                            onClick = {
                                onFpsChange(fpsOption)
                                showFpsMenu = false
                            }
                        )
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(24.dp))

        Button(
            onClick = onDone,
            modifier = Modifier.fillMaxWidth(),
            colors =
            ButtonDefaults.buttonColors(
                containerColor = accentColor
            )
        ) {
            Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(modifier = Modifier.width(8.dp))
            Text("Receiver Ready")
        }
    }
}

// ============================================================================
// Scanning Content
// ============================================================================

@Composable
private fun ScanningContent(
    receivedBlocks: Int,
    totalBlocks: Int,
    passphraseLooksWrong: Boolean,
    passphraseRequired: Boolean,
    onFrameScanned: (String) -> Unit
) {
    Box(modifier = Modifier.fillMaxSize()) {
        QRScannerView(
            onQRCodeScanned = onFrameScanned,
            modifier = Modifier.fillMaxSize()
        )

        val warning = when {
            passphraseRequired -> "The other phone protects its codes with six words. Go back and type them."
            passphraseLooksWrong -> "Nothing decodes: check the six words with the other person."
            else -> null
        }
        if (warning != null) {
            Text(
                text = warning,
                color = MaterialTheme.colorScheme.onErrorContainer,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(16.dp)
                    .background(MaterialTheme.colorScheme.errorContainer, RoundedCornerShape(12.dp))
                    .padding(12.dp)
            )
        }

        ScanProgressOverlay(
            receivedBlocks = receivedBlocks,
            totalBlocks = totalBlocks,
            modifier =
            Modifier
                .align(Alignment.BottomCenter)
                .padding(24.dp)
        )
    }
}

// ============================================================================
// Receiver Setup Content
// ============================================================================

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ReceiverSetupContent(
    channel: CeremonyChannel,
    onChannelChange: (CeremonyChannel) -> Unit,
    passphrase: String,
    passphraseValid: Boolean,
    canStart: Boolean,
    onPassphraseChange: (String) -> Unit,
    selectedColor: ConversationColor,
    onColorChange: (ConversationColor) -> Unit,
    onStartScanning: () -> Unit
) {
    val accentColor = Color(selectedColor.toColorLong())

    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Surface(
            modifier = Modifier.size(72.dp),
            shape = CircleShape,
            color = MaterialTheme.colorScheme.tertiaryContainer
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = Icons.Default.CameraAlt,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onTertiaryContainer,
                    modifier = Modifier.size(36.dp)
                )
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        Text(
            text = if (channel == CeremonyChannel.BLUETOOTH) "Ready to Receive" else "Ready to Scan",
            style = MaterialTheme.typography.headlineSmall
        )

        Text(
            text = if (channel == CeremonyChannel.BLUETOOTH) {
                "Choose the same method as the other phone"
            } else {
                "Point your camera at the sender's QR codes"
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(24.dp))

        // How it works
        OutlinedCard(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Default.Info,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "How it works",
                        style = MaterialTheme.typography.titleSmall
                    )
                }
                Spacer(modifier = Modifier.height(12.dp))

                HowItWorksStep(1, "Hold steady and point at the QR codes")
                HowItWorksStep(2, "Frames are captured automatically")
                HowItWorksStep(3, "Progress shows when complete")
            }
        }

        Spacer(modifier = Modifier.height(12.dp))

        ChannelSelector(channel = channel, onChannelChange = onChannelChange)

        Spacer(modifier = Modifier.height(12.dp))

        if (channel == CeremonyChannel.QR_CODES) {
            // Passphrase
            OutlinedCard(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            imageVector = Icons.Outlined.Lock,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Spacer(modifier = Modifier.width(12.dp))
                        Text(
                            text = "Six Words, If Shown",
                            style = MaterialTheme.typography.titleSmall
                        )
                    }
                    Spacer(modifier = Modifier.height(12.dp))
                    OutlinedTextField(
                        value = passphrase,
                        onValueChange = onPassphraseChange,
                        label = { Text("Words shown on the other phone") },
                        placeholder = { Text("able acid aged also area army") },
                        isError = passphrase.isNotBlank() && !passphraseValid,
                        supportingText = if (passphrase.isNotBlank() && !passphraseValid) {
                            { Text("Type the six words read by the other person, or leave empty") }
                        } else {
                            null
                        },
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.None,
                            autoCorrectEnabled = false
                        ),
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(12.dp))

        // Color picker
        OutlinedCard(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Outlined.Palette,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Conversation Color",
                        style = MaterialTheme.typography.titleSmall
                    )
                }

                Spacer(modifier = Modifier.height(12.dp))

                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    ConversationColor.entries.forEach { color ->
                        ColorButton(
                            color = Color(color.toColorLong()),
                            isSelected = color == selectedColor,
                            onClick = { onColorChange(color) }
                        )
                    }
                }
            }
        }

        Spacer(modifier = Modifier.weight(1f))

        Button(
            onClick = onStartScanning,
            enabled = canStart,
            modifier = Modifier.fillMaxWidth(),
            colors =
            ButtonDefaults.buttonColors(
                containerColor = accentColor
            )
        ) {
            Icon(
                if (channel == CeremonyChannel.BLUETOOTH) Icons.Default.Bluetooth else Icons.Default.CameraAlt,
                contentDescription = null,
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(if (channel == CeremonyChannel.BLUETOOTH) "Start Receiving" else "Start Scanning")
        }
    }
}

@Composable
private fun HowItWorksStep(number: Int, text: String) {
    Row(
        modifier = Modifier.padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Surface(
            modifier = Modifier.size(24.dp),
            shape = CircleShape,
            color = MaterialTheme.colorScheme.primary
        ) {
            Box(contentAlignment = Alignment.Center) {
                Text(
                    text = number.toString(),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onPrimary
                )
            }
        }
        Spacer(modifier = Modifier.width(12.dp))
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

// ============================================================================
// Verification Content
// ============================================================================

@Composable
private fun VerificationContent(
    mnemonic: List<String>,
    conversationName: String,
    onNameChange: (String) -> Unit,
    onConfirm: () -> Unit,
    onReject: () -> Unit,
    accentColor: Color
) {
    // Derive container color from accent (lighter version)
    val accentContainer = accentColor.copy(alpha = 0.15f)

    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Surface(
            modifier = Modifier.size(72.dp),
            shape = CircleShape,
            color = accentContainer
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = Icons.Default.Shield,
                    contentDescription = null,
                    tint = accentColor,
                    modifier = Modifier.size(36.dp)
                )
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        Text(
            text = "Verify Checksum",
            style = MaterialTheme.typography.headlineSmall
        )

        Text(
            text = "Both devices must show the same words",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(modifier = Modifier.height(24.dp))

        // Mnemonic words in a grid
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors =
            CardDefaults.cardColors(
                containerColor = accentContainer
            )
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.weight(1f)) {
                        mnemonic.take(3).forEachIndexed { index, word ->
                            MnemonicWord(index + 1, word, accentColor)
                        }
                    }
                    Spacer(modifier = Modifier.width(16.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        mnemonic.drop(3).take(3).forEachIndexed { index, word ->
                            MnemonicWord(index + 4, word, accentColor)
                        }
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(24.dp))

        OutlinedTextField(
            value = conversationName,
            onValueChange = onNameChange,
            label = { Text("Conversation Name (Optional)") },
            placeholder = { Text("e.g., Alice") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true
        )

        Spacer(modifier = Modifier.height(24.dp))

        Button(
            onClick = onConfirm,
            modifier = Modifier.fillMaxWidth(),
            colors =
            ButtonDefaults.buttonColors(
                containerColor = accentColor
            )
        ) {
            Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(modifier = Modifier.width(8.dp))
            Text("Words Match")
        }

        Spacer(modifier = Modifier.height(8.dp))

        OutlinedButton(
            onClick = onReject,
            modifier = Modifier.fillMaxWidth(),
            colors =
            ButtonDefaults.outlinedButtonColors(
                contentColor = MaterialTheme.colorScheme.error
            )
        ) {
            Icon(Icons.Default.Close, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(modifier = Modifier.width(8.dp))
            Text("Words Don't Match")
        }
    }
}

@Composable
private fun MnemonicWord(number: Int, word: String, accentColor: Color = Color(0xFF5856D6)) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = "$number.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(24.dp)
        )
        Text(
            text = word,
            style = MaterialTheme.typography.titleMedium,
            color = accentColor
        )
    }
}

// ============================================================================
// Completed Content
// ============================================================================

@Suppress("UnusedParameter")
@Composable
private fun CompletedContent(conversationId: String, onDismiss: () -> Unit) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.padding(24.dp)
        ) {
            Surface(
                modifier = Modifier.size(96.dp),
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primaryContainer
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = Icons.Default.Check,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onPrimaryContainer,
                        modifier = Modifier.size(48.dp)
                    )
                }
            }

            Text(
                text = "Conversation Created!",
                style = MaterialTheme.typography.headlineSmall
            )

            Text(
                text = "Your secure channel is ready",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(16.dp))

            Button(onClick = onDismiss) {
                Text("Start Messaging")
            }
        }
    }
}

// ============================================================================
// Failed Content
// ============================================================================

@Composable
private fun FailedContent(error: CeremonyError, onRetry: () -> Unit, onCancel: () -> Unit) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.padding(24.dp)
        ) {
            Surface(
                modifier = Modifier.size(96.dp),
                shape = CircleShape,
                color = MaterialTheme.colorScheme.errorContainer
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onErrorContainer,
                        modifier = Modifier.size(48.dp)
                    )
                }
            }

            Text(
                text = "Ceremony Failed",
                style = MaterialTheme.typography.headlineSmall
            )

            Text(
                text =
                when (error) {
                    CeremonyError.CANCELLED -> "The ceremony was cancelled"
                    CeremonyError.QR_GENERATION_FAILED -> "Failed to generate QR codes"
                    CeremonyError.PAD_RECONSTRUCTION_FAILED -> "Failed to reconstruct pad"
                    CeremonyError.CHECKSUM_MISMATCH -> "Security words didn't match"
                    CeremonyError.PASSPHRASE_MISMATCH -> "Incorrect passphrase"
                    CeremonyError.INVALID_FRAME -> "Invalid QR code frame"
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )

            Spacer(modifier = Modifier.height(16.dp))

            Button(onClick = onRetry) {
                Text("Try Again")
            }

            TextButton(onClick = onCancel) {
                Text("Cancel")
            }
        }
    }
}

/** The six passphrase words, numbered, large enough to read aloud. */
@Composable
private fun PassphraseWords(words: List<String>) {
    words.chunked(2).forEachIndexed { row, pair ->
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            pair.forEachIndexed { column, word ->
                Row(
                    modifier = Modifier
                        .weight(1f)
                        .padding(vertical = 4.dp)
                        .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))
                        .padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        "${row * 2 + column + 1}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(word, style = MaterialTheme.typography.titleMedium, fontFamily = FontFamily.Monospace)
                }
            }
        }
    }
}

// ============================================================================
// Utilities
// ============================================================================

/**
 * Maps ceremony phases to content keys for AnimatedContent.
 * Important: Scanning and Transferring use the same key in receiver flow
 * to prevent camera recreation when progress updates.
 */
private fun phaseToContentKey(phase: CeremonyPhase): String = when (phase) {
    is CeremonyPhase.SelectingRole -> "selecting_role"
    is CeremonyPhase.SelectingPadSize -> "selecting_pad_size"
    is CeremonyPhase.ConfiguringOptions -> "configuring_options"
    is CeremonyPhase.ConfirmingConsent -> "confirming_consent"
    is CeremonyPhase.CollectingEntropy -> "collecting_entropy"
    is CeremonyPhase.GeneratingPad -> "generating_pad"
    is CeremonyPhase.GeneratingQRCodes -> "generating_qr"
    is CeremonyPhase.Transferring -> "scanning_transferring" // Same key as Scanning for receiver
    is CeremonyPhase.BluetoothTransfer -> "bluetooth_transfer"
    is CeremonyPhase.Verifying -> "verifying"
    is CeremonyPhase.Completed -> "completed"
    is CeremonyPhase.Failed -> "failed"
    is CeremonyPhase.ConfiguringReceiver -> "configuring_receiver"
    is CeremonyPhase.Scanning -> "scanning_transferring" // Same key as Transferring for receiver
}
