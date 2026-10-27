# ASH — Architecture (v1)

This document describes the **system architecture** of ASH version 1.

Its purpose is to:
- define clear component boundaries
- document data and trust flows
- prevent architectural drift
- support security review and onboarding

This document must be read together with:
- `scope.md`
- `threat-model.md`
- `ceremony.md`
- `data-lifecycle.md`

---

## Architectural goals

ASH is designed to achieve the following goals:

1. **Security through simplicity**
   - Fewer components, fewer assumptions.
2. **Explicit trust boundaries**
   - Every component has clearly defined responsibilities.
3. **Human-verifiable correctness**
   - Users can confirm critical steps themselves.
4. **Offline-first guarantees**
   - Security does not depend on network availability.
5. **Minimal infrastructure trust**
   - Backend compromise must not reveal message contents.

---

## System overview

ASH consists of four primary subsystems:

```
┌────────────┐
│   Users    │
└─────┬──────┘
      │
┌─────▼──────┐
│  iOS App   │  (SwiftUI)
└─────┬──────┘
      │  FFI boundary (via bindings)
┌─────▼──────┐
│   core     │  (Shared Rust Core)
└─────┬──────┘
      │
┌─────▼──────┐
│  Backend   │  (Rust Relay)
└────────────┘
```

Note: Android support is planned for future versions.

Each subsystem is intentionally constrained.

---

## Shared Rust Core (`ash-core`)

### Purpose

`ash-core` is the **cryptographic and procedural authority** of ASH.

All security-sensitive behavior is defined here.  
All other components must treat it as **authoritative**.

---

### Responsibilities

The shared core is responsible for:

- One-Time Pad (OTP) creation and management
- Enforcing strict pad single-use semantics
- Bidirectional pad consumption (Initiator from start, Responder from end)
- OTP encryption and decryption
- Ceremony rules (chunk sizing, ordering, invariants)
- Ceremony metadata encoding/decoding
- Frame encoding and decoding (basic and extended formats)
- Frame integrity validation (CRC-32)
- Frame encryption with six spoken words (Argon2id + ChaCha20-Poly1305, in `transfer/`)
- Authorization token derivation (conversation ID, auth token, burn token)
- Mnemonic checksum generation (6 words, 512-word custom wordlist)
- Deterministic behavior across platforms
- Best-effort memory wiping

---

### Explicit non-responsibilities

`ash-core` must never:

- access the network
- perform file or database I/O
- access OS randomness directly
- contain platform-specific code
- store data persistently
- include UI logic
- log sensitive data
- make policy or UX decisions

---

### Design characteristics

- Small public API surface
- Minimal dependencies
- Deterministic outputs
- Extensive invariant tests
- Rare, deliberate changes

Once reviewed, changes to `ash-core` are expected to be exceptional.

---

## iOS Application (SwiftUI)

### Purpose

The iOS application is a **presentation and orchestration layer**.

It exists to:
- interact with the user
- manage UI state
- invoke `core` correctly via FFI bindings
- enforce UX constraints

---

### Responsibilities

The iOS app is responsible for:

- Rendering ceremony UI
- Displaying QR codes
- Scanning and validating QR frames
- Managing message display lifecycle
- Handling app foreground/background transitions
- Temporarily storing encrypted blobs
- Calling shared core APIs via bindings

---

### Explicit non-responsibilities

The iOS app must never:

- reimplement cryptographic logic
- alter OTP behavior
- bypass the shared core
- invent alternate checksums
- persist decrypted messages
- perform silent background actions

---

## Bindings Architecture

### Purpose

The bindings layer exposes `core` APIs to the iOS application.

