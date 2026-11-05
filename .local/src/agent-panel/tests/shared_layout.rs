//! agent-panel opens fzf with exactly the preview layout the shell panels use: the
//! `--preview-window` and ctrl-/ toggle `panel_fzf_layout` (`.local/src/tmux/panel-lib.sh`)
//! prints, for the same `PANEL_LAYOUT`. A stub `fzf` on PATH logs its argv one per line and
//! exits 130 (aborted), so the chooser runs for real and selects nothing.
//!
//! One test in this file on purpose: it sets PATH and PANEL_LAYOUT for the whole process.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

fn panel_lib() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../tmux/panel-lib.sh")
}

/// What `panel_fzf_layout` sets for `setting`, one array element per line; None when it fails.
fn shell_layout(setting: Option<&str>) -> Option<Vec<String>> {
    let mut cmd = Command::new("bash");
    cmd.args([
        "-c",
        r#"SELF="$1"; . "$1" || exit 9; panel_fzf_layout 2>/dev/null || exit 7; printf '%s\n' "${PANEL_FZF_LAYOUT[@]}""#,
        "_",
    ])
    .arg(panel_lib());
    match setting {
        Some(s) => cmd.env("PANEL_LAYOUT", s),
        None => cmd.env_remove("PANEL_LAYOUT"),
    };
    let out = cmd.output().expect("bash runs");
    assert_ne!(out.status.code(), Some(9), "panel-lib.sh did not source");
    out.status.success().then(|| {
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(String::from)
            .collect()
    })
}

#[test]
fn fzf_gets_the_layout_panel_lib_prints_for_each_setting() {
    let dir = std::env::temp_dir().join(format!("agent-panel-layout-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let log = dir.join("argv");
    let stub = dir.join("fzf");
    fs::write(
        &stub,
        format!(
            "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' \"$@\" > '{}'\nexit 130\n",
            log.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    std::env::set_var(
        "PATH",
        format!("{}:{}", dir.display(), std::env::var("PATH").unwrap()),
    );
    let map = dir.join("map");

    let mut seen = Vec::new();
    for setting in [None, Some("stacked"), Some("side")] {
        match setting {
            Some(s) => std::env::set_var("PANEL_LAYOUT", s),
            None => std::env::remove_var("PANEL_LAYOUT"),
        }
        let picked = agent_panel::fzf::run("hub/a:1\trow", &map, None).unwrap();
        assert_eq!(picked, None, "an aborted fzf selects nothing");
        let argv: Vec<String> = fs::read_to_string(&log)
            .unwrap()
            .lines()
            .map(String::from)
            .collect();
        let want = shell_layout(setting).expect("panel_fzf_layout succeeds");
        assert_eq!(want.len(), 2, "{want:?}");
        for line in &want {
            assert!(
                argv.contains(line),
                "{setting:?}: fzf argv lacks {line}\n{argv:?}"
            );
        }
        // Only the shared layout sets the preview window: no second, legacy one.
        let windows = argv.iter().filter(|a| a.contains("preview-window")).count();
        assert_eq!(windows, 2, "{setting:?}: {argv:?}");
        seen.push(want);
    }
    // Negative control: the settings really differ, so equality above is not vacuous.
    assert_ne!(seen[0], seen[2]);
    assert_eq!(seen[0], seen[1]);

    // An unknown setting fails in both, before fzf starts.
    std::env::set_var("PANEL_LAYOUT", "bogus");
    fs::remove_file(&log).unwrap();
    assert!(agent_panel::fzf::run("hub/a:1\trow", &map, None).is_err());
    assert!(!log.exists(), "fzf ran on an unknown layout");
    assert!(shell_layout(Some("bogus")).is_none());

    let _ = fs::remove_dir_all(&dir);
}
