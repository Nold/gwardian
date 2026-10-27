//
//  FountainCodeTests.swift
//  AshTests
//
//  Tests for fountain code (Raptor) QR transfer
//

import XCTest
@testable import Ash

// MARK: - Fountain Code Roundtrip Tests

final class FountainCodeRoundtripTests: XCTestCase {

    func testRoundtrip_smallPad_succeeds() throws {
        // Create test data
        let padBytes = [UInt8](repeating: 0xAB, count: 1000)
        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 86400,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B, // new message + expiring + delivery failed
            transferMethod: .raptor,
            relayUrl: "https://relay.test"
        )

        // Create generator with required passphrase
        let testPassphrase = "test-passphrase"
        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: 256,
            passphrase: testPassphrase,
            method: .raptor
        )

        XCTAssertGreaterThan(generator.sourceCount(), 0)

        // Create receiver with matching passphrase
        let receiver = FountainFrameReceiver(passphrase: testPassphrase)

        // Feed frames until complete
        var frameCount = 0
        while !receiver.isComplete() {
            let frame = generator.nextFrame()
            _ = try receiver.addFrame(frameBytes: frame)
            frameCount += 1

            // Safety limit
            XCTAssertLessThan(frameCount, 100, "Too many frames needed")
        }

        // Verify result
        let result = receiver.getResult()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pad, padBytes)
        XCTAssertEqual(result?.metadata.ttlSeconds, 86400)
        XCTAssertEqual(result?.metadata.relayUrl, "https://relay.test")
    }

    func testRoundtrip_withPassphrase_succeeds() throws {
        let padBytes = [UInt8]((0..<500).map { UInt8($0 % 256) })
        let passphrase = "test-passphrase"
        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 3600,
            disappearingMessagesSeconds: 60,
            notificationFlags: 0x000B,
            transferMethod: .raptor,
            relayUrl: "https://relay.test"
        )

        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: 128,
            passphrase: passphrase,
            method: .raptor
        )

        let receiver = FountainFrameReceiver(passphrase: passphrase)

        while !receiver.isComplete() {
            let frame = generator.nextFrame()
            _ = try receiver.addFrame(frameBytes: frame)
        }

        let result = receiver.getResult()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pad, padBytes)
        XCTAssertEqual(result?.metadata.disappearingMessagesSeconds, 60)
    }

    func testRoundtrip_wrongPassphrase_doesNotMatchOriginal() throws {
        // With wrong passphrase, even if decoding completes, data should be garbage
        let padBytes = [UInt8]((0..<500).map { UInt8($0 % 256) })
        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 3600,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B,
            transferMethod: .raptor,
            relayUrl: "https://relay.test"
        )

        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: 128,
            passphrase: "correct-passphrase",
            method: .raptor
        )

        // Receiver with wrong passphrase
        let receiver = FountainFrameReceiver(passphrase: "wrong-passphrase")

        // Try to receive frames (ignoring errors)
        for _ in 0..<100 {
            let frame = generator.nextFrame()
            _ = try? receiver.addFrame(frameBytes: frame)
            if receiver.isComplete() {
                break
            }
        }

        // If it completes (somehow), the result should NOT match original
        if receiver.isComplete() {
            let result = receiver.getResult()
            if let result = result {
                XCTAssertNotEqual(result.pad, padBytes, "Wrong passphrase should produce different data")
            }
        }
        // It's also valid if it never completes due to errors
    }

    func testRoundtrip_outOfOrder_succeeds() throws {
        let padBytes = [UInt8]((0..<2000).map { UInt8($0 % 256) })
        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 86400,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B,
            transferMethod: .raptor,
            relayUrl: "https://relay.test"
        )

        let testPassphrase = "test-passphrase"
        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: 256,
            passphrase: testPassphrase,
            method: .raptor
        )

        let sourceCount = Int(generator.sourceCount())

        // Generate extra frames
        var frames: [[UInt8]] = []
        for _ in 0..<(sourceCount + 10) {
            frames.append(generator.nextFrame())
        }

        // Shuffle frames to simulate out-of-order reception
        frames.shuffle()

        let receiver = FountainFrameReceiver(passphrase: testPassphrase)

        for frame in frames {
            if try receiver.addFrame(frameBytes: frame) {
                break
            }
        }

        XCTAssertTrue(receiver.isComplete())

        let result = receiver.getResult()
        XCTAssertEqual(result?.pad, padBytes)
    }

    func testRoundtrip_withSkippedFrames_succeeds() throws {
        let padBytes = [UInt8](repeating: 0xCD, count: 1500)
        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 86400,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B,
            transferMethod: .raptor,
            relayUrl: "https://relay.test"
        )

        let testPassphrase = "test-passphrase"
        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: 128,
            passphrase: testPassphrase,
            method: .raptor
        )

        let sourceCount = Int(generator.sourceCount())

        // Generate many frames
        var frames: [[UInt8]] = []
        for _ in 0..<(sourceCount * 3) {
            frames.append(generator.nextFrame())
        }

        let receiver = FountainFrameReceiver(passphrase: testPassphrase)

        // Only use every other frame
        for (i, frame) in frames.enumerated() {
            if i % 2 == 0 {
                if try receiver.addFrame(frameBytes: frame) {
                    break
                }
            }
        }

        // If not complete, add remaining frames
        if !receiver.isComplete() {
            for (i, frame) in frames.enumerated() {
                if i % 2 == 1 {
                    if try receiver.addFrame(frameBytes: frame) {
                        break
                    }
                }
            }
        }

        XCTAssertTrue(receiver.isComplete())
        let result = receiver.getResult()
        XCTAssertEqual(result?.pad, padBytes)
    }

    func testProgress_increasesWithFrames() throws {
        let padBytes = [UInt8](repeating: 0x00, count: 2000)
        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 86400,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B,
            transferMethod: .raptor,
            relayUrl: "https://relay.test"
        )

        let testPassphrase = "test-passphrase"
        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: 256,
            passphrase: testPassphrase,
            method: .raptor
        )

        let receiver = FountainFrameReceiver(passphrase: testPassphrase)

        XCTAssertEqual(receiver.progress(), 0.0)
        XCTAssertEqual(receiver.blocksReceived(), 0)

        var lastProgress = 0.0
        while !receiver.isComplete() {
            let frame = generator.nextFrame()
            _ = try receiver.addFrame(frameBytes: frame)

            let newProgress = receiver.progress()
            XCTAssertGreaterThanOrEqual(newProgress, lastProgress)
            lastProgress = newProgress
        }

        XCTAssertEqual(receiver.progress(), 1.0)
        XCTAssertGreaterThan(receiver.blocksReceived(), 0)
    }

    func testDuplicateFrames_areIgnored() throws {
        let padBytes = [UInt8](repeating: 0xFF, count: 1000)
        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 86400,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B,
            transferMethod: .raptor,
            relayUrl: "https://relay.test"
        )

        let testPassphrase = "test-passphrase"
        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: 256,
            passphrase: testPassphrase,
            method: .raptor
        )

        let receiver = FountainFrameReceiver(passphrase: testPassphrase)

        // Add the same frame multiple times
        let frame = generator.nextFrame()
        _ = try receiver.addFrame(frameBytes: frame)
        let uniqueAfterFirst = receiver.uniqueBlocksReceived()

        _ = try receiver.addFrame(frameBytes: frame)
        _ = try receiver.addFrame(frameBytes: frame)

        // Unique count shouldn't change
        XCTAssertEqual(receiver.uniqueBlocksReceived(), uniqueAfterFirst)

        // Total received should increase
        XCTAssertEqual(receiver.blocksReceived(), 3)
    }
}

