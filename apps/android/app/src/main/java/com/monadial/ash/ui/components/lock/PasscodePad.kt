package com.monadial.ash.ui.components.lock

import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Backspace
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.monadial.ash.core.services.applock.LockPolicy
import kotlin.math.roundToInt

/**
 * Title, dots, message and digit pad. Calls [onComplete] once all digits
 * are entered; the caller clears [code] to start over.
 */
@Composable
fun PasscodeEntry(
    title: String,
    code: String,
    onCodeChange: (String) -> Unit,
    onComplete: (String) -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    message: String? = null,
    enabled: Boolean = true,
    /** Changing this value shakes the dots */
    shakeTrigger: Int = 0,
    onBiometric: (() -> Unit)? = null
) {
    val shake = remember { Animatable(0f) }
    LaunchedEffect(shakeTrigger) {
        if (shakeTrigger == 0) return@LaunchedEffect
        for (offset in listOf(12f, -12f, 8f, -8f, 4f, 0f)) shake.animateTo(offset)
    }

    Column(modifier = modifier.padding(horizontal = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(title, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
        if (subtitle != null) {
            Spacer(Modifier.height(8.dp))
            Text(
                subtitle,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        }
        Spacer(Modifier.height(24.dp))
        PasscodeDots(filled = code.length, modifier = Modifier.offset { IntOffset(shake.value.roundToInt(), 0) })
        Spacer(Modifier.height(16.dp))
        Text(
            message ?: "",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.error,
            textAlign = TextAlign.Center,
            modifier = Modifier.heightIn(min = 40.dp)
        )
        PasscodePad(
            enabled = enabled,
            onDigit = { digit ->
                if (code.length < LockPolicy.CODE_LENGTH) {
                    val next = code + digit
                    onCodeChange(next)
                    if (next.length == LockPolicy.CODE_LENGTH) onComplete(next)
                }
            },
            onDelete = { if (code.isNotEmpty()) onCodeChange(code.dropLast(1)) },
            onBiometric = onBiometric
        )
    }
}

@Composable
fun PasscodeDots(filled: Int, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier.semantics { contentDescription = "$filled of ${LockPolicy.CODE_LENGTH} digits entered" },
        horizontalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        repeat(LockPolicy.CODE_LENGTH) { index ->
            val color = MaterialTheme.colorScheme.onSurface
            Box(
                Modifier
                    .size(14.dp)
                    .border(1.5.dp, color.copy(alpha = 0.6f), CircleShape)
                    .background(if (index < filled) color else color.copy(alpha = 0f), CircleShape)
            )
        }
    }
}

@Composable
fun PasscodePad(
    enabled: Boolean,
    onDigit: (Int) -> Unit,
    onDelete: () -> Unit,
    onBiometric: (() -> Unit)?
) {
    val rows = listOf(listOf(1, 2, 3), listOf(4, 5, 6), listOf(7, 8, 9))
    Column(
        modifier = Modifier.alpha(if (enabled) 1f else 0.4f),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        rows.forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                row.forEach { DigitKey(it, enabled, onDigit) }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(KEY_SIZE), contentAlignment = Alignment.Center) {
                if (onBiometric != null) {
                    IconButton(onClick = onBiometric, enabled = enabled, modifier = Modifier.size(KEY_SIZE)) {
                        Icon(Icons.Default.Fingerprint, contentDescription = "Unlock with biometrics")
                    }
                }
            }
            DigitKey(0, enabled, onDigit)
            IconButton(onClick = onDelete, enabled = enabled, modifier = Modifier.size(KEY_SIZE)) {
                Icon(Icons.AutoMirrored.Filled.Backspace, contentDescription = "Delete")
            }
        }
    }
}

@Composable
private fun DigitKey(digit: Int, enabled: Boolean, onDigit: (Int) -> Unit) {
    FilledTonalButton(
        onClick = { onDigit(digit) },
        enabled = enabled,
        shape = CircleShape,
        modifier = Modifier.size(KEY_SIZE)
    ) {
        Text("$digit", fontSize = 28.sp)
    }
}

private val KEY_SIZE = 76.dp
