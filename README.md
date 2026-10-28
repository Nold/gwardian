# Gwardian

Secure, ephemeral messaging for high-security, low-frequency communication.

Gwardian is derived from [ASH](https://github.com/monadial/ash) by Monadial, licensed under the Apache License 2.0 (see `LICENSE.md`).

## What is Gwardian?

Gwardian is a messaging application that uses One-Time Pad (OTP) encryption to provide information-theoretic security. It is designed for situations where confidentiality matters and trust in infrastructure is limited.

Gwardian prioritizes:
- Correctness over convenience
- Human-verifiable security
- Minimal trust in infrastructure
- Deliberate user actions

Gwardian is **not** designed for everyday chat.

## How it works

1. **Ceremony**: Two devices establish a shared One-Time Pad through an offline, QR-based transfer
2. **Verification**: Users confirm matching mnemonic checksums
3. **Messaging**: Messages are encrypted with OTP and relayed through an untrusted backend
4. **Burn**: Either party can irreversibly destroy the conversation

## Architecture

```
┌────────────┐
│   Users    │
└─────┬──────┘
      │
┌─────▼──────┐
│  iOS App   │  (SwiftUI)
└─────┬──────┘
      │  FFI boundary
┌─────▼──────┐
│   core     │  (Shared Rust Core)
└─────┬──────┘
      │
┌─────▼──────┐
│  Backend   │  (Rust Relay)
└────────────┘
```

- **core**: Rust library containing all cryptographic logic
- **apps/ios**: SwiftUI iOS application
- **backend**: Untrusted relay that never sees plaintext

Note: Android support is planned for future versions.

## Security Model

Gwardian provides:
- Message confidentiality against network and backend observers
- Information-theoretic security via One-Time Pad
- Pad non-reuse enforcement by design
- Human-verifiable ceremony correctness

Gwardian does **not** provide:
- Anonymity at the network level
- Protection against device compromise
- Protection against malicious participants
- Forensic-level secure deletion

See [docs/threat-model.md](docs/threat-model.md) for the complete threat model.

## Documentation

| Document | Description |
|----------|-------------|
| [Scope](docs/scope.md) | What's in and out of v1 |
| [Architecture](docs/architecture.md) | System design and boundaries |
| [Threat Model](docs/threat-model.md) | Security guarantees and limitations |
| [Ceremony](docs/ceremony.md) | Pad establishment protocol |
| [Framing](docs/framing.md) | QR frame format specification |
| [Data Lifecycle](docs/data-lifecycle.md) | How data is handled and destroyed |
| [Backend Contract](docs/backend-contract.md) | API invariants and behavior |
| [Ethics](docs/ethics.md) | Ethical position and boundaries |
| [Glossary](docs/glossary.md) | Project terminology |

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## License

See [LICENSE](LICENSE) for details.
