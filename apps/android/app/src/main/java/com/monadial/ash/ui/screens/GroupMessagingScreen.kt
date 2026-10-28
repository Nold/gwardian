package com.monadial.ash.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.monadial.ash.domain.entities.GroupChatMessage
import com.monadial.ash.ui.viewmodels.GroupMessagingViewModel
import java.text.DateFormat
import java.util.Date

/** Messages of a group, with the author's name above each message. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupMessagingScreen(
    onBack: () -> Unit,
    viewModel: GroupMessagingViewModel = hiltViewModel()
) {
    var showInfo by remember { mutableStateOf(false) }
    val state by viewModel.uiState.collectAsState()
    val messages by viewModel.messages.collectAsState()
    val group = state.group
    val accent = group?.let { Color(it.color.toColorLong()) } ?: MaterialTheme.colorScheme.primary
    val listState = rememberLazyListState()

    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.size - 1)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(group?.displayName ?: "", maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { showInfo = true }) {
                        Icon(Icons.Default.Info, contentDescription = "Group info")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .imePadding()
        ) {
            val error = state.loadError
            if (error != null) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text(error) }
                return@Column
            }
            val disappearing = group?.disappearingMessages
            val disappearingNote = if (disappearing?.seconds != null) {
                " · messages disappear after ${disappearing.displayName.lowercase()}"
            } else {
                ""
            }
            Text(
                "${(state.remainingFraction * 100).toInt()} % of your pad left$disappearingNote",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(8.dp),
            )
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                items(messages, key = { it.id }) { message ->
                    GroupBubble(
                        message = message,
                        senderName = group?.nameOf(message.sender) ?: "",
                        accent = accent,
                        onRetry = { viewModel.retry(message) }
                    )
                }
            }
            if (!state.canSendAny) {
                Text(
                    "Your pad is used up. Create a new group to keep writing.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(12.dp)
                )
            } else {
                Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = state.draft,
                        onValueChange = viewModel::setDraft,
                        placeholder = { Text("Message") },
                        maxLines = 5,
                        modifier = Modifier.weight(1f)
                    )
                    IconButton(onClick = viewModel::send, enabled = viewModel.canSend(state)) {
                        Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send", tint = accent)
                    }
                }
            }
        }
    }

    if (showInfo && group != null) {
        GroupInfoDialog(
            group = group,
            onDismiss = { showInfo = false },
            onDelete = {
                showInfo = false
                viewModel.delete(onDeleted = onBack)
            }
        )
    }
}

@Composable
private fun GroupBubble(message: GroupChatMessage, senderName: String, accent: Color, onRetry: () -> Unit) {
    val outgoing = message.isOutgoing
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (outgoing) Arrangement.End else Arrangement.Start) {
        Column(horizontalAlignment = if (outgoing) Alignment.End else Alignment.Start) {
            if (!outgoing) {
                Text(
                    senderName,
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Surface(
                color = if (outgoing) accent else MaterialTheme.colorScheme.surfaceVariant,
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.widthIn(max = 300.dp)
            ) {
                Text(
                    message.text,
                    color = if (outgoing) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
                )
            }
            when (message.status) {
                GroupChatMessage.Status.SENDING -> Caption("Sending…")
                GroupChatMessage.Status.FAILED -> Text(
                    "Not sent. Tap to retry.",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.clickable(onClick = onRetry)
                )
                else -> Caption(DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(message.timestamp)))
            }
        }
    }
}

@Composable
private fun Caption(text: String) {
    Text(text, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
