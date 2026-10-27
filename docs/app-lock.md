# App lock

Gwardian opens only with its own 6-digit code. A relative or colleague who knows the phone's passcode, or whose face or fingerprint is enrolled on the phone, cannot open it. iOS and Android follow this document.

## Requirements

- A 6-digit app code is **mandatory**. It is set up after onboarding, and by existing users on the first launch after the update.
- Biometric unlock (Face ID, Touch ID, fingerprint) is an **optional shortcut**. Enabling it shows a warning: anyone whose face or fingerprint is enrolled on the phone can open Gwardian.
- If the phone's biometric enrollment changes (a new face or finger is added), the shortcut stops working and the code is required, then the shortcut can be enabled again.
- Pads and conversations are **unreadable without the code**, not merely hidden behind a screen.
- Wrong codes trigger increasing delays.
- **Optional, off by default**: erase all pads after 10 wrong codes in a row.
- The app locks when it goes to the background (existing setting).

## Design

### Vault key

- A random 256-bit **vault key** encrypts every pad and conversation record before it is written to secure storage (AEAD; ChaCha20-Poly1305 on iOS with CryptoKit, AES-GCM on Android). Stored values start with the marker `GWV1`.
- The vault key exists in memory only while the app is unlocked. Locking drops it.
- The vault key is stored twice in the platform's secure storage:
  1. **Code copy**, readable only with the app code:
     - iOS: Keychain item with access control `.applicationPassword`; the code is given as the `LAContext` credential. The Keychain mixes the code with device-bound keys, so guessing the code requires the device.
     - Android: wrapped with a key derived from the code (PBKDF2-HMAC-SHA256) combined with an HMAC computed by a non-exportable Android Keystore key, so guessing the code requires the device.
  2. **Biometric copy**, optional:
     - iOS: Keychain item with access control `.biometryCurrentSet`, which the system deletes when enrollment changes.
     - Android: wrapped with a Keystore key created with `setUserAuthenticationRequired(true)` and `setInvalidatedByBiometricEnrollment(true)`.
- **Erasing** deletes both copies of the vault key, then the stored records. Without the key the records are unreadable even if a copy survives (crypto-shredding).
- Changing the code rewraps only the vault key; records are not re-encrypted.

### Attempts

| Wrong codes in a row | Wait before the next try |
|---|---|
| 1–4 | none |
| 5 | 30 s |
| 6 | 1 min |
| 7 | 5 min |
| 8 | 15 min |
| 9 and more | 1 h each |
| 10, with erase enabled | everything is erased |

The counter and the time of the last failure are kept in secure storage, outside the vault, and reset after a correct code.

### Migration

Existing records written before the lock are plaintext in secure storage. Right after the code is set up, every record is read and written back encrypted. A plaintext record found later is still accepted and encrypted on its next read.

### Forgotten code

There is no recovery. The only way out is to delete and reinstall the app, which erases every pad and conversation (the fresh-install check also deletes the vault key and the attempt counter).

### While locked

The app shows only the lock screen; nothing read from the vault stays in memory. Conversations, pads and the screens built from them are rebuilt after unlocking.

## Limits

- The delays and the erase option are enforced by the app. An attacker able to run code on the device or modify its storage can bypass them; that is the compromised-device case, out of scope in `threat-model.md`. Guessing the code offline still requires the device itself.
- A 6-digit code has a million combinations: it stops relatives and colleagues, not an attacker with forensic tools and time.
- Messages kept by "disappearing messages" persistence are stored by SwiftData under iOS data protection, not sealed with the vault key; while locked the app never displays them, and an erase deletes them.
- Push notifications cannot decrypt anything while the app is locked; messages wait on the relay until the app is unlocked.
