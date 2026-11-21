# Third-party API clients

How every repo calls an API it does not run. The global CLAUDE.md "Standards" points here.

- A third-party API is called through the owning repo's one client for that provider: a timeout, one request budget per provider shared by every process on the same key or IP, backoff on 429 and 5xx that honors Retry-After, bounded retries, and no retry of a non-idempotent write after a 5xx. Why: per-process pacing adds up past a per-IP limit (overlapping jobs on one exchange key drew about 3,000 429s a run), and a blind retry of an order POST can place it twice.
- The provider's published limit or quota sits beside its config, with the number and the date it was read. Why: a limit with no date cannot be told from a stale one.
