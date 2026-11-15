//! The one read cache every tab's slow read goes through. A read that takes seconds
//! (Prometheus, journald, unit properties, `fleet-bench`) is kept for its module's TTL, so
//! concurrent tabs, quick reloads and each keystroke of a search share one. The lock is held
//! across the read, so requests that arrive together wait on one read instead of starting one
//! each.

use std::future::Future;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::Value;
use tokio::sync::broadcast::{self, error::TryRecvError};
use tokio::sync::Mutex;

/// The last read, kept for `TTL_SECS` and for the key it was read for (`()` when a module has
/// one read). The TTL is a type parameter so a module's cache is `Default` and can be a static.
pub struct ReadCache<T, const TTL_SECS: u64, K = ()> {
    last: Mutex<Option<(Instant, K, Arc<T>)>>,
}

impl<T, const TTL_SECS: u64, K> Default for ReadCache<T, TTL_SECS, K> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T, const TTL_SECS: u64, K> ReadCache<T, TTL_SECS, K> {
    pub const fn new() -> Self {
        Self {
            last: Mutex::const_new(None),
        }
    }
}

impl<T, const TTL_SECS: u64, K: PartialEq> ReadCache<T, TTL_SECS, K> {
    /// The read kept for `key` while it is younger than the TTL; otherwise `read` is awaited and
    /// an Ok answer kept. An Err is handed back and not kept, so the next request tries again.
    pub async fn get<E>(
        &self,
        key: K,
        read: impl Future<Output = Result<T, E>>,
    ) -> Result<Arc<T>, E> {
        self.get_if(key, read, |_| true).await
    }

    /// As `get`, keeping an Ok answer only when `keep` says so: a read that came back empty is
    /// shown but read again next time.
    pub async fn get_if<E>(
        &self,
        key: K,
        read: impl Future<Output = Result<T, E>>,
        keep: impl FnOnce(&T) -> bool,
    ) -> Result<Arc<T>, E> {
        let mut last = self.last.lock().await;
        let ttl = Duration::from_secs(TTL_SECS);
        if let Some((_, _, v)) = last
            .as_ref()
            .filter(|(at, k, _)| *k == key && at.elapsed() < ttl)
        {
            return Ok(v.clone());
        }
        let v = Arc::new(read.await?);
        if keep(&v) {
            *last = Some((Instant::now(), key, v.clone()));
        }
        Ok(v)
    }

    /// Drop the kept read, so the next request reads afresh and shows a write just made.
    pub async fn clear(&self) {
        *self.last.lock().await = None;
    }
}

/// A [`ReadCache`] that an event outdates: the page refreshes on the same events, so a read is
/// kept only until one of `kinds` arrives, and never past the TTL should the watcher be down.
pub struct EventCache<T, const TTL_SECS: u64, K = ()> {
    events: Mutex<broadcast::Receiver<String>>,
    kinds: &'static [&'static str],
    last: ReadCache<T, TTL_SECS, K>,
}

/// Whether anything queued says a ledger changed; a missed event might have.
fn written(events: &mut broadcast::Receiver<String>, kinds: &[&str]) -> bool {
    let mut any = false;
    loop {
        match events.try_recv() {
            Ok(m) => {
                let v: Value = serde_json::from_str(&m).unwrap_or_default();
                any |= kinds.iter().any(|k| v["kind"] == *k);
            }
            Err(TryRecvError::Lagged(_)) => any = true,
            Err(_) => return any,
        }
    }
}

impl<T: Send + 'static, const TTL_SECS: u64, K: PartialEq> EventCache<T, TTL_SECS, K> {
    pub fn new(events: broadcast::Receiver<String>, kinds: &'static [&'static str]) -> Self {
        Self {
            events: Mutex::new(events),
            kinds,
            last: ReadCache::new(),
        }
    }

    /// The read for `key`. Events are drained before the read, so one arriving during it outdates
    /// it; the events lock is held across the read, so the next request sees that one.
    pub async fn get(
        &self,
        key: K,
        read: impl FnOnce() -> T + Send + 'static,
    ) -> Result<Arc<T>, String> {
        self.get_if(key, read, |_| true).await
    }

    /// As `get`, keeping the answer only when `keep` says so.
    pub async fn get_if(
        &self,
        key: K,
        read: impl FnOnce() -> T + Send + 'static,
        keep: impl FnOnce(&T) -> bool,
    ) -> Result<Arc<T>, String> {
        let mut events = self.events.lock().await;
        if written(&mut events, self.kinds) {
            self.last.clear().await;
        }
        self.last.get_if(key, off(read), keep).await
    }

    /// Drop the kept read, so a write this server just made shows before its event arrives.
    pub async fn clear(&self) {
        self.last.clear().await;
    }
}

/// `f` off the async workers; a panic in it comes back as its message.
pub async fn off<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Result<T, String> {
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    async fn count(reads: &AtomicUsize, n: u32) -> Result<u32, String> {
        reads.fetch_add(1, Ordering::SeqCst);
        if n == 0 {
            Err("down".into())
        } else {
            Ok(n)
        }
    }

    #[tokio::test]
    async fn a_fresh_read_is_shared_per_key_and_a_failure_is_not_kept() {
        let c: ReadCache<u32, 60, &str> = ReadCache::new();
        let reads = AtomicUsize::new(0);
        let count = |n| count(&reads, n);
        assert_eq!(*c.get("a", count(1)).await.unwrap(), 1);
        assert_eq!(*c.get("a", count(2)).await.unwrap(), 1, "kept while fresh");
        assert_eq!(*c.get("b", count(3)).await.unwrap(), 3, "another key reads");
        assert_eq!(reads.load(Ordering::SeqCst), 2);
        assert_eq!(c.get("c", count(0)).await.unwrap_err(), "down");
        assert_eq!(
            *c.get("c", count(4)).await.unwrap(),
            4,
            "a failure is not kept"
        );
        c.clear().await;
        assert_eq!(*c.get("c", count(5)).await.unwrap(), 5, "cleared");
        assert_eq!(*c.get_if("d", count(6), |_| false).await.unwrap(), 6);
        assert_eq!(
            *c.get("d", count(7)).await.unwrap(),
            7,
            "an unkept answer reads again"
        );
    }

    #[tokio::test]
    async fn a_stale_read_is_read_again() {
        let c: ReadCache<u32, 0> = ReadCache::new();
        let reads = AtomicUsize::new(0);
        assert_eq!(*c.get((), count(&reads, 1)).await.unwrap(), 1);
        assert_eq!(*c.get((), count(&reads, 2)).await.unwrap(), 2);
    }

    #[tokio::test]
    async fn an_event_cache_reads_again_on_its_kind_or_a_clear_and_not_otherwise() {
        let (tx, _) = broadcast::channel(8);
        let c: EventCache<u32, 60> = EventCache::new(tx.subscribe(), &["queue"]);
        assert_eq!(*c.get((), || 1).await.unwrap(), 1);
        tx.send(r#"{"kind":"transcript"}"#.into()).unwrap();
        assert_eq!(*c.get((), || 2).await.unwrap(), 1, "another kind keeps it");
        tx.send(r#"{"kind":"queue"}"#.into()).unwrap();
        assert_eq!(*c.get((), || 3).await.unwrap(), 3, "its kind outdates it");
        c.clear().await;
        assert_eq!(*c.get((), || 4).await.unwrap(), 4, "a clear outdates it");
    }

    #[tokio::test]
    async fn a_panic_off_the_workers_is_an_err() {
        let r = off(|| -> u32 { panic!("boom") }).await;
        assert!(r.unwrap_err().contains("panic"));
    }
}
