package com.monadial.ash.core.services.bletransfer

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
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
import uniffi.ash.SecurityLevel

/**
 * Handing a copy of this device's pad to someone nearby over Bluetooth LE:
 * this phone is the central and connects to the receiver whose code the
 * person picks (docs/ble-transfer.md).
 *
 * All state changes happen on the main thread; GATT callbacks, which arrive on
 * binder threads, are posted there.
 *
 * @param pad this device's sending pad, as stored before the transfer.
 */
@SuppressLint("MissingPermission") // start() checks BleTransferPermissions first
class BlePadSenderSession(private val context: Context, private val pad: ByteArray) {
    /** A phone advertising a pad transfer nearby. */
    data class NearbyReceiver(val address: String, val code: String, val rssi: Int)

    private val _state = MutableStateFlow<BleTransferState>(BleTransferState.Idle)
    val state: StateFlow<BleTransferState> = _state.asStateFlow()

    private val _nearby = MutableStateFlow<List<NearbyReceiver>>(emptyList())
    val nearby: StateFlow<List<NearbyReceiver>> = _nearby.asStateFlow()

    private val main = Handler(Looper.getMainLooper())
    private val bluetooth = context.getSystemService(BluetoothManager::class.java)
    private val discovered = mutableMapOf<String, BluetoothDevice>()
    private var gatt: BluetoothGatt? = null
    private var toReceiver: BluetoothGattCharacteristic? = null
    private var flow: PadSenderFlow? = null
    private var reassembler = BlePacketReassembler()
    private val outbox = BlePacketOutbox()
    private var maxPacket = BlePacketOutbox.MIN_PACKET_SIZE
    private var writeInFlight = false
    private var sealedPacketCount = 0
    private var scanning = false

    fun start() {
        stop()
        val scanner = bluetooth?.adapter?.takeIf { it.isEnabled }?.bluetoothLeScanner
        when {
            !BleTransferPermissions.granted(context) -> return fail(BleTransferFailure.PermissionMissing)
            scanner == null -> return fail(BleTransferFailure.BluetoothUnavailable)
        }
        _nearby.value = emptyList()
        reassembler = BlePacketReassembler()
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(BleTransferUuids.service)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner?.startScan(listOf(filter), settings, scanCallback)
        scanning = true
        _state.value = BleTransferState.Scanning
    }

    /** Connect to the receiver showing this code. */
    fun connect(receiver: NearbyReceiver) {
        val device = discovered[receiver.address] ?: return
        stopScan()
        _state.value = BleTransferState.Connecting
        gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    /** The person confirmed the words match: seal and send the pad. */
    fun confirmWords() {
        val flow = flow ?: return
        try {
            outbox.enqueue(flow.confirmWordsAndSeal(pad, LEVEL), maxPacket)
            sealedPacketCount = outbox.count
            _state.value = BleTransferState.Transferring(0.0)
            pump()
        } catch (e: Exception) {
            fail(BleTransferFailure.ProtocolError(e.toString()))
        }
    }

    fun cancel() {
        stop()
        _state.value = BleTransferState.Idle
    }

    private fun stopScan() {
        if (scanning) bluetooth?.adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        scanning = false
    }

    private fun stop() {
        stopScan()
        gatt?.disconnect()
        gatt?.close()
        gatt = null
        discovered.clear()
        toReceiver = null
        flow = null
        outbox.clear()
        writeInFlight = false
        sealedPacketCount = 0
        maxPacket = BlePacketOutbox.MIN_PACKET_SIZE
    }

    private fun fail(failure: BleTransferFailure) {
        Log.w(TAG, "BLE send failed: $failure")
        stop()
        _state.value = BleTransferState.Failed(failure)
    }

    private fun perform(events: List<PadTransferEvent>) {
        for (event in events) {
            when (event) {
                is PadTransferEvent.Send -> {
                    outbox.enqueue(event.message, maxPacket)
                    pump()
                }
                is PadTransferEvent.CompareWords -> _state.value = BleTransferState.ComparingWords(event.words)
                is PadTransferEvent.ReceivedPad -> throw PadTransferFlowException("unexpected message")
            }
        }
    }

    /** Writes go one at a time, with response, which gives flow control. */
    private fun pump() {
        val gatt = gatt ?: return
        val characteristic = toReceiver ?: return
        val packet = outbox.next
        if (writeInFlight || packet == null) return
        writeInFlight = true
        val type = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        val queued = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(characteristic, packet, type) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.writeType = type
            @Suppress("DEPRECATION")
            characteristic.value = packet
            @Suppress("DEPRECATION")
            gatt.writeCharacteristic(characteristic)
        }
        if (!queued) fail(BleTransferFailure.Disconnected)
    }