// MARK: - QR Code Simulation Tests

final class QRCodeSimulationTests: XCTestCase {

    func testSimulatedQRTransfer_smallPad() throws {
        try simulateQRTransfer(padSize: 1000, blockSize: 256)
    }

    func testSimulatedQRTransfer_mediumPad() throws {
        try simulateQRTransfer(padSize: 10000, blockSize: 1500)
    }

    func testSimulatedQRTransfer_withBase64() throws {
        // This simulates the actual QR flow: base64 encode -> decode
        let padBytes = [UInt8]((0..<1000).map { UInt8($0 % 256) })
        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 86400,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B,
            transferMethod: .raptor,
            relayUrl: "https://relay.test"
        )

        let testPassphrase = "test-passphrase"
        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: 256,
            passphrase: testPassphrase,
            method: .raptor
        )

        let receiver = FountainFrameReceiver(passphrase: testPassphrase)

        while !receiver.isComplete() {
            // Generate frame
            let frameBytes = generator.nextFrame()
            let frameData = Data(frameBytes)

            // Simulate QR encoding/decoding (base64)
            let base64String = frameData.base64EncodedString()
            guard let decodedData = Data(base64Encoded: base64String) else {
                XCTFail("Base64 decoding failed")
                return
            }

            let decodedBytes = [UInt8](decodedData)
            _ = try receiver.addFrame(frameBytes: decodedBytes)
        }

        let result = receiver.getResult()
        XCTAssertEqual(result?.pad, padBytes)
    }

    private func simulateQRTransfer(padSize: Int, blockSize: UInt32) throws {
        let padBytes = [UInt8]((0..<padSize).map { UInt8($0 % 256) })
        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 86400,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B,
            transferMethod: .raptor,
            relayUrl: "https://relay.test"
        )

        let testPassphrase = "test-passphrase"
        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: blockSize,
            passphrase: testPassphrase,
            method: .raptor
        )

        let sourceCount = generator.sourceCount()
        print("Pad size: \(padSize), Source blocks: \(sourceCount)")

        let receiver = FountainFrameReceiver(passphrase: testPassphrase)

        var frameCount: UInt32 = 0
        while !receiver.isComplete() {
            let frame = generator.nextFrame()
            _ = try receiver.addFrame(frameBytes: frame)
            frameCount += 1
        }

        let overhead = Double(frameCount) / Double(sourceCount)
        print("Frames needed: \(frameCount), Overhead: \(String(format: "%.2f", overhead))x")

        let result = receiver.getResult()
        XCTAssertEqual(result?.pad, padBytes)

        // Raptor codes should have very low overhead
        XCTAssertLessThan(overhead, 1.5, "Raptor overhead should be less than 1.5x")
    }
}

