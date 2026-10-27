package com.monadial.ash.ui.components.keyboard

import android.content.Context
import android.content.pm.ApplicationInfo
import android.provider.Settings
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.PlatformTextInputMethodRequest
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect

/**
 * Asks every keyboard opened inside [content] not to learn what is typed
 * (IME_FLAG_NO_PERSONALIZED_LEARNING): Gboard and Samsung Keyboard switch
 * to incognito. Android cannot forbid a keyboard; this is a request that
 * well-behaved keyboards honour.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun PrivateKeyboard(content: @Composable () -> Unit) {
    InterceptPlatformTextInput(
        interceptor = { request, nextHandler ->
            val privateRequest = PlatformTextInputMethodRequest { outAttributes ->
                request.createInputConnection(outAttributes).also {
                    outAttributes.imeOptions = outAttributes.imeOptions or
                        EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
                }
            }
            nextHandler.startInputMethod(privateRequest)
        },
        content = content
    )
}

/**
 * Name of the active keyboard when it was not built into the phone, or
 * null for a preinstalled keyboard. A downloaded keyboard can read and send
 * everything typed with it.
 */
fun thirdPartyKeyboardName(context: Context): String? {
    val activeId = Settings.Secure.getString(context.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
        ?: return null
    val imm = context.getSystemService(InputMethodManager::class.java) ?: return null
    val keyboard = imm.enabledInputMethodList.firstOrNull { it.id == activeId } ?: return null
    val preinstalled = keyboard.serviceInfo.applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM != 0
    return if (preinstalled) null else keyboard.loadLabel(context.packageManager).toString()
}

/** [thirdPartyKeyboardName], checked again each time the screen resumes. */
@Composable
fun rememberThirdPartyKeyboardName(): String? {
    val context = LocalContext.current
    var name by remember { mutableStateOf(thirdPartyKeyboardName(context)) }
    LifecycleResumeEffect(context) {
        name = thirdPartyKeyboardName(context)
        onPauseOrDispose { }
    }
    return name
}

/** Shown above the message field while a downloaded keyboard is active. */
@Composable
fun ThirdPartyKeyboardWarning() {
    val name = rememberThirdPartyKeyboardName() ?: return
    Text(
        text = "Your keyboard \"$name\" was not built into the phone and may read what you type. " +
            "Switch to the phone's own keyboard for sensitive messages.",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onErrorContainer,
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.errorContainer)
            .padding(horizontal = 16.dp, vertical = 8.dp)
    )
}
