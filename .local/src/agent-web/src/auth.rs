//! Sign in with Forgejo (OAuth2 authorization-code flow).
//!
//! The page can type into live agent sessions, so the LAN allowlist at the ingress is
//! not enough on its own. A signed-out visit is sent to Forgejo; on return agent-web
//! exchanges the code for the user's login name, checks it against an allowlist, and
//! hands the browser an opaque session id. Sessions live in
//! `~/.config/agent-web/sessions.json` (0600) so a restart does not sign anyone out.
//!
//! The OAuth app's client id and secret are read from `~/.config/agent-web/oauth.json`.
//! The two Forgejo calls go through `curl`, with the secret on stdin rather than argv.

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;

pub const SESSION_COOKIE: &str = "agent_web";
pub const STATE_COOKIE: &str = "agent_web_state";
const SESSION_TTL_SECS: u64 = 90 * 24 * 3600;
const STATE_TTL_SECS: u64 = 600;
const DEFAULT_ALLOWED: &str = "kblack0610";

fn config_dir() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| agent_panel::session::home().join(".config"));
    base.join("agent-web")
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn random_hex(bytes: usize) -> Result<String> {
    let mut raw = vec![0u8; bytes];
    fs::File::open("/dev/urandom")?.read_exact(&mut raw)?;
    Ok(raw.iter().map(|b| format!("{b:02x}")).collect())
}

/// Constant-time equality, so response timing does not leak a prefix of the secret.
pub fn matches(given: &str, secret: &str) -> bool {
    let (a, b) = (given.as_bytes(), secret.as_bytes());
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// The value of one cookie from a `Cookie` header.
pub fn cookie<'a>(header: Option<&'a str>, name: &str) -> Option<&'a str> {
    header?.split(';').find_map(|kv| {
        let (k, v) = kv.trim().split_once('=')?;
        (k == name).then_some(v)
    })
}

/// Lax, not Strict: the callback is a top-level navigation from Forgejo, and Strict
/// would drop the state cookie on exactly that request.
pub fn set_cookie(name: &str, value: &str, max_age: u64) -> String {
    format!("{name}={value}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age={max_age}")
}

pub fn session_cookie(id: &str) -> String {
    set_cookie(SESSION_COOKIE, id, SESSION_TTL_SECS)
}

pub fn state_cookie(state: &str) -> String {
    set_cookie(STATE_COOKIE, state, STATE_TTL_SECS)
}

pub fn clear_cookie(name: &str) -> String {
    set_cookie(name, "", 0)
}

/// Percent-encode for a query string or form body (RFC 3986 unreserved set kept).
pub fn pct_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[derive(Deserialize)]
struct Credentials {
    client_id: String,
    client_secret: String,
}

pub struct OAuth {
    client_id: String,
    client_secret: String,
    forgejo: String,
    base: String,
    allowed: Vec<String>,
}

impl OAuth {
    /// Reads `oauth.json` plus the required `AGENT_WEB_FORGEJO_URL` and
    /// `AGENT_WEB_BASE_URL`, and the optional `AGENT_WEB_ALLOWED_USERS` (comma separated).
    /// The URLs are env, not constants, because this source is public.
    pub fn load() -> Result<Self> {
        let path = config_dir().join("oauth.json");
        let raw = fs::read_to_string(&path).with_context(|| {
            format!(
                "no OAuth app credentials at {} (register one in Forgejo: Settings -> Applications)",
                path.display()
            )
        })?;
        let c: Credentials = serde_json::from_str(&raw).with_context(|| {
            format!(
                "{} is not {{client_id, client_secret}} JSON",
                path.display()
            )
        })?;
        let required = |k: &str| -> Result<String> {
            let v = std::env::var(k).with_context(|| format!("{k} is not set"))?;
            Ok(v.trim_end_matches('/').to_string())
        };
        let allowed =
            std::env::var("AGENT_WEB_ALLOWED_USERS").unwrap_or_else(|_| DEFAULT_ALLOWED.into());
        Ok(Self {
            client_id: c.client_id,
            client_secret: c.client_secret,
            forgejo: required("AGENT_WEB_FORGEJO_URL")?,
            base: required("AGENT_WEB_BASE_URL")?,
            allowed: parse_allowed(&allowed),
        })
    }

    pub fn is_allowed(&self, login: &str) -> bool {
        self.allowed.iter().any(|a| a.eq_ignore_ascii_case(login))
    }

    fn redirect_uri(&self) -> String {
        format!("{}/oauth/callback", self.base)
    }

    pub fn authorize_url(&self, state: &str) -> String {
        format!(
            "{}/login/oauth/authorize?client_id={}&redirect_uri={}&response_type=code&state={}",
            self.forgejo,
            pct_encode(&self.client_id),
            pct_encode(&self.redirect_uri()),
            pct_encode(state)
        )
    }

    /// Trade the authorization code for the signed-in user's Forgejo login name.
    pub async fn login_for_code(&self, code: &str) -> Result<String> {
        let body = format!(
            "client_id={}&client_secret={}&code={}&grant_type=authorization_code&redirect_uri={}",
            pct_encode(&self.client_id),
            pct_encode(&self.client_secret),
            pct_encode(code),
            pct_encode(&self.redirect_uri())
        );
        let reply = curl(&format!(
            "url = \"{}/login/oauth/access_token\"\nheader = \"Accept: application/json\"\ndata = \"{body}\"\n",
            self.forgejo
        ))
        .await?;
        let access = reply
            .get("access_token")
            .and_then(|v| v.as_str())
            .context("Forgejo returned no access token")?
            .to_string();
        let user = curl(&format!(
            "url = \"{}/api/v1/user\"\nheader = \"Authorization: Bearer {access}\"\n",
            self.forgejo
        ))
        .await?;
        user.get("login")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .context("Forgejo returned no login name")
    }
}

