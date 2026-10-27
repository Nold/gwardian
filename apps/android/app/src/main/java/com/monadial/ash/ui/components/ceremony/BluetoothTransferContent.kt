package com.monadial.ash.ui.components.ceremony

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.monadial.ash.core.services.bletransfer.BlePadReceiverSession
import com.monadial.ash.core.services.bletransfer.BlePadSenderSession
import com.monadial.ash.core.services.bletransfer.BleTransferFailure
import com.monadial.ash.core.services.bletransfer.BleTransferPermissions
import com.monadial.ash.core.services.bletransfer.BleTransferState
import com.monadial.ash.domain.entities.CeremonyChannel

/** QR codes (🔴 Maximum) or Bluetooth (🟠 Enhanced). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChannelSelector(channel: CeremonyChannel, onChannelChange: (CeremonyChannel) -> Unit) {
    OutlinedCard(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                CeremonyChannel.entries.forEachIndexed { index, option ->
                    SegmentedButton(
                        selected = option == channel,
                        onClick = { onChannelChange(option) },
                        shape = SegmentedButtonDefaults.itemShape(index, CeremonyChannel.entries.size)
                    ) {
                        Text(if (option == CeremonyChannel.QR_CODES) "QR Codes" else "Bluetooth")
                    }
                }
            }
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = if (channel == CeremonyChannel.QR_CODES) {
                    "🔴 Maximum security: nothing goes over the air. Needs good light."
                } else {
                    "🟠 Enhanced security: faster, protected by a post-quantum key exchange. " +
                        "You will compare six words."
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

/**
 * Asks for the Bluetooth permissions, then runs [onResult] with whether all
 * were granted (immediately if they already are).
 */
@Composable
fun rememberBluetoothPermissionRequest(onResult: (Boolean) -> Unit): () -> Unit {
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
        onResult(grants.values.all { it })
    }
    return { launcher.launch(BleTransferPermissions.required) }
}

/** Sending side: pick the other phone, compare the words, send. */
@Composable
fun BluetoothSendContent(
    session: BlePadSenderSession,
    accentColor: Color,
    onWordsRejected: () -> Unit,
    onRetry: () -> Unit
) {
    val state by session.state.collectAsState()
    val nearby by session.nearby.collectAsState()

    BluetoothTransferLayout(
        state = state,
        accentColor = accentColor,
        onConfirmWords = session::confirmWords,
        onRejectWords = onWordsRejected,
        onRetry = onRetry
    ) {
        BluetoothHeader(
            icon = Icons.Default.Bluetooth,
            title = "Choose the Other Phone",
            subtitle = "On the other phone, choose Bluetooth and start receiving. Then tap the code it shows.",
            accentColor = accentColor
        )
        Spacer(modifier = Modifier.height(24.dp))
        if (nearby.isEmpty()) {
            CircularProgressIndicator(color = accentColor)
            Spacer(modifier = Modifier.height(8.dp))
            Text("Looking for nearby phones…", style = MaterialTheme.typography.bodyMedium)
        } else {
            nearby.forEach { receiver ->
                OutlinedCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 4.dp)
                        .clickable { session.connect(receiver) }
                ) {
                    Row(
                        modifier = Modifier.padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            receiver.code,
                            fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.Bold,
                            fontSize = 24.sp,
                            modifier = Modifier.weight(1f)
                        )
                        SignalBars(receiver.rssi)
                    }
                }
            }
        }
    }
}

/** Receiving side: show a code, compare the words, receive. */
@Composable
fun BluetoothReceiveContent(
    session: BlePadReceiverSession,
    accentColor: Color,
    onWordsRejected: () -> Unit,
    onRetry: () -> Unit
) {
    val state by session.state.collectAsState()

    BluetoothTransferLayout(
        state = state,
        accentColor = accentColor,
        onConfirmWords = session::confirmWords,
        onRejectWords = onWordsRejected,
        onRetry = onRetry
    ) {
        BluetoothHeader(
            icon = Icons.Default.Bluetooth,
            title = "Waiting for the Other Phone",
            subtitle = "On the phone creating the conversation, choose this code.",
            accentColor = accentColor
        )
        val advertising = state as? BleTransferState.Advertising
        if (advertising != null) {
            Spacer(modifier = Modifier.height(24.dp))
            Text(
                advertising.code,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold,
                fontSize = 44.sp,
                modifier = Modifier
                    .background(accentColor.copy(alpha = 0.12f), RoundedCornerShape(20.dp))
                    .padding(horizontal = 32.dp, vertical = 20.dp)
                    .semantics { contentDescription = "Code ${advertising.code.toList().joinToString(" ")}" }
            )
        }
    }
}

