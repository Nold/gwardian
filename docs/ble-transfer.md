# Pad transfer over Bluetooth LE (Enhanced level)

Two people side by side hand over a pad over Bluetooth LE instead of QR codes. The pad is protected by the `ash-transfer` protocol (X-Wing key exchange, six words compared aloud, ChaCha20-Poly1305), so the Bluetooth link needs no pairing or link-layer encryption: it is only a pipe. A pad moved this way is recorded as `Enhanced`.

iOS (CoreBluetooth) and Android (platform BLE APIs) must follow this document exactly so the two can talk to each other.

## Roles

| Person | BLE role | Protocol role |
|---|---|---|
| Receives the pad | Peripheral: advertises the service | `PadTransferReceiver` |
| Owns the pad | Central: scans and connects | `PadTransferSender` |

## Discovery

- The receiver shows a fresh code `GW-XXXX` on its screen, where `XXXX` is 4 characters of Crockford base32 from secure randomness, and advertises the service UUID below together with the code:
  - **iOS receiver**: local name `GW-XXXX` (iOS peripherals cannot advertise service data).
  - **Android receiver**: service data for the service UUID, in the scan response, holding the 4 code characters in ASCII (Android apps cannot set their own local name without renaming the phone).
- The sender scans for the service UUID, reads the code from either the local name or the service data, and lists the codes found; the person picks the code shown on the receiver's screen.
- The code only avoids connecting to the wrong phone nearby. It is not a secret: security comes from the six words.
- Both apps stay in the foreground during a transfer (iOS drops the local name from background advertising).

## GATT service

| Item | UUID | Properties |
|---|---|---|
| Service | `77c45bd0-3c1a-4051-959d-387547be92f7` | primary |
| To receiver (sender → receiver) | `31fa7cbc-d38b-42f7-95f0-26023575637c` | write (with response) |
| To sender (receiver → sender) | `6b284ef0-96af-4d31-9672-b73d80f71d78` | notify |

The same UUIDs are exported by the bindings (`ble_service_uuid()`, `ble_to_receiver_uuid()`, `ble_to_sender_uuid()`).

## Packets

Protocol messages are larger than one BLE write, so each is split with `split_into_ble_packets(message, message_id, max_packet)` and rebuilt with `BlePacketReassembler` (see `transfer/src/framing.rs`):

- `max_packet` is the largest write the link allows: on iOS `maximumWriteValueLength(for: .withResponse)` (central) or `maximumUpdateValueLength` (peripheral); on Android request an MTU of 517 and use `mtu - 3`. Never below 20.
- `message_id` increments by one for each message a side sends.
- Writes use "with response" so the link provides flow control; on iOS, notifications that return `false` are retried in `peripheralManagerIsReady(toUpdateSubscribers:)`.
- Any reassembly error ends the transfer; both people start over.

## Message flow

1. Sender connects, discovers the service, subscribes to "to sender".
2. Receiver sends the **offer** on "to sender".
3. Sender sends the **response** on "to receiver".
4. Receiver sends the **nonce** on "to sender".
5. Sender sends the **reveal** on "to receiver".
6. Both screens show the six words. People compare them aloud and both confirm, or cancel.
7. Sender sends the **sealed pad** on "to receiver"; the receiver opens it and adds it to the group at level `Enhanced`.
8. Either side disconnects. A disconnect before step 7 completes cancels the transfer.

All randomness (receiver seed, encapsulation seed, nonces, the 4-character code) comes from the platform's secure random number generator.