fn parse_allowed(list: &str) -> Vec<String> {
    list.split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Run curl with its config on stdin (keeps secrets out of argv) and parse the JSON reply.
async fn curl(config: &str) -> Result<serde_json::Value> {
    let mut child = tokio::process::Command::new("curl")
        .args(["-sS", "--fail-with-body", "--max-time", "15", "-K", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("could not run curl")?;
    child
        .stdin
        .take()
        .context("curl has no stdin")?
        .write_all(config.as_bytes())
        .await?;
    let out = child.wait_with_output().await?;
    if !out.status.success() {
        bail!(
            "Forgejo request failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    serde_json::from_slice(&out.stdout).context("Forgejo reply was not JSON")
}

#[derive(Serialize, Deserialize, Clone)]
struct Entry {
    user: String,
    expires: u64,
}

pub struct Sessions {
    path: PathBuf,
    map: Mutex<HashMap<String, Entry>>,
}

impl Sessions {
    pub fn load() -> Self {
        Self::at(config_dir().join("sessions.json"))
    }

    fn at(path: PathBuf) -> Self {
        let map = fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        Self {
            path,
            map: Mutex::new(map),
        }
    }

    pub fn create(&self, user: &str) -> Result<String> {
        let id = random_hex(32)?;
        let mut map = self.map.lock().unwrap();
        let t = now();
        map.retain(|_, e| e.expires > t);
        map.insert(
            id.clone(),
            Entry {
                user: user.to_string(),
                expires: t + SESSION_TTL_SECS,
            },
        );
        self.save(&map)?;
        Ok(id)
    }

    pub fn user(&self, id: &str) -> Option<String> {
        let map = self.map.lock().unwrap();
        map.get(id)
            .filter(|e| e.expires > now())
            .map(|e| e.user.clone())
    }

    pub fn revoke(&self, id: &str) {
        let mut map = self.map.lock().unwrap();
        if map.remove(id).is_some() {
            let _ = self.save(&map);
        }
    }

    fn save(&self, map: &HashMap<String, Entry>) -> Result<()> {
        use std::io::Write;
        if let Some(dir) = self.path.parent() {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(dir)?;
        }
        fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&self.path)?
            .write_all(serde_json::to_string(map)?.as_bytes())?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn oauth() -> OAuth {
        OAuth {
            client_id: "id-1".into(),
            client_secret: "s3cret".into(),
            forgejo: "https://git.example".into(),
            base: "https://agents.example".into(),
            allowed: parse_allowed("alice, Bob ,"),
        }
    }

    #[test]
    fn compares_secrets() {
        assert!(matches("abc", "abc"));
        assert!(!matches("abd", "abc"));
        assert!(!matches("ab", "abc"));
        assert!(!matches("", "abc"));
    }

    #[test]
    fn reads_one_cookie_by_exact_name() {
        assert_eq!(
            cookie(Some("a=1; agent_web=tok; b=2"), SESSION_COOKIE),
            Some("tok")
        );
        assert_eq!(cookie(Some("agent_web_state=x"), SESSION_COOKIE), None);
        assert_eq!(cookie(None, SESSION_COOKIE), None);
    }

    #[test]
    fn encodes_reserved_characters() {
        assert_eq!(pct_encode("a b/c:d"), "a%20b%2Fc%3Ad");
        assert_eq!(pct_encode("Az09-_.~"), "Az09-_.~");
    }

    #[test]
    fn authorize_url_carries_state_and_callback() {
        let u = oauth().authorize_url("st8");
        assert!(u.starts_with("https://git.example/login/oauth/authorize?client_id=id-1"));
        assert!(u.contains("redirect_uri=https%3A%2F%2Fagents.example%2Foauth%2Fcallback"));
        assert!(u.ends_with("&state=st8"));
    }

    #[test]
    fn allowlist_ignores_case_and_blanks() {
        let o = oauth();
        assert!(o.is_allowed("ALICE"));
        assert!(o.is_allowed("bob"));
        assert!(!o.is_allowed("mallory"));
        assert!(!o.is_allowed(""));
    }

    #[test]
    fn sessions_persist_expire_and_revoke() {
        let dir = std::env::temp_dir().join(format!("agent-web-test-{}", random_hex(6).unwrap()));
        let path = dir.join("sessions.json");
        let s = Sessions::at(path.clone());
        let id = s.create("alice").unwrap();
        assert_eq!(s.user(&id).as_deref(), Some("alice"));
        assert_eq!(s.user("nope"), None);

        let reloaded = Sessions::at(path.clone());
        assert_eq!(reloaded.user(&id).as_deref(), Some("alice"));

        reloaded.map.lock().unwrap().get_mut(&id).unwrap().expires = 1;
        assert_eq!(reloaded.user(&id), None);

        s.revoke(&id);
        assert_eq!(s.user(&id), None);
        let _ = fs::remove_dir_all(dir);
    }
}
