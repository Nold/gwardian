package com.monadial.ash.ui.screens

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.monadial.ash.ui.components.lock.PasscodeEntry
import com.monadial.ash.ui.viewmodels.LockViewModel

private enum class ChangeStep { CURRENT, NEW, CONFIRM }

/** Change the app code from settings. */
@Composable
fun ChangePasscodeDialog(viewModel: LockViewModel, onDismiss: () -> Unit) {
    val state by viewModel.state.collectAsState()
    var step by remember { mutableStateOf(ChangeStep.CURRENT) }
    var current by remember { mutableStateOf("") }
    var newCode by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    var shakeCount by remember { mutableIntStateOf(0) }
    val waiting = (state.retryAtMillis ?: 0) > System.currentTimeMillis()

    fun fail(text: String?) {
        message = text
        viewModel.clearError()
        shakeCount++
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(modifier = Modifier.fillMaxSize()) {
            Box {
                TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.TopStart).padding(8.dp)) {
                    Text("Cancel")
                }
                Column(
                    modifier = Modifier.align(Alignment.Center),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    PasscodeEntry(
                        title = when (step) {
                            ChangeStep.CURRENT -> "Enter your current code"
                            ChangeStep.NEW -> "Enter a new code"
                            ChangeStep.CONFIRM -> "Confirm the new code"
                        },
                        subtitle = if (waiting) "Too many wrong codes. Wait before trying again." else null,
                        code = code,
                        onCodeChange = { code = it },
                        onComplete = { entered ->
                            code = ""
                            when (step) {
                                // Checked right away; a wrong code counts as a failed attempt
                                ChangeStep.CURRENT -> if (viewModel.unlock(entered)) {
                                    current = entered
                                    message = null
                                    step = ChangeStep.NEW
                                } else {
                                    fail(viewModel.state.value.errorMessage)
                                }
                                ChangeStep.NEW -> {
                                    newCode = entered
                                    step = ChangeStep.CONFIRM
                                }
                                ChangeStep.CONFIRM -> when {
                                    entered != newCode -> {
                                        fail("The codes don't match.")
                                        step = ChangeStep.NEW
                                    }
                                    viewModel.changeCode(current, newCode) -> onDismiss()
                                    else -> {
                                        fail(viewModel.state.value.errorMessage)
                                        step = ChangeStep.CURRENT
                                    }
                                }
                            }
                        },
                        message = message,
                        enabled = !waiting,
                        shakeTrigger = shakeCount
                    )
                }
            }
        }
    }
}
