//
//  BLETransferState.swift
//  Ash
//

import CoreBluetooth

/// Progress of a Bluetooth pad transfer, shown by the transfer screens.
enum BLETransferState: Equatable {
    case idle
    case waitingForBluetooth
    /// Receiver: advertising this code, waiting for the pad owner.
    case advertising(code: String)
    /// Sender: looking for nearby receivers.
    case scanning
    case connecting
    /// Running the key exchange before the words can be shown.
    case exchanging
    /// Both people must compare these words and confirm.
    case comparingWords([String])
    case transferring(progress: Double)
    case completed
    case failed(BLETransferFailure)
}

enum BLETransferFailure: Equatable {
    case bluetoothUnavailable
    case bluetoothUnauthorized
    case disconnected
    /// The exchange failed; the six words cannot be trusted. Start over.
    case protocolError(String)
}

/// GATT identifiers, defined once in the Rust core for iOS and Android.
enum BLETransferUUIDs {
    static var service: CBUUID { CBUUID(string: bleServiceUuid()) }
    static var toReceiver: CBUUID { CBUUID(string: bleToReceiverUuid()) }
    static var toSender: CBUUID { CBUUID(string: bleToSenderUuid()) }
}

extension BLETransferFailure {
    init?(state: CBManagerState) {
        switch state {
        case .unauthorized: self = .bluetoothUnauthorized
        case .unsupported, .poweredOff: self = .bluetoothUnavailable
        default: return nil
        }
    }
}
