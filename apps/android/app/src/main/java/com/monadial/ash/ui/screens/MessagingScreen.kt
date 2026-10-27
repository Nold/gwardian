package com.monadial.ash.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.monadial.ash.domain.entities.DeliveryStatus
import com.monadial.ash.domain.entities.Message
import com.monadial.ash.domain.entities.MessageDirection
import com.monadial.ash.ui.components.keyboard.ThirdPartyKeyboardWarning
import com.monadial.ash.ui.viewmodels.MessagingViewModel

@Suppress("UnusedParameter")
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MessagingScreen(
    conversationId: String,
    viewModel: MessagingViewModel = hiltViewModel(),
    onBack: () -> Unit,
    onInfoClick: () -> Unit = {}
) {
    val conversation by viewModel.conversation.collectAsState()
    val messages by viewModel.messages.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val isSending by viewModel.isSending.collectAsState()
    val error by viewModel.error.collectAsState()
    val inputText by viewModel.inputText.collectAsState()

    val snackbarHostState = remember { SnackbarHostState() }
    val listState = rememberLazyListState()

    val accentColor =
        conversation?.color?.let { Color(it.toColorLong()) }
            ?: MaterialTheme.colorScheme.primary

    // Scroll to bottom when new message arrives
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) {
            listState.animateScrollToItem(messages.size - 1)
        }
    }

    // Show error snackbar
    LaunchedEffect(error) {
        error?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.clearError()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            text = conversation?.name ?: "Loading...",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold
                        )
                        if (conversation != null) {
                            val remaining = viewModel.remainingBytes
                            val percentage = viewModel.padUsagePercentage
                            Text(
                                text = "${formatBytes(remaining)} remaining (${percentage.toInt()}% used)",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = onInfoClick) {
                        Icon(Icons.Default.Info, contentDescription = "Info")
                    }
                },
                colors =
                TopAppBarDefaults.topAppBarColors(
                    containerColor = accentColor.copy(alpha = 0.1f)
                )
            )
        },
        snackbarHost = {
            SnackbarHost(snackbarHostState) { data ->
                Snackbar(
                    snackbarData = data,
                    containerColor = MaterialTheme.colorScheme.errorContainer,
                    contentColor = MaterialTheme.colorScheme.onErrorContainer
                )
            }
        }
    ) { padding ->
        Column(
            modifier =
            Modifier
                .fillMaxSize()
                .padding(padding)
                .imePadding()
        ) {
            // Pad usage bar
            if (conversation != null) {
                val progressColor =
                    when {
                        viewModel.padUsagePercentage > 90 -> MaterialTheme.colorScheme.error
                        viewModel.padUsagePercentage > 70 -> MaterialTheme.colorScheme.tertiary
                        else -> accentColor
                    }
                LinearProgressIndicator(
                    progress = { viewModel.padUsagePercentage / 100f },
                    modifier = Modifier.fillMaxWidth(),
                    color = progressColor
                )
            }

            // Messages list
            LazyColumn(
                modifier =
                Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                state = listState,
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                if (isLoading) {
                    item {
                        Box(
                            modifier =
                            Modifier
                                .fillMaxWidth()
                                .padding(32.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            CircularProgressIndicator()
                        }
                    }
                }

                if (messages.isEmpty() && !isLoading) {
                    item {
                        EmptyMessagesPlaceholder(
                            mnemonic = conversation?.mnemonic ?: emptyList(),
                            accentColor = accentColor
                        )
                    }
                }

                items(messages, key = { it.id }) { message ->
                    MessageBubble(
                        message = message,
                        accentColor = accentColor,
                        onRetry = { viewModel.retryMessage(message.id) }
                    )
                }
            }

            // A downloaded keyboard could read the message as it is typed
            ThirdPartyKeyboardWarning()

            // Input area
            MessageInput(
                text = inputText,
                onTextChange = viewModel::setInputText,
                onSend = viewModel::sendMessage,
                onSendLocation = viewModel::sendLocation,
                isSending = isSending,
                isGettingLocation = viewModel.isGettingLocation.collectAsState().value,
                accentColor = accentColor
            )
        }
    }
}

