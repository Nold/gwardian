package com.monadial.ash

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import com.monadial.ash.core.services.SettingsService
import com.monadial.ash.core.services.applock.AppLockManager
import com.monadial.ash.ui.AshApp
import com.monadial.ash.ui.components.keyboard.PrivateKeyboard
import com.monadial.ash.ui.theme.AshTheme
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

@AndroidEntryPoint
// FragmentActivity: the biometric prompt needs it
class MainActivity : FragmentActivity() {
    @Inject
    lateinit var settingsService: SettingsService

    @Inject
    lateinit var appLock: AppLockManager

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
        // A rotation is not leaving the app
        if (isChangingConfigurations) return
        // App is going to background: lock now, so the code is asked on return
        lifecycleScope.launch {
            if (settingsService.lockOnBackground.first()) {
                appLock.lock()
            }
        }
    }

    override fun onStart() {
        super.onStart()
        appLock.refresh()
    }
}
