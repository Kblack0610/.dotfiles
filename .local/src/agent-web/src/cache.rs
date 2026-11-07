//! The one read cache every tab's slow read goes through. A read that takes seconds
//! (Prometheus, journald, unit properties, `fleet-bench`) is kept for its module's TTL, so
//! concurrent tabs, quick reloads and each keystroke of a search share one. The lock is held
//! across the read, so requests that arrive together wait on one read instead of starting one
//! each.

use std::convert::Infallible;
use std::future::Future;
use std::sync::Arc;
use std::time::{Duration, Instant};

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

    /// As `get`, for a read whose every answer is kept: its failures ride inside the answer.
    pub async fn keep(&self, key: K, read: impl Future<Output = T>) -> Arc<T> {
        let Ok(v) = self
            .get(key, async { Ok::<_, Infallible>(read.await) })
            .await;
        v
    }

    /// Drop the kept read, so the next request reads afresh and shows a write just made.
    pub async fn clear(&self) {
        *self.last.lock().await = None;
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
    async fn a_panic_off_the_workers_is_an_err() {
        let r = off(|| -> u32 { panic!("boom") }).await;
        assert!(r.unwrap_err().contains("panic"));
    }
}