@Composable
private fun MessageBubble(message: Message, accentColor: Color, onRetry: () -> Unit) {
    val isSent = message.direction == MessageDirection.SENT
    val alignment = if (isSent) Alignment.CenterEnd else Alignment.CenterStart
    val backgroundColor = if (isSent) accentColor else MaterialTheme.colorScheme.surfaceVariant
    val textColor = if (isSent) Color.White else MaterialTheme.colorScheme.onSurfaceVariant

    Box(
        modifier = Modifier.fillMaxWidth(),
        contentAlignment = alignment
    ) {
        Column(
            horizontalAlignment = if (isSent) Alignment.End else Alignment.Start
        ) {
            Surface(
                shape =
                RoundedCornerShape(
                    topStart = 16.dp,
                    topEnd = 16.dp,
                    bottomStart = if (isSent) 16.dp else 4.dp,
                    bottomEnd = if (isSent) 4.dp else 16.dp
                ),
                color = backgroundColor,
                modifier = Modifier.widthIn(max = 280.dp)
            ) {
                Column(
                    modifier = Modifier.padding(12.dp)
                ) {
                    Text(
                        text = message.displayContent,
                        style = MaterialTheme.typography.bodyMedium,
                        color = textColor
                    )

                    Spacer(modifier = Modifier.height(4.dp))

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.End,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(
                            text = message.formattedTime,
                            style = MaterialTheme.typography.labelSmall,
                            color = textColor.copy(alpha = 0.7f)
                        )

                        if (isSent) {
                            Spacer(modifier = Modifier.width(4.dp))
                            MessageStatusIcon(
                                status = message.status,
                                tint = textColor.copy(alpha = 0.7f)
                            )
                        }
                    }
                }
            }

            // Retry button for failed messages
            if (message.status.isFailed) {
                TextButton(onClick = onRetry) {
                    Text("Retry", color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}

@Composable
private fun MessageStatusIcon(status: DeliveryStatus, tint: Color) {
    val successColor = MaterialTheme.colorScheme.primary
    val errorColor = MaterialTheme.colorScheme.error

    when (status) {
        DeliveryStatus.SENDING ->
            CircularProgressIndicator(
                modifier = Modifier.size(12.dp),
                strokeWidth = 1.dp,
                color = tint
            )
        DeliveryStatus.SENT ->
            Icon(
                Icons.Default.CheckCircle,
                contentDescription = "Sent",
                modifier = Modifier.size(14.dp),
                tint = tint
            )
        DeliveryStatus.DELIVERED ->
            Icon(
                Icons.Default.CheckCircle,
                contentDescription = "Delivered",
                modifier = Modifier.size(14.dp),
                tint = successColor
            )
        is DeliveryStatus.FAILED ->
            Icon(
                Icons.Default.Error,
                contentDescription = "Failed",
                modifier = Modifier.size(14.dp),
                tint = errorColor
            )
        DeliveryStatus.NONE ->
            Icon(
                Icons.Default.Schedule,
                contentDescription = "Pending",
                modifier = Modifier.size(14.dp),
                tint = tint
            )
    }
}

@Composable
private fun MessageInput(
    text: String,
    onTextChange: (String) -> Unit,
    onSend: () -> Unit,
    onSendLocation: () -> Unit,
    isSending: Boolean,
    isGettingLocation: Boolean,
    accentColor: Color
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shadowElevation = 8.dp,
        color = MaterialTheme.colorScheme.surface
    ) {
        Row(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Location button
            IconButton(
                onClick = onSendLocation,
                enabled = !isSending && !isGettingLocation,
                modifier = Modifier.size(48.dp)
            ) {
                if (isGettingLocation) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        strokeWidth = 2.dp,
                        color = accentColor
                    )
                } else {
                    Icon(
                        Icons.Default.LocationOn,
                        contentDescription = "Send Location",
                        tint = accentColor
                    )
                }
            }

            TextField(
                value = text,
                onValueChange = onTextChange,
                modifier = Modifier.weight(1f),
                placeholder = { Text("Message") },
                colors =
                TextFieldDefaults.colors(
                    focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent
                ),
                shape = RoundedCornerShape(24.dp),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { onSend() }),
                maxLines = 4
            )

            Spacer(modifier = Modifier.width(8.dp))

            IconButton(
                onClick = onSend,
                enabled = text.isNotBlank() && !isSending,
                modifier =
                Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .background(
                        if (text.isNotBlank() && !isSending) {
                            accentColor
                        } else {
                            MaterialTheme.colorScheme.surfaceVariant
                        }
                    )
            ) {
                if (isSending) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                } else {
                    Icon(
                        Icons.AutoMirrored.Filled.Send,
                        contentDescription = "Send",
                        tint =
                        if (text.isNotBlank()) {
                            Color.White
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        }
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun EmptyMessagesPlaceholder(
    mnemonic: List<String> = emptyList(),
    accentColor: Color = MaterialTheme.colorScheme.primary
) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        // Lock icon
        Box(
            modifier =
            Modifier
                .size(80.dp)
                .background(
                    color = accentColor.copy(alpha = 0.1f),
                    shape = CircleShape
                ),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "🔐",
                style = MaterialTheme.typography.displaySmall
            )
        }

        Spacer(modifier = Modifier.height(24.dp))

        Text(
            text = "Secure Channel Ready",
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            text = "Your messages are encrypted with a one-time pad that can never be recovered or compromised.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )

        // Mnemonic tags
        if (mnemonic.isNotEmpty()) {
            Spacer(modifier = Modifier.height(24.dp))

            Text(
                text = "Security Words",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontWeight = FontWeight.Medium
            )

            Spacer(modifier = Modifier.height(8.dp))

            FlowRow(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                mnemonic.forEach { word ->
                    MnemonicTag(word = word, accentColor = accentColor)
                }
            }
        }

        Spacer(modifier = Modifier.height(24.dp))

        Text(
            text = "Send your first message!",
            style = MaterialTheme.typography.bodyMedium,
            color = accentColor,
            fontWeight = FontWeight.Medium,
            textAlign = TextAlign.Center
        )
    }
}

@Composable
private fun MnemonicTag(word: String, accentColor: Color) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = accentColor.copy(alpha = 0.1f)
    ) {
        Text(
            text = word,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            style = MaterialTheme.typography.labelMedium,
            color = accentColor,
            fontWeight = FontWeight.Medium
        )
    }
}

private fun formatBytes(bytes: Long): String = when {
    bytes >= 1024 * 1024 -> "%.1f MB".format(bytes / (1024.0 * 1024.0))
    bytes >= 1024 -> "%.1f KB".format(bytes / 1024.0)
    else -> "$bytes B"
}
