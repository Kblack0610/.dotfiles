//! Profile-aware configuration — the single source of truth for "where notes live".
//!
//! Resolution order for the active profile:
//!   1. `--profile` flag
//!   2. `$NOTES_PROFILE`
//!   3. `[hostname_map]` lookup on the short hostname
//!   4. `default_profile`
//!
//! Config file is read from (first that exists):
//!   `$NOTES_CONFIG`, `~/.config/notes/config.toml`, `~/.dotfiles/.config/notes/config.toml`.
//! If none exist, a built-in `personal` default is used so the tool works out of the box.

use anyhow::{anyhow, Context, Result};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize)]
struct RawConfig {
    #[serde(default = "default_profile_name")]
    default_profile: String,
    #[serde(default)]
    hostname_map: HashMap<String, String>,
    #[serde(default)]
    profile: HashMap<String, RawProfile>,
}

#[derive(Debug, Deserialize, Clone)]
struct RawProfile {
    root: String,
    daily: String,
    refs: String,
    fun: String,
    carryover: String,
    summaries: String,
    archive: String,
    zettel: String,
    index: String,
    #[serde(default)]
    projects: Option<String>,
    /// Dated capture drop (`/remember`, `/daily:analysis`, `notes inbox add`).
    /// Defaults to `inbox` so configs predating this field keep working.
    #[serde(default = "default_inbox")]
    inbox: String,
}

fn default_profile_name() -> String {
    "personal".to_string()
}

fn default_inbox() -> String {
    "inbox".to_string()
}

/// A fully-resolved profile with absolute paths.
pub struct Profile {
    pub name: String,
    pub source: String,
    pub root: PathBuf,
    pub daily: PathBuf,
    pub refs: PathBuf,
    /// vault-relative refs path (e.g. "journal/refs") used to build `[[wikilinks]]`
    pub refs_rel: String,
    pub fun: PathBuf,
    pub carryover: PathBuf,
    pub summaries: PathBuf,
    pub continuous: PathBuf,
    pub monthly: PathBuf,
    pub archive: PathBuf,
    pub zettel: PathBuf,
    pub index: PathBuf,
    pub projects: Option<PathBuf>,
    pub inbox: PathBuf,
    pub state_dir: PathBuf,
    pub log_file: PathBuf,
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into()))
}

/// Expand a leading `~` to $HOME.
fn expand(s: &str) -> PathBuf {
    if let Some(rest) = s.strip_prefix("~/") {
        home().join(rest)
    } else if s == "~" {
        home()
    } else {
        PathBuf::from(s)
    }
}

fn detect_hostname() -> String {
    if let Ok(h) = std::env::var("NOTES_HOSTNAME") {
        if !h.is_empty() {
            return h;
        }
    }
    if let Ok(out) = std::process::Command::new("hostname").arg("-s").output() {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !s.is_empty() {
                return s;
            }
        }
    }
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("HOST"))
        .unwrap_or_default()
}

fn config_paths() -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Ok(p) = std::env::var("NOTES_CONFIG") {
        if !p.is_empty() {
            v.push(expand(&p));
        }
    }
    v.push(home().join(".config/notes/config.toml"));
    v.push(home().join(".dotfiles/.config/notes/config.toml"));
    v
}

/// Built-in default mirroring the `personal` profile, so a fresh machine works
/// even before a config file is in place.
fn builtin_default() -> RawConfig {
    let mut profile = HashMap::new();
    profile.insert(
        "personal".to_string(),
        RawProfile {
            root: "~/.notes".into(),
            daily: "journal/daily".into(),
            refs: "journal/refs".into(),
            fun: "journal/backlogs/fun.md".into(),
            carryover: "journal/backlogs/carryover.md".into(),
            summaries: "journal/summaries".into(),
            archive: "journal/daily_archive".into(),
            zettel: "journal/permanent".into(),
            index: "journal/index".into(),
            projects: None,
            inbox: "inbox".into(),
        },
    );
    RawConfig {
        default_profile: "personal".into(),
        hostname_map: HashMap::new(),
        profile,
    }
}

fn load_raw() -> Result<(RawConfig, String)> {
    for path in config_paths() {
        if path.exists() {
            let text = std::fs::read_to_string(&path)
                .with_context(|| format!("reading config {}", path.display()))?;
            let raw: RawConfig = toml::from_str(&text)
                .with_context(|| format!("parsing config {}", path.display()))?;
            return Ok((raw, path.display().to_string()));
        }
    }
    Ok((builtin_default(), "built-in default".to_string()))
}

