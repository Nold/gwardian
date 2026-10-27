# ASH — v1 Scope Definition

This document defines the **explicit scope** of ASH version 1.

Its purpose is to:
- prevent scope creep
- preserve security guarantees
- align contributors (human or AI)
- act as a reference during reviews and decisions

If something is **not listed here**, it is **out of scope**.

This document must be read together with:
- `architecture.md`
- `threat-model.md`

---

## Gwardian v2: deliberate scope changes

Gwardian is a fork of ASH. Following the change policy below, these departures from the v1 scope are made deliberately, with their rationale and tradeoffs. Everything else in this document still applies. The security impact is reviewed in `threat-model.md` (sections marked "new in v2").

| v1 rule | v2 change | Rationale | Tradeoff |
|---|---|---|---|
| Group chats out of scope | **In scope**: one sending pad per member, every member holds copies of the others' (`ash-core::group`) | Families and teams need groups; a pad per member keeps pad non-reuse without coordination | Authenticity is per group, not per member; removing a member requires new pads |
| OTP only | **Messages stay OTP only.** Computational cryptography is allowed solely to *transfer a pad*, in the separate `ash-transfer` crate | Lets people start or refresh a conversation without meeting in person | Pads moved this way rest on computational assumptions |
| Key exchange protocols and key derivation functions out of scope | **In scope for pad transfer only**: X-Wing (ML-KEM-768 + X25519), HKDF-SHA256, ChaCha20-Poly1305 | Post-quantum hybrid protection for transfers that cannot be done by QR code | New dependencies to trust and audit |
| Bluetooth-based pairing out of scope | **In scope**: Bluetooth LE pad transfer (`docs/ble-transfer.md`) | Faster than QR codes, no screen to film | Weaker than QR codes, labelled `Enhanced` |
| One security level | **Three levels**, `Maximum` (QR), `Enhanced` (Bluetooth), `Standard` (relay), always shown, never lowered without consent | Users choose convenience knowingly, per conversation | The UI must make levels clear |
| iOS only | **Android in scope**, interoperable with iOS | Families and companies use both | A second app to maintain and audit |

Unchanged:
- No crypto agility: every algorithm is fixed by the protocol version.
- `Maximum` remains reachable only by QR code and keeps ASH's information-theoretic guarantees.
- `ash-core` keeps no computational cryptography and no dependencies.

---

## What ASH *is*

ASH is a secure, ephemeral messaging application designed for **high-security, low-frequency communication**.

ASH prioritizes:
- correctness over convenience
- human-verifiable security
- minimal trust in infrastructure
- deliberate user actions
- clarity over speed

ASH is **not** designed for everyday chat.

---

## Core principles (non-negotiable)

- One-Time Pad (OTP) only  
- No key escrow  
- No key recovery  
- No crypto agility  
- No silent background behavior  
- No hidden persistence  
- No reliance on backend trust  

If any feature weakens these principles, it is out of scope.

---

## In scope for v1

### Shared Rust Core (`ash-core`)

The shared Rust core is the **single source of truth** for ASH’s security model.

It is used by:
- the iOS application
- the backend (where applicable)
- tests and verification tools

The shared core is responsible for:
- One-Time Pad generation and consumption
- Strict enforcement of pad non-reuse
- OTP encryption and decryption
- Ceremony rules (chunking, ordering, invariants)
- Frame encoding and decoding with integrity checks
- Human-verifiable mnemonic checksum generation
- Deterministic, testable behavior across platforms
- Best-effort memory wipe utilities

The shared core must **never**:
- access the network
- access OS randomness directly
- store data on disk
- contain UI logic
- contain platform-specific code
- make policy decisions
- include analytics or logging

The shared core must remain:
- small
- auditable
- deterministic
- stable once reviewed

---

### Ceremony (conversation creation)

- Offline device-to-device ceremony
- QR code–based transfer of random pad bytes
- Chunked frame transfer with integrity validation
- Human-verifiable mnemonic checksum
- Restart-only failure handling (no partial recovery)

The ceremony must:
- be explicit
- be visible to the user
- require deliberate participation

---

### Messaging

- One-to-one conversations only
- Text messages
- One-shot location messages
  - Lat/long with 6 decimal places (~10cm precision)
  - No altitude, speed, or heading
- Ephemeral message lifecycle
- Automatic message disappearance after read / time
- Manual "burn" action that irreversibly wipes conversation state

---

### iOS Application (SwiftUI)

- SwiftUI-based iOS application
- Thin orchestration layer around shared Rust core
- Clear, minimal UI
- Limited visible message history
- Dynamic Type and accessibility support
- Reduced motion support
- Explicit user actions (no background automation)

The iOS app must **never**:
- reimplement cryptography
- modify security logic
- bypass the shared core
- invent alternative checksums or encryption
- silently persist decrypted data

---

### Backend (Rust relay)

The backend is a **dumb relay with a clock**.

It exists only to:
- relay encrypted message blobs
- relay burn signals
- notify devices via silent push notifications

The backend:
- does not decrypt data
- does not understand message contents
- does not identify users
- does not authenticate identities
- does not store data long-term

Backend characteristics:
- implemented in Rust
- stateless or ephemeral storage only
- strict TTL-based cleanup
- HTTPS only
- minimal API surface

The backend must **never**:
- store plaintext
- perform cryptographic operations on messages
- enforce business logic
- track users or behavior
- provide guarantees beyond best-effort delivery

---

### Website

- Static website only
- Educational and explanatory content
- Explanation of ceremony and security model
- Ethical use statement
- Privacy posture
- No analytics
- No tracking
- No user accounts
- No interactivity beyond simple demos

---

## Explicitly out of scope for v1

### Messaging & social features
- Group chats
- Channels
- Threads
- Reactions
- Media messages (images, video, audio)
- Stickers, emojis beyond system defaults

---

### Accounts & identity
- User accounts
- Phone number registration
- Email login
- Contacts integration
- Identity recovery
- Username systems

---

### Cryptography & transport
- End-to-end encryption other than OTP
- Key exchange protocols
- Key derivation functions
- Cloud key storage
- Bluetooth-based pairing
- Wi-Fi Direct pairing
- Background syncing

---

### Platform & ecosystem
- Android application (planned for future)
- Web application
- Desktop application
- VisionOS / watchOS support
- External plugins
- SDKs for third parties

---

### Infrastructure & scale
- Multi-region backend
- High availability guarantees
- Load balancing
- Analytics pipelines
- Crash reporting SDKs
- User metrics or tracking

---

### Product & business
- Monetization
- Subscriptions
- Ads
- Growth features
- Marketing campaigns
- Virality mechanics

---

## Non-goals (important clarification)

ASH does **not** aim to:
- be convenient
- be fast
- be social
- be anonymous at the network level
- defeat a compromised operating system
- defeat a physically compromised device
- provide plausible deniability against a determined forensic adversary

ASH aims to:
> reduce attack surface, reduce mistakes, and make security properties understandable to humans.

---

## Change policy

- This document may only be changed deliberately.
- Any change requires:
  - a written rationale
  - explicit acknowledgment of tradeoffs
  - review of security impact

Silent scope expansion is not allowed.

---

## Final note

If a future feature conflicts with this document,  
**this document wins**.

ASH succeeds by doing **less**, not more.