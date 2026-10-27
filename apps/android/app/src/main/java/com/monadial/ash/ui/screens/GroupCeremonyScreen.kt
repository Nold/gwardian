package com.monadial.ash.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.foundation.Image
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.monadial.ash.domain.entities.ConversationColor
import com.monadial.ash.domain.entities.DisappearingMessages
import com.monadial.ash.domain.entities.MessageRetention
import com.monadial.ash.domain.entities.PadSize
import com.monadial.ash.ui.components.EntropyCollectionView
import com.monadial.ash.ui.components.QRScannerView
import com.monadial.ash.ui.viewmodels.GroupCeremonyUiState
import com.monadial.ash.ui.viewmodels.GroupCeremonyViewModel
import com.monadial.ash.ui.viewmodels.GroupRole
import com.monadial.ash.ui.viewmodels.GroupStep

/**
 * Group ceremony around the table (docs/group-ceremony.md): one phone shows
 * its card, every other phone scans it, then the next member takes a turn.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupCeremonyScreen(
    role: GroupRole,
    onComplete: () -> Unit,
    onCancel: () -> Unit,
    viewModel: GroupCeremonyViewModel = hiltViewModel()
) {
    LaunchedEffect(role) { viewModel.begin(role) }
    val state by viewModel.uiState.collectAsState()
    val accent = Color(state.color.toColorLong())

    val cancel = {
        viewModel.cancel()
        onCancel()
    }
    BackHandler(onBack = cancel)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (state.role == GroupRole.CREATOR) "New Group" else "Join a Group") },
                navigationIcon = {
                    IconButton(onClick = cancel) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Cancel")
                    }
                }
            )
        }
    ) { padding ->
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            when (val step = state.step) {
                GroupStep.Setup -> SetupContent(state, viewModel)
                GroupStep.CollectingEntropy -> Column(Modifier.padding(24.dp)) {
                    Text(
                        "Draw random patterns. Your movements mix extra randomness into your pad.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(Modifier.height(16.dp))
                    EntropyCollectionView(
                        progress = state.entropyProgress,
                        onPointCollected = viewModel::addEntropy,
                        accentColor = accent
                    )
                }
                GroupStep.Generating -> Centered { CircularProgressIndicator() }
                GroupStep.Showing -> ShowCardContent(state, accent, viewModel::finishShowing)
                GroupStep.Scanning -> ScanCardContent(state, viewModel)
                GroupStep.Waiting -> TurnContent(state, accent, viewModel)
                is GroupStep.Completed -> EndContent(
                    title = "Group Ready",
                    message = "With ${step.group.displayName}.",
                    good = true,
                    button = "Done",
                    onClick = onComplete
                )
                is GroupStep.Failed -> EndContent(
                    title = "Group Not Created",
                    message = step.message,
                    good = false,
                    button = "Close",
                    onClick = cancel
                )
            }
        }
    }
}

// MARK: - Setup

@Composable
private fun SetupContent(state: GroupCeremonyUiState, viewModel: GroupCeremonyViewModel) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        OutlinedTextField(
            value = state.myName,
            onValueChange = viewModel::setName,
            label = { Text("Your name") },
            supportingText = { Text("Shown to the other members next to your messages.") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth()
        )

        if (state.role == GroupRole.CREATOR) {
            SectionTitle("Members")
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("${state.memberCount} members, including you", Modifier.weight(1f))
                OutlinedButton(onClick = { viewModel.setMemberCount(state.memberCount - 1) }) { Text("−") }
                Spacer(Modifier.width(8.dp))
                OutlinedButton(onClick = { viewModel.setMemberCount(state.memberCount + 1) }) { Text("+") }
            }
            Hint("Everyone must be in the same room. Each phone shows its card in turn and scans all the others.")

            SectionTitle("Settings for Everyone")
            Choice("Pad size", state.padSize.displayName, PadSize.entries.filter { it != PadSize.TINY }, { it.displayName }, viewModel::setPadSize)
            Choice("Messages wait on the relay", state.serverRetention.displayName, MessageRetention.entries, { it.displayName }, viewModel::setServerRetention)
            Choice("Disappearing messages", state.disappearingMessages.displayName, DisappearingMessages.entries, { it.displayName }, viewModel::setDisappearingMessages)
            Choice("Color", state.color.name.lowercase().replaceFirstChar { it.uppercase() }, ConversationColor.entries, { it.name.lowercase().replaceFirstChar { c -> c.uppercase() } }, viewModel::setColor)
            OutlinedTextField(
                value = state.relayUrl,
                onValueChange = viewModel::setRelayUrl,
                label = { Text("Relay") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
                modifier = Modifier.fillMaxWidth()
            )

            SectionTitle("Protection")
            SwitchRow("Family group", state.isFamilyConversation, viewModel::setFamilyConversation)
            SwitchRow("Protect the codes with six words", state.usesPassphrase, viewModel::setUsesPassphrase)
            if (state.usesPassphrase) {
                WordsGrid(state.passphraseWords)
                TextButton(onClick = viewModel::regeneratePassphrase) { Text("Draw Other Words") }
                Hint("Read these words aloud once. The others type them, so a camera filming the codes learns nothing.")
            } else {
                Hint("Without words, make sure no camera can film the screens.")
            }
        } else {
            OutlinedTextField(
                value = state.typedPassphrase,
                onValueChange = viewModel::setTypedPassphrase,
                label = { Text("Six words, only if the creator reads some") },
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
                modifier = Modifier.fillMaxWidth()
            )
            Hint("The creator chooses every setting. Your place in the group is set by the order of the turns.")
        }

        Button(
            onClick = viewModel::start,
            enabled = viewModel.canStart(state),
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(if (state.role == GroupRole.CREATOR) "Create My Card" else "Scan the Creator's Card")
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun Hint(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun <T> Choice(label: String, current: String, options: List<T>, name: (T) -> String, onSelect: (T) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Box {
            TextButton(onClick = { expanded = true }) { Text(current) }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                options.forEach { option ->
                    DropdownMenuItem(
                        text = { Text(name(option)) },
                        onClick = {
                            onSelect(option)
                            expanded = false
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun WordsGrid(words: List<String>) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        words.chunked(2).forEachIndexed { row, pair ->
            Row {
                pair.forEachIndexed { column, word ->
                    Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "${row * 2 + column + 1}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.width(20.dp)
                        )
                        Text(word, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }
}

// MARK: - Showing

@Composable
private fun ShowCardContent(state: GroupCeremonyUiState, accent: Color, onDone: () -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text(
            "Member ${(state.me ?: 0) + 1} of ${state.totalMembers}",
            color = accent,
            fontWeight = FontWeight.SemiBold
        )
        Text("Everyone Scans This Card", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Hint("Hold your phone so the others can scan it, one or several at once.")
        Surface(
            color = Color.White,
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier
                .widthIn(max = 360.dp)
                .fillMaxWidth()
                .aspectRatio(1f)
        ) {
            state.currentQRBitmap?.let { bitmap ->
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = "Group card",
                    filterQuality = FilterQuality.None,
                    modifier = Modifier.padding(10.dp)
                )
            } ?: Centered { CircularProgressIndicator() }
        }
        Button(onClick = onDone, modifier = Modifier.fillMaxWidth()) { Text("Everyone Has Scanned") }
    }
}

// MARK: - Scanning

@Composable
private fun ScanCardContent(state: GroupCeremonyUiState, viewModel: GroupCeremonyViewModel) {
    val place = state.nextPlaceToScan
    Column(
        Modifier
            .fillMaxSize()
            .padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text(
            when (place) {
                null -> "Scan a Card"
                0 -> "Scan the Creator's Card"
                else -> "Scan Member ${place + 1}'s Card"
            },
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold
        )
        QRScannerView(
            onQRCodeScanned = viewModel::processScannedFrame,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(RoundedCornerShape(16.dp))
        )
        LinearProgressIndicator(progress = { state.scanProgress }, modifier = Modifier.fillMaxWidth())
        val notice = state.scanMessage
            ?: if (state.passphraseRequired) {
                "These codes are protected by six words. Go back and type the words the creator read aloud."
            } else if (state.passphraseLooksWrong) {
                "Nothing can be read. Check the six words."
            } else {
                null
            }
        notice?.let {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Warning, contentDescription = null, tint = Color(0xFFFF9500))
                Spacer(Modifier.width(8.dp))
                Text(it, style = MaterialTheme.typography.bodyMedium)
            }
        }
        Spacer(Modifier.weight(1f))
        if (state.me != null || state.knownCount > 0) {
            TextButton(onClick = viewModel::stopScanning) { Text("Back") }
        }
    }
}

// MARK: - Turns

@Composable
private fun TurnContent(state: GroupCeremonyUiState, accent: Color, viewModel: GroupCeremonyViewModel) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text(
            "${state.knownCount} of ${state.totalMembers} Cards",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold
        )
        Hint("One phone shows its card at a time. Every other phone scans it.")

        Surface(shape = RoundedCornerShape(12.dp), tonalElevation = 2.dp, modifier = Modifier.fillMaxWidth()) {
            Column {
                for (index in 0 until state.totalMembers) {
                    val scanned = state.scanned.firstOrNull { it.index == index }
                    Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("${index + 1}", Modifier.width(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(
                            when {
                                index == state.me -> "${state.trimmedName} (you)"
                                scanned != null -> scanned.name
                                else -> "Waiting"
                            },
                            Modifier.weight(1f)
                        )
                        if (index == state.me || scanned != null) {
                            Icon(Icons.Default.CheckCircle, contentDescription = null, tint = Color(0xFF34C759))
                        }
                    }
                    if (index < state.totalMembers - 1) HorizontalDivider()
                }
            }
        }

        state.nextPlaceToScan?.let { place ->
            Button(onClick = viewModel::startScanning, modifier = Modifier.fillMaxWidth()) {
                Text("Scan Member ${place + 1}'s Card")
            }
        }
        if (state.canTakeTurn) {
            OutlinedButton(onClick = viewModel::takeTurn, modifier = Modifier.fillMaxWidth()) {
                Text("It's My Turn to Show", color = accent)
            }
            Hint("Only when nobody else is showing a card.")
        }
        if (state.me != null) {
            TextButton(onClick = viewModel::showCardAgain) { Text("Show My Card Again") }
        }
    }
}

// MARK: - End

@Composable
private fun EndContent(title: String, message: String, good: Boolean, button: String, onClick: () -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically)
    ) {
        Icon(
            if (good) Icons.Default.Groups else Icons.Default.Warning,
            contentDescription = null,
            tint = if (good) MaterialTheme.colorScheme.primary else Color(0xFFFF9500),
            modifier = Modifier.size(56.dp)
        )
        Text(title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Text(message, textAlign = TextAlign.Center)
        Button(onClick = onClick) { Text(button) }
    }
}

@Composable
private fun Centered(content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Transparent), contentAlignment = Alignment.Center) { content() }
}
