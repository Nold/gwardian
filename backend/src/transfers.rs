//! Short-lived mailboxes relaying pad transfers (`Standard` security level).
//!
//! Two devices that share no secret yet use a transfer session to run the
//! `ash-transfer` protocol through the relay. The receiver creates the
//! session and gets two tokens; it keeps its own and passes the sender's
//! token to the other person out of band (link, message, call).
//!
//! The relay only queues opaque messages between the two roles. It cannot
//! read the pad: the protocol encrypts it end to end, and the six words people
//! compare reveal an attacker in the middle, including the relay itself.
//!
//! # Limits
//!
//! Sessions expire after `TransferLimits::ttl`, each inbox holds a few
//! messages, and a global byte budget caps memory use. Like the rest of the
//! relay, nothing is persisted and no identity is stored.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use bytes::Bytes;
use dashmap::DashMap;
use ring::digest::{digest, SHA256};
use ring::rand::{SecureRandom, SystemRandom};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tracing::info;

/// Limits applied to transfer sessions.
#[derive(Debug, Clone)]
pub struct TransferLimits {
    /// Lifetime of a session from its creation.
    pub ttl: Duration,
    /// Largest single message (a sealed 1 MiB pad plus overhead fits).
    pub max_message_size: usize,
    /// Messages waiting in one direction before the sender must wait.
    pub max_queued_per_inbox: usize,
    /// Concurrent sessions.
    pub max_sessions: usize,
    /// Bytes queued across all sessions.
    pub max_total_bytes: usize,
}

impl Default for TransferLimits {
    fn default() -> Self {
        Self {
            ttl: Duration::from_secs(10 * 60),
            max_message_size: 2 * 1024 * 1024,
            max_queued_per_inbox: 4,
            max_sessions: 10_000,
            max_total_bytes: 256 * 1024 * 1024,
        }
    }
}

/// Side of a transfer, determined by the token presented.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// Device receiving the pad; created the session.
    Receiver,
    /// Pad owner, joining with the token passed out of band.
    Sender,
}

/// Errors returned by transfer operations.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferError {
    /// Unknown or expired session.
    NotFound,
    /// Token matches neither role.
    Unauthorized,
    /// Message exceeds `max_message_size`.
    TooLarge,
    /// The peer has not collected earlier messages yet.
    InboxFull,
    /// Session or byte budget exhausted.
    Capacity,
}

/// Identifiers handed to the receiver when a session is created.
#[derive(Debug, Clone)]
pub struct CreatedTransfer {
    /// Session id, used in URLs.
    pub id: String,
    /// Token the receiver keeps.
    pub receiver_token: String,
    /// Token the receiver passes to the sender.
    pub sender_token: String,
}

struct Session {
    receiver_hash: [u8; 32],
    sender_hash: [u8; 32],
    created: Instant,
    to_receiver: VecDeque<Bytes>,
    to_sender: VecDeque<Bytes>,
}

impl Session {
    fn role(&self, token: &str) -> Option<Role> {
        // Comparing hashes: timing cannot leak the tokens themselves
        let hash = hash(token);
        if hash == self.receiver_hash {
            Some(Role::Receiver)
        } else if hash == self.sender_hash {
            Some(Role::Sender)
        } else {
            None
        }
    }

    fn queued_bytes(&self) -> usize {
        self.to_receiver
            .iter()
            .chain(&self.to_sender)
            .map(Bytes::len)
            .sum()
    }
}

fn hash(token: &str) -> [u8; 32] {
    let mut out = [0u8; 32];
    out.copy_from_slice(digest(&SHA256, token.as_bytes()).as_ref());
    out
}

/// In-memory store of transfer sessions.
pub struct TransferStore {
    sessions: DashMap<String, Session>,
    total_bytes: AtomicUsize,
    limits: TransferLimits,
    rng: SystemRandom,
}

impl TransferStore {
    /// Create an empty store.
    pub fn new(limits: TransferLimits) -> Self {
        Self {
            sessions: DashMap::new(),
            total_bytes: AtomicUsize::new(0),
            limits,
            rng: SystemRandom::new(),
        }
    }

    /// Limits in force.
    pub fn limits(&self) -> &TransferLimits {
        &self.limits
    }

    /// Number of live sessions (expired ones may linger until cleanup).
    pub fn len(&self) -> usize {
        self.sessions.len()
    }

    /// Whether there are no sessions.
    pub fn is_empty(&self) -> bool {
        self.sessions.is_empty()
    }

