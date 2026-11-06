//! Spawn fzf with the chooser rows, wiring the preview + next callbacks back
//! into this same binary. fzf and tmux remain the UI; only the core is Rust.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use anyhow::{bail, Context, Result};

/// The prompt says which rows are listed; ctrl-y flips it, and every reload reads it back.
const PROMPT_ALL: &str = "Select agent > ";
const PROMPT_ASKING: &str = "Asking only > ";
const HEADER: &str = "Enter=jump  n=next-attention  C-s shepherd  C-t manual  C-l labels  C-y asking  C-o sort  A-o reverse  C-/ layout  C-d/C-u scroll  ·  \x1b[1;31m!\x1b[0m input  \x1b[1;33m~\x1b[0m busy  \x1b[1;32m✓\x1b[0m idle";

/// The preview layout every panel shares, from its one source: `panel-layout.sh args agent-panel`
/// (`.local/src/tmux/`, beside panel-lib.sh) prints the `--preview-window` to open with, which is
/// the layout ctrl-/ last left this panel in, and the ctrl-/ bind that cycles and saves it.
pub fn layout() -> Result<Vec<String>> {
    let home = std::env::var("HOME").context("HOME is not set")?;
    let helper = Path::new(&home).join(".local/src/tmux/panel-layout.sh");
    let out = Command::new(&helper)
        .args(["args", "agent-panel"])
        .stderr(Stdio::inherit())
        .output()
        .with_context(|| format!("cannot run {}", helper.display()))?;
    if !out.status.success() {
        bail!("{} gave no layout", helper.display());
    }
    Ok(String::from_utf8_lossy(&out.stdout).lines().map(String::from).collect())
}

/// Run fzf over `rows` (newline-joined). `map_file` backs the preview callback;
/// `restore_line`, when set, positions the cursor on the active agent.
/// Returns the selected row text, or None if the user aborted.
pub fn run(rows: &str, map_file: &Path, restore_line: Option<usize>) -> Result<Option<String>> {
    let exe = std::env::current_exe()
        .context("cannot resolve own path for fzf callbacks")?
        .to_string_lossy()
        .into_owned();
    let map = map_file.to_string_lossy().into_owned();
    let layout = layout()?;

    let mut child = Command::new("fzf")
        .args(args(&exe, &map, restore_line, &layout))
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
fn args(exe: &str, map: &str, restore_line: Option<usize>, layout: &[String]) -> Vec<String> {
    let preview_cmd = format!("{exe} preview --map-file '{map}' {{}}");
    let next_bind = format!("n:execute-silent({exe} next)+abort");
    // `fleet-shepherd open` is the one way to the running pass (Prefix o too): it hops worlds.
    let shepherd_bind = "ctrl-s:execute-silent(fleet-shepherd open)+abort".to_string();
    // Label keys write through fleet-sessions (the labels' one home), then reload the rows in
    // place. {1} is the row's full target; on a project header it is empty and the label fails.
    // The prompt is the asking-only state (ctrl-y), so a reload from a label key keeps the view.
    let rows = format!("{exe} rows --map-file '{map}'");
    let asking_arg = format!("$([ \"$FZF_PROMPT\" = '{PROMPT_ASKING}' ] && echo --asking)");
    let reload = format!("reload({rows} {asking_arg})");
    // C-o steps the sort key and A-o flips it; rows saves the sort, so the panel reopens in it.
    let sort_next_bind = format!("ctrl-o:reload({rows} --sort next {asking_arg})");
    let sort_reverse_bind = format!("alt-o:reload({rows} --sort reverse {asking_arg})");
    let asking_bind = format!(
        "ctrl-y:transform:if [ \"$FZF_PROMPT\" = '{PROMPT_ASKING}' ]; \
         then echo \"change-prompt({PROMPT_ALL})+reload({rows})\"; \
         else echo \"change-prompt({PROMPT_ASKING})+reload({rows} --asking)\"; fi"
    );
    let manual_bind = format!("ctrl-t:execute-silent(fleet-sessions label {{1}} ^manual)+{reload}");
    let labels_bind = format!(
        "ctrl-l:execute(sh -c 'printf \"labels for %s (+add -drop ^flip): \" \"$1\"; read -r ops; \
         [ -z \"$ops\" ] || fleet-sessions label \"$1\" $ops >/dev/null || read -r _' _ {{1}})+{reload}"
    );

    let mut args: Vec<String> = vec![
        "--reverse".into(),
        "--border".into(),
        "--cycle".into(),
        format!("--prompt={PROMPT_ALL}"),
        format!("--header={HEADER}"),
        "--ansi".into(),
        "--no-sort".into(),
        "--delimiter=\t".into(),
        "--with-nth=2..".into(),
        "--preview".into(),
        preview_cmd,
    ];
    args.extend(layout.iter().cloned());
    args.extend([
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
        "--bind".into(),
        asking_bind,
        "--bind".into(),
        sort_next_bind,
        "--bind".into(),
        sort_reverse_bind,
        // Skip non-selectable project header rows when navigating.
        "--bind".into(),
        "up:up+transform:case {} in *━━*) echo up ;; esac".into(),
        "--bind".into(),
        "down:down+transform:case {} in *━━*) echo down ;; esac".into(),
    ]);
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
        let stacked = ["--preview-window=down".to_string(), "--bind=ctrl-/:x".to_string()];
        let a = args("/bin/ap", "/tmp/m.map", Some(3), &stacked);
        let reload = "reload(/bin/ap rows --map-file '/tmp/m.map' $([ \"$FZF_PROMPT\" = 'Asking only > ' ] && echo --asking))";
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
        assert!(HEADER.contains("C-s shepherd") && HEADER.contains("C-y asking"));
        let y = a.iter().find(|x| x.starts_with("ctrl-y:")).expect("ctrl-y bind");
        assert!(y.contains("change-prompt(Asking only > )+reload(/bin/ap rows --map-file '/tmp/m.map' --asking)"), "{y}");
        assert!(y.contains("change-prompt(Select agent > )+reload(/bin/ap rows --map-file '/tmp/m.map')\""), "{y}");
        // C-o and A-o move the saved sort, keeping the asking-only view like every reload.
        let asking = "$([ \"$FZF_PROMPT\" = 'Asking only > ' ] && echo --asking)";
        let rows = "/bin/ap rows --map-file '/tmp/m.map'";
        assert!(a.contains(&format!("ctrl-o:reload({rows} --sort next {asking})")), "{a:?}");
        assert!(a.contains(&format!("alt-o:reload({rows} --sort reverse {asking})")), "{a:?}");
        assert!(HEADER.contains("C-o sort") && HEADER.contains("A-o reverse"));
        // Negative control: no active agent, no load bind.
        assert!(!args("/bin/ap", "/tmp/m.map", None, &stacked)
            .iter()
            .any(|x| x.starts_with("load:")));
    }
}
