package com.monadial.ash.ui.screens

import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import androidx.hilt.navigation.compose.hiltViewModel
import com.monadial.ash.core.services.applock.LockPolicy
import com.monadial.ash.ui.viewmodels.LockViewModel
import com.monadial.ash.ui.viewmodels.SettingsViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    viewModel: SettingsViewModel = hiltViewModel(),
    lockViewModel: LockViewModel = hiltViewModel()
) {
    val lockState by lockViewModel.state.collectAsState()
    val activity = LocalContext.current as? FragmentActivity
    var showChangeCode by remember { mutableStateOf(false) }
    var showBiometricWarning by remember { mutableStateOf(false) }
    var showEraseWarning by remember { mutableStateOf(false) }
    val lockOnBackground by viewModel.lockOnBackground.collectAsState()
    val familyMode by viewModel.familyMode.collectAsState()
    val editedRelayUrl by viewModel.editedRelayUrl.collectAsState()
    val hasUnsavedChanges by viewModel.hasUnsavedChanges.collectAsState()
    val isTestingConnection by viewModel.isTestingConnection.collectAsState()
    val connectionTestResult by viewModel.connectionTestResult.collectAsState()
    val isBurningAll by viewModel.isBurningAll.collectAsState()

    var showPanicBurnDialog by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
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
                .verticalScroll(rememberScrollState())
                .padding(16.dp)
        ) {
            // Security Section
            SectionHeader(
                title = "Security",
                icon = Icons.Default.Shield
            )

            Card(
                modifier = Modifier.fillMaxWidth(),
                colors =
                CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surface
                )
            ) {
                TextButton(
                    onClick = { showChangeCode = true },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp)
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Change App Code", style = MaterialTheme.typography.bodyLarge)
                        Text(
                            "The 6-digit code that opens the app",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                if (lockViewModel.canUseBiometrics && activity != null) {
                    HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

                    SettingRow(
                        title = "Biometric Unlock",
                        description = "Shortcut instead of the app code",
                        checked = lockState.isBiometricUnlockEnabled,
                        onCheckedChange = { enabled ->
                            if (enabled) {
                                showBiometricWarning = true
                            } else {
                                lockViewModel.setBiometricUnlock(activity, false)
                            }
                        }
                    )
                }

                HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

                SettingRow(
                    title = "Lock on Background",
                    description = "Ask for the code when the app returns",
                    checked = lockOnBackground,
                    onCheckedChange = { viewModel.setLockOnBackground(it) }
                )

                HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

                SettingRow(
                    title = "Family Mode",
                    description = "QR ceremonies start without the six words",
                    checked = familyMode,
                    onCheckedChange = { viewModel.setFamilyMode(it) }
                )

                HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

                SettingRow(
                    title = "Erase After ${LockPolicy.ERASE_THRESHOLD} Wrong Codes",
                    description = "Destroy all conversations and pads",
                    checked = lockState.eraseAfterFailures,
                    onCheckedChange = { enabled ->
                        if (enabled) showEraseWarning = true else lockViewModel.setEraseAfterFailures(false)
                    }
                )
            }

            if (showChangeCode) {
                ChangePasscodeDialog(viewModel = lockViewModel, onDismiss = { showChangeCode = false })
            }

            if (showBiometricWarning && activity != null) {
                AlertDialog(
                    onDismissRequest = { showBiometricWarning = false },
                    title = { Text("Unlock with biometrics?") },
                    text = {
                        Text(
                            "Anyone whose fingerprint or face is registered on this phone will be able to " +
                                "open the app. If a fingerprint or face is added later, the app code will be " +
                                "required again."
                        )
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            showBiometricWarning = false
                            lockViewModel.setBiometricUnlock(activity, true)
                        }) { Text("Enable") }
                    },
                    dismissButton = {
                        TextButton(onClick = { showBiometricWarning = false }) { Text("Cancel") }
                    }
                )
            }

            if (showEraseWarning) {
                AlertDialog(
                    onDismissRequest = { showEraseWarning = false },
                    title = { Text("Erase after ${LockPolicy.ERASE_THRESHOLD} wrong codes?") },
                    text = {
                        Text(
                            "After ${LockPolicy.ERASE_THRESHOLD} wrong codes in a row, all conversations and pads " +
                                "are destroyed and cannot be recovered. Someone could trigger this on purpose by " +
                                "entering wrong codes."
                        )
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            showEraseWarning = false
                            lockViewModel.setEraseAfterFailures(true)
                        }) { Text("Enable", color = MaterialTheme.colorScheme.error) }
                    },
                    dismissButton = {
                        TextButton(onClick = { showEraseWarning = false }) { Text("Cancel") }
                    }
                )
            }

            Spacer(modifier = Modifier.height(24.dp))

            // Relay Section
            SectionHeader(
                title = "Network",
                icon = Icons.Default.Cloud
            )

            Card(
                modifier = Modifier.fillMaxWidth(),
                colors =
                CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surface
                )
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = "Relay Server URL",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.weight(1f)
                        )
                        if (hasUnsavedChanges) {
                            Text(
                                text = "Modified",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.tertiary
                            )
                        }
                    }

                    Spacer(modifier = Modifier.height(8.dp))

                    OutlinedTextField(
                        value = editedRelayUrl,
                        onValueChange = { viewModel.setEditedRelayUrl(it) },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        placeholder = { Text("https://relay.example.com") }
                    )

                    Spacer(modifier = Modifier.height(12.dp))

                    // Action buttons row
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        // Test button
                        OutlinedButton(
                            onClick = { viewModel.testConnection() },
                            enabled = !isTestingConnection && editedRelayUrl.isNotBlank(),
                            modifier = Modifier.weight(1f)
                        ) {
                            if (isTestingConnection) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    strokeWidth = 2.dp
                                )
                                Spacer(modifier = Modifier.width(4.dp))
                                Text("Testing...")
                            } else {
                                Icon(
                                    Icons.Default.Wifi,
                                    contentDescription = null,
                                    modifier = Modifier.size(16.dp)
                                )
                                Spacer(modifier = Modifier.width(4.dp))
                                Text("Test")
                            }
                        }

                        // Save button
                        Button(
                            onClick = { viewModel.saveRelayUrl() },
                            enabled = hasUnsavedChanges && editedRelayUrl.isNotBlank()
                        ) {
                            Text("Save")
                        }

                        // Reset button
                        TextButton(
                            onClick = { viewModel.resetRelayUrl() }
                        ) {
                            Text("Reset")
                        }
                    }

                    // Connection test result
                    connectionTestResult?.let { result ->
                        Spacer(modifier = Modifier.height(12.dp))
                        Row(
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            val statusColor = if (result.success) {
                                MaterialTheme.colorScheme.primary
                            } else {
                                MaterialTheme.colorScheme.error
                            }
                            Icon(
                                imageVector = if (result.success) {
                                    Icons.Default.Wifi
                                } else {
                                    Icons.Default.Warning
                                },
                                contentDescription = null,
                                modifier = Modifier.size(16.dp),
                                tint = statusColor
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                text =
                                if (result.success) {
                                    val latency = result.latencyMs?.let { "${it}ms" } ?: ""
                                    val version = result.version ?: "OK"
                                    "Connected ($version) $latency"
                                } else {
                                    "Failed: ${result.error ?: "Unknown error"}"
                                },
                                style = MaterialTheme.typography.bodySmall,
                                color = statusColor
                            )
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(24.dp))

            // About Section
            SectionHeader(
                title = "About",
                icon = Icons.Default.Info
            )

            Card(
                modifier = Modifier.fillMaxWidth(),
                colors =
                CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surface
                )
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text(
                        text = "ASH Secure Messaging",
                        style = MaterialTheme.typography.titleMedium
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = "Version 1.0.0",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "One-Time Pad encryption for truly secure messaging.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            Spacer(modifier = Modifier.height(32.dp))

            // Danger Zone
            SectionHeader(
                title = "Danger Zone",
                icon = Icons.Default.Warning,
                color = MaterialTheme.colorScheme.error
            )

            Card(
                modifier = Modifier.fillMaxWidth(),
                colors =
                CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.errorContainer
                )
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text(
                        text = "Burn All Conversations",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onErrorContainer
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = "Permanently destroy all encryption pads and messages. This cannot be undone.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onErrorContainer.copy(alpha = 0.8f)
                    )
                    Spacer(modifier = Modifier.height(12.dp))

                    Button(
                        onClick = { showPanicBurnDialog = true },
                        enabled = !isBurningAll,
                        modifier = Modifier.fillMaxWidth(),
                        colors =
                        ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.error
                        )
                    ) {
                        if (isBurningAll) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                                color = MaterialTheme.colorScheme.onError
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                        } else {
                            Icon(
                                Icons.Default.LocalFireDepartment,
                                contentDescription = null,
                                modifier = Modifier.size(16.dp)
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                        }
                        Text(if (isBurningAll) "Burning..." else "Burn All")
                    }
                }
            }

            Spacer(modifier = Modifier.height(32.dp))
        }
    }

    // Panic Burn Confirmation Dialog
    if (showPanicBurnDialog) {
        AlertDialog(
            onDismissRequest = { showPanicBurnDialog = false },
            icon = {
                Icon(
                    Icons.Default.LocalFireDepartment,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.error,
                    modifier = Modifier.size(32.dp)
                )
            },
            title = { Text("Burn All Conversations?") },
            text = {
                Text(
                    "This will permanently destroy ALL encryption pads and messages across ALL conversations. " +
                        "Your peers will be notified. This action CANNOT be undone."
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        showPanicBurnDialog = false
                        viewModel.burnAllConversations()
                    },
                    colors =
                    ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.error
                    )
                ) {
                    Text("Burn All")
                }
            },
            dismissButton = {
                TextButton(onClick = { showPanicBurnDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }
}

@Composable
private fun SectionHeader(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    color: Color = MaterialTheme.colorScheme.primary
) {
    Row(
        modifier = Modifier.padding(bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = color,
            modifier = Modifier.size(18.dp)
        )
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmall,
            color = color,
            fontWeight = FontWeight.Medium
        )
    }
}

@Composable
private fun SettingRow(
    title: String,
    description: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    enabled: Boolean = true
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
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                color =
                if (enabled) {
                    MaterialTheme.colorScheme.onSurface
                } else {
                    MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
                }
            )
            Text(
                text = description,
                style = MaterialTheme.typography.bodySmall,
                color =
                if (enabled) {
                    MaterialTheme.colorScheme.onSurfaceVariant
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                }
            )
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            enabled = enabled
        )
    }
}
