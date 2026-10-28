//
//  GroupConversation.swift
//  Ash
//
//  A group conversation: every member sends with their own pad and holds a
//  copy of everyone else's (core/src/group.rs).
//

import Foundation

struct GroupMember: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Index in the group, 0 to 7; member 0 created the group
    let index: UInt8
    var name: String

    var id: UInt8 { index }
}

struct GroupConversation: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Relay conversation ID, derived from member 0's pad
    let id: String
    let authToken: String
    let burnToken: String
    var relayURL: String
    /// This device's member index
    let me: UInt8
    var members: [GroupMember]
    let createdAt: Date
    var messageRetention: MessageRetention
    var disappearingMessages: DisappearingMessages
    var accentColor: ConversationColor
    /// Created at home: the six words started off
    let isFamilyConversation: Bool

    var others: [GroupMember] { members.filter { $0.index != me } }

    /// "Léa, Sam and Noé"
    var displayName: String {
        let names = others.map { $0.name.isEmpty ? "Member \($0.index + 1)" : $0.name }
        guard let last = names.last else { return "Group" }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }

    func name(of index: UInt8) -> String {
        members.first { $0.index == index }?.name ?? "Member \(index + 1)"
    }
}
