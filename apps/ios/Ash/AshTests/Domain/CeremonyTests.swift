//
//  CeremonyTests.swift
//  AshTests
//
//  Unit tests for Ceremony domain entities
//

import XCTest
import Foundation
@testable import Ash

// MARK: - CeremonyRole Tests

final class CeremonyRoleTests: XCTestCase {

    func testRawValues_areCorrect() {
        XCTAssertEqual(CeremonyRole.sender.rawValue, "sender")
        XCTAssertEqual(CeremonyRole.receiver.rawValue, "receiver")
    }
}

// MARK: - CeremonyError Tests

final class CeremonyErrorTests: XCTestCase {

    func testLocalizedDescription_insufficientEntropy() {
        let error = CeremonyError.insufficientEntropy
        XCTAssertTrue(error.localizedDescription.contains("randomness"))
    }

    func testLocalizedDescription_qrGenerationFailed() {
        let error = CeremonyError.qrGenerationFailed
        XCTAssertTrue(error.localizedDescription.contains("QR"))
    }

    func testLocalizedDescription_qrScanFailed() {
        let error = CeremonyError.qrScanFailed
        XCTAssertTrue(error.localizedDescription.contains("scan"))
    }

    func testLocalizedDescription_frameDecodingFailed() {
        let error = CeremonyError.frameDecodingFailed
        XCTAssertTrue(error.localizedDescription.contains("Invalid"))
    }

    func testLocalizedDescription_checksumMismatch() {
        let error = CeremonyError.checksumMismatch
        XCTAssertTrue(error.localizedDescription.contains("Checksum"))
    }

    func testLocalizedDescription_padReconstructionFailed() {
        let error = CeremonyError.padReconstructionFailed
        XCTAssertTrue(error.localizedDescription.contains("reconstruct"))
    }

    func testLocalizedDescription_cancelled() {
        let error = CeremonyError.cancelled
        XCTAssertTrue(error.localizedDescription.contains("cancelled"))
    }

    func testEquatable_sameErrors_areEqual() {
        XCTAssertEqual(CeremonyError.cancelled, CeremonyError.cancelled)
        XCTAssertEqual(CeremonyError.qrScanFailed, CeremonyError.qrScanFailed)
    }
}

// MARK: - CeremonyPhase Tests

final class CeremonyPhaseTests: XCTestCase {

    func testEquatable_idle() {
        XCTAssertEqual(CeremonyPhase.idle, CeremonyPhase.idle)
    }

    func testEquatable_selectingRole() {
        XCTAssertEqual(CeremonyPhase.selectingRole, CeremonyPhase.selectingRole)
    }

    func testEquatable_selectingPadSize() {
        XCTAssertEqual(CeremonyPhase.selectingPadSize, CeremonyPhase.selectingPadSize)
    }

    func testEquatable_collectingEntropy() {
        XCTAssertEqual(CeremonyPhase.collectingEntropy, CeremonyPhase.collectingEntropy)
    }

    func testEquatable_generatingPad() {
        XCTAssertEqual(CeremonyPhase.generatingPad, CeremonyPhase.generatingPad)
    }

    func testEquatable_generatingQRCodes_sameValues() {
        let phase1 = CeremonyPhase.generatingQRCodes(progress: 0.5, total: 10)
        let phase2 = CeremonyPhase.generatingQRCodes(progress: 0.5, total: 10)
        XCTAssertEqual(phase1, phase2)
    }

    func testEquatable_generatingQRCodes_differentValues() {
        let phase1 = CeremonyPhase.generatingQRCodes(progress: 0.5, total: 10)
        let phase2 = CeremonyPhase.generatingQRCodes(progress: 0.8, total: 10)
        XCTAssertNotEqual(phase1, phase2)
    }

    func testEquatable_transferring_sameValues() {
        let phase1 = CeremonyPhase.transferring(currentFrame: 5, totalFrames: 10)
        let phase2 = CeremonyPhase.transferring(currentFrame: 5, totalFrames: 10)
        XCTAssertEqual(phase1, phase2)
    }