fn pick_profile(raw: &RawConfig, override_name: Option<&str>) -> (String, String) {
    if let Some(o) = override_name {
        return (o.to_string(), "--profile flag".into());
    }
    if let Ok(e) = std::env::var("NOTES_PROFILE") {
        if !e.is_empty() {
            return (e, "$NOTES_PROFILE".into());
        }
    }
    let host = detect_hostname();
    if !host.is_empty() {
        if let Some(p) = raw.hostname_map.get(&host) {
            return (p.clone(), format!("hostname_map[{host}]"));
        }
    }
    (raw.default_profile.clone(), "default_profile".into())
}

/// Resolve the active profile into absolute paths.
pub fn resolve(override_name: Option<&str>) -> Result<Profile> {
    let (raw, config_src) = load_raw()?;
    let (name, how) = pick_profile(&raw, override_name);
    let rp = raw.profile.get(&name).ok_or_else(|| {
        anyhow!(
            "profile '{}' is not defined (config: {}). Defined profiles: {}",
            name,
            config_src,
            raw.profile.keys().cloned().collect::<Vec<_>>().join(", ")
        )
    })?;

    let root = expand(&rp.root);
    let join = |s: &str| -> PathBuf {
        let p = expand(s);
        if p.is_absolute() {
            p
        } else {
            root.join(s)
        }
    };

    let summaries = join(&rp.summaries);
    let state_dir = home().join(".local/state/notes");
    let log_file = state_dir.join("journal.log");

    Ok(Profile {
        name,
        source: format!("{how} (config: {config_src})"),
        root: root.clone(),
        daily: join(&rp.daily),
        refs: join(&rp.refs),
        refs_rel: rp.refs.trim_end_matches('/').to_string(),
        fun: join(&rp.fun),
        carryover: join(&rp.carryover),
        continuous: summaries.join("continuous"),
        monthly: summaries.join("monthly"),
        summaries,
        archive: join(&rp.archive),
        zettel: join(&rp.zettel),
        index: join(&rp.index),
        projects: rp.projects.as_ref().map(|s| join(s)),
        inbox: join(&rp.inbox),
        state_dir,
        log_file,
    })
}

/// Build a vault-relative `[[wikilink]]` body for a file under `root`.
pub fn wikilink(root: &Path, file: &Path) -> String {
    let rel = file.strip_prefix(root).unwrap_or(file);
    let s = rel.to_string_lossy();
    s.strip_suffix(".md").unwrap_or(&s).to_string()
}

pub fn print(p: &Profile) {
    println!("profile     {}", p.name);
    println!("resolved by {}", p.source);
    println!("root        {}", p.root.display());
    println!("daily       {}", p.daily.display());
    println!("refs        {}", p.refs.display());
    println!("fun         {}", p.fun.display());
    println!("carryover   {}", p.carryover.display());
    println!("continuous  {}", p.continuous.display());
    println!("monthly     {}", p.monthly.display());
    println!("archive     {}", p.archive.display());
    println!("zettel      {}", p.zettel.display());
    println!("index       {}", p.index.display());
    println!("inbox       {}", p.inbox.display());
    println!("summaries   {}", p.summaries.display());
    if let Some(pr) = &p.projects {
        println!("projects    {}", pr.display());
    }
    println!("state       {}", p.state_dir.display());
    println!("log         {}", p.log_file.display());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expand_tilde() {
        std::env::set_var("HOME", "/home/test");
        assert_eq!(expand("~/.notes"), PathBuf::from("/home/test/.notes"));
        assert_eq!(expand("/abs/path"), PathBuf::from("/abs/path"));
        assert_eq!(expand("~"), PathBuf::from("/home/test"));
    }

    #[test]
    fn profile_pick_override_wins() {
        let raw = builtin_default();
        let (name, _) = pick_profile(&raw, Some("work"));
        assert_eq!(name, "work");
    }

    #[test]
    fn profile_pick_hostname_map() {
        let mut raw = builtin_default();
        raw.hostname_map
            .insert("corp-laptop".into(), "giganticplayground".into());
        std::env::remove_var("NOTES_PROFILE");
        std::env::set_var("NOTES_HOSTNAME", "corp-laptop");
        let (name, src) = pick_profile(&raw, None);
        assert_eq!(name, "giganticplayground");
        assert!(src.contains("hostname_map"));
        std::env::remove_var("NOTES_HOSTNAME");
    }

    #[test]
    fn wikilink_strips_root_and_ext() {
        let root = Path::new("/home/test/.notes");
        let file = Path::new("/home/test/.notes/journal/backlogs/fun.md");
        assert_eq!(wikilink(root, file), "journal/backlogs/fun");
    }
}
