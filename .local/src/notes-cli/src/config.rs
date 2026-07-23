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
    /// Multi-account email triage (`notes comms`). Global (spans profiles), so it lives at
    /// the top level rather than per-profile — each account names the profile whose daily
    /// note its critical items surface into. Optional: an empty `[comms]` means the feature
    /// is off on this machine (so it never strips a `## Comms` another machine wrote).
    #[serde(default)]
    comms: RawComms,
}

/// Global comms (email triage) config. Read independently of the active profile via
/// [`comms_config`], the same way [`all_profile_names`] reads the raw config directly.
#[derive(Debug, Deserialize, Default)]
struct RawComms {
    /// Runtime state dir the triage poller writes to (dedup ledger + per-profile surface
    /// files). Outside the vault. Defaults to `~/.local/state/notes-comms`.
    #[serde(default)]
    state_dir: Option<String>,
    /// Local Ollama base URL for tier-2 classification. Defaults to the lab box.
    #[serde(default)]
    ollama_url: Option<String>,
    /// Ollama model for tier-2 classification. Defaults to `qwen3-coder:30b`.
    #[serde(default)]
    ollama_model: Option<String>,
    /// One entry per mailbox (`[[comms.account]]`).
    #[serde(default, rename = "account")]
    account: Vec<RawAccount>,
}

#[derive(Debug, Deserialize, Clone)]
struct RawAccount {
    /// Short handle (used for rbw item + state filenames), e.g. `personal`, `work`, `biz`.
    name: String,
    /// The email address (display only). Optional.
    #[serde(default)]
    address: Option<String>,
    /// rbw/Vaultwarden item holding this account's OAuth refresh token. Defaults to
    /// `gmail_oauth_<name>` (the immich per-account convention).
    #[serde(default)]
    rbw_entry: Option<String>,
    /// Which profile's daily note this account's critical items surface into. Defaults to
    /// `personal`.
    #[serde(default = "default_surface_profile")]
    surface_profile: String,
}

fn default_surface_profile() -> String {
    "personal".to_string()
}

