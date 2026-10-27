# Gwardian — Threat Model (v2)

This document describes the **explicit threat model** for Gwardian, a fork of ASH v1 that adds group conversations, three security levels and remote or Bluetooth pad transfer.

Its purpose is to:
- make security assumptions visible
- prevent false expectations
- guide implementation decisions
- align contributors (human and AI)
- provide clarity for users, reviewers and auditors

Gwardian is designed to reduce risk, not eliminate it.

Sections marked **(new in v2)** cover what Gwardian adds on top of ASH v1. Everything else is inherited from ASH and still holds.

---

## Security philosophy

Gwardian assumes:
- humans make mistakes
- software systems are fallible
- infrastructure should not be trusted
- security must be understandable by users

Gwardian intentionally favors:
- small, auditable components
- explicit user actions
- offline-first security guarantees
- minimal reliance on third parties
- **visible security levels**: the user always sees how strong a conversation is

Gwardian does **not** promise absolute security.

---

## Assets to protect

1. **Message confidentiality**
   - Message contents must remain unreadable to anyone except participants.

2. **Pad secrecy**
   - One-Time Pad material must never be reused.
   - Pad material must not be recoverable after burn.

3. **Conversation integrity**
   - Messages must not be silently altered without detection.

4. **Security level honesty** (new in v2)
   - The level shown for a conversation must never overstate how its pads were distributed.
   - The level must never drop without the user's explicit consent.

5. **User understanding**
   - Users must be able to reason about what is happening.
   - Security must not rely on invisible background behavior.

---

## Security levels (new in v2)

Each member's pad records the channel it was distributed over. A message is as safe as its sender's pad; a group is as safe as its weakest pad.

| Level | How the pad was distributed | Confidentiality rests on | Recorded traffic decryptable later? |
|---|---|---|---|
| **Maximum** | In person, by QR code (ASH ceremony) | One-Time Pad only, no computational assumption | No, as long as the pad stays secret |
| **Enhanced** | In person, over Bluetooth LE | X-Wing (ML-KEM-768 + X25519) and ChaCha20-Poly1305 protecting the transfer, then One-Time Pad | Only by breaking both ML-KEM-768 and X25519 on a recording of that transfer |
| **Standard** | Remotely, through the relay | Same as Enhanced | Same as Enhanced, and the relay itself can record the transfer |

Rules enforced by the core:
- The level of a group is the minimum of its pads' levels.
- Adding a member or replacing a pad with a weaker one fails (`SecurityDowngrade`) unless the app calls the explicit `*_allow_downgrade` variant after the user agreed.
- A `Maximum` pad is refused by the transfer channels; it can only be exchanged by QR code.

Rule the apps must follow:
- **A pad is distributed over one kind of channel only.** If an owner hands a pad to one member by QR code and to another through the relay, every copy is only `Standard`. To add someone remotely, the owner generates a new pad.

---

## Trust boundaries

### Trusted
- The shared Rust core (`ash-core`): OTP, Wegman-Carter MAC, groups, levels. No dependencies, no computational cryptography.
- The transfer crate (`ash-transfer`) and its cryptographic dependencies (new in v2):
  - `libcrux-ml-kem` and `libcrux-sha3` (formally verified with hax and F*)
  - `x25519-dalek`, `hkdf`, `sha2`, `chacha20poly1305` (RustCrypto)
- The users performing the ceremony or the word comparison correctly
- The operating system *to a limited extent*

### Partially trusted
- The iOS and Android application runtimes
- Device secure storage (Keychain / Keystore)
- The platforms' secure random number generators, which supply all randomness

### Not trusted
- Backend infrastructure, including the transfer mailboxes
- Network transport
- Bluetooth radio and anyone within range
- Push notification services
- Other devices
- Physical environment
- Observers

---

## Attacker models

### 1. Network attacker (passive)

**Capabilities**
- Observes network traffic
- Records packets
- Replays messages

**Defenses**
- One-Time Pad encryption
- Encrypted blobs only
- No plaintext over network
- Backend ignorance of contents

**Residual risk**
- Metadata leakage (timing, size, who talks to whom)

---

### 2. Network attacker (active)

**Capabilities**
- Modifies, drops, replays or forges packets

**Defenses**
- **Wegman-Carter 256-bit authentication** (information-theoretic), forgery probability ~2^-128
- Frame integrity checks (CRC)
- Group frames: the sender id and pad offset select the authentication key, so altering either fails verification
- A pad range is consumed only after authentication, so forged frames cannot burn pad bytes
- Each pad range is accepted once: replays are rejected

**Residual risk**
- Denial of service (not prevented)

---

### 3. Backend compromise

**Capabilities**
- Full access to backend storage, logs and memory
- Ability to inject, drop or delay messages and transfer mailbox contents

**Defenses**
- Backend never sees plaintext or pads
- No keys stored on backend; transfer mailboxes store only SHA-256 hashes of their tokens
- Transfer mailboxes expire after 10 minutes and are never persisted
- An active attack on a remote transfer is exposed by the word comparison (see 11)