    private fun receive(packet: ByteArray) {
        val message = reassembler.push(packet.toUBytes()) ?: return
        val current = flow
        if (current != null) {
            perform(current.handle(message))
        } else {
            // The first message is the receiver's offer
            val created = PadSenderFlow(message)
            flow = created
            perform(listOf(PadTransferEvent.Send(created.response)))
        }
    }

    private fun didWritePacket() {
        writeInFlight = false
        outbox.markSent()
        if (sealedPacketCount > 0) {
            val sent = sealedPacketCount - outbox.count
            _state.value = BleTransferState.Transferring(sent.toDouble() / sealedPacketCount)
            if (outbox.isEmpty) {
                _state.value = BleTransferState.Completed
                Log.i(TAG, "BLE pad sent")
                stop()
                return
            }
        }
        pump()
    }

    private fun subscribe(gatt: BluetoothGatt) {
        val service = gatt.getService(BleTransferUuids.service)
        val toReceiver = service?.getCharacteristic(BleTransferUuids.toReceiver)
        val toSender = service?.getCharacteristic(BleTransferUuids.toSender)
        val config = toSender?.getDescriptor(BleTransferUuids.clientConfig)
        if (toReceiver == null || config == null) {
            return fail(BleTransferFailure.ProtocolError("transfer service not found"))
        }
        this.toReceiver = toReceiver
        _state.value = BleTransferState.Exchanging
        gatt.setCharacteristicNotification(toSender, true)
        // Subscribing makes the receiver send its offer
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(config, BleTransferUuids.enableNotification)
        } else {
            @Suppress("DEPRECATION")
            config.value = BleTransferUuids.enableNotification
            @Suppress("DEPRECATION")
            gatt.writeDescriptor(config)
        }
    }

    private fun onPacket(characteristic: BluetoothGattCharacteristic, value: ByteArray) {
        if (characteristic.uuid != BleTransferUuids.toSender) return
        try {
            receive(value)
        } catch (e: Exception) {
            fail(BleTransferFailure.ProtocolError(e.toString()))
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val record = result.scanRecord
            // iOS receivers put the code in the local name, Android ones in service data
            val dataCode = record?.getServiceData(ParcelUuid(BleTransferUuids.service))
                ?.toString(Charsets.US_ASCII)
                ?.let { BleSessionCode.PREFIX + it }
            val name = listOf(record?.deviceName, dataCode).firstOrNull(BleSessionCode::isValid) ?: return
            val device = result.device
            val receiver = NearbyReceiver(device.address, name, result.rssi)
            main.post {
                discovered[device.address] = device
                _nearby.value = _nearby.value.filterNot { it.address == receiver.address } + receiver
            }
        }

        override fun onScanFailed(errorCode: Int) {
            main.post { fail(BleTransferFailure.BluetoothUnavailable) }
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                when {
                    newState == BluetoothProfile.STATE_CONNECTED -> gatt.requestMtu(REQUESTED_MTU)
                    _state.value != BleTransferState.Completed -> fail(BleTransferFailure.Disconnected)
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            main.post {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    maxPacket = maxOf(mtu - ATT_HEADER, BlePacketOutbox.MIN_PACKET_SIZE)
                }
                gatt.discoverServices()
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            main.post {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    subscribe(gatt)
                } else {
                    fail(BleTransferFailure.ProtocolError("service discovery failed"))
                }
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            main.post {
                if (status != BluetoothGatt.GATT_SUCCESS) fail(BleTransferFailure.ProtocolError("subscription refused"))
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            val packet = value.copyOf()
            main.post { onPacket(characteristic, packet) }
        }

        @Deprecated("Called instead of the ByteArray variant before Android 13")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            @Suppress("DEPRECATION")
            val packet = characteristic.value?.copyOf() ?: return
            main.post { onPacket(characteristic, packet) }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            main.post {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    didWritePacket()
                } else {
                    fail(BleTransferFailure.ProtocolError("write rejected by receiver"))
                }
            }
        }
    }

    companion object {
        /** Pads sent over Bluetooth are always recorded at this level. */
        val LEVEL = SecurityLevel.ENHANCED

        private const val TAG = "BlePadSender"
        private const val REQUESTED_MTU = 517
        private const val ATT_HEADER = 3
    }
}
