package com.monadial.ash.ui.screens

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.monadial.ash.domain.entities.Conversation
import com.monadial.ash.domain.entities.GroupConversation
import com.monadial.ash.ui.viewmodels.ConversationsViewModel
import com.monadial.ash.ui.viewmodels.GroupListViewModel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConversationsScreen(
    onConversationClick: (String) -> Unit,
    onNewConversation: () -> Unit,
    onGroupClick: (String) -> Unit,
    onNewGroup: () -> Unit,
    onJoinGroup: () -> Unit,
    onSettingsClick: () -> Unit,
    viewModel: ConversationsViewModel = hiltViewModel(),
    groupListViewModel: GroupListViewModel = hiltViewModel()
) {
    val conversations by viewModel.conversations.collectAsState()
    val groups by groupListViewModel.groups.collectAsState()
    val isRefreshing by viewModel.isRefreshing.collectAsState()
    var showNewMenu by remember { mutableStateOf(false) }
    var conversationToBurn by remember { mutableStateOf<Conversation?>(null) }
    var groupForInfo by remember { mutableStateOf<GroupConversation?>(null) }

    // Back from a group ceremony: show the new group
    LaunchedEffect(Unit) { groupListViewModel.refresh() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Gwardian") },
                actions = {
                    IconButton(onClick = onSettingsClick) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings")
                    }
                }
            )
        },
        floatingActionButton = {
            Box {
                FloatingActionButton(onClick = { showNewMenu = true }) {
                    Icon(Icons.Default.Add, contentDescription = "New")
                }
                // Two-person conversation, or a group to create or join
                DropdownMenu(expanded = showNewMenu, onDismissRequest = { showNewMenu = false }) {
                    DropdownMenuItem(
                        text = { Text("New Conversation") },
                        leadingIcon = { Icon(Icons.Default.Person, contentDescription = null) },
                        onClick = {
                            showNewMenu = false
                            onNewConversation()
                        }
                    )
                    DropdownMenuItem(
                        text = { Text("New Group") },
                        leadingIcon = { Icon(Icons.Default.Groups, contentDescription = null) },
                        onClick = {
                            showNewMenu = false
                            onNewGroup()
                        }
                    )
                    DropdownMenuItem(
                        text = { Text("Join a Group") },
                        leadingIcon = { Icon(Icons.Default.QrCodeScanner, contentDescription = null) },
                        onClick = {
                            showNewMenu = false
                            onJoinGroup()
                        }
                    )
                }
            }
        }
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                viewModel.refresh()
                groupListViewModel.refresh()
            },
            modifier =
            Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            if (conversations.isEmpty() && groups.isEmpty() && !isRefreshing) {
                EmptyConversationsView(
                    modifier = Modifier.fillMaxSize(),
                    onNewConversation = { showNewMenu = true }
                )
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    items(groups, key = { "group-" + it.id }) { group ->
                        GroupCard(
                            group = group,
                            onClick = { onGroupClick(group.id) },
                            onLongClick = { groupForInfo = group }
                        )
                    }
                    items(conversations, key = { it.id }) { conversation ->
                        SwipeableConversationCard(
                            conversation = conversation,
                            onClick = { onConversationClick(conversation.id) },
                            onBurn = { conversationToBurn = conversation }
                        )
                    }
                }
            }
        }

    }

    groupForInfo?.let { group ->
        GroupInfoDialog(
            group = group,
            onDismiss = { groupForInfo = null },
            onDelete = {
                groupListViewModel.delete(group)
                groupForInfo = null
            }
        )
    }

    // Burn confirmation dialog
    conversationToBurn?.let { conv ->
        AlertDialog(
            onDismissRequest = { conversationToBurn = null },
            icon = {
                Icon(
                    Icons.Default.LocalFireDepartment,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.error
                )
            },
            title = { Text("Burn Conversation?") },
            text = {
                Text(
                    "This will permanently destroy the encryption pad and all messages with \"${conv.displayName}\". " +
                        "Your peer will be notified. This cannot be undone."
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        viewModel.burnConversation(conv)
                        conversationToBurn = null
                    },
                    colors =
                    ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.error
                    )
                ) {
                    Text("Burn")
                }
            },
            dismissButton = {
                TextButton(onClick = { conversationToBurn = null }) {
                    Text("Cancel")
                }
            }
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun GroupCard(group: GroupConversation, onClick: () -> Unit, onLongClick: () -> Unit) {
    Card(
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Groups, contentDescription = null, tint = Color(group.color.toColorLong()))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    group.displayName,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    "${group.members.size} members",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

/** Members and settings; deleting only affects this phone. */
@Composable
internal fun GroupInfoDialog(group: GroupConversation, onDismiss: () -> Unit, onDelete: () -> Unit) {
    var confirming by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(Icons.Default.Groups, contentDescription = null) },
        title = { Text(group.displayName) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                group.members.forEach { member ->
                    val you = if (member.index == group.me) " (you)" else ""
                    val creator = if (member.index == 0) " · creator" else ""
                    Text("${member.index + 1}. ${member.name}$you$creator")
                }
                Spacer(Modifier.height(8.dp))
                Text("Messages wait on the relay: ${group.messageRetention.displayName}", style = MaterialTheme.typography.bodySmall)
                Text("Disappearing messages: ${group.disappearingMessages.displayName}", style = MaterialTheme.typography.bodySmall)
                if (confirming) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Delete the group and its pads from this phone? The other members keep theirs. This cannot be undone.",
                        color = MaterialTheme.colorScheme.error
                    )
                }
            }
        },
        confirmButton = {
            if (confirming) {
                Button(
                    onClick = onDelete,
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                ) { Text("Delete") }
            } else {
                TextButton(onClick = { confirming = true }) {
                    Text("Delete from This Phone", color = MaterialTheme.colorScheme.error)
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        }
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SwipeableConversationCard(conversation: Conversation, onClick: () -> Unit, onBurn: () -> Unit) {
    val dismissState =
        rememberSwipeToDismissBoxState(
            confirmValueChange = { value ->
                if (value == SwipeToDismissBoxValue.EndToStart) {
                    onBurn()
                    false // Don't actually dismiss, show confirmation dialog
                } else {
                    false
                }
            }
        )

    val errorColor = MaterialTheme.colorScheme.error

    SwipeToDismissBox(
        state = dismissState,
        backgroundContent = {
            val color by animateColorAsState(
                when (dismissState.targetValue) {
                    SwipeToDismissBoxValue.EndToStart -> errorColor
                    else -> Color.Transparent
                },
                label = "background"
            )
            Box(
                modifier =
                Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(12.dp))
                    .background(color)
                    .padding(horizontal = 20.dp),
                contentAlignment = Alignment.CenterEnd
            ) {
                Icon(
                    Icons.Default.LocalFireDepartment,
                    contentDescription = "Burn",
                    tint = Color.White
                )
            }
        },
        enableDismissFromStartToEnd = false
    ) {
        ConversationCard(
            conversation = conversation,
            onClick = onClick
        )
    }
}

@Composable
private fun EmptyConversationsView(modifier: Modifier = Modifier, onNewConversation: () -> Unit) {
    Column(
        modifier = modifier.padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        // Icon circle
        Box(
            modifier =
            Modifier
                .size(100.dp)
                .background(
                    color = MaterialTheme.colorScheme.primary.copy(alpha = 0.1f),
                    shape = CircleShape
                ),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "💬",
                style = MaterialTheme.typography.displayMedium
            )
        }

        Spacer(modifier = Modifier.height(24.dp))

        Text(
            text = "No Conversations",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface
        )

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            text = "Start a secure conversation by meeting with someone in person " +
                "and performing a key exchange ceremony.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center
        )

        Spacer(modifier = Modifier.height(24.dp))

        Button(
            onClick = onNewConversation,
            colors =
            ButtonDefaults.buttonColors(
                containerColor = MaterialTheme.colorScheme.primary
            )
        ) {
            Icon(
                Icons.Default.Add,
                contentDescription = null,
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text("New Conversation")
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MnemonicTagsRow(mnemonic: List<String>, accentColor: Color) {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        mnemonic.forEach { word ->
            Surface(
                shape = RoundedCornerShape(4.dp),
                color = accentColor.copy(alpha = 0.15f)
            ) {
                Text(
                    text = word,
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                    style = MaterialTheme.typography.labelSmall,
                    color = accentColor,
                    fontWeight = FontWeight.Medium
                )
            }
        }
    }
}

@Composable
private fun ConversationCard(conversation: Conversation, onClick: () -> Unit) {
    val accentColor = Color(conversation.color.toColorLong())

    Card(
        modifier =
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        colors =
        CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        )
    ) {
        Column {
            Row(
                modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                // Color indicator avatar
                Surface(
                    modifier = Modifier.size(48.dp),
                    shape = CircleShape,
                    color = accentColor
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Text(
                            text = conversation.avatarInitials,
                            style = MaterialTheme.typography.titleMedium,
                            color = Color.White,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }

                Spacer(modifier = Modifier.width(16.dp))

                Column(modifier = Modifier.weight(1f)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = conversation.displayName,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f)
                        )
                        conversation.lastMessageAt?.let { timestamp ->
                            Text(
                                text = formatTimestamp(timestamp),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }

                    Spacer(modifier = Modifier.height(4.dp))

                    Text(
                        text = conversation.lastMessagePreview ?: "No messages yet",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )

                    // Mnemonic tags
                    if (conversation.mnemonic.isNotEmpty()) {
                        Spacer(modifier = Modifier.height(6.dp))
                        MnemonicTagsRow(
                            mnemonic = conversation.mnemonic,
                            accentColor = accentColor
                        )
                    }
                }
            }

            // Dual usage bar
            DualUsageBar(
                myUsage = conversation.myUsagePercentage.toFloat(),
                peerUsage = conversation.peerUsagePercentage.toFloat(),
                accentColor = accentColor
            )
        }
    }
}

@Composable
private fun DualUsageBar(myUsage: Float, peerUsage: Float, accentColor: Color) {
    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .height(4.dp)
            .background(MaterialTheme.colorScheme.surfaceVariant)
    ) {
        // My usage from left
        Box(
            modifier =
            Modifier
                .fillMaxWidth(myUsage / 100f)
                .height(4.dp)
                .background(accentColor)
                .align(Alignment.CenterStart)
        )
        // Peer usage from right
        Box(
            modifier =
            Modifier
                .fillMaxWidth(peerUsage / 100f)
                .height(4.dp)
                .background(accentColor.copy(alpha = 0.5f))
                .align(Alignment.CenterEnd)
        )
    }
}

private fun formatTimestamp(timestamp: Long): String {
    val now = System.currentTimeMillis()
    val diff = now - timestamp

    return when {
        diff < 60_000 -> "Now"
        diff < 3600_000 -> "${diff / 60_000}m"
        diff < 86400_000 -> "${diff / 3600_000}h"
        else -> SimpleDateFormat("MMM d", Locale.getDefault()).format(Date(timestamp))
    }
}
