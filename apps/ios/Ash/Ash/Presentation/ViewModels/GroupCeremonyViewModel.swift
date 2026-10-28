//
//  GroupCeremonyViewModel.swift
//  Ash
//
//  Presentation Layer - Group ceremony (docs/group-ceremony.md)
//
//  Around the table, one phone at a time shows its card as QR codes and all
//  the others scan it. A card holds the member's place, name and sending
//  pad. Each phone takes its place from the number of cards it scanned, so
//  nobody types a number. Once a phone holds every card, the group is formed.
//

import CryptoKit
import SwiftUI
import UIKit

@MainActor
@Observable
final class GroupCeremonyViewModel {

    enum Role: Equatable {
        /// Member 0: chooses the settings and shows the first card
        case creator
        /// Scans the creator's card first
        case joiner
    }

    enum Step: Equatable {
        case setup
        case collectingEntropy
        case generating
        /// Showing this phone's card while the others scan it
        case showing
        /// Scanning another member's card
        case scanning
        /// Between turns: scan the next card, or take this phone's turn
        case waiting
        case completed(GroupConversation)
        case failed(String)
    }

    private let dependencies: Dependencies

    let role: Role
    private(set) var step: Step = .setup

    // MARK: - Setup

    /// This member's name, shown to the others
    var myName = ""
    /// Creator only: members including this phone, 2 to 8
    var memberCount = 3
    var selectedPadSizeOption: PadSizeOption = .medium
    var serverRetention: MessageRetention = .oneDay
    var disappearingMessages: DisappearingMessages = .off
    var selectedColor: ConversationColor = .indigo
    var selectedRelayURL: String

    /// Family conversation: done at home, so the six words start off
    var isFamilyConversation = false {
        didSet { usesPassphrase = !isFamilyConversation }
    }

    /// Seal the cards with six words; on by default, off for a family group
    var usesPassphrase = true

    /// Creator: six words drawn by the app, read aloud once to the others
    private(set) var passphraseWords: [String] = []

    /// Joiner: the six words the creator read aloud; empty if none
    var typedPassphrase = ""

    // MARK: - Progress

    private(set) var entropyProgress: Double = 0
    private var collectedEntropy: [UInt8] = []

    /// This phone's place, once taken
    private(set) var me: UInt8?
    /// Cards scanned from the other members, by place
    private(set) var cards: [UInt8: GroupMemberCard] = [:]
    /// Settings chosen by the creator, from the creator's card
    private var groupMetadata: CeremonyMetadata?
    private var ownPad: [UInt8]?

    /// Scanning state
    private(set) var scanProgress: Double = 0
    private(set) var passphraseLooksWrong = false
    private(set) var passphraseRequired = false
    /// Last scan problem worth telling, such as a card scanned twice
    private(set) var scanMessage: String?
    private var receiver: FountainFrameReceiver?

    /// Showing state
    private var generator: FountainFrameGenerator?
    private var frameIndex: UInt32 = 0
    private var displayTimer: Timer?
    private(set) var currentQRImage: UIImage?

    // MARK: - Initialization

    init(dependencies: Dependencies, role: Role) {
        self.dependencies = dependencies
        self.role = role
        self.selectedRelayURL = dependencies.settingsService.relayServerURL
        if role == .creator {
            regeneratePassphrase()
        }
    }

    // MARK: - Computed Properties

    static var maxMembers: Int { Int(getMaxGroupMembers()) }

    /// Members in the group, known from the creator's card for a joiner
    var totalMembers: Int {
        role == .creator ? memberCount : Int(cards[0]?.members ?? 0)
    }

    /// Places this phone knows: its own and the scanned cards
    var knownCount: Int { cards.count + (me == nil ? 0 : 1) }