It uses **UniFFI** (Mozilla's Uniform Foreign Function Interface) to generate Swift bindings.

---

### Design

```
┌─────────────────┐
│  core (Rust)    │
└────────┬────────┘
         │ UniFFI generates
         │
    ┌────▼────┐
    │  Swift  │
    └─────────┘
```

UniFFI generates bindings from a single interface definition.

Note: Kotlin bindings for Android will use the same interface when Android support is added.

---

### Responsibilities

The bindings layer:
- Exposes safe, minimal API surface
- Handles memory management across FFI boundary
- Converts types between Rust and platform languages
- Provides error handling across languages

---

### Explicit non-responsibilities

The bindings must never:
- Add business logic
- Cache or store data
- Make security decisions
- Differ in behavior between platforms

---

## Ceremony Architecture

### Purpose

The ceremony establishes a **shared One-Time Pad** between two devices.

It is:
- offline
- explicit
- human-verifiable
- restart-only on failure

---

### Ceremony flow

1. Sender gathers entropy
2. Sender constructs pad
3. Pad is chunked into frames (with ceremony metadata in frame 0)
4. Frames are encoded and displayed as QR codes
5. Receiver scans frames
6. Frames are decoded and validated
7. Pad is reconstructed
8. Both devices compute mnemonic checksum
9. Users visually verify checksum
10. Authorization tokens are derived from pad bytes
11. Conversation becomes active

---

### Failure handling

- Any error aborts the ceremony
- Partial state is discarded
- No recovery or resume is supported

This avoids ambiguous states.

---

## Messaging Architecture

### Overview

Messages are encrypted and decrypted using the shared pad.

There is **no key negotiation** after the ceremony.

---

### Bidirectional Pad Consumption

ASH uses a **bidirectional pad consumption** model to allow both parties to send messages independently:

```
Pad: [████████████████████████████████████████]
      ↑                                      ↑
      Initiator consumes →        ← Responder consumes
```

- **Initiator** (ceremony creator): Consumes bytes from the **start** of the pad
- **Responder** (ceremony scanner): Consumes bytes from the **end** of the pad

This design ensures:
- No coordination needed between parties
- Both can send messages simultaneously
- Pad bytes never overlap (until exhaustion)

---

### Message Authentication (Wegman-Carter MAC)

Every message is authenticated using a **Wegman-Carter MAC** with 256-bit tags.

This provides **information-theoretic authentication** — mathematically proven unforgeable without the pad, regardless of computational power.

**Authentication scheme:**
- **Tag size:** 256 bits (32 bytes)
- **Auth key size:** 64 bytes from pad per message (4 × 16-byte keys: r₁, r₂, s₁, s₂)
- **Algorithm:** Dual polynomial evaluation in GF(2^128)
- **Forgery probability:** ~2^-128 (negligible)

**How it works:**
1. Split ciphertext into 128-bit blocks
2. Evaluate two independent polynomials over GF(2^128):
   - Tag₁ = Σ(blockᵢ · r₁^(n-i)) + s₁
   - Tag₂ = Σ(blockᵢ · r₂^(n-i)) + s₂
3. Concatenate: final_tag = Tag₁ || Tag₂ (256 bits)

**Security properties:**
- **Information-theoretic:** Cannot be broken regardless of computational advances
- **One-time:** Each auth key is used exactly once (pad consumption)
- **Unforgeable:** Without pad bytes, attacker cannot create valid tags
- **Tamper-evident:** Any modification invalidates the tag

---

### Mandatory Message Padding

All messages are padded to a minimum of **32 bytes** to protect against traffic analysis.

**Why padding matters:**
Without padding, an adversary observing encrypted message sizes could:
- Distinguish short messages ("yes", "no", "ok") from longer ones
- Fingerprint message patterns based on size sequences
- Infer conversation topics or emotional state from message lengths

**Padding format:**
```
[0x00 marker][2-byte BE length][content][zero padding]
```

- **0x00 marker:** Identifies padded messages (UTF-8 never starts with null byte)
- **Length header:** 2-byte big-endian length of original content
- **Content:** Original plaintext bytes
- **Zero padding:** Fills remaining bytes to reach 32-byte minimum

Messages longer than 29 bytes (32 - 3 header) are not padded beyond their natural size.

Group messages (`core/src/group.rs`) are padded the same way by the core itself, to a minimum of **64 bytes** (`GROUP_MIN_PADDED_SIZE`): messages up to 61 bytes all have the same length on the wire. Longer messages keep their natural size plus 3 bytes, so their length stays visible to the relay.

---

### Sending a message

1. User composes message
2. Message is padded to minimum 32 bytes
3. App requests pad slice from `ash-core`: 64 bytes (auth key) + padded length (encryption key)
4. Message is OTP-encrypted with encryption key bytes
5. Authentication tag is computed using Wegman-Carter MAC with auth key
6. Pad cursors advance (front for Initiator, back for Responder)
7. Authenticated frame (header + ciphertext + tag) is sent to backend

---

### Receiving a message

1. Authenticated frame is received (via SSE or polling)
2. App requests pad slice from `ash-core` using the **sender's** role
3. Authentication tag is verified using Wegman-Carter MAC
4. If tag is invalid, message is rejected (tampering detected)
5. Ciphertext is OTP-decrypted using encryption key bytes
6. Padding is stripped to recover original plaintext
7. Plaintext is displayed briefly
8. Plaintext is discarded

---

### Real-time delivery via SSE

ASH uses **Server-Sent Events (SSE)** for real-time message delivery:

```
Alice                         Server                           Bob
  │                              │                              │
  │  Submit message              │                              │
  ├─────────────────────────────►│  (store in RAM, start TTL)   │
  │◄── blob_id ──────────────────│                              │
  │                              │                              │
  │                              │  SSE: {"type":"message",...} │
  │                              │─────────────────────────────►│
  │                              │                     (decrypt) │
  │                              │                    (display)  │
```

**SSE event types:**
- `message` - New encrypted message blob received
- `delivered` - Message was displayed by recipient (delivery report)
- `burned` - Conversation has been burned
- `ping` - Keep-alive (every 15 seconds)

**Connection:**
- Endpoint: `GET /v1/messages/stream?conversation_id=...`
- Requires auth token in `Authorization` header
- Long-lived connection with automatic reconnection

**Fallback:**
- Polling via `GET /v1/messages` when SSE unavailable
- Push notifications (APNS) wake app when backgrounded

---

### Message lifecycle (ephemeral only)

ASH has a single messaging mode: **ephemeral**.

```
┌─────────────────────────────────────────────────────────────────┐
│                     CLIENT MESSAGE LIFECYCLE                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Message received → displayed on screen → ACK sent to server   │
│                                                                  │
│   App closed = all messages wiped from client                    │
│                                                                  │
│   No local persistence. No message history.                      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

Rules:
- Plaintext exists only in memory
- Messages visible only while app is open
- **Close app = messages gone forever**
- Burn action wipes all remaining state
- No "persistent" mode - simplicity over convenience

---

## Authorization Token Architecture

### Purpose

Authorization tokens enable API authentication without accounts or identity.
Both parties derive the same tokens from the shared pad, allowing the relay
to verify requests without knowing who is making them.

---

### Token Types

| Token | Pad Bytes | Purpose |
|-------|-----------|---------|
| Conversation ID | 0-31 | Identifies the conversation on the relay |
| Auth Token | 32-95 | Authenticates API requests (messages, polling) |
| Burn Token | 96-159 | Required specifically for burn operations |

---

### Derivation Process

Tokens are derived by:
1. Extracting specific byte ranges from the pad
2. XOR-folding to 32-byte output
3. Applying domain separation constant
4. Multiple mixing rounds for diffusion
5. Encoding as 64-character lowercase hex string

---

### Security Properties

- **Deterministic**: Same pad produces same tokens on both devices
- **Unpredictable**: Without pad, tokens cannot be computed or forged
- **Separated**: Different tokens for different operations (defense in depth)
- **Backend-safe**: Backend stores only hash(token), can verify but not forge

---

### Minimum Requirements

Token derivation requires at least 160 bytes of pad data.
All standard pad sizes (32 KB+) exceed this minimum.

---

## Backend Architecture (Rust Relay)

### Purpose

The backend is a **stateless RAM-only relay**.

It is intentionally simple and untrusted.

---

### Storage Model

**RAM only** - all message data is stored in memory:

```
┌─────────────────────────────────────────────────────────────────┐
│                      SERVER (RAM ONLY)                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Messages held until:                                           │
│   - Client ACK (message displayed) → immediate delete            │
│   - TTL expires (unread) → automatic delete                      │
│   - Server restart → ALL messages lost                           │
│                                                                  │
│   ⚠️ Users are warned: server restart = unread messages lost    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Why RAM only:**
- No disk forensics possible
- No data at rest
- Truly ephemeral
- Simpler implementation

**Accepted tradeoff:**
- Server crash/restart loses unread messages
- For high-security, low-frequency use case, this is acceptable

---

### Message Flow (SSE with ACK)

```
Alice                         Server (RAM)                    Bob
  │                              │                              │
  │                              │◄─── SSE connect ─────────────│
  │                              │                              │
  │  POST /v1/messages           │                              │
  ├─────────────────────────────►│  (store, start TTL)          │
  │◄── {blob_id} ────────────────│                              │
  │                              │                              │
  │                              │───── SSE: message ──────────►│
  │                              │                     (decrypt) │
  │                              │                    (display)  │
  │                              │◄─── POST /v1/ack ────────────│
  │                              │     {blob_id}                 │
  │◄── SSE: delivered ───────────│  (delete from RAM)           │
  │     {blob_id}                │                              │
```

### Message Flow (Polling fallback with ACK)

```
Alice                         Server (RAM)                    Bob
  │                              │                              │
  │  POST /v1/messages           │                              │
  ├─────────────────────────────►│  (store, start TTL)          │
  │◄── {blob_id} ────────────────│                              │
  │                              │────── push notification ────►│
  │                              │                              │
  │                              │         Bob opens app        │
  │                              │◄─── GET /v1/messages ────────│
  │                              │───── [messages] ────────────►│
  │                              │                     (decrypt) │
  │                              │                    (display)  │
  │                              │◄─── POST /v1/ack ────────────│
  │◄── SSE: delivered ───────────│  (delete from RAM)           │
```

### ACK and Delivery Reports

When a recipient displays a message, their client sends an **ACK** to the server:

1. **ACK Request**: `POST /v1/ack` with `blob_id`
2. **Immediate Deletion**: Server deletes message from RAM
3. **Delivery Report**: Server broadcasts `delivered` event via SSE to sender
4. **Sender Notification**: Sender's UI can show delivery confirmation

**ACK behavior:**
- ACK is sent when message is **displayed**, not just received
- Messages without ACK are deleted after TTL expiry (5 minutes)
- ACK is idempotent (safe to retry)
- Delivery report is best-effort (sender may be offline)

---

### Responsibilities

The backend is responsible for:

- Accepting encrypted message blobs (store in RAM)
- Holding messages until ACK or TTL expiry
- Notifying sender when recipient ACKs ("delivered")
- Relaying encrypted blobs to recipients
- Propagating burn signals
- Sending silent push notifications (APNS)
- Enforcing TTL-based deletion

---

### Explicit non-responsibilities

The backend must never:

- persist messages to disk
- decrypt messages
- inspect payload contents
- identify users
- authenticate identities
- store data long-term
- provide delivery guarantees
- implement business logic

---

## Infrastructure Architecture

### Characteristics

- Single region deployment (v1)
- HTTPS only
- No analytics
- No load balancing (initially)
- Manual deployments

Infrastructure is considered untrusted.

---

## Website Architecture

### Purpose

The website provides **documentation and education only**.

---

### Characteristics

- Static content only
- No user interaction
- No tracking or analytics
- No accounts
- HTTPS only

---

## Trust boundaries

| Component  | Trust level |
|-----------|-------------|
| ash-core  | Trusted |
| iOS App | Partially trusted |
| Backend  | Untrusted |
| Network  | Untrusted |
| Website  | Untrusted |
| User     | Trusted (with responsibility) |

---

## Architectural consequences

This architecture deliberately avoids:

- background synchronization
- convenience features
- user accounts
- key recovery
- cloud storage
- analytics and tracking

All constraints are intentional.

---

## Final note

ASH’s architecture is intentionally **narrow and opinionated**.

Security emerges not from complexity,  
but from **clear boundaries, explicit flows, and deliberate limits**.

Any change that violates these principles  
must trigger architectural review before implementation.