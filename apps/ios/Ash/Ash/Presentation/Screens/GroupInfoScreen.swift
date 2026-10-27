//
//  GroupInfoScreen.swift
//  Ash
//
//  Members and settings of a group conversation
//

import SwiftUI

struct GroupInfoScreen: View {
    let group: GroupConversation
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section("Members") {
                    ForEach(group.members) { member in
                        HStack {
                            Text(member.name.isEmpty ? "Member \(Int(member.index) + 1)" : member.name)
                            if member.index == group.me {
                                Text("(you)").foregroundStyle(.secondary)
                            }
                            Spacer()
                            if member.index == 0 {
                                Text("Creator")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Settings") {
                    LabeledContent("Messages wait on the relay", value: group.messageRetention.displayName)
                    LabeledContent("Disappearing messages", value: group.disappearingMessages.displayName)
                    LabeledContent("Six words", value: group.isFamilyConversation ? "Off (family)" : "On")
                    LabeledContent("Relay", value: group.relayURL)
                    LabeledContent("Created", value: group.createdAt.formatted(date: .abbreviated, time: .shortened))
                }

                Section {
                    Button("Delete from This Phone", role: .destructive) {
                        isConfirmingDelete = true
                    }
                } footer: {
                    Text("Deletes the group and its pads from this phone only. The other members keep theirs.")
                }
            }
            .navigationTitle(group.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete this group?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: onDelete)
            } message: {
                Text("Its pads are erased. This cannot be undone.")
            }
        }
    }
}
