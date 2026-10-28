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

Removes the message from this phone only, and wipes its pad bytes where the
app keeps them. Available on every message.

## Delete for everyone

- Only offered to the author, on a message the relay accepted.
- The author's phone sends a `Delete` message (type `0x03`) holding the pad
  offset where the deleted message's keys started: its relay `sequence` in a
  two-person conversation, its frame `offset` in a group.
- A receiver deletes the message with this offset **from the same sender**
  only, so nobody can delete someone else's message.
- The request is encrypted like any message: the relay cannot tell it from
  text. It uses a little pad, like a short message.
- It is a request. A modified app, a phone that already showed the message to
  a camera, or a screenshot can keep it.

## Platforms

| | Two-person | Group |
|---|---|---|
| iOS | Yes | Yes |
| Android | Not yet: Android two-person messages are not yet sent as authenticated frames, which carry the message type | Yes |
