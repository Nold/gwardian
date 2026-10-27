package com.monadial.ash.core.services.bletransfer

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import uniffi.ash.BlePacketReassembler

/**
 * Receiving a pad over Bluetooth LE: this phone is the peripheral and
 * advertises a short code (docs/ble-transfer.md). The resulting pad is
 * recorded at the Enhanced security level.
 *
 * All state changes happen on the main thread; GATT callbacks, which arrive on
 * binder threads, are posted there.
 */
@SuppressLint("MissingPermission") // start() checks BleTransferPermissions first
class BlePadReceiverSession(private val context: Context) {
    private val _state = MutableStateFlow<BleTransferState>(BleTransferState.Idle)
    val state: StateFlow<BleTransferState> = _state.asStateFlow()

    /** Set once the pad arrived and was authenticated. */
    var receivedPad: PadTransferEvent.ReceivedPad? = null
        private set

    private val main = Handler(Looper.getMainLooper())
    private val bluetooth = context.getSystemService(BluetoothManager::class.java)
    private var server: BluetoothGattServer? = null
    private var toSender: BluetoothGattCharacteristic? = null
    private var subscriber: BluetoothDevice? = null
    private var flow: PadReceiverFlow? = null
    private var reassembler = BlePacketReassembler()
    private val outbox = BlePacketOutbox()
    private var maxPacket = BlePacketOutbox.MIN_PACKET_SIZE
    private var notificationInFlight = false
    private var code = ""

    fun start() {
        stop()
        val adapter = bluetooth?.adapter
        when {
            !BleTransferPermissions.granted(context) -> return fail(BleTransferFailure.PermissionMissing)
            adapter == null || !adapter.isEnabled || adapter.bluetoothLeAdvertiser == null ->
                return fail(BleTransferFailure.BluetoothUnavailable)
        }
        try {
            code = BleSessionCode.generate()
            flow = PadReceiverFlow()
        } catch (e: Exception) {
            return fail(BleTransferFailure.ProtocolError(e.toString()))
        }
        reassembler = BlePacketReassembler()
        _state.value = BleTransferState.WaitingForBluetooth
        server = bluetooth?.openGattServer(context, serverCallback)?.also { it.addService(buildService()) }
            ?: return fail(BleTransferFailure.BluetoothUnavailable)
    }

    /** The person confirmed the words match the other phone's. */
    fun confirmWords() {
        val flow = flow ?: return
        try {
            perform(flow.confirmWords())
            if (receivedPad == null) {
                _state.value = BleTransferState.Transferring(reassembler.progress())
            } else {
                stop()
            }
        } catch (e: Exception) {
            fail(BleTransferFailure.ProtocolError(e.toString()))
        }
    }

    fun cancel() {
        stop()
        _state.value = BleTransferState.Idle
    }

    private fun stop() {
        bluetooth?.adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        subscriber?.let { server?.cancelConnection(it) }
        server?.close()
        server = null
        toSender = null
        subscriber = null
        flow = null
        outbox.clear()
        notificationInFlight = false
        maxPacket = BlePacketOutbox.MIN_PACKET_SIZE
    }

    private fun fail(failure: BleTransferFailure) {
        Log.w(TAG, "BLE receive failed: $failure")
        stop()
        _state.value = BleTransferState.Failed(failure)
    }

    private fun buildService(): BluetoothGattService {
        val toReceiver = BluetoothGattCharacteristic(
            BleTransferUuids.toReceiver,
            BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        val toSender = BluetoothGattCharacteristic(
            BleTransferUuids.toSender,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        ).apply {
            addDescriptor(
                BluetoothGattDescriptor(
                    BleTransferUuids.clientConfig,
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
                )
            )
        }
        this.toSender = toSender
        return BluetoothGattService(BleTransferUuids.service, BluetoothGattService.SERVICE_TYPE_PRIMARY).apply {
            addCharacteristic(toReceiver)
            addCharacteristic(toSender)
        }
    }

    private fun startAdvertising() {
        val advertiser = bluetooth?.adapter?.bluetoothLeAdvertiser ?: return fail(BleTransferFailure.BluetoothUnavailable)
        val service = ParcelUuid(BleTransferUuids.service)
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(service)
            .setIncludeDeviceName(false)
            .build()
        // Android cannot set its own local name, so the code goes in service data
        val scanResponse = AdvertiseData.Builder()
            .addServiceData(service, code.toByteArray(Charsets.US_ASCII))
            .setIncludeDeviceName(false)
            .build()
        advertiser.startAdvertising(settings, data, scanResponse, advertiseCallback)
    }

    private fun perform(events: List<PadTransferEvent>) {
        for (event in events) {
            when (event) {
                is PadTransferEvent.Send -> {
                    outbox.enqueue(event.message, maxPacket)
                    pump()
                }
                is PadTransferEvent.CompareWords -> _state.value = BleTransferState.ComparingWords(event.words)
                is PadTransferEvent.ReceivedPad -> {
                    // Callers stop the session once any pending write response is sent
                    receivedPad = event
                    _state.value = BleTransferState.Completed
                    Log.i(TAG, "BLE pad received")
                }
            }
        }
    }

    /** Android allows one notification in flight; the next follows onNotificationSent. */
    private fun pump() {
        val server = server ?: return
        val device = subscriber ?: return
        val characteristic = toSender ?: return
        val packet = outbox.next
        if (notificationInFlight || packet == null) return
        notificationInFlight = true
        val queued = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            server.notifyCharacteristicChanged(device, characteristic, false, packet) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.value = packet
            @Suppress("DEPRECATION")
            server.notifyCharacteristicChanged(device, characteristic, false)
        }
        if (!queued) fail(BleTransferFailure.Disconnected)
    }

