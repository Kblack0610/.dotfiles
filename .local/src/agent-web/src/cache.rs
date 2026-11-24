//! The one read cache every tab's slow read goes through. A read that takes seconds
//! (agent-queue, fleet-bench, Prometheus, journald, unit properties) is kept and served from
//! memory, so no page waits on a CLI it has read before.
//!
//! A kept read goes stale when its TTL passes or an event outdates it. A stale read is still
//! answered at once, and one refresh starts behind it (stale-while-revalidate); when the refresh
//! lands, a `ready` event names the cache, and the open page reads again and gets the fresh
//! answer from memory. Only the first read of a key waits, and requests that arrive together
//! wait on that one read instead of starting one each. A write this server just made calls
//! `clear`, after which the next read waits for a fresh answer, so a page shows its own write.

use std::fmt::Debug;
use std::future::Future;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use serde_json::Value;
use tokio::sync::broadcast::{self, error::TryRecvError};
use tokio::sync::Mutex;
use tokio::time::Instant;

/// A refresh that takes longer than this writes a journal line: the request no longer waits on
/// it, so reqlog cannot see it, and a source that slows down must still show.
pub const SLOW_REFRESH: Duration = crate::reqlog::SLOW;

/// Where a landed refresh is announced: the pages' event channel, set once at start. Unset (the
/// tests), nothing is announced.
static READY: OnceLock<broadcast::Sender<String>> = OnceLock::new();

/// Announce landed refreshes on `events`, the channel the pages listen to.
pub fn announce_to(events: broadcast::Sender<String>) {
    let _ = READY.set(events);
}

fn ready(name: &str) {
    if let Some(tx) = READY.get() {
        let _ = tx.send(serde_json::json!({ "kind": "ready", "of": name }).to_string());
    }
}

/// True when `msg` is the event `ready` sends for `name`'s landed refresh.
pub fn is_ready(msg: &str, name: &str) -> bool {
    serde_json::from_str::<Value>(msg).is_ok_and(|v| v["kind"] == "ready" && v["of"] == name)
}

struct Kept<T, K> {
    at: Instant,
    key: K,
    value: Arc<T>,
    /// The outdate count when the read started: an event since makes it stale.
    as_of: u64,
    /// The clear count when the read started: a write since makes it unkept.
    cleared: u64,
    /// False for an answer `keep` refused (a failure, an empty read): shown, then read again.
    settled: bool,
}

/// What a background refresh needs after the request that started it has gone: the kept read
/// and the two flags no writer or reader waits on a lock for.
struct Inner<T, K> {
    kept: Mutex<Option<Kept<T, K>>>,
    /// Bumped by each `clear`, so a write never waits on a read holding the lock, and a read
    /// that started before the write is not kept after it.
    cleared: AtomicU64,
    /// One refresh at a time; a guard resets it, so a refresh that panics does not wedge it.
    refreshing: AtomicBool,
}

/// The last read, kept for `TTL_SECS` and for the key it was read for (`()` when a module has
/// one read). The TTL is a type parameter so a module's cache can be a static.
pub struct ReadCache<T, const TTL_SECS: u64, K = ()> {
    /// What its `ready` event and its `refresh slow` line call it: the read, never its type.
    name: &'static str,
    /// Bumped by `outdate`, outside the lock, so the watcher never waits on a read.
    outdated: AtomicU64,
    inner: OnceLock<Arc<Inner<T, K>>>,
}

impl<T, const TTL_SECS: u64, K> ReadCache<T, TTL_SECS, K> {
    pub const fn new(name: &'static str) -> Self {
        Self {
            name,
            outdated: AtomicU64::new(0),
            inner: OnceLock::new(),
        }
    }

    fn inner(&self) -> Arc<Inner<T, K>> {
        self.inner
            .get_or_init(|| {
                Arc::new(Inner {
                    kept: Mutex::new(None),
                    cleared: AtomicU64::new(0),
                    refreshing: AtomicBool::new(false),
                })
            })
            .clone()
    }

    /// The kept read is stale: the next request answers it and refreshes it behind.
    pub fn outdate(&self) {
        self.outdated.fetch_add(1, Ordering::SeqCst);
    }

    /// Drop the kept read, so the next request waits for a fresh one and shows a write just made.
    /// It takes no lock: a read in flight is simply not kept.
    pub fn clear(&self) {
        self.inner().cleared.fetch_add(1, Ordering::SeqCst);
    }
}