**Residual risk**
- Message delay or loss
- Metadata observation
- Recording of `Standard` transfers for a later cryptanalytic attack (see 12)

Gwardian explicitly assumes the backend may be hostile.

---

### 4. Malicious or curious service provider

**Capabilities**
- Observes infrastructure behavior, inspects memory, storage and logs

**Defenses**
- No secrets stored server-side
- No long-term storage
- No meaningful data to exfiltrate

**Residual risk**
- Traffic analysis

---

### 5. Shoulder-surfing / visual observation

**Capabilities**
- Observes screens during a QR ceremony
- Records QR codes visually

**Defenses**
- Human-verifiable mnemonic checksum
- User guidance to perform the ceremony privately
- QR frames encrypted with six spoken words drawn by the app: Argon2id + ChaCha20-Poly1305 (see [ceremony.md](ceremony.md)). A recording is useless without the words. On by default; off when the sender disables it or in family mode

**Residual risk**
- Full pad compromise if the ceremony is fully recorded **and** the six words are overheard, or if it is recorded with the protection turned off

This is a known and accepted risk.

---

### 6. Compromised backend + delayed attack

**Capabilities**
- Records encrypted traffic and attempts later decryption

**Defenses**
- `Maximum` pads: information-theoretic security of OTP, no key reuse, no key escrow
- `Enhanced` / `Standard` pads: see 12

**Residual risk**
- None for `Maximum`, assuming pad secrecy is maintained

---

### 7. Compromised device (software)

**Capabilities**
- Malware, screen recording, memory inspection, Keychain / Keystore access

**Defenses**
- Best-effort memory wipe (pad bytes are wiped in Rust after use and on drop)
- Limited data lifetime
- No background decryption

**Residual risk**
- Full compromise possible
- Pad bytes handed to the app across the FFI boundary cannot be wiped by Rust; apps keep them only in secure storage

Gwardian does **not** defend against a compromised operating system.

#### 7.1 Keyboards and dictation

Encryption protects a message once it is written, but the keyboard sees every character before that.

**Capabilities**
- A downloaded keyboard (with "full access" on iOS, by default on Android) can log and send everything typed
- Built-in keyboards learn words for suggestions; dictation may send audio to Apple or Google

**Defenses**
- The app code is entered on Gwardian's own digit pad, never through the keyboard
- iOS: third-party keyboards are refused inside the app (`shouldAllowExtensionPointIdentifier`); only Apple's keyboard appears
- Android: every text field asks the keyboard not to learn what is typed (`IME_FLAG_NO_PERSONALIZED_LEARNING`; Gboard and Samsung Keyboard switch to incognito), and the conversation screen warns when the active keyboard was not preinstalled. Open-source keyboards without Internet access (HeliBoard, FlorisBoard) are trusted like preinstalled ones, matched by package name

**Residual risk**
- Android cannot forbid a keyboard; a malicious one can ignore the no-learning request
- Dictation stays available with Apple's keyboard and on Android; users should not dictate sensitive messages
- A keyboard built into Gwardian is a possible future option for `Maximum` groups

---

### 8. Compromised device (physical)

**Capabilities**
- Physical access to the device, forensic tools, cold boot attacks
- A relative or colleague who knows the phone's passcode or has enrolled a fingerprint or face

**Defenses**
- Ephemeral message lifecycle (default)
- Best-effort wipe
- Reliance on OS protections
- **Planned:** an app-specific 6-digit code required to open Gwardian, pads bound to it in secure hardware, optional biometric shortcut disabled when the phone's biometric enrollment changes, increasing delays after wrong codes, and optional wipe after 10 wrong codes

**Residual risk**
- Partial or full recovery possible
- **Until the app lock ships, anyone who can unlock the phone can open the app**
- Higher risk with persistent mode — see [persistent-messages.md](persistent-messages.md)

Gwardian does **not** claim forensic resistance.

---

### 9. Malicious conversation participant

**Capabilities**
- Screenshots, recording, copying or exporting messages

**Defenses**
- None

Gwardian explicitly does **not** defend against a malicious participant. Trust between participants is required.

---

### 10. Malicious group member (new in v2)

**Capabilities**
- Holds a copy of every member's pad
- Can read every group message
- Can create validly authenticated messages under another member's id
- Can send forged frames to push a member into the `Suspect` health state
- Keeps all pad copies after being removed

**Defenses**
- Each member encrypts only with their own pad, so honest members never reuse each other's bytes
- Health tracking reports members whose messages repeatedly fail authentication

**Residual risk**
- **Authenticity is per group, not per member**: a member can impersonate another member
- A member who sends with another member's pad causes pad reuse for that pad
- Removing a member does not revoke anything: remaining members must exchange new pads

Groups should only include people who already trust each other, as for any participant (see 9).

---

### 11. Attacker on a transfer channel (new in v2)

**Capabilities**
- Passive: records a remote transfer through the relay, or a Bluetooth transfer within radio range
- Active: runs a separate exchange with each side (attacker in the middle), including a malicious relay