    func testEquatable_transferring_differentValues() {
        let phase1 = CeremonyPhase.transferring(currentFrame: 5, totalFrames: 10)
        let phase2 = CeremonyPhase.transferring(currentFrame: 6, totalFrames: 10)
        XCTAssertNotEqual(phase1, phase2)
    }

    func testEquatable_verifying_sameMnemonic() {
        let phase1 = CeremonyPhase.verifying(mnemonic: ["a", "b", "c"])
        let phase2 = CeremonyPhase.verifying(mnemonic: ["a", "b", "c"])
        XCTAssertEqual(phase1, phase2)
    }

    func testEquatable_failed_sameError() {
        let phase1 = CeremonyPhase.failed(.cancelled)
        let phase2 = CeremonyPhase.failed(.cancelled)
        XCTAssertEqual(phase1, phase2)
    }

    func testEquatable_failed_differentError() {
        let phase1 = CeremonyPhase.failed(.cancelled)
        let phase2 = CeremonyPhase.failed(.qrScanFailed)
        XCTAssertNotEqual(phase1, phase2)
    }
}

// MARK: - CeremonyState Tests

final class CeremonyStateTests: XCTestCase {

    func testInit_hasDefaultValues() {
        let state = CeremonyState()

        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.role, .sender)
        XCTAssertEqual(state.selectedPadSizeOption, .medium)
        XCTAssertEqual(state.entropyProgress, 0.0)
        XCTAssertTrue(state.collectedEntropy.isEmpty)
        XCTAssertNil(state.generatedPad)
        XCTAssertTrue(state.scannedFrames.isEmpty)
        XCTAssertEqual(state.totalFrames, 0)
    }

    func testIsInProgress_idle_returnsFalse() {
        var state = CeremonyState()
        state.phase = .idle

        XCTAssertFalse(state.isInProgress)
    }

    func testIsInProgress_completed_returnsFalse() {
        var state = CeremonyState()
        let padBytes = [UInt8](repeating: 0xAB, count: 1000)
        let conversation = Conversation.fromCeremony(
            padBytes: padBytes,
            mnemonic: ["a", "b", "c", "d", "e", "f"],
            role: .initiator,
            relayURL: "https://relay.test",
            authToken: "test-auth-token-0123456789abcdef0123456789abcdef0123456789abcdef01234567",
            burnToken: "test-burn-token-0123456789abcdef0123456789abcdef0123456789abcdef01234567"
        )
        state.phase = .completed(conversation: conversation)

        XCTAssertFalse(state.isInProgress)
    }

    func testIsInProgress_failed_returnsFalse() {
        var state = CeremonyState()
        state.phase = .failed(.cancelled)

        XCTAssertFalse(state.isInProgress)
    }

    func testIsInProgress_selectingRole_returnsTrue() {
        var state = CeremonyState()
        state.phase = .selectingRole

        XCTAssertTrue(state.isInProgress)
    }

    func testIsInProgress_collectingEntropy_returnsTrue() {
        var state = CeremonyState()
        state.phase = .collectingEntropy

        XCTAssertTrue(state.isInProgress)
    }

    func testIsInProgress_transferring_returnsTrue() {
        var state = CeremonyState()
        state.phase = .transferring(currentFrame: 1, totalFrames: 10)

        XCTAssertTrue(state.isInProgress)
    }

    func testCanCancel_idle_returnsFalse() {
        var state = CeremonyState()
        state.phase = .idle

        XCTAssertFalse(state.canCancel)
    }

    func testCanCancel_completed_returnsFalse() {
        var state = CeremonyState()
        let padBytes = [UInt8](repeating: 0xAB, count: 1000)
        let conversation = Conversation.fromCeremony(
            padBytes: padBytes,
            mnemonic: ["a", "b", "c", "d", "e", "f"],
            role: .initiator,
            relayURL: "https://relay.test",
            authToken: "test-auth-token-0123456789abcdef0123456789abcdef0123456789abcdef01234567",
            burnToken: "test-burn-token-0123456789abcdef0123456789abcdef0123456789abcdef01234567"
        )
        state.phase = .completed(conversation: conversation)

        XCTAssertFalse(state.canCancel)
    }

    func testCanCancel_inProgress_returnsTrue() {
        var state = CeremonyState()
        state.phase = .collectingEntropy

        XCTAssertTrue(state.canCancel)
    }

    func testCanCancel_failed_returnsTrue() {
        var state = CeremonyState()
        state.phase = .failed(.cancelled)

        XCTAssertTrue(state.canCancel)
    }

    func testReset_restoresDefaultState() {
        var state = CeremonyState()
        state.phase = .collectingEntropy
        state.role = .receiver
        state.entropyProgress = 0.75
        state.collectedEntropy = [1, 2, 3]
        state.totalFrames = 50

        state.reset()

        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.role, .sender)
        XCTAssertEqual(state.entropyProgress, 0.0)
        XCTAssertTrue(state.collectedEntropy.isEmpty)
        XCTAssertEqual(state.totalFrames, 0)
    }
}

