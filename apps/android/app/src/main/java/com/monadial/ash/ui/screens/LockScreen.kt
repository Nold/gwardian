package com.monadial.ash.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import androidx.hilt.navigation.compose.hiltViewModel
import com.monadial.ash.ui.components.lock.PasscodeEntry
import com.monadial.ash.ui.viewmodels.LockViewModel
import kotlinx.coroutines.delay

/** App code lock screen, with the optional biometric shortcut. */
@Composable
fun LockScreen(viewModel: LockViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsState()
    val activity = LocalContext.current as? FragmentActivity
    var code by remember { mutableStateOf("") }
    var hasAttemptedAutoAuth by rememberSaveable { mutableStateOf(false) }

    // Ticks every second so the delay counts down
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(state.retryAtMillis) {
        while (true) {
            now = System.currentTimeMillis()
            if ((state.retryAtMillis ?: 0) <= now) break
            delay(1_000)
        }
    }
    val waitingMillis = state.retryAtMillis?.let { it - now }?.takeIf { it > 0 }

    // Offer biometrics once when the lock screen first shows
    LaunchedEffect(state.isBiometricUnlockEnabled) {
        if (!hasAttemptedAutoAuth && state.isBiometricUnlockEnabled && activity != null) {
            hasAttemptedAutoAuth = true
            viewModel.unlockWithBiometrics(activity)
        }
    }

    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(
            Icons.Default.Lock,
            contentDescription = null,
            modifier = Modifier.size(48.dp),
            tint = MaterialTheme.colorScheme.primary
        )
        Spacer(Modifier.height(24.dp))
        PasscodeEntry(
            title = "Enter your code",
            subtitle = lockSubtitle(waitingMillis, state.attemptsBeforeErase),
            code = code,
            onCodeChange = { code = it },
            onComplete = { entered ->
                if (!viewModel.unlock(entered)) code = ""
            },
            message = state.errorMessage,
            enabled = waitingMillis == null && !state.isAuthenticating,
            shakeTrigger = state.wrongCodeCount,
            onBiometric = if (state.isBiometricUnlockEnabled && activity != null) {
                { viewModel.unlockWithBiometrics(activity) }
            } else {
                null
            }
        )
    }
}

private fun lockSubtitle(waitingMillis: Long?, attemptsBeforeErase: Int?): String? = when {
    waitingMillis != null -> "Too many wrong codes. Try again in ${formatWait(waitingMillis)}."
    attemptsBeforeErase == 1 -> "1 attempt left before everything is erased"
    attemptsBeforeErase != null && attemptsBeforeErase <= 3 ->
        "$attemptsBeforeErase attempts left before everything is erased"
    else -> null
}

private fun formatWait(millis: Long): String {
    val seconds = (millis + 999) / 1000
    if (seconds < 60) return "$seconds s"
    val rest = seconds % 60
    return if (rest == 0L) "${seconds / 60} min" else "${seconds / 60} min $rest s"
}