    private fun receive(packet: ByteArray) {
        val message = reassembler.push(packet.toUBytes())
        if (message == null) {
            if (_state.value is BleTransferState.Transferring) {
                _state.value = BleTransferState.Transferring(reassembler.progress())
            }
            return
        }
        val flow = flow ?: throw PadTransferFlowException("unexpected message")
        perform(flow.handle(message))
    }

    private fun onSubscribed(device: BluetoothDevice) {
        val flow = flow ?: return
        // One transfer per session: ignore anyone else once connected
        if (subscriber != null) return
        subscriber = device
        bluetooth?.adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        _state.value = BleTransferState.Exchanging
        try {
            perform(listOf(PadTransferEvent.Send(flow.offer)))
        } catch (e: Exception) {
            fail(BleTransferFailure.ProtocolError(e.toString()))
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            main.post { _state.value = BleTransferState.Advertising(BleSessionCode.PREFIX + code) }
        }

        override fun onStartFailure(errorCode: Int) {
            main.post { fail(BleTransferFailure.BluetoothUnavailable) }
        }
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            main.post {
                if (status == BluetoothGatt.GATT_SUCCESS) startAdvertising() else fail(BleTransferFailure.BluetoothUnavailable)
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            main.post {
                val lostSubscriber = newState == BluetoothProfile.STATE_DISCONNECTED &&
                    device.address == subscriber?.address
                // Once the sealed pad is here, the link is no longer needed to finish
                val padPending = flow?.hasSealedPad == true
                if (lostSubscriber && receivedPad == null && !padPending) fail(BleTransferFailure.Disconnected)
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            main.post { maxPacket = maxOf(mtu - ATT_HEADER, BlePacketOutbox.MIN_PACKET_SIZE) }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            main.post {
                notificationInFlight = false
                if (status != BluetoothGatt.GATT_SUCCESS) return@post fail(BleTransferFailure.Disconnected)
                outbox.markSent()
                pump()
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            val subscribing = descriptor.uuid == BleTransferUuids.clientConfig &&
                value?.contentEquals(BleTransferUuids.enableNotification) == true
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            if (subscribing) main.post { onSubscribed(device) }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            val packet = value?.copyOf() ?: ByteArray(0)
            main.post {
                val accepted = device.address == subscriber?.address &&
                    characteristic.uuid == BleTransferUuids.toReceiver &&
                    !preparedWrite && offset == 0
                if (!accepted) {
                    if (responseNeeded) {
                        server?.sendResponse(device, requestId, BluetoothGatt.GATT_WRITE_NOT_PERMITTED, 0, null)
                    }
                    return@post
                }
                val status = try {
                    receive(packet)
                    BluetoothGatt.GATT_SUCCESS
                } catch (e: Exception) {
                    Log.w(TAG, "BLE packet rejected: $e")
                    BluetoothGatt.GATT_FAILURE
                }
                // Answer before stopping, so the sender learns the outcome of its last write
                if (responseNeeded) server?.sendResponse(device, requestId, status, 0, null)
                when {
                    status != BluetoothGatt.GATT_SUCCESS -> fail(BleTransferFailure.ProtocolError("packet rejected"))
                    receivedPad != null -> stop()
                }
            }
        }
    }

    private companion object {
        const val TAG = "BlePadReceiver"
        const val ATT_HEADER = 3
    }
}