#[derive(Debug, Deserialize, Clone)]
struct RawProfile {
    root: String,
    daily: String,
    refs: String,
    fun: String,
    carryover: String,
    /// Scheduled/deferred-task backlog (the holding pen for future-dated tasks).
    /// Optional so configs predating this field keep working — resolve() falls back
    /// to a `scheduled.md` sibling of `carryover`.
    #[serde(default)]
    scheduled: Option<String>,
    /// Standing recurring-task backlog (`(every:…)` cadence lines). Optional — resolve()
    /// falls back to a `recurring.md` sibling of `scheduled`.
    #[serde(default)]
    recurring: Option<String>,
    /// Which backlogs the daily-note footer links, in order. Each entry is a known name
    /// (`fun` | `scheduled` | `recurring`) or a vault-relative path. Optional — defaults
    /// to `["fun", "scheduled"]` when unset. This is the editable lever for that list.
    #[serde(default)]
    footer_backlogs: Option<Vec<String>>,
    /// Sentinel watches dir (`~/.agent/watches`), a RUNTIME path outside the vault. When
    /// set, `notes today` renders a `## Watches` section from the `*.yaml` manifests +
    /// their live state. Optional — unset means no watches surface (opt-in).
    #[serde(default)]
    watches: Option<String>,
    /// Dir holding per-watch `<name>.state` files. Optional — defaults to
    /// `~/.local/state/watch-companion` when `watches` is set.
    #[serde(default)]
    watches_state: Option<String>,
    /// ClickUp list id whose in-progress tickets assigned to me are mirrored into the
    /// daily note's `## Focus` (`notes clickup sync`). Optional — unset means the ClickUp
    /// bridge is off (opt-in, per-profile: only the work profile sets it). An id, NOT a path.
    #[serde(default)]
    clickup_list: Option<String>,
    summaries: String,
    archive: String,
    zettel: String,
    index: String,
    #[serde(default)]
    projects: Option<String>,
    /// Meeting logs (`notes meeting new`). Optional so configs predating this
    /// field keep working — resolve() falls back to `<root>/meetings`.
    #[serde(default)]
    meetings: Option<String>,
    /// Dated capture drop (`/remember`, `/daily:analysis`, `notes inbox add`).
    /// Defaults to `inbox` so configs predating this field keep working.
    #[serde(default = "default_inbox")]
    inbox: String,
    /// Dirs `notes tags` scans for `#hashtag`/frontmatter tags. Optional — when empty,
    /// resolve() derives a sensible default (daily, inbox, permanent, backlogs, knowledge).
    #[serde(default)]
    tag_dirs: Vec<String>,
    /// Other profiles whose open Focus tasks are MIRRORED into this profile's daily note
    /// as `### <name>` subsections (`rollup = ["acmecorp"]`). Empty = off.
    #[serde(default)]
    rollup: Vec<String>,
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
    pub scheduled: PathBuf,
    /// Standing recurring-task backlog — `(every:…)` cadence lines emitted into the
    /// daily note's Due on matching days. Sibling `recurring.md` by default.
    pub recurring: PathBuf,
    /// Resolved backlog paths the daily-note footer links, in order (config-driven).
    pub footer_backlogs: Vec<PathBuf>,
    /// Sentinel watches dir (runtime, outside the vault). `None` disables the daily
    /// note's `## Watches` section (opt-in via config).
    pub watches: Option<PathBuf>,
    /// Dir of per-watch `<name>.state` files (runtime).
    pub watches_state: PathBuf,
    /// ClickUp list id whose in-progress tickets are mirrored into `## Focus`. `None`
    /// disables the ClickUp bridge (`notes clickup sync` is a no-op), opt-in via config.
    pub clickup_list: Option<String>,
    /// Profile NAMES whose Focus is mirrored into this profile's daily note. Empty = off.
    ///
    /// Deliberately left unresolved: `resolve()` calling itself for each entry would
    /// recurse forever on a config cycle (personal -> job -> personal). `daily::rollup_entries`
    /// resolves each name lazily instead, and tolerates one that does not resolve.
    pub rollup: Vec<String>,
    pub summaries: PathBuf,
    pub continuous: PathBuf,
    pub monthly: PathBuf,
    pub archive: PathBuf,
    pub zettel: PathBuf,
    pub meetings: PathBuf,
    pub index: PathBuf,
    pub projects: Option<PathBuf>,
    /// Hand-curated cross-project index (`lab/projects/index.md`) whose `## Current`
    /// lane drives the daily note's Current Projects. Derived as the `index.md`
    /// sibling of the `projects` dir's parent; None when `projects` is unset.
    pub project_index: Option<PathBuf>,
    pub inbox: PathBuf,
    /// Dirs scanned by `notes tags` (existing dirs only; missing ones are dropped).
    pub tag_scan: Vec<PathBuf>,
    pub state_dir: PathBuf,
    pub log_file: PathBuf,
}

/// One resolved comms account (email mailbox) with defaults filled in.
pub struct Account {
    pub name: String,
    pub address: String,
    pub rbw_entry: String,
    pub surface_profile: String,
}

