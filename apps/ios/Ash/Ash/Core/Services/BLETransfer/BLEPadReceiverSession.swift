//
//  BLEPadReceiverSession.swift
//  Ash
//
//  Receiving a pad over Bluetooth LE: this phone is the peripheral and
//  advertises a short code (docs/ble-transfer.md). The resulting pad is
//  recorded at the Enhanced security level.
//

import CoreBluetooth
import Foundation

@MainActor
@Observable
final class BLEPadReceiverSession: NSObject {
    private(set) var state: BLETransferState = .idle
    /// Set once the pad arrived and was authenticated.
    private(set) var receivedPad: ReceivedPad?

    private var manager: CBPeripheralManager?
    private var toSender: CBMutableCharacteristic?
    private var subscriber: CBCentral?
    private var flow: PadReceiverFlow?
    private var reassembler = BlePacketReassembler()
    private var outbox = BLEPacketOutbox()
    private var code = ""

    /// Start advertising. Delegate callbacks arrive on the main queue.
    func start() {
        stop()
        do {
            code = try BLESessionCode.generate()
            flow = try PadReceiverFlow()
        } catch {
            fail(.protocolError("\(error)"))
            return
        }
        reassembler = BlePacketReassembler()
        state = .waitingForBluetooth
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    /// The person confirmed the words match the other phone's.
    func confirmWords() {
        guard let flow else { return }
        do {
            try perform(flow.confirmWords())
            if receivedPad == nil {
                state = .transferring(progress: reassembler.progress())
            } else {
                stop()
            }
        } catch {
            fail(.protocolError("\(error)"))
        }
    }

    func cancel() {
        stop()
        state = .idle
    }

    private func stop() {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager?.delegate = nil
        manager = nil
        toSender = nil
        subscriber = nil
        flow = nil
        outbox.clear()
    }

    private func fail(_ failure: BLETransferFailure) {
        Log.warning(.ceremony, "BLE receive failed: \(failure)")
        stop()
        state = .failed(failure)
    }

    private func publishService() {
        let toReceiver = CBMutableCharacteristic(
            type: BLETransferUUIDs.toReceiver,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        let toSender = CBMutableCharacteristic(
            type: BLETransferUUIDs.toSender,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        let service = CBMutableService(type: BLETransferUUIDs.service, primary: true)
        service.characteristics = [toReceiver, toSender]
        self.toSender = toSender
        manager?.add(service)
    }

    private func perform(_ events: [PadTransferEvent]) throws {
        for event in events {
            switch event {
            case .send(let message):
                let maxPacket = subscriber?.maximumUpdateValueLength ?? 20
                try outbox.enqueue(message, maxPacket: maxPacket)
                pump()
            case .compareWords(let words):
                state = .comparingWords(words)
            case .receivedPad(let pad, let level):
                // Callers stop the session once any pending write response is sent
                receivedPad = ReceivedPad(pad: pad, level: level)
                state = .completed
                Log.info(.ceremony, "BLE pad received")
            }
        }
    }

    /// Send queued packets until CoreBluetooth's queue is full; resumed in
    /// `peripheralManagerIsReady(toUpdateSubscribers:)`.
    private func pump() {
        guard let manager, let toSender, let subscriber else { return }
        while let packet = outbox.next {
            guard manager.updateValue(Data(packet), for: toSender, onSubscribedCentrals: [subscriber]) else {
                return
            }
            outbox.markSent()
        }
    }

    private func receive(_ packet: [UInt8]) throws {
        guard let message = try reassembler.push(packet: packet) else {
            if case .transferring = state {
                state = .transferring(progress: reassembler.progress())
            }
            return
        }
        guard let flow else { throw PadTransferFlowError.unexpectedMessage }
        try perform(flow.handle(message))
    }
}

extension BLEPadReceiverSession: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let managerState = peripheral.state
        MainActor.assumeIsolated {
            if managerState == .poweredOn {
                publishService()
            } else if let failure = BLETransferFailure(state: managerState) {
                fail(failure)
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        let failed = error != nil
        MainActor.assumeIsolated {
            guard !failed else {
                fail(.bluetoothUnavailable)
                return
            }
            manager?.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [BLETransferUUIDs.service],
                CBAdvertisementDataLocalNameKey: code
            ])
            state = .advertising(code: code)
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        // CBCentral is not Sendable, but callbacks already run on the main queue
        nonisolated(unsafe) let central = central
        MainActor.assumeIsolated {
            // One transfer per session: ignore anyone else once connected
            guard subscriber == nil, let flow else { return }
            subscriber = central
            manager?.stopAdvertising()
            state = .exchanging
            do {
                try perform([.send(flow.offer)])
            } catch {
                fail(.protocolError("\(error)"))
            }
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        let identifier = central.identifier
        MainActor.assumeIsolated {
            // Once the sealed pad is here, the link is no longer needed to finish
            let padPending = flow?.hasSealedPad ?? false
            guard subscriber?.identifier == identifier, receivedPad == nil, !padPending else { return }
            fail(.disconnected)
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            pump()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // CBATTRequest is not Sendable, but callbacks already run on the main queue
        nonisolated(unsafe) let requests = requests
        MainActor.assumeIsolated {
            guard let first = requests.first else { return }
            let fromSubscriber = requests.allSatisfy {
                $0.central.identifier == subscriber?.identifier
                    && $0.characteristic.uuid == BLETransferUUIDs.toReceiver
            }
            guard fromSubscriber else {
                manager?.respond(to: first, withResult: .writeNotPermitted)
                return
            }
            do {
                for request in requests {
                    try receive([UInt8](request.value ?? Data()))
                }
                // Answer before stopping, so the sender learns the outcome of its last write
                manager?.respond(to: first, withResult: .success)
                if receivedPad != nil {
                    stop()
                }
            } catch {
                manager?.respond(to: first, withResult: .unlikelyError)
                fail(.protocolError("\(error)"))
            }
        }
    }
}