/** Steps shared by both sides; [waiting] shows while looking for the other phone. */
@Composable
private fun BluetoothTransferLayout(
    state: BleTransferState,
    accentColor: Color,
    onConfirmWords: () -> Unit,
    onRejectWords: () -> Unit,
    onRetry: () -> Unit,
    waiting: @Composable () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        when (state) {
            BleTransferState.Idle, BleTransferState.WaitingForBluetooth -> {
                Spacer(modifier = Modifier.height(80.dp))
                CircularProgressIndicator(color = accentColor)
                Spacer(modifier = Modifier.height(8.dp))
                Text("Starting Bluetooth…")
            }

            is BleTransferState.Advertising, BleTransferState.Scanning -> waiting()

            BleTransferState.Connecting, BleTransferState.Exchanging -> {
                BluetoothHeader(
                    icon = Icons.Default.Lock,
                    title = "Securing the Connection",
                    subtitle = "Exchanging keys with the other phone…",
                    accentColor = accentColor
                )
                Spacer(modifier = Modifier.height(24.dp))
                CircularProgressIndicator(color = accentColor)
            }

            is BleTransferState.ComparingWords -> WordsComparison(
                words = state.words,
                accentColor = accentColor,
                onConfirm = onConfirmWords,
                onReject = onRejectWords
            )

            is BleTransferState.Transferring -> {
                BluetoothHeader(
                    icon = Icons.Default.SwapHoriz,
                    title = "Transferring",
                    subtitle = "Keep both phones close together.",
                    accentColor = accentColor
                )
                Spacer(modifier = Modifier.height(24.dp))
                LinearProgressIndicator(
                    progress = { state.progress.toFloat() },
                    color = accentColor,
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(modifier = Modifier.height(8.dp))
                Text("${(state.progress * 100).toInt()} %", style = MaterialTheme.typography.titleMedium)
            }

            BleTransferState.Completed -> BluetoothHeader(
                icon = Icons.Default.CheckCircle,
                title = "Transfer Complete",
                subtitle = null,
                accentColor = accentColor
            )

            is BleTransferState.Failed -> {
                BluetoothHeader(
                    icon = Icons.Default.Warning,
                    title = "Transfer Failed",
                    subtitle = state.failure.message(),
                    accentColor = MaterialTheme.colorScheme.error
                )
                Spacer(modifier = Modifier.height(24.dp))
                Button(
                    onClick = onRetry,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = accentColor)
                ) {
                    Text("Try Again")
                }
            }
        }
    }
}

/**
 * The six words both people read aloud; a difference means someone may be
 * in the middle, so the transfer must stop.
 */
@Composable
private fun WordsComparison(
    words: List<String>,
    accentColor: Color,
    onConfirm: () -> Unit,
    onReject: () -> Unit
) {
    BluetoothHeader(
        icon = Icons.Default.Lock,
        title = "Compare These Words",
        subtitle = "Read them aloud. The other phone must show exactly the same words, in the same order.",
        accentColor = accentColor
    )
    Spacer(modifier = Modifier.height(24.dp))
    words.chunked(2).forEachIndexed { row, pair ->
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
            pair.forEachIndexed { column, word ->
                OutlinedCard(modifier = Modifier.weight(1f).padding(vertical = 6.dp)) {
                    Row(modifier = Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "${row * 2 + column + 1}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(word, style = MaterialTheme.typography.titleMedium)
                    }
                }
            }
        }
    }
    Spacer(modifier = Modifier.height(24.dp))
    Button(
        onClick = onConfirm,
        modifier = Modifier.fillMaxWidth(),
        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF34C759))
    ) {
        Text("The Words Match")
    }
    TextButton(onClick = onReject, modifier = Modifier.fillMaxWidth()) {
        Text("They Are Different", color = MaterialTheme.colorScheme.error)
    }
}

@Composable
private fun BluetoothHeader(icon: ImageVector, title: String, subtitle: String?, accentColor: Color) {
    Surface(modifier = Modifier.size(72.dp), shape = CircleShape, color = accentColor.copy(alpha = 0.15f)) {
        Box(contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = accentColor, modifier = Modifier.size(36.dp))
        }
    }
    Spacer(modifier = Modifier.height(16.dp))
    Text(title, style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
    if (subtitle != null) {
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            subtitle,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
    }
}

@Composable
private fun SignalBars(rssi: Int) {
    val bars = when {
        rssi >= -60 -> 3
        rssi >= -75 -> 2
        else -> 1
    }
    Row(
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier.semantics { contentDescription = "Signal $bars of 3" }
    ) {
        (1..3).forEach { level ->
            Box(
                Modifier
                    .width(4.dp)
                    .height((4 + level * 4).dp)
                    .background(
                        if (level <= bars) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.outlineVariant,
                        RoundedCornerShape(1.dp)
                    )
            )
        }
    }
}

private fun BleTransferFailure.message(): String = when (this) {
    BleTransferFailure.BluetoothUnavailable -> "Bluetooth is off or not available. Turn it on and try again."
    BleTransferFailure.PermissionMissing -> "Gwardian is not allowed to use Bluetooth. Allow it in the app settings."
    BleTransferFailure.Disconnected -> "The connection was lost. Keep the phones close and try again."
    is BleTransferFailure.ProtocolError -> "The exchange failed. Start again on both phones."
}