/// Resolved global comms config. `accounts` empty == the feature is off on this machine.
pub struct Comms {
    pub state_dir: PathBuf,
    pub ollama_url: String,
    pub ollama_model: String,
    pub accounts: Vec<Account>,
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
            scheduled: None,
            recurring: None,
            footer_backlogs: None,
            watches: None,
            watches_state: None,
            clickup_list: None,
            summaries: "journal/summaries".into(),
            archive: "journal/daily_archive".into(),
            zettel: "journal/permanent".into(),
            index: "journal/index".into(),
            projects: None,
            meetings: None,
            inbox: "inbox".into(),
            tag_dirs: Vec::new(),
            rollup: Vec::new(),
        },
    );
    RawConfig {
        default_profile: "personal".into(),
        hostname_map: HashMap::new(),
        profile,
        comms: RawComms::default(),
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

    // Scheduled (one-shot future dates) and its recurring sibling. Both optional so
    // configs predating the fields keep working: scheduled falls back to a `scheduled.md`
    // sibling of carryover, recurring to a `recurring.md` sibling of scheduled.
    let scheduled = rp
        .scheduled
        .as_ref()
        .map(|s| join(s))
        .unwrap_or_else(|| join(&rp.carryover).with_file_name("scheduled.md"));
    let recurring = rp
        .recurring
        .as_ref()
        .map(|s| join(s))
        .unwrap_or_else(|| scheduled.with_file_name("recurring.md"));
    let fun = join(&rp.fun);

    // Which backlogs the daily-note footer links, in order. Known names map to their
    // resolved paths; anything else is treated as a vault-relative path. Defaults to
    // fun + scheduled so existing behavior is unchanged.
    let footer_backlogs: Vec<PathBuf> = match &rp.footer_backlogs {
        Some(names) => names
            .iter()
            .map(|n| match n.as_str() {
                "fun" => fun.clone(),
                "scheduled" | "carryover" | "carry" => scheduled.clone(),
                "recurring" => recurring.clone(),
                other => join(other),
            })
            .collect(),
        None => vec![fun.clone(), scheduled.clone()],
    };

    // Sentinel watches (runtime paths OUTSIDE the vault; join honors absolute/~). Opt-in:
    // `watches` unset disables the `## Watches` section. State dir defaults to the
    // watch-companion runtime dir.
    let watches = rp.watches.as_ref().map(|s| join(s));
    let watches_state = rp
        .watches_state
        .as_ref()
        .map(|s| join(s))
        .unwrap_or_else(|| home().join(".local/state/watch-companion"));

    // Dirs scanned by `notes tags`. Explicit `tag_dirs` wins; otherwise derive a
    // sensible default from existing paths (daily, inbox, permanent, backlogs, knowledge).
    let mut tag_scan: Vec<PathBuf> = if rp.tag_dirs.is_empty() {
        let mut v = vec![join(&rp.daily), join(&rp.inbox), join(&rp.zettel)];
        if let Some(parent) = join(&rp.fun).parent() {
            v.push(parent.to_path_buf()); // backlogs dir (parent of fun.md)
        }
        v.push(root.join("knowledge"));
        v
    } else {
        rp.tag_dirs.iter().map(|s| join(s)).collect()
    };
    tag_scan.sort();
    tag_scan.dedup();
    tag_scan.retain(|d| d.exists());

    Ok(Profile {
        name,
        source: format!("{how} (config: {config_src})"),
        root: root.clone(),
        daily: join(&rp.daily),
        refs: join(&rp.refs),
        refs_rel: rp.refs.trim_end_matches('/').to_string(),
        fun,
        carryover: join(&rp.carryover),
        scheduled,
        recurring,
        footer_backlogs,
        watches,
        watches_state,
        // A list id (not a path) — carried through verbatim; `None` keeps the bridge off.
        clickup_list: rp.clickup_list.clone(),
        rollup: rp.rollup.clone(),
        continuous: summaries.join("continuous"),
        monthly: summaries.join("monthly"),
        summaries,
        archive: join(&rp.archive),
        zettel: join(&rp.zettel),
        meetings: rp
            .meetings
            .as_ref()
            .map(|s| join(s))
            .unwrap_or_else(|| root.join("meetings")),
        index: join(&rp.index),
        projects: rp.projects.as_ref().map(|s| join(s)),
        // `<projects-dir>/../index.md` — e.g. lab/projects/current → lab/projects/index.md
        project_index: rp
            .projects
            .as_ref()
            .map(|s| join(s))
            .and_then(|d| d.parent().map(|p| p.join("index.md"))),
        inbox: join(&rp.inbox),
        tag_scan,
        state_dir,
        log_file,
    })
}

/// Every profile NAME defined in the active config, sorted. Cross-profile aggregation
/// (`notes focus --all`) iterates this to visit all profiles without knowing them ahead
/// of time. Falls back to the built-in default's single `personal` profile when no config
/// file exists — the same source `resolve` reads, so the two never disagree.
pub fn all_profile_names() -> Result<Vec<String>> {
    let (raw, _src) = load_raw()?;
    let mut names: Vec<String> = raw.profile.keys().cloned().collect();
    names.sort();
    Ok(names)
}

