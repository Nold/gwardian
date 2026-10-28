# Group Ceremony

How 2 to 8 people in the same room form a group conversation. Messaging
itself is described in `ash-core::group`: every member sends with their own
pad and holds a copy of every other member's pad.

## Around the table

1. The **creator** chooses the settings: number of members, pad size,
   retention on the relay, disappearing messages, color and relay. Unless
   the group is a family group, the app draws six words and the creator
   reads them aloud once.
2. Every phone enters its owner's name. Joiners type the six words, if any.
3. The creator's phone shows its **card** as QR codes. Every other phone
   scans it.
4. Then, one at a time, the next member taps **It's my turn**. Their phone
   shows its card and every other phone scans it, including the creator's.
5. When a phone holds every card, its owner taps **Create the Group**, once
   every phone has all the cards. Until then, any phone can show its card
   again for a phone that missed it.

Nobody types a number: a joiner takes its place from the number of cards it
already scanned. The creator is member 0, the first joiner to show is
member 1, and so on.

## Card

A card is sent with the same fountain-coded QR frames as a two-person
ceremony (`docs/framing.md`), sealed with the six words when they are used
(`transfer::qr`). The payload is:

```
["GWG1"][member: u8][members: u8][name_len: u8][name: UTF-8][pad]
```

- `member` < `members`, and `members` is 2 to 8.
- `name` is at most 32 bytes.
- `pad` is the member's sending pad; every pad has the size of the
  creator's.

The frame metadata carries the group settings. Only the creator's are used;
joiners copy them into their own card.

## Checks

A phone refuses a card:

- before the creator's card, if it is not the creator's;
- whose member count or pad size differs from the creator's;
- already scanned (same place, same pad).

Two phones took the same turn at once when a phone scans a card with its
own place, or a second card for a place with a different pad, or a joiner
finds every place taken. The ceremony stops; it must start again, one turn
at a time.

A phone that missed a card asks its owner to show it again: every phone
that has shown its card can show it again until its group is created.

## Relay tokens

The conversation ID, auth token and burn token are derived from the first
160 bytes of member 0's pad (`PadGroup::take_relay_tokens`). Those bytes are
then consumed, so they never also serve as message keys: member 0's first
message starts at offset 160. Every member registers the group with the
relay, with `members` and the chosen retention (`docs/backend-contract.md`).

## Messaging

- A member encrypts with its own pad (`PadGroup::encrypt`) and saves the
  pad state before sending, so a crash never reuses a key. A message that
  fails to reach the relay is sent again with the same ciphertext.
- The relay gets the sender's index with each message. A member polls and
  acknowledges with its own index: it never gets its own messages back,
  and the relay deletes a message once every other member acknowledged it
  (`docs/backend-contract.md`).
- Decrypted messages stay in memory only: they are gone when the app quits
  or locks. Disappearing messages are removed the
  chosen time after they arrive.
- A message already read (`PadRangeAlreadyUsed`) or unreadable is
  acknowledged anyway, so it does not come back on every poll.

## Security level

Cards travel by QR code only, so every pad is at the 🔴 Maximum level.

## Not covered yet

- Adding or removing a member after the group is formed: remaining members
  must exchange new pads.
- Bluetooth cards.