**Defenses**
- Hybrid key exchange X-Wing (ML-KEM-768 + X25519), following draft-connolly-cfrg-xwing-kem and checked against its official test vectors; the ML-KEM public key is validated (FIPS 203)
- Six words derived from the whole transcript, compared by the two people aloud or over a call
- The sender commits to its nonce before seeing the receiver's, so an attacker in the middle cannot search for matching words: one chance in 2^54 per attempt
- Pad sealed with ChaCha20-Poly1305 under an HKDF-SHA256 key bound to the transcript; the security level is authenticated, so a `Standard` pad cannot be passed off as `Enhanced`
- The receiving app keeps the sealed pad closed until its own user confirms the words
- Any protocol error ends the transfer, which starts over with fresh keys

**Residual risk**
- **Users who confirm without really comparing the words defeat the protection against an active attacker**
- Confidentiality of the transfer rests on computational assumptions (see 12)
- Denial of service: blocking the relay or jamming Bluetooth prevents transfers

---

### 12. Harvest now, decrypt later (new in v2)

**Capabilities**
- Records `Enhanced` or `Standard` transfers today
- Attempts decryption years later, for example with a large quantum computer

**Defenses**
- X-Wing stays secure as long as either ML-KEM-768 or X25519 resists; ML-KEM-768 is designed to resist quantum computers
- Once delivered, the pad itself is used as a One-Time Pad: messages add no computational assumption beyond the transfer
- Users can upgrade a conversation to `Maximum` at any time by exchanging new pads by QR code

**Residual risk**
- If both ML-KEM-768 and X25519 are broken, recorded `Enhanced` / `Standard` transfers reveal those pads and every message encrypted with them

This is why these levels are shown as weaker than `Maximum`.

---

### 13. Abuse of the transfer mailboxes (new in v2)

**Capabilities**
- Opens many mailboxes without authentication
- Fills mailboxes with large messages

**Defenses**
- At most 10,000 concurrent mailboxes, each expiring after 10 minutes
- Messages capped at 2 MiB, 4 waiting per direction, 256 MiB in total
- Mailbox ids are 128-bit random, tokens 256-bit random

**Residual risk**
- Temporary denial of the remote transfer service; HTTP-layer rate limiting (required by the backend contract) is expected in front of the relay

---

### 14. Local pad corruption (new in v2)

**Capabilities**
- Storage faults or a failed restore damage a pad copy on one device

**Defenses**
- A CRC-32 per 4 KiB chunk is checked before pad bytes are used, which tells a damaged local copy (`PadCorrupted`) apart from a message altered in transit (`AuthenticationFailed`)
- Damaged pads are never used to encrypt
- Only the affected member's pad needs to be exchanged again

**Residual risk**
- Messages from that member are unreadable until a new pad is exchanged

The checksums are stored with the pad and reveal nothing to anyone who could not already read it. They detect accidents, not attacks: an attacker who can modify local storage can already read the pads.

---

## Out-of-scope threats (explicit)

Gwardian does **not** defend against:

- A compromised operating system
- A malicious participant or group member
- Physical device seizure
- Advanced forensic analysis
- Network anonymity attacks
- Traffic correlation attacks
- Coercion or legal compulsion (a duress code is planned, not implemented)
- Side-channel attacks
- Supply-chain attacks, including on the cryptographic dependencies of `ash-transfer`
- Rogue OS updates
- Users who skip the word comparison or the mnemonic check

---

## Security guarantees (what Gwardian *does* provide)

Gwardian provides the following guarantees **if used correctly**:

- Message confidentiality against network and backend observers
- Information-theoretic security via One-Time Pad for `Maximum` conversations
- Post-quantum hybrid protection (ML-KEM-768 + X25519) for pads exchanged at `Enhanced` and `Standard` levels
- **Information-theoretic message authentication** via Wegman-Carter MAC, 256-bit tags
- **Traffic analysis protection** via mandatory 32-byte message padding, when the app pads messages before encryption (group frames do not pad by themselves)
- Pad non-reuse enforcement by design, including across group members
- A security level that is always shown and never drops without consent
- Detection of accidental corruption, distinguished from tampering
- Detection of message tampering or forgery by outsiders
- Human-verifiable ceremony and transfer correctness
- Minimal attack surface

---

## User responsibility (important)

Gwardian requires users to:
- perform the QR ceremony carefully, in private
- verify the mnemonic checksum
- **really compare the six words** during a Bluetooth or remote transfer, aloud or over a call, before confirming
- understand the level shown for each conversation, and meet in person to upgrade it when it matters
- understand that screenshots cannot be prevented
- trust conversation and group participants

Gwardian makes security *visible*, not automatic.

---

## Design consequences

This threat model explains why Gwardian:

- keeps QR codes as the only way to reach `Maximum`
- allows Bluetooth and remote transfer only as weaker, clearly labelled levels
- keeps the transfer cryptography out of the OTP core
- avoids background syncing, accounts and recovery
- avoids cloud storage and analytics

Every inconvenience is deliberate.

---

## Final note

Gwardian is designed to make **security tradeoffs explicit**.

If a threat is not listed here, it is **not defended against**.

Security is not a promise —
it is a set of clearly defined limits.
