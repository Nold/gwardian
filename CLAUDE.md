# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Gwardian (derived from ASH by Monadial; internal code names still say `ash`) is a secure, ephemeral messaging application for high-security, low-frequency communication. It uses One-Time Pad (OTP) encryption with no key recovery, no key escrow, and minimal infrastructure trust.

## Repository Structure

```
ash/
├── apps/
│   └── ios/        # SwiftUI iOS app
├── core/           # Shared Rust core (cryptographic authority)
├── transfer/       # Pad transfer for Standard/Enhanced levels (X-Wing KEM, kept out of core)
├── backend/        # Rust relay server
├── bindings/       # FFI bindings (Swift via UniFFI)
├── website/        # Static documentation website
├── infra/          # Infrastructure configuration
├── docs/           # Project documentation
├── tools/          # Development and build tools
└── .github/        # CI/CD workflows
```

Note: Android support planned for future versions.

## Architecture

```
┌────────────┐
│   Users    │
└─────┬──────┘
      │
┌─────▼──────┐
│  iOS App   │  (SwiftUI)
└─────┬──────┘
      │  FFI boundary (via bindings/)
┌─────▼──────┐
│   core     │  (Shared Rust Core)
└─────┬──────┘
      │
┌─────▼──────┐
│  Backend   │  (Rust Relay)
└────────────┘
```

### core/ (Shared Rust Core)
The cryptographic authority. Handles OTP creation/consumption, pad enforcement, encryption/decryption, ceremony rules, frame encoding, and mnemonic checksums.

**Must never:** access network, perform I/O, access OS randomness directly, contain platform-specific code, store data, include UI logic, log sensitive data.

### apps/ios/ (iOS Application)
SwiftUI-based presentation and orchestration layer. Invokes core via bindings, manages UI, handles QR code display/scanning.

**Must never:** reimplement cryptography, bypass core, persist decrypted messages.

### backend/ (Rust Relay)
Untrusted stateless relay. Accepts/relays encrypted blobs, propagates burn signals, sends silent push notifications (APNS). TTL-based ephemeral storage only.

**Must never:** decrypt messages, identify users, store data long-term.

### bindings/
FFI layer using **UniFFI** to generate Swift bindings from a single Rust interface definition.

## Trust Boundaries

| Component | Trust Level |
|-----------|-------------|
| core | Trusted |
| Mobile Apps | Partially trusted |
| Backend | Untrusted |
| Network | Untrusted |

## Core Principles (Non-negotiable)

- OTP only (no other encryption)
- No key escrow/recovery
- No crypto agility
- No silent background behavior
- No hidden persistence
- No reliance on backend trust

## Security Considerations for Contributors

- Respect documented trust boundaries
- No hidden persistence or analytics
- No logging sensitive data
- Security-relevant changes require rationale, threat impact analysis, and tests
- If a security property is unclear or undocumented, treat it as not guaranteed
- Ethical concerns are first-class design issues (see `docs/ethics.md`)

## Key Documentation

| Document | Purpose |
|----------|---------|
| `docs/scope.md` | v1 feature scope (what's in/out) |
| `docs/architecture.md` | Component boundaries and data flows |
| `docs/threat-model.md` | Explicit threat model and security guarantees |
| `docs/ceremony.md` | Ceremony protocol specification |
| `docs/framing.md` | QR frame format specification |
| `docs/group-ceremony.md` | Group ceremony around the table (2 to 8 members) |
| `docs/message-deletion.md` | Per-message lifetime, delete for me, delete for everyone |
| `docs/data-lifecycle.md` | Data lifetime and destruction rules |
| `docs/backend-contract.md` | Backend API invariants and TTL policies |
| `docs/ethics.md` | Ethical position and boundaries |
| `docs/glossary.md` | Project-specific terminology |
| `SECURITY.md` | Vulnerability reporting process |

## Implementation Decisions (v1)

| Area | Decision |
|------|----------|
| Platform | iOS only (Android planned for future) |
| iOS UI | SwiftUI |
| FFI | UniFFI for Swift bindings |
| Entropy | OS randomness + gesture-based mixing (required) |
| Pad sizes | Slider selection: 64KB / 256KB / 1MB |
| Message types | Text, one-shot location |
| Location precision | 6 decimal places (~10cm) |
| Mnemonic wordlist | Custom (not BIP-39) |
| Backend storage | In-memory default, optional SQLite for delayed reading |
| Push notifications | APNS |