// MARK: - PadSizeOption Extension Tests

final class PadSizeOptionExtensionTests: XCTestCase {

    func testAllCases_containsFiveSizes() {
        XCTAssertEqual(PadSizeOption.allCases.count, 5)
        XCTAssertTrue(PadSizeOption.allCases.contains(.small))
        XCTAssertTrue(PadSizeOption.allCases.contains(.medium))
        XCTAssertTrue(PadSizeOption.allCases.contains(.large))
        XCTAssertTrue(PadSizeOption.allCases.contains(.huge))
        XCTAssertTrue(PadSizeOption.allCases.contains(.custom))
    }

    func testDisplayName_allSizes() {
        XCTAssertEqual(PadSizeOption.small.displayName, "Small")
        XCTAssertEqual(PadSizeOption.medium.displayName, "Medium")
        XCTAssertEqual(PadSizeOption.large.displayName, "Large")
        XCTAssertEqual(PadSizeOption.huge.displayName, "Huge")
        XCTAssertEqual(PadSizeOption.custom.displayName, "Custom")
    }

    func testPresetBytes_allSizes() {
        XCTAssertEqual(PadSizeOption.small.presetBytes, 64 * 1024)   // 64 KB
        XCTAssertEqual(PadSizeOption.medium.presetBytes, 256 * 1024) // 256 KB
        XCTAssertEqual(PadSizeOption.large.presetBytes, 512 * 1024)  // 512 KB
        XCTAssertEqual(PadSizeOption.huge.presetBytes, 1024 * 1024)  // 1 MB
        XCTAssertNil(PadSizeOption.custom.presetBytes)
    }

    func testDescription_containsMessages() {
        XCTAssertTrue(PadSizeOption.small.description.contains("messages"))
        XCTAssertTrue(PadSizeOption.medium.description.contains("messages"))
        XCTAssertTrue(PadSizeOption.large.description.contains("messages"))
        XCTAssertTrue(PadSizeOption.huge.description.contains("messages"))
    }

    func testDescription_containsFrames() {
        XCTAssertTrue(PadSizeOption.small.description.contains("frames"))
        XCTAssertTrue(PadSizeOption.medium.description.contains("frames"))
        XCTAssertTrue(PadSizeOption.large.description.contains("frames"))
        XCTAssertTrue(PadSizeOption.huge.description.contains("frames"))
    }

    func testId_usesRawValue() {
        XCTAssertEqual(PadSizeOption.small.id, "small")
        XCTAssertEqual(PadSizeOption.medium.id, "medium")
        XCTAssertEqual(PadSizeOption.large.id, "large")
        XCTAssertEqual(PadSizeOption.huge.id, "huge")
        XCTAssertEqual(PadSizeOption.custom.id, "custom")
    }
}

