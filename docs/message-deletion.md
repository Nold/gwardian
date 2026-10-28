# Deleting Messages

Two ways to remove a message, plus a lifetime the author chooses for each
message. Wire formats are in `core/src/content.rs`.

## Lifetime chosen by the author

- Each conversation and group has a default lifetime, set at its ceremony.
  It is only the starting value of the timer next to the message field.
- The author picks the lifetime of each message before sending it. A text
  with a lifetime is sent as `ExpiringText` (type `0x04`):
  `[seconds: u32 big-endian][text]`. A text without one is plain `Text`
  (`0x01`) and does not disappear on its own.
- Receivers remove the message `seconds` after it arrives; the author's phone
  removes it the same time after sending.
- Locations keep the conversation's lifetime for now.

## Delete for me

Removes the message from this phone only, and wipes exactly the pad bytes it
used where the app keeps them. Available on every message.

A message without a lifetime is never written to disk, even in a
conversation that allows persistence: it lives in memory only.

## Delete for everyone

- Only offered to the author, on a message the relay accepted.
- The author's phone sends a `Delete` message (type `0x03`) holding the pad
  offset where the deleted message's keys started: its relay `sequence` in a
  two-person conversation, its frame `offset` in a group.
- A receiver deletes the message with this offset **from the same sender**
  only. In a two-person conversation nobody but the author can delete a
  message. In a group this holds against the relay and outsiders, but not
  against another member: any member holds every pad, so it can forge a
  frame under someone else's index (`core/src/group.rs`) and delete that
  member's message on the other phones.
- The request is encrypted like any message: the relay cannot tell it from
  text. It uses a little pad, like a short message.
- The message stays on the author's phone until the relay accepts the
  request; if sending fails, the action is offered again with the same
  ciphertext.
- It is a request. A modified app, a phone that already showed the message to
  a camera, or a screenshot can keep it.
- Phones with an app from before this change cannot read types `0x03` and
  `0x04`: update every phone together.

## Platforms

Both apps, two-person conversations and groups. Android two-person messages
use the same authenticated frames as iOS (`core::message::MessageFrame`):
the pad range of a message is a 64-byte authentication key followed by the
encryption key, and the frame carries the message type.
