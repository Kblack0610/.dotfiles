//! Configuration + path derivation. Mirrors notes-cli's loader: an env override, then
//! `~/.config`, then the dotfiles copy, then a built-in default so the tool works on a
//! fresh machine with zero setup. All fields `#[serde(default)]` for forward-compat.

use anyhow::{Context, Result};
use serde::Deserialize;
use std::path::PathBuf;
use timebox_core::dur;

#[derive(Debug, Default, Deserialize)]
struct RawConfig {
    /// Runtime state dir. Defaults to `~/.local/state/timebox`.
    #[serde(default)]
    state_dir: Option<String>,
    /// Default recurring lap when `start` is given no `--lap` (e.g. "25m"). Unset = no lap.
    #[serde(default)]
    default_lap: Option<String>,
    /// Global sound-on-lap default (per-`start` `--sound` also enables it).
    #[serde(default)]
    sound: bool,
    /// Sound asset to play on a lap boundary. Defaults to the bundled `assets/switch.wav`
    /// next to the binary if present.
    #[serde(default)]
    sound_file: Option<String>,
    /// Optional leading glyph/label for the Waybar text (default empty -> plain ASCII).
    #[serde(default)]
    icon: Option<String>,
    /// Text the Waybar module shows when no stopwatch is active (so the module stays
    /// visible + clickable). Default "timebox".
    #[serde(default)]
    idle_text: Option<String>,
    /// Flash the screen on a lap boundary (runs `flash_cmd`).
    #[serde(default)]
    flash: bool,
    /// Command run on a lap boundary when `flash = true`. Default `timebox-flash`.
    #[serde(default)]
    flash_cmd: Option<String>,
}

/// Resolved config with absolute paths.
pub struct Config {
    pub state_dir: PathBuf,
    pub state_path: PathBuf,
    pub events_path: PathBuf,
    pub log_file: PathBuf,
    pub default_lap_s: Option<u64>,
    pub sound: bool,
    pub sound_file: Option<PathBuf>,
    pub icon: String,
    pub idle_text: String,
    pub flash: bool,
    pub flash_cmd: String,
    pub source: String,
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into()))
}

fn expand(s: &str) -> PathBuf {
    if let Some(rest) = s.strip_prefix("~/") {
        home().join(rest)
    } else if s == "~" {
        home()
    } else {
        PathBuf::from(s)
    }
}

fn config_paths() -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Ok(p) = std::env::var("TIMEBOX_CONFIG") {
        if !p.is_empty() {
            v.push(expand(&p));
        }
    }
    v.push(home().join(".config/timebox/config.toml"));
    v.push(home().join(".dotfiles/.config/timebox/config.toml"));
    v
}

/// Default sound asset shipped beside the binary (`<exe-dir>/../assets/switch.wav` in a
/// cargo layout, or `<exe-dir>/assets/switch.wav`). Returns it only if it exists.
fn bundled_sound() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    for cand in [
        dir.join("assets/switch.wav"),
        dir.join("../assets/switch.wav"),
        home().join(".dotfiles/.local/src/timebox/assets/switch.wav"),
    ] {
        if cand.exists() {
            return Some(cand);
        }
    }
    None
}

pub fn resolve() -> Result<Config> {
    let mut source = "built-in default".to_string();
    let mut raw = RawConfig::default();
    for path in config_paths() {
        if path.exists() {
            let text = std::fs::read_to_string(&path)
                .with_context(|| format!("reading config {}", path.display()))?;
            raw = toml::from_str(&text)
                .with_context(|| format!("parsing config {}", path.display()))?;
            source = path.display().to_string();
            break;
        }
    }

    let state_dir = raw
        .state_dir
        .as_deref()
        .map(expand)
        .unwrap_or_else(|| home().join(".local/state/timebox"));

    let default_lap_s = match raw.default_lap.as_deref() {
        Some(s) => Some(dur::parse_duration(s).map_err(anyhow::Error::msg)?),
        None => None,
    };

    let sound_file = raw
        .sound_file
        .as_deref()
        .map(expand)
        .or_else(bundled_sound);

    Ok(Config {
        state_path: state_dir.join("state.json"),
        events_path: state_dir.join("events.jsonl"),
        log_file: state_dir.join("timebox.log"),
        state_dir,
        default_lap_s,
        sound: raw.sound,
        sound_file,
        icon: raw.icon.unwrap_or_default(),
        idle_text: raw.idle_text.unwrap_or_else(|| "timebox".into()),
        flash: raw.flash,
        flash_cmd: raw.flash_cmd.unwrap_or_else(|| "timebox-flash".into()),
        source,
    })
}

pub fn print(c: &Config) {
    println!("config      {}", c.source);
    println!("state-dir   {}", c.state_dir.display());
    println!("state       {}", c.state_path.display());
    println!("events      {}", c.events_path.display());
    println!("log         {}", c.log_file.display());
    println!(
        "default-lap {}",
        c.default_lap_s
            .map(|s| dur::fmt_hms(s as i64))
            .unwrap_or_else(|| "none".into())
    );
    println!("sound       {}", c.sound);
    println!(
        "sound-file  {}",
        c.sound_file
            .as_ref()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| "none".into())
    );
    println!("icon        {:?}", c.icon);
    println!("idle-text   {:?}", c.idle_text);
    println!("flash       {}", c.flash);
    println!("flash-cmd   {}", c.flash_cmd);
}
