//! agent-panel opens fzf with the preview layout the shell panels use, taken from its one source:
//! `panel-layout.sh args agent-panel` (`.local/src/tmux/`), found under $HOME. HOME here is a temp
//! dir whose `.local/src/tmux` links to this repo's, and a stub `fzf` on PATH logs its argv one
//! per line and exits 130 (aborted), so the chooser runs for real and selects nothing.
//!
//! One test in this file on purpose: it sets HOME, PATH and XDG_STATE_HOME for the whole process.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

fn fzf_argv(log: &Path) -> Vec<String> {
    fs::read_to_string(log)
        .unwrap()
        .lines()
        .map(String::from)
        .collect()
}

#[test]
fn fzf_gets_the_layout_the_helper_prints_and_the_one_saved_last() {
    let dir = std::env::temp_dir().join(format!("agent-panel-layout-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    let home = dir.join("home");
    fs::create_dir_all(home.join(".local/src")).unwrap();
    let tmux_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../tmux");
    std::os::unix::fs::symlink(
        tmux_dir.canonicalize().unwrap(),
        home.join(".local/src/tmux"),
    )
    .unwrap();
    let state = dir.join("state");
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
    std::env::set_var("HOME", &home);
    std::env::set_var("XDG_STATE_HOME", &state);
    std::env::remove_var("PANEL_LAYOUT");
    std::env::set_var(
        "PATH",
        format!("{}:{}", dir.display(), std::env::var("PATH").unwrap()),
    );
    let map = dir.join("map");
    let helper = home.join(".local/src/tmux/panel-layout.sh");
    let helper_says = || -> Vec<String> {
        let out = Command::new(&helper)
            .args(["args", "agent-panel"])
            .output()
            .unwrap();
        assert!(out.status.success(), "{out:?}");
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(String::from)
            .collect()
    };

    let mut opened = Vec::new();
    for saved in [None, Some("side"), Some("stacked")] {
        if let Some(s) = saved {
            fs::create_dir_all(state.join("panels")).unwrap();
            fs::write(state.join("panels/agent-panel.layout"), format!("{s}\n")).unwrap();
        }
        let picked = agent_panel::fzf::run("hub/a:1\trow", &map, None).unwrap();
        assert_eq!(picked, None, "an aborted fzf selects nothing");
        let argv = fzf_argv(&log);
        let want = helper_says();
        assert_eq!(want.len(), 2, "{want:?}");
        for line in &want {
            assert!(
                argv.contains(line),
                "{saved:?}: fzf argv lacks {line}\n{argv:?}"
            );
        }
        // Only the shared layout sets the preview window: no second one of agent-panel's own.
        let windows = argv.iter().filter(|a| a.contains("preview-window")).count();
        assert_eq!(windows, 1, "{saved:?}: {argv:?}");
        assert!(
            want[1].contains("transform(") && want[1].contains(" next agent-panel)"),
            "{want:?}"
        );
        opened.push(want[0].clone());
    }
    // Negative control: the saved layout really changes what fzf opens with.
    assert!(opened[0].contains("=down,"), "{opened:?}");
    assert!(opened[1].contains("=right,"), "{opened:?}");
    assert_eq!(opened[0], opened[2]);

    // A saved value that is not a layout fails before fzf starts.
    fs::write(state.join("panels/agent-panel.layout"), "bogus\n").unwrap();
    fs::remove_file(&log).unwrap();
    assert!(agent_panel::fzf::run("hub/a:1\trow", &map, None).is_err());
    assert!(!log.exists(), "fzf ran on an unknown layout");

    let _ = fs::remove_dir_all(&dir);
}
