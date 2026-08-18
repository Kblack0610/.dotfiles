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
    /// The VAULT root — the one directory every org lives under. Top-level, because it belongs
    /// to no org: it is what a cross-org artifact is addressed relative to, and what lets an
    /// org's note link something outside itself.
    ///
    /// Without it the only anchor was "the active profile's root", and for `personal` that
    /// happens to equal the vault. Cross-org state then silently acquired a personal address:
    /// the board aggregates every org but was written wherever the ACTIVE profile pointed, and
    /// every other org's daily note linked a `board.md` that had never been written there.
    #[serde(default = "default_vault")]
    vault: String,
    /// The cross-org board, relative to `vault`. One file, one address, regardless of which org
    /// is active when it is regenerated.
    #[serde(default = "default_board")]
    board: String,
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
    /// LiteLLM gateway base URL for tier-2 classification (OpenAI-compatible). The
    /// `ollama_url` alias is the legacy key name (the endpoint is the gateway, not Ollama).
    #[serde(default, alias = "ollama_url")]
    llm_base_url: Option<String>,
    /// Model name the gateway routes tier-2 to. `ollama_model` is the legacy alias.
    #[serde(default, alias = "ollama_model")]
    llm_model: Option<String>,
    /// Machine-local path to `comms-stats.py` (the private skill), used by
    /// `notes comms stats --fresh` to regenerate the snapshot live. The public CLI never
    /// hardcodes the private path - it lives in this machine-local config.
    #[serde(default)]
    stats_bin: Option<String>,
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