    /// Bytes currently queued across all sessions.
    pub fn total_bytes(&self) -> usize {
        self.total_bytes.load(Ordering::Relaxed)
    }

    fn random<const N: usize>(&self) -> [u8; N] {
        let mut out = [0u8; N];
        self.rng
            .fill(&mut out)
            .expect("system random number generator failed");
        out
    }

    /// Open a new session.
    ///
    /// # Errors
    ///
    /// `Capacity` when `max_sessions` is reached.
    pub fn create(&self) -> Result<CreatedTransfer, TransferError> {
        if self.sessions.len() >= self.limits.max_sessions {
            return Err(TransferError::Capacity);
        }
        let id = hex::encode(self.random::<16>());
        let receiver_token = URL_SAFE_NO_PAD.encode(self.random::<32>());
        let sender_token = URL_SAFE_NO_PAD.encode(self.random::<32>());
        self.sessions.insert(
            id.clone(),
            Session {
                receiver_hash: hash(&receiver_token),
                sender_hash: hash(&sender_token),
                created: Instant::now(),
                to_receiver: VecDeque::new(),
                to_sender: VecDeque::new(),
            },
        );
        Ok(CreatedTransfer {
            id,
            receiver_token,
            sender_token,
        })
    }

    /// Run `f` on a live session after checking the token.
    fn with_session<T>(
        &self,
        id: &str,
        token: &str,
        f: impl FnOnce(&mut Session, Role) -> Result<T, TransferError>,
    ) -> Result<T, TransferError> {
        let mut session = self.sessions.get_mut(id).ok_or(TransferError::NotFound)?;
        if session.created.elapsed() >= self.limits.ttl {
            drop(session);
            self.remove(id);
            return Err(TransferError::NotFound);
        }
        let role = session.role(token).ok_or(TransferError::Unauthorized)?;
        f(&mut session, role)
    }

    /// Queue a message for the other role.
    ///
    /// # Errors
    ///
    /// `NotFound`, `Unauthorized`, `TooLarge`, `InboxFull` or `Capacity`.
    pub fn post(&self, id: &str, token: &str, message: Bytes) -> Result<(), TransferError> {
        if message.len() > self.limits.max_message_size {
            return Err(TransferError::TooLarge);
        }
        self.with_session(id, token, |session, role| {
            let inbox = match role {
                Role::Receiver => &mut session.to_sender,
                Role::Sender => &mut session.to_receiver,
            };
            if inbox.len() >= self.limits.max_queued_per_inbox {
                return Err(TransferError::InboxFull);
            }
            let len = message.len();
            let reserved = self.total_bytes.fetch_add(len, Ordering::Relaxed) + len;
            if reserved > self.limits.max_total_bytes {
                self.total_bytes.fetch_sub(len, Ordering::Relaxed);
                return Err(TransferError::Capacity);
            }
            inbox.push_back(message);
            Ok(())
        })
    }

    /// Take the oldest message addressed to the caller's role, if any.
    ///
    /// # Errors
    ///
    /// `NotFound` or `Unauthorized`.
    pub fn take(&self, id: &str, token: &str) -> Result<Option<Bytes>, TransferError> {
        self.with_session(id, token, |session, role| {
            let inbox = match role {
                Role::Receiver => &mut session.to_receiver,
                Role::Sender => &mut session.to_sender,
            };
            let message = inbox.pop_front();
            if let Some(m) = &message {
                self.total_bytes.fetch_sub(m.len(), Ordering::Relaxed);
            }
            Ok(message)
        })
    }

    /// End a session; either role may do so.
    ///
    /// # Errors
    ///
    /// `NotFound` or `Unauthorized`.
    pub fn close(&self, id: &str, token: &str) -> Result<(), TransferError> {
        self.with_session(id, token, |_, _| Ok(()))?;
        self.remove(id);
        Ok(())
    }

    fn remove(&self, id: &str) {
        if let Some((_, session)) = self.sessions.remove(id) {
            self.total_bytes
                .fetch_sub(session.queued_bytes(), Ordering::Relaxed);
        }
    }

    /// Drop expired sessions; returns how many were removed.
    pub fn cleanup_expired(&self) -> usize {
        let expired: Vec<String> = self
            .sessions
            .iter()
            .filter(|s| s.created.elapsed() >= self.limits.ttl)
            .map(|s| s.key().clone())
            .collect();
        for id in &expired {
            self.remove(id);
        }
        expired.len()
    }