// MARK: - Corrupted Frame Tests

final class CorruptedFrameTests: XCTestCase {

    func testCorruptedFrame_failsCRC() throws {
        let padBytes = [UInt8](repeating: 0xAB, count: 500)
        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 86400,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B,
            transferMethod: .raptor,
            relayUrl: "https://relay.test"
        )

        let testPassphrase = "test-passphrase"
        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: 128,
            passphrase: testPassphrase,
            method: .raptor
        )

        var frame = generator.nextFrame()

        // Corrupt a byte in the payload
        if frame.count > 20 {
            frame[15] ^= 0xFF
        }

        let receiver = FountainFrameReceiver(passphrase: testPassphrase)

        XCTAssertThrowsError(try receiver.addFrame(frameBytes: frame)) { error in
            XCTAssertTrue(error is AshError)
        }
    }

    func testTruncatedFrame_failsDecode() throws {
        let padBytes = [UInt8](repeating: 0xAB, count: 500)
        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 86400,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B,
            transferMethod: .raptor,
            relayUrl: "https://relay.test"
        )

        let testPassphrase = "test-passphrase"
        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: 128,
            passphrase: testPassphrase,
            method: .raptor
        )

        let frame = generator.nextFrame()
        let truncatedFrame = Array(frame.prefix(10))

        let receiver = FountainFrameReceiver(passphrase: testPassphrase)

        XCTAssertThrowsError(try receiver.addFrame(frameBytes: truncatedFrame)) { error in
            XCTAssertTrue(error is AshError)
        }
    }
}

// MARK: - Transfer Method Detection Tests

final class TransferMethodDetectionTests: XCTestCase {

    /// Test that transfer method is detected from ANY frame (not just block 0)
    /// This is the key fix: allows scanning to start mid-stream
    func testTransferMethod_detectedFromAnyFrame() throws {
        let padBytes = [UInt8]((0..<3000).map { UInt8($0 % 256) })
        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 86400,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B,
            transferMethod: .lt,  // Use LT to test non-default method
            relayUrl: "https://relay.test"
        )

