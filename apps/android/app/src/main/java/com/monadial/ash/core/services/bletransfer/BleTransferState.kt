package com.monadial.ash.core.services.bletransfer

import android.Manifest
import android.bluetooth.BluetoothGattDescriptor
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import java.util.UUID
import uniffi.ash.bleServiceUuid
import uniffi.ash.bleToReceiverUuid
import uniffi.ash.bleToSenderUuid

/** Progress of a Bluetooth pad transfer, shown by the transfer screens. */
sealed interface BleTransferState {
    data object Idle : BleTransferState

    data object WaitingForBluetooth : BleTransferState

    /** Receiver: advertising this code, waiting for the pad owner. */
    data class Advertising(val code: String) : BleTransferState

    /** Sender: looking for nearby receivers. */
    data object Scanning : BleTransferState

    data object Connecting : BleTransferState

    /** Running the key exchange before the words can be shown. */
    data object Exchanging : BleTransferState

    /** Both people must compare these words and confirm. */
    data class ComparingWords(val words: List<String>) : BleTransferState

    data class Transferring(val progress: Double) : BleTransferState

    data object Completed : BleTransferState

    data class Failed(val failure: BleTransferFailure) : BleTransferState
}

sealed interface BleTransferFailure {
    data object BluetoothUnavailable : BleTransferFailure

    data object PermissionMissing : BleTransferFailure

    data object Disconnected : BleTransferFailure

    /** The exchange failed; the six words cannot be trusted. Start over. */
    data class ProtocolError(val reason: String) : BleTransferFailure
}

/** GATT identifiers, defined once in the Rust core for iOS and Android. */
object BleTransferUuids {
    val service: UUID by lazy { UUID.fromString(bleServiceUuid()) }
    val toReceiver: UUID by lazy { UUID.fromString(bleToReceiverUuid()) }
    val toSender: UUID by lazy { UUID.fromString(bleToSenderUuid()) }

    /** Client Characteristic Configuration descriptor, used to subscribe. */
    val clientConfig: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    val enableNotification: ByteArray get() = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE.copyOf()
}

/** Runtime permissions the transfer needs; the screen requests them first. */
object BleTransferPermissions {
    val required: Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_ADVERTISE
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    fun granted(context: Context): Boolean =
        required.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
}
