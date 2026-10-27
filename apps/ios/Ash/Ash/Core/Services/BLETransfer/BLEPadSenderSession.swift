//
//  BLEPadSenderSession.swift
//  Ash
//
//  Handing a copy of this device's pad to someone nearby over Bluetooth LE:
//  this phone is the central and connects to the receiver whose code the
//  person picks (docs/ble-transfer.md).
//

import CoreBluetooth
import Foundation

@MainActor
@Observable
final class BLEPadSenderSession: NSObject {
    /// A phone advertising a pad transfer nearby.
    struct NearbyReceiver: Identifiable, Equatable {
        let id: UUID
        let code: String
        let rssi: Int
    }

    private(set) var state: BLETransferState = .idle
    private(set) var nearby: [NearbyReceiver] = []

    /// Pads sent over Bluetooth are always recorded at this level.
    static let level = SecurityLevel.enhanced

    private let pad: [UInt8]
    private var central: CBCentralManager?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var toReceiver: CBCharacteristic?
    private var flow: PadSenderFlow?
    private var reassembler = BlePacketReassembler()
    private var outbox = BLEPacketOutbox()
    private var writeInFlight = false
    private var sealedPacketCount = 0

    /// - Parameter pad: this device's sending pad, as stored before the transfer.
    init(pad: [UInt8]) {
        self.pad = pad
        super.init()
    }

    /// Start looking for receivers. Delegate callbacks arrive on the main queue.
    func start() {
        stop()
        nearby = []
        reassembler = BlePacketReassembler()
        state = .waitingForBluetooth
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// Connect to the receiver showing this code.
    func connect(to receiver: NearbyReceiver) {
        guard let central, let target = discovered[receiver.id] else { return }
        central.stopScan()
        peripheral = target
        target.delegate = self
        state = .connecting
        central.connect(target)
    }

    /// The person confirmed the words match: seal and send the pad.
    func confirmWords() {
        guard let flow, let peripheral else { return }
        do {
            let sealed = try flow.confirmWordsAndSeal(pad: pad, level: Self.level)
            try outbox.enqueue(sealed, maxPacket: peripheral.maximumWriteValueLength(for: .withResponse))
            sealedPacketCount = outbox.count
            state = .transferring(progress: 0)
            pump()
        } catch {
            fail(.protocolError("\(error)"))
        }
    }

    func cancel() {
        stop()
        state = .idle
    }

    private func stop() {
        central?.stopScan()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        central?.delegate = nil
        central = nil
        peripheral = nil
        discovered = [:]
        toReceiver = nil
        flow = nil
        outbox.clear()
        writeInFlight = false
        sealedPacketCount = 0
    }

    private func fail(_ failure: BLETransferFailure) {
        Log.warning(.ceremony, "BLE send failed: \(failure)")
        stop()
        state = .failed(failure)
    }

    private func perform(_ events: [PadTransferEvent]) throws {
        for event in events {
            switch event {
            case .send(let message):
                let maxPacket = peripheral?.maximumWriteValueLength(for: .withResponse) ?? 20
                try outbox.enqueue(message, maxPacket: maxPacket)
                pump()
            case .compareWords(let words):
                state = .comparingWords(words)
            case .receivedPad:
                throw PadTransferFlowError.unexpectedMessage
            }
        }
    }

    /// Writes go one at a time, with response, which gives flow control.
    private func pump() {
        guard !writeInFlight, let peripheral, let toReceiver, let packet = outbox.next else { return }
        writeInFlight = true
        peripheral.writeValue(Data(packet), for: toReceiver, type: .withResponse)
    }

    private func receive(_ packet: [UInt8]) throws {
        guard let message = try reassembler.push(packet: packet) else { return }
        if let flow {
            try perform(flow.handle(message))
        } else {
            // The first message is the receiver's offer
            let flow = try PadSenderFlow(offer: message)
            self.flow = flow
            try perform([.send(flow.response)])
        }
    }

    private func didWritePacket() {
        writeInFlight = false
        outbox.markSent()
        if sealedPacketCount > 0 {
            let sent = sealedPacketCount - outbox.count
            state = .transferring(progress: Double(sent) / Double(sealedPacketCount))
            if outbox.isEmpty {
                state = .completed
                Log.info(.ceremony, "BLE pad sent")
                stop()
                return
            }
        }
        pump()
    }
}

extension BLEPadSenderSession: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let managerState = central.state
        MainActor.assumeIsolated {
            if managerState == .poweredOn {
                self.central?.scanForPeripherals(withServices: [BLETransferUUIDs.service])
                state = .scanning
            } else if let failure = BLETransferFailure(state: managerState) {
                fail(failure)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let rssi = RSSI.intValue
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            guard BLESessionCode.isValid(name), let name else { return }
            discovered[peripheral.identifier] = peripheral
            let receiver = NearbyReceiver(id: peripheral.identifier, code: name, rssi: rssi)
            if let index = nearby.firstIndex(where: { $0.id == receiver.id }) {
                nearby[index] = receiver
            } else {
                nearby.append(receiver)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            peripheral.discoverServices([BLETransferUUIDs.service])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            fail(.disconnected)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard state != .completed else { return }
            fail(.disconnected)
        }
    }
}

extension BLEPadSenderSession: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == BLETransferUUIDs.service }) else {
                fail(.protocolError("transfer service not found"))
                return
            }
            peripheral.discoverCharacteristics(
                [BLETransferUUIDs.toReceiver, BLETransferUUIDs.toSender],
                for: service
            )
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        nonisolated(unsafe) let peripheral = peripheral
        nonisolated(unsafe) let service = service
        MainActor.assumeIsolated {
            let characteristics = service.characteristics ?? []
            guard
                let toReceiver = characteristics.first(where: { $0.uuid == BLETransferUUIDs.toReceiver }),
                let toSender = characteristics.first(where: { $0.uuid == BLETransferUUIDs.toSender })
            else {
                fail(.protocolError("transfer characteristics not found"))
                return
            }
            self.toReceiver = toReceiver
            state = .exchanging
            // Subscribing makes the receiver send its offer
            peripheral.setNotifyValue(true, for: toSender)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let packet = characteristic.value.map { [UInt8]($0) }
        let isToSender = characteristic.uuid == BLETransferUUIDs.toSender
        let failed = error != nil
        MainActor.assumeIsolated {
            guard isToSender else { return }
            guard !failed, let packet else {
                fail(.disconnected)
                return
            }
            do {
                try receive(packet)
            } catch {
                fail(.protocolError("\(error)"))
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let failed = error != nil
        MainActor.assumeIsolated {
            guard !failed else {
                fail(.protocolError("write rejected by receiver"))
                return
            }
            didWritePacket()
        }
    }
}