    var trimmedName: String { myName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canStart: Bool {
        guard !trimmedName.isEmpty, trimmedName.utf8.count <= 32 else { return false }
        switch role {
        case .creator:
            return (2...Self.maxMembers).contains(memberCount) && (!usesPassphrase || !passphraseWords.isEmpty)
                && !selectedRelayURL.trimmingCharacters(in: .whitespaces).isEmpty
        case .joiner:
            let words = typedPassphrase.trimmingCharacters(in: .whitespaces)
            return words.isEmpty || validatePassphrase(passphrase: words)
        }
    }

    /// The smallest place not known yet: the next card to scan
    var nextPlaceToScan: UInt8? {
        guard totalMembers > 0 else { return 0 }
        return (0..<UInt8(totalMembers)).first { $0 != me && cards[$0] == nil }
    }

    /// Every card is known: the group can be created
    var isReadyToFinish: Bool { me != nil && totalMembers > 0 && knownCount == totalMembers }

    /// A joiner takes the next place once it scanned every earlier card
    var canTakeTurn: Bool {
        role == .joiner && me == nil && totalMembers > 0 && cards.count < totalMembers
            && cards.keys.allSatisfy { Int($0) < cards.count }
    }

    /// Words sealing every card of this ceremony
    private var passphrase: String? {
        switch role {
        case .creator:
            return usesPassphrase ? passphraseWords.joined(separator: " ") : nil
        case .joiner:
            let words = typedPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? nil : words
        }
    }

    // MARK: - Setup Actions

    func regeneratePassphrase() {
        do {
            passphraseWords = try generateQrPassphrase(random: SecureRandom.bytes(12))
        } catch {
            Log.error(.ceremony, "Failed to draw passphrase words: \(error)")
            passphraseWords = []
        }
    }

    func start() {
        guard canStart else { return }
        dependencies.hapticService.medium()
        switch role {
        case .creator:
            me = 0
            step = .collectingEntropy
        case .joiner:
            startScanning()
        }
    }

    /// Joiner: every earlier card is scanned, so this phone takes the next place.
    func takeTurn() {
        guard canTakeTurn else { return }
        me = UInt8(cards.count)
        Log.info(.ceremony, "Taking place \(cards.count) of \(totalMembers)")
        step = .collectingEntropy
    }

    // MARK: - Entropy and Card

    func addEntropy(from point: CGPoint) {
        guard step == .collectingEntropy else { return }
        let x = UInt8(truncatingIfNeeded: Int(point.x * 256))
        let y = UInt8(truncatingIfNeeded: Int(point.y * 256))
        let timestamp = UInt8(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000))
        collectedEntropy.append(contentsOf: [x, y, timestamp])
        entropyProgress = min(1.0, Double(collectedEntropy.count) / 500.0)
        if entropyProgress >= 1.0 {
            // Set now, so later touches cannot start a second card
            step = .generating
            Task { await generateCard() }
        }
    }

    private func generateCard() async {
        guard let me else { return }
        dependencies.hapticService.success()

        do {
            // Every pad has the creator's size
            let size = role == .creator
                ? Int(selectedPadSizeOption.presetBytes ?? 256 * 1024)
                : cards[0]?.pad.count ?? 0
            guard size > 0 else { throw GroupCeremonyError.missingSettings }
            let pad = try await dependencies.performCeremonyUseCase.generatePadBytes(
                entropy: collectedEntropy,
                sizeBytes: size
            )
            collectedEntropy = []
            ownPad = pad

            guard let metadata = role == .creator ? creatorMetadata() : groupMetadata else {
                throw GroupCeremonyError.missingSettings
            }
            if role == .creator { groupMetadata = metadata }

            let card = try encodeMemberCard(card: GroupMemberCard(
                member: me,
                members: UInt8(totalMembers),
                name: trimmedName,
                pad: pad
            ))
            generator = try await dependencies.performCeremonyUseCase.createFountainGenerator(
                padBytes: card,
                metadata: CeremonyMetadataSwift(
                    ttlSeconds: metadata.ttlSeconds,
                    disappearingMessagesSeconds: metadata.disappearingMessagesSeconds,
                    conversationFlags: metadata.notificationFlags,
                    relayURL: metadata.relayUrl
                ),
                blockSize: UInt32(QRFrameCalculator.blockSize),
                passphrase: passphrase,
                transferMethod: .raptor
            )
            Log.info(.ceremony, "Group card ready: place \(me), pad \(pad.count) bytes")
            startShowing()
        } catch {
            Log.error(.ceremony, "Group card generation failed: \(error)")
            step = .failed("The card could not be created. Start again.")
        }
    }

