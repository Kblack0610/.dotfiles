//! One shared token, kept on this machine only.
//!
//! The page can type into live agent sessions, so the LAN allowlist at the ingress
//! is not enough on its own. The token lives in `~/.config/agent-web/token` (0600)
//! and is generated on first start; the browser trades it once for a cookie.

use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::PathBuf;

use anyhow::{Context, Result};

pub const COOKIE: &str = "agent_web";

pub fn token_path() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| agent_panel::session::home().join(".config"));
    base.join("agent-web").join("token")
}

/// Read the token, creating it (and its 0700 dir) on first run.
pub fn load_or_create() -> Result<String> {
    let path = token_path();
    if let Ok(t) = fs::read_to_string(&path) {
        let t = t.trim().to_string();
        if t.len() >= 32 {
            return Ok(t);
        }
    }
    let dir = path.parent().context("token path has no parent")?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    let mut raw = [0u8; 32];
    fs::File::open("/dev/urandom")?.read_exact(&mut raw)?;
    let token: String = raw.iter().map(|b| format!("{b:02x}")).collect();
    fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)?
        .write_all(token.as_bytes())?;
    eprintln!("agent-web: generated a new token at {}", path.display());
    Ok(token)
}

/// Constant-time equality, so response timing does not leak the token prefix.
pub fn matches(given: &str, token: &str) -> bool {
    let (a, b) = (given.as_bytes(), token.as_bytes());
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// The token a request carries: `Authorization: Bearer <t>` or the cookie.
pub fn presented<'a>(authorization: Option<&'a str>, cookie: Option<&'a str>) -> Option<&'a str> {
    if let Some(t) = authorization.and_then(|h| h.strip_prefix("Bearer ")) {
        return Some(t.trim());
    }
    cookie?.split(';').find_map(|kv| {
        let (k, v) = kv.trim().split_once('=')?;
        (k == COOKIE).then_some(v)
    })
}

pub fn set_cookie(token: &str) -> String {
    format!("{COOKIE}={token}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=31536000")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compares_tokens() {
        assert!(matches("abc", "abc"));
        assert!(!matches("abd", "abc"));
        assert!(!matches("ab", "abc"));
        assert!(!matches("", "abc"));
    }

    #[test]
    fn finds_token_in_header_or_cookie() {
        assert_eq!(presented(Some("Bearer xyz"), None), Some("xyz"));
        assert_eq!(
            presented(None, Some("a=1; agent_web=tok; b=2")),
            Some("tok")
        );
        assert_eq!(presented(None, Some("agent_web_other=tok")), None);
        assert_eq!(presented(Some("Basic xyz"), None), None);
        assert_eq!(presented(None, None), None);
    }
}