impl<T, const TTL_SECS: u64, K> ReadCache<T, TTL_SECS, K>
where
    T: Send + Sync + 'static,
    K: PartialEq + Send + Sync + 'static,
{
    /// The read kept for `key`: answered at once, refreshed behind when stale. With nothing kept
    /// for `key`, `read` is awaited and an Ok answer kept. An Err is handed back and not kept.
    pub async fn get<E: Debug + Send + 'static>(
        &self,
        key: K,
        read: impl Future<Output = Result<T, E>> + Send + 'static,
    ) -> Result<Arc<T>, E> {
        self.get_if(key, read, |_| true).await
    }

    /// As `get`, settling an Ok answer only when `keep` says so: a read that came back empty is
    /// still answered, and refreshed behind the next request as a stale one is.
    pub async fn get_if<E: Debug + Send + 'static>(
        &self,
        key: K,
        read: impl Future<Output = Result<T, E>> + Send + 'static,
        keep: impl FnOnce(&T) -> bool + Send + 'static,
    ) -> Result<Arc<T>, E> {
        let inner = self.inner();
        let mut kept = inner.kept.lock().await;
        let now_as_of = self.outdated.load(Ordering::SeqCst);
        let now_cleared = inner.cleared.load(Ordering::SeqCst);
        let ttl = Duration::from_secs(TTL_SECS);
        if let Some(k) = kept
            .as_ref()
            .filter(|k| k.key == key && k.cleared == now_cleared)
        {
            let value = k.value.clone();
            let fresh = k.settled && k.as_of == now_as_of && k.at.elapsed() < ttl;
            if !fresh && !inner.refreshing.swap(true, Ordering::SeqCst) {
                drop(kept);
                let i = inner.clone();
                tokio::spawn(refresh(
                    i,
                    self.name,
                    key,
                    now_as_of,
                    now_cleared,
                    read,
                    keep,
                ));
            }
            return Ok(value);
        }
        // Nothing kept for this key: wait for it, holding the lock so others share the read.
        let at = Instant::now();
        let value = Arc::new(read.await?);
        let settled = keep(&value);
        *kept = Some(Kept {
            at,
            key,
            value: value.clone(),
            as_of: now_as_of,
            cleared: now_cleared,
            settled,
        });
        Ok(value)
    }
}

/// Resets `refreshing` however the refresh ends, a panic included.
struct Refreshing<T, K>(Arc<Inner<T, K>>);

impl<T, K> Drop for Refreshing<T, K> {
    fn drop(&mut self) {
        self.0.refreshing.store(false, Ordering::SeqCst);
    }
}

/// One refresh behind a stale answer: kept if no write cleared the cache meanwhile and the slot
/// still holds the same key, then announced.
async fn refresh<T, K: PartialEq, E: Debug>(
    inner: Arc<Inner<T, K>>,
    name: &'static str,
    key: K,
    as_of: u64,
    cleared: u64,
    read: impl Future<Output = Result<T, E>>,
    keep: impl FnOnce(&T) -> bool,
) {
    let guard = Refreshing(inner);
    let at = Instant::now();
    let r = read.await;
    let took = at.elapsed();
    if took > SLOW_REFRESH {
        eprintln!("agent-web: {name} refresh slow: {}ms", took.as_millis());
    }
    let v = match r {
        Ok(v) => v,
        // The stale answer stays, and the next request tries again, one refresh at a time.
        Err(e) => {
            eprintln!(
                "agent-web: {name} refresh failed after {}ms: {e:?}",
                took.as_millis()
            );
            return;
        }
    };
    let inner = &guard.0;
    let mut kept = inner.kept.lock().await;
    let same = inner.cleared.load(Ordering::SeqCst) == cleared
        && kept.as_ref().is_some_and(|k| k.key == key);
    if !same {
        return;
    }
    // Timed from when it landed, so a read slower than its TTL is not stale on arrival.
    let settled = keep(&v);
    *kept = Some(Kept {
        at: Instant::now(),
        key,
        value: Arc::new(v),
        as_of,
        cleared,
        settled,
    });
    drop(kept);
    // An unsettled answer is read again on the next request; announcing it would have the page
    // ask again at once, and again, for as long as the source stays down.
    if settled {
        ready(name);
    }
}