    /// Start a background task removing expired sessions every `interval`.
    pub fn start_cleanup_task(self: Arc<Self>, interval: Duration) {
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(interval);
            loop {
                ticker.tick().await;
                self.cleanup_expired();
            }
        });
        info!(
            interval_secs = interval.as_secs(),
            "Started transfer cleanup task"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> TransferStore {
        TransferStore::new(TransferLimits::default())
    }

    #[test]
    fn messages_flow_between_roles() {
        let store = store();
        let t = store.create().unwrap();

        store
            .post(&t.id, &t.receiver_token, Bytes::from_static(b"offer"))
            .unwrap();
        // The receiver does not get its own message back
        assert_eq!(store.take(&t.id, &t.receiver_token).unwrap(), None);
        assert_eq!(
            store.take(&t.id, &t.sender_token).unwrap().unwrap(),
            Bytes::from_static(b"offer")
        );

        store
            .post(&t.id, &t.sender_token, Bytes::from_static(b"one"))
            .unwrap();
        store
            .post(&t.id, &t.sender_token, Bytes::from_static(b"two"))
            .unwrap();
        assert_eq!(store.total_bytes(), 6);
        assert_eq!(
            store.take(&t.id, &t.receiver_token).unwrap().unwrap(),
            Bytes::from_static(b"one")
        );
        assert_eq!(
            store.take(&t.id, &t.receiver_token).unwrap().unwrap(),
            Bytes::from_static(b"two")
        );
        assert_eq!(store.total_bytes(), 0);
    }

    #[test]
    fn tokens_and_ids_are_checked() {
        let store = store();
        let t = store.create().unwrap();
        let other = store.create().unwrap();
        assert_ne!(t.id, other.id);
        assert_ne!(t.receiver_token, t.sender_token);

        assert_eq!(
            store.take(&t.id, "wrong").unwrap_err(),
            TransferError::Unauthorized
        );
        assert_eq!(
            store.take(&t.id, &other.sender_token).unwrap_err(),
            TransferError::Unauthorized
        );
        assert_eq!(
            store.take("missing", &t.sender_token).unwrap_err(),
            TransferError::NotFound
        );
    }

    #[test]
    fn limits_are_enforced() {
        let store = TransferStore::new(TransferLimits {
            max_message_size: 10,
            max_queued_per_inbox: 2,
            max_sessions: 2,
            max_total_bytes: 15,
            ..TransferLimits::default()
        });
        let t = store.create().unwrap();
        store.create().unwrap();
        assert_eq!(store.create().unwrap_err(), TransferError::Capacity);

        assert_eq!(
            store
                .post(&t.id, &t.sender_token, Bytes::from(vec![0; 11]))
                .unwrap_err(),
            TransferError::TooLarge
        );
        store
            .post(&t.id, &t.sender_token, Bytes::from(vec![0; 10]))
            .unwrap();
        // Byte budget: 10 + 6 > 15
        assert_eq!(
            store
                .post(&t.id, &t.receiver_token, Bytes::from(vec![0; 6]))
                .unwrap_err(),
            TransferError::Capacity
        );
        assert_eq!(store.total_bytes(), 10);

        store
            .post(&t.id, &t.sender_token, Bytes::from(vec![0; 1]))
            .unwrap();
        assert_eq!(
            store
                .post(&t.id, &t.sender_token, Bytes::from(vec![0; 1]))
                .unwrap_err(),
            TransferError::InboxFull
        );
    }

    #[test]
    fn sessions_expire() {
        let store = TransferStore::new(TransferLimits {
            ttl: Duration::ZERO,
            ..TransferLimits::default()
        });
        let t = store.create().unwrap();
        assert_eq!(
            store.take(&t.id, &t.receiver_token).unwrap_err(),
            TransferError::NotFound
        );
        assert!(store.is_empty());

        store.create().unwrap();
        assert_eq!(store.cleanup_expired(), 1);
        assert!(store.is_empty());
    }

    #[test]
    fn close_frees_queued_bytes() {
        let store = store();
        let t = store.create().unwrap();
        store
            .post(&t.id, &t.sender_token, Bytes::from(vec![0; 100]))
            .unwrap();
        assert_eq!(
            store.close(&t.id, "wrong").unwrap_err(),
            TransferError::Unauthorized
        );
        store.close(&t.id, &t.receiver_token).unwrap();
        assert_eq!(store.total_bytes(), 0);
        assert_eq!(
            store.take(&t.id, &t.sender_token).unwrap_err(),
            TransferError::NotFound
        );
    }
}