        let testPassphrase = "test-passphrase"
        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: 256,
            passphrase: testPassphrase,
            method: .lt
        )

        // Generate many frames
        var frames: [[UInt8]] = []
        for _ in 0..<50 {
            frames.append(generator.nextFrame())
        }

        // Simulate starting scan from frame 30 (skipping 0-29)
        let receiver = FountainFrameReceiver(passphrase: testPassphrase)

        // First frame received is frame 30 - should detect method immediately
        _ = try receiver.addFrame(frameBytes: frames[30])

        // Method should be detected from first scanned frame
        let detected = receiver.detectedMethod()
        XCTAssertEqual(detected, .lt, "Should detect LT method from frame 30")

        // Continue adding frames (including block 0 later)
        for (i, frame) in frames.enumerated() {
            if i != 30 {  // Skip the one we already added
                if try receiver.addFrame(frameBytes: frame) {
                    break
                }
            }
        }

        XCTAssertTrue(receiver.isComplete())
        let result = receiver.getResult()
        XCTAssertEqual(result?.pad, padBytes)
    }

    /// Test that all transfer methods are correctly detected
    func testTransferMethod_allMethodsDetected() throws {
        let padBytes = [UInt8](repeating: 0x42, count: 1000)
        let testPassphrase = "test-passphrase"

        for method: TransferMethod in [.raptor, .lt, .sequential] {
            let metadata = CeremonyMetadata(
                version: 1,
                ttlSeconds: 86400,
                disappearingMessagesSeconds: 0,
                notificationFlags: 0x000B,
                transferMethod: method,
                relayUrl: "https://relay.test"
            )

            let generator = try createFountainGenerator(
                metadata: metadata,
                padBytes: padBytes,
                blockSize: 256,
                passphrase: testPassphrase,
                method: method
            )

            // Generate a frame (any frame)
            let frame = generator.generateFrame(index: 5)

            let receiver = FountainFrameReceiver(passphrase: testPassphrase)
            _ = try receiver.addFrame(frameBytes: frame)

            // Verify method is detected correctly
            XCTAssertEqual(receiver.detectedMethod(), method, "Should detect \(method) method")
        }
    }

    /// Test that method in frame header matches metadata
    func testTransferMethod_headerMatchesMetadata() throws {
        let padBytes = [UInt8](repeating: 0xAB, count: 1000)
        let metadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: 86400,
            disappearingMessagesSeconds: 0,
            notificationFlags: 0x000B,
            transferMethod: .sequential,
            relayUrl: "https://relay.test"
        )

        let testPassphrase = "test-passphrase"
        let generator = try createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: 256,
            passphrase: testPassphrase,
            method: .sequential
        )

        let receiver = FountainFrameReceiver(passphrase: testPassphrase)

        // Complete the transfer
        while !receiver.isComplete() {
            let frame = generator.nextFrame()
            _ = try receiver.addFrame(frameBytes: frame)
        }

        // Verify both detected method and result metadata match
        XCTAssertEqual(receiver.detectedMethod(), .sequential)

        let result = receiver.getResult()
        XCTAssertEqual(result?.metadata.transferMethod, .sequential)
    }

    /// Test roundtrip with each transfer method
    func testTransferMethod_roundtripAllMethods() throws {
        let padBytes = [UInt8]((0..<2000).map { UInt8($0 % 256) })
        let testPassphrase = "test-passphrase"

        for method: TransferMethod in [.raptor, .lt, .sequential] {
            let metadata = CeremonyMetadata(
                version: 1,
                ttlSeconds: 86400,
                disappearingMessagesSeconds: 0,
                notificationFlags: 0x000B,
                transferMethod: method,
                relayUrl: "https://relay.test"
            )

            let generator = try createFountainGenerator(
                metadata: metadata,
                padBytes: padBytes,
                blockSize: 256,
                passphrase: testPassphrase,
                method: method
            )

            let receiver = FountainFrameReceiver(passphrase: testPassphrase)

            let maxFrames = Int(generator.sourceCount()) * 3
            var frameCount = 0

            while !receiver.isComplete() && frameCount < maxFrames {
                let frame = generator.nextFrame()
                _ = try receiver.addFrame(frameBytes: frame)
                frameCount += 1
            }

            XCTAssertTrue(receiver.isComplete(), "\(method) should complete")

            let result = receiver.getResult()
            XCTAssertEqual(result?.pad, padBytes, "\(method) should preserve pad")
            XCTAssertEqual(result?.metadata.transferMethod, method, "\(method) should preserve method in metadata")
        }
    }
}
