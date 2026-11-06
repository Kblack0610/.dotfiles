//! The Fleet tab: hub-core's `fleet`, shared with the TUI. The file parts are read on every
//! request, so a file event shows at once; the Prometheus part is cached here as Infra's is.
//! A runner's page (`/api/fleet/runner?name=`) is read only when it is opened, never cached.

use std::time::{Duration, Instant};

use hub_core::fleet::{self, Fleet, Paths, Prom};
use tokio::sync::Mutex;

/// As Infra's cache: a second tab or a reload inside this window reuses the last answer.
const CACHE: Duration = Duration::from_secs(30);

#[derive(Default)]
pub struct Cache(Mutex<Option<(Instant, Prom)>>);

impl Cache {
    async fn prom(&self) -> Prom {
        let mut c = self.0.lock().await;
        if let Some((at, p)) = c.as_ref() {
            if at.elapsed() < CACHE {
                return p.clone();
            }
        }
        let p = tokio::task::spawn_blocking(fleet::prom)
            .await
            .unwrap_or_else(|e| Prom {
                errors: vec![e.to_string()],
                ..Default::default()
            });
        *c = Some((Instant::now(), p.clone()));
        p
    }

    pub async fn get(&self) -> String {
        let files = tokio::task::spawn_blocking(|| fleet::files(&Paths::from_env()));
        let p = self.prom().await;
        let mut f = files.await.unwrap_or_else(|e| Fleet {
            errors: vec![e.to_string()],
            ..Default::default()
        });
        f.apply(&p);
        serde_json::to_string(&f).unwrap_or_else(|e| {
            serde_json::json!({"errors": [e.to_string()], "workers": []}).to_string()
        })
    }
}

/// One runner's page, read only when `#fleet/<name>` opens. An unknown name is the caller's 404.
pub async fn runner(name: String) -> Result<String, String> {
    let r = tokio::task::spawn_blocking(move || fleet::runner::read(&Paths::from_env(), &name))
        .await
        .map_err(|e| e.to_string())??;
    serde_json::to_string(&r).map_err(|e| e.to_string())
}