/// Resolve the global comms config (defaults filled in). Read independently of the active
/// profile, like [`all_profile_names`] — the same raw source `resolve` reads. `accounts`
/// empty means comms is not configured on this machine (feature off).
pub fn comms_config() -> Result<Comms> {
    let (raw, _src) = load_raw()?;
    let rc = raw.comms;
    let state_dir = rc
        .state_dir
        .as_ref()
        .map(|s| expand(s))
        .unwrap_or_else(|| home().join(".local/state/notes-comms"));
    let ollama_url = rc
        .ollama_url
        .unwrap_or_else(|| "http://127.0.0.1:11434".to_string());
    let ollama_model = rc
        .ollama_model
        .unwrap_or_else(|| "qwen3-coder:30b".to_string());
    let accounts = rc
        .account
        .into_iter()
        .map(|a| {
            let name = a.name;
            let rbw_entry = a.rbw_entry.unwrap_or_else(|| format!("gmail_oauth_{name}"));
            Account {
                address: a.address.unwrap_or_default(),
                rbw_entry,
                surface_profile: a.surface_profile,
                name,
            }
        })
        .collect();
    Ok(Comms {
        state_dir,
        ollama_url,
        ollama_model,
        accounts,
    })
}

/// Per-profile surface file the triage poller writes and `## Comms` renders from.
pub fn comms_surface_file(c: &Comms, profile: &str) -> PathBuf {
    c.state_dir.join("surface").join(format!("{profile}.md"))
}

/// Print the resolved comms config (`notes config` appends this when comms is configured).
pub fn print_comms(c: &Comms) {
    println!();
    println!("comms-state {}", c.state_dir.display());
    println!("comms-ollama {} ({})", c.ollama_url, c.ollama_model);
    for a in &c.accounts {
        let addr = if a.address.is_empty() {
            String::new()
        } else {
            format!(" <{}>", a.address)
        };
        println!(
            "comms-acct  {}{} -> {} (rbw: {})",
            a.name, addr, a.surface_profile, a.rbw_entry
        );
    }
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
    println!("scheduled   {}", p.scheduled.display());
    println!("recurring   {}", p.recurring.display());
    println!(
        "footer      {}",
        p.footer_backlogs
            .iter()
            .map(|d| d.display().to_string())
            .collect::<Vec<_>>()
            .join(", ")
    );
    println!(
        "rollup      {}",
        if p.rollup.is_empty() {
            "(off)".to_string()
        } else {
            p.rollup.join(", ")
        }
    );
    println!("continuous  {}", p.continuous.display());
    println!("monthly     {}", p.monthly.display());
    println!("archive     {}", p.archive.display());
    println!("zettel      {}", p.zettel.display());
    println!("meetings    {}", p.meetings.display());
    println!("index       {}", p.index.display());
    println!("inbox       {}", p.inbox.display());
    println!("summaries   {}", p.summaries.display());
    println!(
        "tag-scan    {}",
        p.tag_scan
            .iter()
            .map(|d| d.display().to_string())
            .collect::<Vec<_>>()
            .join(", ")
    );
    if let Some(w) = &p.watches {
        println!("watches     {}", w.display());
        println!("watch-state {}", p.watches_state.display());
    }
    if let Some(cl) = &p.clickup_list {
        println!("clickup     list {cl}");
    }
    if let Some(pr) = &p.projects {
        println!("projects    {}", pr.display());
    }
    if let Some(pi) = &p.project_index {
        println!("proj-index  {}", pi.display());
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
            .insert("corp-laptop".into(), "AcmeCorp".into());
        std::env::remove_var("NOTES_PROFILE");
        std::env::set_var("NOTES_HOSTNAME", "corp-laptop");
        let (name, src) = pick_profile(&raw, None);
        assert_eq!(name, "AcmeCorp");
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