/// A [`ReadCache`] that an event outdates: the page refreshes on the same events, so a read
/// goes stale when one of `kinds` arrives, and never lives past the TTL should the watcher be
/// down.
pub struct EventCache<T, const TTL_SECS: u64, K = ()> {
    events: std::sync::Mutex<broadcast::Receiver<String>>,
    kinds: &'static [&'static str],
    last: ReadCache<T, TTL_SECS, K>,
}

/// Whether anything queued says a ledger changed; a missed event might have, so a lag or a
/// `resync` (the file watcher started late) counts as a change to every ledger. A `ready` is a
/// cache landing, not a ledger change: no kind list names it, so no cache refreshes on another's
/// landing, and a read built from several caches joins them per request instead of caching them.
fn written(events: &mut broadcast::Receiver<String>, kinds: &[&str]) -> bool {
    let mut any = false;
    loop {
        match events.try_recv() {
            Ok(m) => {
                let v: Value = serde_json::from_str(&m).unwrap_or_default();
                any |= v["kind"]
                    .as_str()
                    .is_some_and(|k| k == "resync" || kinds.contains(&k));
            }
            Err(TryRecvError::Lagged(_)) => any = true,
            Err(_) => return any,
        }
    }
}

impl<T, const TTL_SECS: u64, K> EventCache<T, TTL_SECS, K>
where
    T: Send + Sync + 'static,
    K: PartialEq + Send + Sync + 'static,
{
    pub fn new(
        events: broadcast::Receiver<String>,
        kinds: &'static [&'static str],
        name: &'static str,
    ) -> Self {
        Self {
            events: std::sync::Mutex::new(events),
            kinds,
            last: ReadCache::new(name),
        }
    }

    /// The read for `key`. Events are drained first, so one that arrived since the last request
    /// outdates the kept read.
    pub async fn get(
        &self,
        key: K,
        read: impl FnOnce() -> T + Send + 'static,
    ) -> Result<Arc<T>, String> {
        self.get_if(key, read, |_| true).await
    }

    /// As `get`, settling the answer only when `keep` says so.
    pub async fn get_if(
        &self,
        key: K,
        read: impl FnOnce() -> T + Send + 'static,
        keep: impl FnOnce(&T) -> bool + Send + 'static,
    ) -> Result<Arc<T>, String> {
        let outdated = {
            let mut events = self.events.lock().unwrap_or_else(|e| e.into_inner());
            written(&mut events, self.kinds)
        };
        if outdated {
            self.last.outdate();
        }
        self.last.get_if(key, off(read), keep).await
    }

    /// Drop the kept read, so a write this server just made shows before its event arrives.
    pub fn clear(&self) {
        self.last.clear();
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
    use std::sync::atomic::AtomicUsize;
    use tokio::sync::Notify;

    /// A `resync` outdates every cache, whatever its kinds; any other kind only its own.
    #[test]
    fn a_resync_counts_as_a_write_to_every_ledger() {
        let (tx, mut rx) = broadcast::channel(4);
        tx.send(r#"{"kind":"asks"}"#.to_string()).unwrap();
        assert!(!written(&mut rx, &["queue"]));
        tx.send(r#"{"kind":"resync"}"#.to_string()).unwrap();
        assert!(written(&mut rx, &["queue"]));
    }

    fn counter() -> Arc<AtomicUsize> {
        Arc::new(AtomicUsize::new(0))
    }

    fn count(reads: &Arc<AtomicUsize>, n: u32) -> impl Future<Output = Result<u32, String>> {
        let reads = reads.clone();
        async move {
            reads.fetch_add(1, Ordering::SeqCst);
            if n == 0 {
                Err("down".into())
            } else {
                Ok(n)
            }
        }
    }

    /// Let every spawned refresh run to its end.
    async fn settle() {
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
    }

    #[tokio::test]
    async fn a_first_read_waits_and_is_shared_per_key_and_a_failure_is_not_kept() {
        let c: ReadCache<u32, 60, &str> = ReadCache::new("test");
        let reads = counter();
        assert_eq!(*c.get("a", count(&reads, 1)).await.unwrap(), 1);
        assert_eq!(
            *c.get("a", count(&reads, 2)).await.unwrap(),
            1,
            "kept while fresh"
        );
        assert_eq!(
            *c.get("b", count(&reads, 3)).await.unwrap(),
            3,
            "another key reads"
        );
        assert_eq!(reads.load(Ordering::SeqCst), 2);
        assert_eq!(c.get("c", count(&reads, 0)).await.unwrap_err(), "down");
        assert_eq!(
            *c.get("c", count(&reads, 4)).await.unwrap(),
            4,
            "a failure is not kept"
        );
    }

    #[tokio::test]
    async fn a_clear_makes_the_next_read_wait_for_a_fresh_answer() {
        let c: ReadCache<u32, 60> = ReadCache::new("test");
        let reads = counter();
        assert_eq!(*c.get((), count(&reads, 1)).await.unwrap(), 1);
        c.clear();
        assert_eq!(
            *c.get((), count(&reads, 2)).await.unwrap(),
            2,
            "a write shows"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_stale_read_is_answered_at_once_and_refreshed_once_behind() {
        let c: Arc<ReadCache<u32, 60>> = Arc::new(ReadCache::new("test"));
        let reads = counter();
        assert_eq!(*c.get((), count(&reads, 1)).await.unwrap(), 1);
        tokio::time::advance(Duration::from_secs(61)).await;
        // The refresh blocks until released, so an answer that waited on it would hang here.
        let gate = Arc::new(Notify::new());
        let slow = |n: u32| {
            let (gate, reads) = (gate.clone(), reads.clone());
            async move {
                reads.fetch_add(1, Ordering::SeqCst);
                gate.notified().await;
                Ok::<_, String>(n)
            }
        };
        assert_eq!(*c.get((), slow(2)).await.unwrap(), 1, "stale, at once");
        assert_eq!(*c.get((), slow(3)).await.unwrap(), 1, "still stale");
        settle().await;
        assert_eq!(
            reads.load(Ordering::SeqCst),
            2,
            "one refresh, not one per request"
        );
        gate.notify_waiters();
        settle().await;
        assert_eq!(
            *c.get((), count(&reads, 9)).await.unwrap(),
            2,
            "the refresh landed"
        );
        assert_eq!(reads.load(Ordering::SeqCst), 2, "and is fresh");
    }

    #[tokio::test]
    async fn an_outdate_refreshes_behind_and_a_clear_during_it_wins() {
        let c: ReadCache<u32, 60> = ReadCache::new("test");
        let reads = counter();
        assert_eq!(*c.get((), count(&reads, 1)).await.unwrap(), 1);
        c.outdate();
        assert_eq!(
            *c.get((), count(&reads, 2)).await.unwrap(),
            1,
            "stale, at once"
        );
        settle().await;
        assert_eq!(*c.get((), count(&reads, 3)).await.unwrap(), 2, "refreshed");

        // A refresh that started before a write must not overwrite the write's fresh read.
        let gate = Arc::new(Notify::new());
        let g = gate.clone();
        c.outdate();
        let before = async move {
            g.notified().await;
            Ok::<_, String>(40)
        };
        assert_eq!(*c.get((), before).await.unwrap(), 2);
        c.clear();
        assert_eq!(*c.get((), count(&reads, 5)).await.unwrap(), 5, "the write");
        gate.notify_waiters();
        settle().await;
        assert_eq!(
            *c.get((), count(&reads, 6)).await.unwrap(),
            5,
            "not the old read"
        );
    }

    #[tokio::test]
    async fn a_first_read_a_write_cleared_in_flight_is_not_kept() {
        let c: Arc<ReadCache<u32, 60>> = Arc::new(ReadCache::new("test"));
        let reads = counter();
        let gate = Arc::new(Notify::new());
        let g = gate.clone();
        let first = tokio::spawn({
            let c = c.clone();
            async move {
                c.get((), async move {
                    g.notified().await;
                    Ok::<_, String>(1)
                })
                .await
            }
        });
        settle().await;
        // The read holds the lock; a clear that waited on it would hang here.
        c.clear();
        gate.notify_waiters();
        assert_eq!(
            *first.await.unwrap().unwrap(),
            1,
            "its caller still gets it"
        );
        assert_eq!(
            *c.get((), count(&reads, 2)).await.unwrap(),
            2,
            "the next read waits for one after the write"
        );
    }

    #[tokio::test]
    async fn a_refresh_that_panics_does_not_stop_the_next_one() {
        let c: ReadCache<u32, 60> = ReadCache::new("test");
        let reads = counter();
        assert_eq!(*c.get((), count(&reads, 1)).await.unwrap(), 1);
        c.outdate();
        let boom = async { panic!("read failed") as Result<u32, String> };
        assert_eq!(*c.get((), boom).await.unwrap(), 1);
        settle().await;
        assert_eq!(
            *c.get((), count(&reads, 2)).await.unwrap(),
            1,
            "stale, at once"
        );
        settle().await;
        assert_eq!(*c.get((), count(&reads, 3)).await.unwrap(), 2, "refreshed");
    }
    #[tokio::test]
    async fn a_refresh_that_fails_keeps_the_stale_answer() {
        let c: ReadCache<u32, 60> = ReadCache::new("test");
        let reads = counter();
        assert_eq!(*c.get((), count(&reads, 1)).await.unwrap(), 1);
        c.outdate();
        assert_eq!(*c.get((), count(&reads, 0)).await.unwrap(), 1);
        settle().await;
        assert_eq!(
            *c.get((), count(&reads, 2)).await.unwrap(),
            1,
            "kept, tried again"
        );
        settle().await;
        assert_eq!(*c.get((), count(&reads, 3)).await.unwrap(), 2);
    }

    #[tokio::test]
    async fn an_unsettled_answer_is_shown_and_read_again() {
        let c: ReadCache<u32, 60> = ReadCache::new("test");
        let reads = counter();
        assert_eq!(*c.get_if((), count(&reads, 6), |_| false).await.unwrap(), 6);
        assert_eq!(*c.get((), count(&reads, 7)).await.unwrap(), 6);
        settle().await;
        assert_eq!(*c.get((), count(&reads, 8)).await.unwrap(), 7);
        assert_eq!(reads.load(Ordering::SeqCst), 2);
    }

    /// The announcements, from one channel every test shares (the sink is set once).
    fn announced() -> broadcast::Receiver<String> {
        static TX: OnceLock<broadcast::Sender<String>> = OnceLock::new();
        let tx = TX.get_or_init(|| {
            let (tx, _) = broadcast::channel(64);
            announce_to(tx.clone());
            tx
        });
        tx.subscribe()
    }

    /// Wait for `name`'s next `ready`, skipping other tests' announcements.
    async fn landed(rx: &mut broadcast::Receiver<String>, name: &str) {
        while !is_ready(&rx.recv().await.unwrap(), name) {}
    }

    #[test]
    fn is_ready_matches_only_its_own_landed_refresh() {
        assert!(is_ready(r#"{"kind":"ready","of":"builds"}"#, "builds"));
        assert!(!is_ready(r#"{"kind":"ready","of":"suites"}"#, "builds"));
        assert!(!is_ready(r#"{"kind":"builds"}"#, "builds"));
        assert!(!is_ready("not json", "builds"));
    }

    #[tokio::test]
    async fn a_landed_refresh_is_announced_by_name() {
        let mut rx = announced();
        let c: ReadCache<u32, 60> = ReadCache::new("announce-test");
        let reads = counter();
        c.get((), count(&reads, 1)).await.unwrap();
        c.outdate();
        c.get((), count(&reads, 2)).await.unwrap();
        landed(&mut rx, "announce-test").await;
        assert_eq!(*c.get((), count(&reads, 3)).await.unwrap(), 2);
    }

    #[tokio::test]
    async fn an_event_cache_goes_stale_on_its_kind_and_not_otherwise() {
        let mut rx = announced();
        let (tx, _) = broadcast::channel(8);
        let c: EventCache<u32, 60> = EventCache::new(tx.subscribe(), &["queue"], "event-test");
        assert_eq!(*c.get((), || 1).await.unwrap(), 1);
        tx.send(r#"{"kind":"transcript"}"#.into()).unwrap();
        tx.send(r#"{"kind":"ready","of":"queue"}"#.into()).unwrap();
        assert_eq!(
            *c.get((), || 2).await.unwrap(),
            1,
            "another kind, or a landing, keeps it"
        );
        tx.send(r#"{"kind":"queue"}"#.into()).unwrap();
        assert_eq!(
            *c.get((), || 3).await.unwrap(),
            1,
            "its kind: stale, at once"
        );
        landed(&mut rx, "event-test").await;
        assert_eq!(*c.get((), || 4).await.unwrap(), 3, "refreshed behind");
        c.clear();
        assert_eq!(
            *c.get((), || 5).await.unwrap(),
            5,
            "a clear waits for fresh"
        );
    }

    #[tokio::test]
    async fn a_panic_off_the_workers_is_an_err() {
        let r = off(|| -> u32 { panic!("boom") }).await;
        assert!(r.unwrap_err().contains("panic"));
    }
}