/// An ORG's layout, and the only thing a new org has to declare.
///
/// Every key below `root` defaults to the convention the non-personal orgs already share. That
/// convention was not invented here: dumping every non-personal org side by side showed them
/// BYTE-IDENTICAL on all ten non-root keys, each one restating the same layout because the layout
/// had nowhere else to live. `personal` is the sole outlier, on every key, because its root IS the
/// vault and its dirs predate the org model.
///
/// So the defaults make an org one line — `root = "…"` — and they make personal's specialness
/// explicit and countable rather than structural: it is the org carrying an override block, and
/// that block shrinking to nothing is exactly what "personal is just another org" means.
#[derive(Debug, Deserialize, Clone)]
struct RawProfile {
    root: String,
    #[serde(default = "default_daily")]
    daily: String,
    #[serde(default = "default_refs")]
    refs: String,
    #[serde(default = "default_fun")]
    fun: String,
    #[serde(default = "default_carryover")]
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
    /// The SCHEDULE: every task carrying a time trigger, `[date]` (once) or `(every:…)`
    /// (repeating). Supersedes `scheduled` + `recurring`, which were two files for one
    /// idea. Optional — resolve() falls back to a `schedule.md` sibling of the daily dir,
    /// deliberately outside `backlogs/`: a backlog has no time trigger, a schedule does.
    #[serde(default)]
    schedule: Option<String>,
    /// Which files the daily-note footer links, in order. Each entry is a known name
    /// (`backlog`/`fun` | `schedule` | `scheduled` | `recurring`) or a vault-relative
    /// path. Optional — defaults to `["fun", "schedule"]`: one backlog, one schedule.
    /// `footer_backlogs` is the legacy key name, kept as a serde alias.
    #[serde(default, alias = "footer_backlogs")]
    footer_links: Option<Vec<String>>,
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
    #[serde(default = "default_summaries")]
    summaries: String,
    #[serde(default = "default_archive")]
    archive: String,
    #[serde(default = "default_zettel")]
    zettel: String,
    #[serde(default = "default_index")]
    index: String,
    /// Defaults to `projects/current` — the same value the three non-personal orgs each spell out.
    /// Still `Option` because "this org has no projects root" is a real state (resolve() maps None
    /// through to `project_index`/`board_path` being None), distinct from "unset, so use default".
    #[serde(default = "default_projects")]
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

fn default_vault() -> String {
    "~/.notes".to_string()
}

// Where the cross-org board has always physically lived. Keeping the location while moving its
// OWNERSHIP off the active profile is deliberate: the address is referenced by existing notes,
// and relocating it is a separate, link-rewriting change.
fn default_board() -> String {
    "lab/projects/board.md".to_string()
}

fn default_inbox() -> String {
    "inbox".to_string()
}

// The org layout, as one place instead of once per org. Values are the ones `bnb`,
// every non-personal org already agreed on independently; `personal` overrides all of them.
// Changing one here changes it for every org that has not opted out.
fn default_daily() -> String {
    "log".to_string()
}

fn default_refs() -> String {
    "refs".to_string()
}

fn default_fun() -> String {
    "backlogs/fun.md".to_string()
}

fn default_carryover() -> String {
    "backlogs/carryover.md".to_string()
}

fn default_summaries() -> String {
    "summaries".to_string()
}

fn default_archive() -> String {
    "log_archive".to_string()
}

fn default_zettel() -> String {
    "permanent".to_string()
}

fn default_index() -> String {
    "index".to_string()
}

fn default_projects() -> Option<String> {
    Some("projects/current".to_string())
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
    /// The SCHEDULE — one file for every task with a time trigger. `[date]` fires once and
    /// is consumed; `(every:…)` fires each cycle and is kept. Supersedes `scheduled` +
    /// `recurring`, which are still resolved above so a pre-migration vault keeps working.
    pub schedule: PathBuf,
    /// Resolved backlog paths the daily-note footer links, in order (config-driven).
    /// Files the daily-note footer links, as `(label, path)`. The LABEL travels with the
    /// path so the footer can say what each link IS — "Backlog" and "Schedule" are
    /// different kinds of thing, and rendering both under one "Backlogs:" heading is the
    /// mislabelling this split exists to remove.
    pub footer_links: Vec<(String, PathBuf)>,
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
    /// Hand-curated cross-project index (`lab/projects/index.md`). The daily note links
    /// it from the footer (`Projects: [[…]]`); it used to also copy the index's
    /// `## Current` lane into a `## Current Projects` block, which was the same
    /// destination rendered twice. Derived as the `index.md` sibling of the `projects`
    /// dir's parent; None when `projects` is unset.
    pub project_index: Option<PathBuf>,
    /// The vault root — same value for every org, so a note can address something outside its
    /// own org. `wikilink(&p.vault, target)` is the cross-org form; `wikilink(&p.root, target)`
    /// stays the within-org form.
    pub vault: PathBuf,
    /// The cross-org board. Identical on every resolved profile, which is the point: it is not
    /// the active org's board, it is THE board.
    pub board: PathBuf,
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
    pub llm_base_url: String,
    pub llm_model: String,
    /// Machine-local path to `comms-stats.py`, for `notes comms stats --fresh`.
    pub stats_bin: Option<PathBuf>,
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
            schedule: None,
            footer_links: None,
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
        vault: default_vault(),
        board: default_board(),
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
    let vault = expand(&raw.vault);
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

    // The SCHEDULE: one file for every task with a time trigger, `[date]` (fires once,
    // consumed) or `(every:…)` (fires each cycle, kept). `scheduled` and `recurring` were
    // two files for one idea — the difference is a TOKEN, not a location, and both already
    // surfaced into the same section by the same helpers.
    //
    // It lives OUTSIDE `backlogs/` on purpose. A backlog is what has no time trigger; a
    // schedule is what does. Calling all three "backlogs" is what made the daily note's
    // footer list three links for two concepts.
    let schedule = rp
        .schedule
        .as_ref()
        .map(|s| join(s))
        .unwrap_or_else(|| join(&rp.daily).with_file_name("schedule.md"));

    // Which backlogs the daily-note footer links, in order. Known names map to their
    // resolved paths; anything else is treated as a vault-relative path. Defaults to
    // fun + scheduled so existing behavior is unchanged.
    // `scheduled` and `recurring` still RESOLVE to their old names so a pre-migration
    // vault keeps working and the migration has something to read; they simply are not
    // linked any more. The default is now one backlog + one schedule.
    // A label travels with each path. An unknown entry is a vault-relative path, and its
    // label falls back to the file stem so a custom link is still self-describing.
    let label_path = |n: &str| -> (String, PathBuf) {
        match n {
            "backlog" | "fun" => ("Backlog".into(), fun.clone()),
            "schedule" => ("Schedule".into(), schedule.clone()),
            "scheduled" | "carryover" | "carry" => ("Schedule".into(), scheduled.clone()),
            "recurring" => ("Schedule".into(), recurring.clone()),
            other => {
                let p = join(other);
                let stem = p
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or(other)
                    .to_string();
                (stem, p)
            }
        }
    };
    let footer_links: Vec<(String, PathBuf)> = match &rp.footer_links {
        Some(names) => names.iter().map(|n| label_path(n)).collect(),
        None => vec![label_path("backlog"), label_path("schedule")],
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
        schedule,
        footer_links,
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
        // Cross-org, so anchored to the vault rather than to this org's root. Every profile
        // resolves the SAME two values.
        vault: vault.clone(),
        board: vault.join(&raw.board),
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
    // Fallbacks only: the real gateway URL/model come from machine-local config.toml
    // (this is the PUBLIC repo - no private hostnames here). Generic LiteLLM localhost.
    let llm_base_url = rc
        .llm_base_url
        .unwrap_or_else(|| "http://localhost:4000/v1".to_string());
    let llm_model = rc
        .llm_model
        .unwrap_or_else(|| "local".to_string());
    let stats_bin = rc.stats_bin.as_ref().map(|s| expand(s));
    let accounts = rc
        .account
        .into_iter()
        .map(|a| {
            let name = a.name;
            let rbw_entry = a
                .rbw_entry
                .unwrap_or_else(|| format!("gmail_app_{name}"));
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
        llm_base_url,
        llm_model,
        stats_bin,
        accounts,
    })
}

/// Per-profile surface file the triage poller writes and `## Comms` renders from.
pub fn comms_surface_file(c: &Comms, profile: &str) -> PathBuf {
    c.state_dir.join("surface").join(format!("{profile}.md"))
}

/// Pre-rendered stats dashboard the poller writes (`comms-stats.py --write`) and
/// `notes comms stats` prints. Read-only, offline (surface-file model).
pub fn comms_stats_file(c: &Comms) -> PathBuf {
    c.state_dir.join("stats.txt")
}

/// One-line cross-account stats summary the poller writes; rendered as the lead line of
/// the daily note's `## Comms` section.
pub fn comms_stats_summary_file(c: &Comms) -> PathBuf {
    c.state_dir.join("stats-summary.txt")
}

/// Print the resolved comms config (`notes config` appends this when comms is configured).
pub fn print_comms(c: &Comms) {
    println!();
    println!("comms-state {}", c.state_dir.display());
    println!("comms-llm   {} ({})", c.llm_base_url, c.llm_model);
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
    // Cross-org, so identical on every profile. Printed next to `root` precisely so the two are
    // easy to compare: for `personal` they coincide, and that coincidence is what let cross-org
    // state quietly acquire a personal address.
    println!("vault       {}", p.vault.display());
    println!("board       {}", p.board.display());
    println!("daily       {}", p.daily.display());
    println!("refs        {}", p.refs.display());
    println!("fun         {}", p.fun.display());
    println!("carryover   {}", p.carryover.display());
    println!("schedule    {}", p.schedule.display());
    println!(
        "footer      {}",
        p.footer_links
            .iter()
            .map(|(l, d)| format!("{l}: {}", d.display()))
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

    /// An org declares its root and nothing else. This is the whole point of the defaults:
    /// every non-personal org was byte-identical on every one of these keys, each restating a
    /// convention that had nowhere to live, and personal's divergence read as structure rather
    /// than as the legacy override it is.
    #[test]
    fn an_org_is_one_line() {
        let raw: RawProfile = toml::from_str(r#"root = "~/notes/orgs/newco""#).unwrap();
        assert_eq!(raw.daily, "log");
        assert_eq!(raw.refs, "refs");
        assert_eq!(raw.fun, "backlogs/fun.md");
        assert_eq!(raw.carryover, "backlogs/carryover.md");
        assert_eq!(raw.summaries, "summaries");
        assert_eq!(raw.archive, "log_archive");
        assert_eq!(raw.zettel, "permanent");
        assert_eq!(raw.index, "index");
        assert_eq!(raw.inbox, "inbox");
        assert_eq!(raw.projects.as_deref(), Some("projects/current"));
    }

    /// The defaults must not become a straitjacket: personal overrides all ten, and that
    /// override block is what "personal is still special" now means — visible and countable
    /// instead of baked into the code.
    #[test]
    fn an_explicit_key_still_beats_the_default() {
        let raw: RawProfile = toml::from_str(
            r#"
            root = "~/.notes"
            daily = "journal/daily"
            projects = "lab/projects/current"
        "#,
        )
        .unwrap();
        assert_eq!(raw.daily, "journal/daily");
        assert_eq!(raw.projects.as_deref(), Some("lab/projects/current"));
        // untouched keys still fall through to the convention
        assert_eq!(raw.zettel, "permanent");
    }
}
