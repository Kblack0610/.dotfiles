//! Spawn fzf with the chooser rows, wiring the preview + next callbacks back
//! into this same binary. fzf and tmux remain the UI; only the core is Rust.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use anyhow::{Context, Result};

const HEADER: &str = "Enter=jump  n=next-attention  C-s shepherd  C-t manual  C-l labels  C-/ toggle preview  C-d/C-u scroll  ·  \x1b[1;31m!\x1b[0m input  \x1b[1;33m~\x1b[0m busy  \x1b[1;32m✓\x1b[0m idle";

/// Run fzf over `rows` (newline-joined). `map_file` backs the preview callback;
/// `restore_line`, when set, positions the cursor on the active agent.
/// Returns the selected row text, or None if the user aborted.
pub fn run(rows: &str, map_file: &Path, restore_line: Option<usize>) -> Result<Option<String>> {
    let exe = std::env::current_exe()
        .context("cannot resolve own path for fzf callbacks")?
        .to_string_lossy()
        .into_owned();
    let map = map_file.to_string_lossy().into_owned();

    let mut child = Command::new("fzf")
        .args(args(&exe, &map, restore_line))
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

/// fzf's arguments: layout, the preview and reload callbacks into `exe`, and the key binds.
fn args(exe: &str, map: &str, restore_line: Option<usize>) -> Vec<String> {
    let preview_cmd = format!("{exe} preview --map-file '{map}' {{}}");
    let next_bind = format!("n:execute-silent({exe} next)+abort");
    // `fleet-shepherd open` is the one way to the running pass (Prefix o too): it hops worlds.
    let shepherd_bind = "ctrl-s:execute-silent(fleet-shepherd open)+abort".to_string();
    // Label keys write through fleet-sessions (the labels' one home), then reload the rows in
    // place. {1} is the row's full target; on a project header it is empty and the label fails.
    let reload = format!("reload({exe} rows --map-file '{map}')");
    let manual_bind = format!("ctrl-t:execute-silent(fleet-sessions label {{1}} ^manual)+{reload}");
    let labels_bind = format!(
        "ctrl-l:execute(sh -c 'printf \"labels for %s (+add -drop ^flip): \" \"$1\"; read -r ops; \
         [ -z \"$ops\" ] || fleet-sessions label \"$1\" $ops >/dev/null || read -r _' _ {{1}})+{reload}"
    );

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
        "--bind".into(),
        shepherd_bind,
        "--bind".into(),
        manual_bind,
        "--bind".into(),
        labels_bind,
        // Skip non-selectable project header rows when navigating.
        "--bind".into(),
        "up:up+transform:case {} in *━━*) echo up ;; esac".into(),
        "--bind".into(),
        "down:down+transform:case {} in *━━*) echo down ;; esac".into(),
    ];
    if let Some(line) = restore_line {
        // Once: a reload fires load again and must not pull the cursor back.
        args.push("--bind".into());
        args.push(format!("load:pos({line})+unbind(load)"));
    }
    args
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn label_keys_write_through_fleet_sessions_and_reload_in_place() {
        let a = args("/bin/ap", "/tmp/m.map", Some(3));
        let reload = "reload(/bin/ap rows --map-file '/tmp/m.map')";
        let manual = format!("ctrl-t:execute-silent(fleet-sessions label {{1}} ^manual)+{reload}");
        assert!(a.contains(&manual), "{a:?}");
        let l = a
            .iter()
            .find(|x| x.starts_with("ctrl-l:"))
            .expect("ctrl-l bind");
        assert!(l.contains("fleet-sessions label \"$1\" $ops"), "{l}");
        assert!(l.ends_with(&format!(" _ {{1}})+{reload}")), "{l}");
        assert!(a.contains(&"load:pos(3)+unbind(load)".to_string()), "{a:?}");
        assert!(a.contains(&"ctrl-s:execute-silent(fleet-shepherd open)+abort".to_string()), "{a:?}");
        assert!(HEADER.contains("C-s shepherd"));
        // Negative control: no active agent, no load bind.
        assert!(!args("/bin/ap", "/tmp/m.map", None)
            .iter()
            .any(|x| x.starts_with("load:")));
    }
}
