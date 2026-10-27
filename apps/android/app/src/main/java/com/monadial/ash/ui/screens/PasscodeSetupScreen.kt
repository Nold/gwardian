package com.monadial.ash.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.monadial.ash.ui.components.lock.PasscodeEntry
import com.monadial.ash.ui.viewmodels.LockViewModel

/** Mandatory app code setup, after onboarding or after an update. */
@Composable
fun PasscodeSetupScreen(viewModel: LockViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsState()
    var code by remember { mutableStateOf("") }
    var firstEntry by remember { mutableStateOf<String?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    var mismatchCount by remember { mutableIntStateOf(0) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        if (state.wasErased) {
            Text(
                "Too many wrong codes: all conversations and pads were erased.",
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
                    .background(MaterialTheme.colorScheme.errorContainer, RoundedCornerShape(12.dp))
                    .padding(16.dp)
            )
            Spacer(Modifier.height(24.dp))
        }

        PasscodeEntry(
            title = if (firstEntry == null) "Choose an app code" else "Confirm your code",
            subtitle = if (firstEntry == null) {
                "6 digits, different from your phone's PIN. Someone who can unlock your phone " +
                    "still cannot open your conversations."
            } else {
                "Enter the same code again."
            },
            code = code,
            onCodeChange = { code = it },
            onComplete = { entered ->
                val first = firstEntry
                when {
                    first == null -> {
                        firstEntry = entered
                        message = null
                    }
                    first == entered -> viewModel.configure(entered)
                    else -> {
                        message = "The codes don't match. Choose a code again."
                        mismatchCount++
                        firstEntry = null
                    }
                }
                code = ""
            },
            message = message ?: state.errorMessage,
            shakeTrigger = mismatchCount
        )

        Spacer(Modifier.height(16.dp))
        Text(
            "There is no way to recover a forgotten code. Without it, your conversations can only be " +
                "erased by uninstalling the app.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 32.dp)
        )
    }
}
