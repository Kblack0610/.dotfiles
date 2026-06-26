//! Spawn fzf with the chooser rows, wiring the preview + next callbacks back
//! into this same binary. fzf and tmux remain the UI; only the core is Rust.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use anyhow::{Context, Result};

const HEADER: &str = "Enter=jump  n=next-attention  C-/ toggle preview  C-d/C-u scroll  ·  \x1b[1;31m!\x1b[0m input  \x1b[1;33m~\x1b[0m busy  \x1b[1;32m✓\x1b[0m idle";

/// Run fzf over `rows` (newline-joined). `map_file` backs the preview callback;
/// `restore_line`, when set, positions the cursor on the active agent.
/// Returns the selected row text, or None if the user aborted.
pub fn run(rows: &str, map_file: &Path, restore_line: Option<usize>) -> Result<Option<String>> {
    let exe = std::env::current_exe()
        .context("cannot resolve own path for fzf callbacks")?
        .to_string_lossy()
        .into_owned();
    let map = map_file.to_string_lossy().into_owned();

    let preview_cmd = format!("{exe} preview --map-file '{map}' {{}}");
    let next_bind = format!("n:execute-silent({exe} next)+abort");

    let mut args: Vec<String> = vec![
        "--reverse".into(),
        "--border".into(),
        "--cycle".into(),
        "--prompt=Select agent > ".into(),
        format!("--header={HEADER}"),
        "--ansi".into(),
        "--no-sort".into(),
        "--delimiter=\t".into(),
        "--with-nth=2..".into(),
        "--preview".into(),
        preview_cmd,
        "--preview-window".into(),
        "right:75%:wrap".into(),
        "--bind".into(),
        "ctrl-/:change-preview-window(hidden|right:75%:wrap)".into(),
        "--bind".into(),
        "ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up".into(),
        "--bind".into(),
        next_bind,
        // Skip non-selectable project header rows when navigating.
        "--bind".into(),
        "up:up+transform:case {} in *━━*) echo up ;; esac".into(),
        "--bind".into(),
        "down:down+transform:case {} in *━━*) echo down ;; esac".into(),
    ];
    if let Some(line) = restore_line {
        args.push("--bind".into());
        args.push(format!("load:pos({line})"));
    }

    let mut child = Command::new("fzf")
        .args(&args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .context("failed to spawn fzf — is it on PATH?")?;

    child
        .stdin
        .take()
        .context("fzf stdin unavailable")?
        .write_all(rows.as_bytes())?;

    let out = child.wait_with_output()?;
    let selected = String::from_utf8_lossy(&out.stdout).trim_end_matches('\n').to_string();
    Ok((!selected.is_empty()).then_some(selected))
}
