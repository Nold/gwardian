package com.monadial.ash

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.lifecycle.lifecycleScope
import com.monadial.ash.core.services.SettingsService
import com.monadial.ash.ui.AshApp
import com.monadial.ash.ui.components.keyboard.PrivateKeyboard
import com.monadial.ash.ui.theme.AshTheme
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    @Inject
    lateinit var settingsService: SettingsService

    private var wasInBackground = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        setContent {
            AshTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    // Ask keyboards not to learn anything typed in the app
                    PrivateKeyboard { AshApp() }
                }
            }
        }
    }

    override fun onStop() {
        super.onStop()
        // App is going to background
        wasInBackground = true
    }

    override fun onStart() {
        super.onStart()
        // App is coming to foreground
        if (wasInBackground) {
            wasInBackground = false
            lifecycleScope.launch {
                val lockOnBackground = settingsService.lockOnBackground.first()
                val biometricEnabled = settingsService.isBiometricEnabled.first()
                if (lockOnBackground && biometricEnabled) {
                    // Trigger lock via broadcast or event
                    // The AshApp composable will handle this via AppViewModel
                    settingsService.triggerLock()
                }
            }
        }
    }
}