// MARK: - Ceremony Fountain Code Tests (FFI Integration)

final class CeremonyFountainCodeTests: XCTestCase {
    /// Block size for fountain codes
    private let blockSize: UInt32 = 900
    private let testPassphrase = "able acid aged also area army"

    func testFountainGenerator_createsFrames() throws {
        let padBytes = [UInt8](repeating: 0xAB, count: Int(PadSizeOption.small.presetBytes ?? 64 * 1024))

        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 172800,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B,
            transferMethod: .raptor,
            relayUrl: "https://relay.ash.test"
        )

        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: blockSize,
            passphrase: testPassphrase,
            method: .raptor,
            salt: [UInt8](repeating: 7, count: 16)
        )

        XCTAssertGreaterThan(generator.sourceCount(), 0)
        XCTAssertGreaterThan(generator.totalSize(), 0)

        // Generate a frame
        let frame = generator.nextFrame()
        XCTAssertGreaterThan(frame.count, 0)
    }

    func testFountainRoundtrip_smallPad() throws {
        let padBytes = [UInt8](repeating: 0xCD, count: 10000)

        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 172800,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B,
            transferMethod: .raptor,
            relayUrl: "https://relay.ash.test"
        )

        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: blockSize,
            passphrase: testPassphrase,
            method: .raptor,
            salt: [UInt8](repeating: 7, count: 16)
        )

        let receiver = try FountainFrameReceiver(passphrase: testPassphrase)

        while !receiver.isComplete() {
            let frame = generator.nextFrame()
            _ = try receiver.addFrame(frameBytes: frame)
        }

        let result = receiver.getResult()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pad, padBytes)
        XCTAssertEqual(result?.metadata.ttlSeconds, 172800)
        XCTAssertEqual(result?.metadata.relayUrl, "https://relay.ash.test")
    }

    func testFountainRoundtrip_withPassphrase() throws {
        let padBytes = [UInt8](repeating: 0x42, count: 5000)

        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 604800,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B,
            transferMethod: .raptor,
            relayUrl: "https://relay.ash.test"
        )

        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: blockSize,
            passphrase: "able acid aged also area army",
            method: .raptor,
            salt: [UInt8](repeating: 7, count: 16)
        )

        let receiver = try FountainFrameReceiver(passphrase: "able acid aged also area army")

        while !receiver.isComplete() {
            let frame = generator.nextFrame()
            _ = try receiver.addFrame(frameBytes: frame)
        }

        let result = receiver.getResult()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pad, padBytes)
    }

    func testFountainRoundtrip_preservesMetadata() throws {
        let originalPad = [UInt8]((0..<1000).map { UInt8($0 % 256) })

        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 86400,
            disappearingMessagesSeconds: 3600,
            notificationFlags: 0x000B,
            transferMethod: .raptor,
            relayUrl: "https://roundtrip.test"
        )

        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: originalPad,
            blockSize: blockSize,
            passphrase: testPassphrase,
            method: .raptor,
            salt: [UInt8](repeating: 7, count: 16)
        )

        let receiver = try FountainFrameReceiver(passphrase: testPassphrase)

        while !receiver.isComplete() {
            let frame = generator.nextFrame()
            _ = try receiver.addFrame(frameBytes: frame)
        }

        let result = receiver.getResult()
        XCTAssertNotNil(result)

        // Verify metadata
        XCTAssertEqual(result?.metadata.ttlSeconds, 86400)
        XCTAssertEqual(result?.metadata.disappearingMessagesSeconds, 3600)
        XCTAssertEqual(result?.metadata.relayUrl, "https://roundtrip.test")
        XCTAssertEqual(result?.metadata.notificationFlags, 0x000B)

        // Verify pad data
        XCTAssertEqual(result?.pad, originalPad, "Pad data should match after roundtrip")
    }
}