    private func creatorMetadata() -> CeremonyMetadata {
        let flags = ConversationFlagsConstants.encodeColor(selectedColor, into: ConversationFlagsConstants.defaultFlags)
        return CeremonyMetadata(
            version: 1,
            ttlSeconds: serverRetention.seconds,
            disappearingMessagesSeconds: UInt32(disappearingMessages.seconds ?? 0),
            notificationFlags: flags,
            transferMethod: CeremonyTransferMethod.raptor.ffiMethod,
            relayUrl: selectedRelayURL
        )
    }

    // MARK: - Showing

    private func startShowing() {
        frameIndex = 0
        step = .showing
        showNextFrame()
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.showNextFrame() }
        }
    }

    private func showNextFrame() {
        guard step == .showing, let generator else { return }
        // Drawn large, scaled down by the screen
        currentQRImage = QRCodeGenerator.generate(from: Data(generator.generateFrame(index: frameIndex)), size: 600)
        frameIndex &+= 1
    }

    /// Show this phone's card again, for a phone that missed it.
    func showCardAgain() {
        guard me != nil, generator != nil, step == .waiting else { return }
        startShowing()
    }

    /// Everyone scanned this phone's card.
    func finishShowing() {
        stopShowing()
        advance()
    }

    private func stopShowing() {
        displayTimer?.invalidate()
        displayTimer = nil
        currentQRImage = nil
    }

    // MARK: - Scanning

    func startScanning() {
        do {
            receiver = try dependencies.performCeremonyUseCase.createFountainReceiver(passphrase: passphrase)
        } catch {
            Log.warning(.ceremony, "Invalid passphrase: \(error)")
            return
        }
        scanProgress = 0
        passphraseLooksWrong = false
        passphraseRequired = false
        scanMessage = nil
        step = .scanning
    }

    /// Back to the turn choice without a card, for instance to take a turn;
    /// back to setup before the first card, for instance to type the words.
    func stopScanning() {
        receiver = nil
        step = (me == nil && cards.isEmpty) ? .setup : .waiting
    }

    func processScannedFrame(_ data: Data) {
        guard step == .scanning, let receiver else { return }
        do {
            let isComplete = try receiver.addFrame(frameBytes: [UInt8](data))
            scanProgress = receiver.progress()
            if isComplete, let result = receiver.getResult() {
                self.receiver = nil
                accept(cardBytes: result.pad, metadata: result.metadata)
            }
        } catch {
            if case .PassphraseRequired? = error as? AshError {
                passphraseRequired = true
            } else if receiver.blocksReceived() == 0 && receiver.rejectedFrames() >= 8 {
                passphraseLooksWrong = true
            }
        }
    }

    private func accept(cardBytes: [UInt8], metadata: CeremonyMetadata) {
        do {
            let card = try decodeMemberCard(bytes: cardBytes)
            try check(card)
            if card.member == 0 {
                groupMetadata = metadata
            }
            cards[card.member] = card
            dependencies.hapticService.success()
            Log.info(.ceremony, "Scanned card of place \(card.member) (\(knownCount)/\(card.members))")
            advance()
        } catch let error as GroupCeremonyError {
            dependencies.hapticService.error()
            // Wrong card: scan the right one; a place taken twice cannot be fixed
            if case .placeTaken = error {
                step = .failed(error.message)
            } else {
                startScanning()
                scanMessage = error.message
            }
        } catch {
            dependencies.hapticService.error()
            Log.warning(.ceremony, "Invalid group card: \(error)")
            startScanning()
            scanMessage = "This is not a group card. Scan the card of the member showing it."
        }
    }

    private func check(_ card: GroupMemberCard) throws {
        // A joiner must start with the creator's card
        if cards.isEmpty && me == nil && card.member != 0 {
            throw GroupCeremonyError.creatorFirst
        }
        if totalMembers > 0 && Int(card.members) != totalMembers {
            throw GroupCeremonyError.otherGroup
        }
        if card.member == me {
            // Two phones took the same place at the same time
            throw GroupCeremonyError.placeTaken
        }
        if let existing = cards[card.member] {
            // Same place with another pad: two phones took the same turn
            throw existing.pad == card.pad ? GroupCeremonyError.alreadyScanned : GroupCeremonyError.placeTaken
        }
        if let first = cards[0], card.pad.count != first.pad.count {
            throw GroupCeremonyError.otherGroup
        }
    }

    // MARK: - Turns

    /// After a card is shown or scanned, wait for the next turn. The group is
    /// formed on request once every card is known, so this phone can still
    /// show its card again to a phone that missed it.
    private func advance() {
        if me == nil && totalMembers > 0 && cards.count >= totalMembers {
            // Every place is taken by another phone
            step = .failed(GroupCeremonyError.placeTaken.message)
        } else {
            step = .waiting
        }
    }

    func finish() {
        guard isReadyToFinish, step == .waiting else { return }
        Task { await formGroup() }
    }

    private func formGroup() async {
        guard let me, let ownPad, let metadata = groupMetadata else {
            step = .failed("The group could not be created. Start again.")
            return
        }
        step = .generating

        do {
            let group = PadGroup(me: me, ownPad: ownPad, level: .maximum)
            for card in cards.values {
                try group.addMember(member: card.member, padBytes: card.pad, level: .maximum)
            }
            let tokens = try group.takeRelayTokens()

            var members = cards.values.map { GroupMember(index: $0.member, name: $0.name) }
            members.append(GroupMember(index: me, name: trimmedName))
            members.sort { $0.index < $1.index }

            let conversation = GroupConversation(
                id: tokens.conversationId,
                authToken: tokens.authToken,
                burnToken: tokens.burnToken,
                relayURL: metadata.relayUrl,
                me: me,
                members: members,
                createdAt: Date(),
                messageRetention: MessageRetention.from(seconds: metadata.ttlSeconds),
                disappearingMessages: DisappearingMessages.from(seconds: metadata.disappearingMessagesSeconds),
                accentColor: ConversationFlagsConstants.decodeColor(from: metadata.notificationFlags),
                isFamilyConversation: passphrase == nil
            )

            try dependencies.groupRepository.savePads(group.exportState(), for: conversation.id)
            try await dependencies.groupRepository.save(conversation)
            register(conversation)

            self.ownPad = nil
            cards = [:]
            dependencies.hapticService.success()
            Log.info(.ceremony, "Group formed: \(members.count) members, place \(me)")
            step = .completed(conversation)
        } catch {
            Log.error(.ceremony, "Group formation failed: \(error)")
            step = .failed("The group could not be created. Start again on every phone.")
        }
    }

    /// Every member registers; the relay accepts the same tokens again.
    private func register(_ conversation: GroupConversation) {
        guard let relay = dependencies.createRelayService(for: conversation.relayURL) else { return }
        let members = UInt8(conversation.members.count)
        let ttl = conversation.messageRetention.seconds
        let authHash = Self.sha256Hex(conversation.authToken)
        let burnHash = Self.sha256Hex(conversation.burnToken)
        Task {
            do {
                try await relay.registerConversation(
                    conversationId: conversation.id,
                    authTokenHash: authHash,
                    burnTokenHash: burnHash,
                    ttlSeconds: ttl,
                    members: members
                )
            } catch {
                Log.warning(.ceremony, "Failed to register group with relay: \(error)")
            }
        }
    }

    private static func sha256Hex(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Cancel

    func cancel() {
        stopShowing()
        receiver = nil
        generator = nil
        ownPad = nil
        cards = [:]
        collectedEntropy = []
    }
}

enum GroupCeremonyError: Error, Equatable {
    case missingSettings
    case creatorFirst
    case otherGroup
    case alreadyScanned
    case placeTaken

    var message: String {
        switch self {
        case .missingSettings:
            return "Scan the creator's card first."
        case .creatorFirst:
            return "Scan the card of the person who created the group first."
        case .otherGroup:
            return "This card belongs to another group."
        case .alreadyScanned:
            return "This card was already scanned. Scan the next member's card."
        case .placeTaken:
            return "Two phones took the same place. Start again on every phone, one turn at a time."
        }
    }
}
