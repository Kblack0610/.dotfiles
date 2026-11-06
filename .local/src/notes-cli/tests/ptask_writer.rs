//! `notes ptask` as one hardened writer, run as the real binary against a throwaway HOME:
//! every verb writes one event naming its row's id, the agent board refuses untyped,
//! size-less and near-duplicate rows, and concurrent writers mint distinct ids under the lock.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

impl Home {
    /// A HOME holding one profile with one project, `demo`, whose tracker code is `dm`.
    fn new(tag: &str) -> Home {
        let root = std::env::temp_dir().join(format!("ptask-writer-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let proj = root.join("notes/projects/current/demo");
        fs::create_dir_all(proj.join("agent")).unwrap();
        fs::write(
            root.join("notes/projects/index.md"),
            "## Current\n- [[projects/current/demo/summary|demo]]\n",
        )
        .unwrap();
        fs::write(proj.join("summary.md"), "# demo\n").unwrap();
        fs::write(
            proj.join("README.md"),
            "# demo\nVersion: v0.1.0\n\n## Inbox\n\n## Tasks\n",
        )
        .unwrap();
        fs::write(
            proj.join("agent/README.md"),
            "# demo - agent board\nVersion: v0.1.0\n\n## Tasks\n",
        )
        .unwrap();
        fs::write(
            root.join("config.toml"),
            format!(
                "[profile.personal]\nroot = \"{}\"\n",
                root.join("notes").display()
            ),
        )
        .unwrap();
        fs::write(
            root.join("map.json"),
            r#"{"trackers": {"demo": {"type": "app", "code": "dm"}}}"#,
        )
        .unwrap();
        Home(root)
    }

    fn cmd(&self, args: &[&str]) -> Command {
        let mut c = Command::new(env!("CARGO_BIN_EXE_notes"));
        c.args(args)
            .env("HOME", &self.0)
            .env("NOTES_CONFIG", self.0.join("config.toml"))
            .env("NOTES_PROFILE", "personal")
            .env("PROJECT_MAP_FILE", self.0.join("map.json"))
            .env_remove("AGENT_QUEUE_ITEM");
        c
    }

    fn run(&self, args: &[&str]) -> Output {
        self.cmd(args).output().unwrap()
    }

    fn board(&self) -> String {
        fs::read_to_string(self.board_path()).unwrap()
    }

    fn board_path(&self) -> PathBuf {
        self.0.join("notes/projects/current/demo/agent/README.md")
    }

    /// `(action, id)` of every event written today.
    fn events(&self) -> Vec<(String, Option<String>)> {
        let out = self.run(&["log", "--json"]);
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(|l| {
                let v: serde_json::Value = serde_json::from_str(l).unwrap();
                (
                    v["action"].as_str().unwrap_or_default().to_string(),
                    v["id"].as_str().map(str::to_string),
                )
            })
            .collect()
    }
}

fn agent(h: &Home, verb: &[&str]) -> Output {
    let mut args = vec!["ptask", "demo", "--agent"];
    args.extend_from_slice(verb);
    h.run(&args)
}

fn ok(o: &Output) {
    assert!(
        o.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    );
}

fn ids(board: &str) -> Vec<String> {
    board
        .lines()
        .filter_map(|l| l.split("id:").nth(1))
        .map(|t| t.split([' ', '-']).take(2).collect::<Vec<_>>().join("-"))
        .collect()
}

#[test]
fn each_ptask_verb_writes_one_event_with_the_row_id() {
    let h = Home::new("events");
    ok(&agent(
        &h,
        &["add", "fix(ui): menu flickers on resume #size/s"],
    ));
    ok(&agent(
        &h,
        &[
            "add",
            "feat(sync): offline queue drains on reconnect #size/m",
        ],
    ));
    ok(&agent(&h, &["start", "dm-1"]));
    ok(&agent(&h, &["start", "dm-1"]));
    ok(&agent(&h, &["unstart", "dm-1"]));
    ok(&agent(&h, &["tag", "--add", "high", "dm-1"]));
    ok(&agent(&h, &["done", "--proof", "pr:9", "dm-1"]));
    ok(&agent(&h, &["drop", "--why", "stale", "dm-2"]));
    let got: Vec<(String, Option<String>)> = h.events();
    let want: Vec<(String, Option<String>)> = [
        ("added", "dm-1"),
        ("added", "dm-2"),
        ("started", "dm-1"),
        ("unstarted", "dm-1"),
        ("tagged", "dm-1"),
        ("done", "dm-1"),
        ("dropped", "dm-2"),
    ]
    .iter()
    .map(|(a, i)| (a.to_string(), Some(i.to_string())))
    .collect();
    assert_eq!(got, want, "the second start is a no-op and writes nothing");
}

#[test]
fn the_agent_board_refuses_untyped_sizeless_and_near_duplicate_rows() {
    let h = Home::new("refuse");
    let before = h.board();
    let untyped = agent(&h, &["add", "menu flickers #size/s"]);
    assert_eq!(untyped.status.code(), Some(1));
    let sizeless = agent(&h, &["add", "fix(ui): menu flickers"]);
    assert_eq!(sizeless.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&sizeless.stderr).contains("#size/"));
    assert_eq!(h.board(), before, "a refused add writes nothing");

    ok(&agent(
        &h,
        &["add", "fix(ui): the pause menu flickers on resume #size/s"],
    ));
    let twin = agent(
        &h,
        &["add", "fix(ui): pause menu flickers on resume #size/m"],
    );
    assert_eq!(
        twin.status.code(),
        Some(3),
        "a near-dup reads as already filed"
    );
    assert!(
        String::from_utf8_lossy(&twin.stderr).contains("id:dm-1"),
        "names the open row: {}",
        String::from_utf8_lossy(&twin.stderr)
    );
    assert_eq!(ids(&h.board()), ["dm-1"]);
}

#[test]
fn ambiguous_words_write_nothing() {
    let h = Home::new("ambig");
    ok(&agent(&h, &["add", "fix(ui): menu flickers #size/s"]));
    ok(&agent(&h, &["add", "fix(ui): menu lags on load #size/s"]));
    let before = h.board();
    let o = agent(&h, &["done", "--proof", "pr:1", "menu"]);
    assert_eq!(o.status.code(), Some(1));
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(err.contains("dm-1") && err.contains("dm-2"), "{err}");
    assert_eq!(h.board(), before);
}

#[test]
fn concurrent_adds_mint_distinct_ids() {
    let h = Home::new("race");
    let kids: Vec<_> = (0..8)
        .map(|i| {
            h.cmd(&[
                "ptask",
                "demo",
                "--agent",
                "add",
                &format!("chore(race{i}): writer number {i} #size/s"),
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap()
        })
        .collect();
    for k in kids {
        ok(&k.wait_with_output().unwrap());
    }
    let mut got = ids(&h.board());
    got.sort();
    got.dedup();
    assert_eq!(got.len(), 8, "{}", h.board());
}

#[test]
fn an_id_is_never_reused_after_its_row_leaves() {
    let h = Home::new("reuse");
    ok(&agent(
        &h,
        &["add", "fix(ui): first row of the board #size/s"],
    ));
    ok(&agent(
        &h,
        &["add", "fix(ui): second row of the board #size/s"],
    ));
    // The row holding the highest id leaves every sheet (hand-deleted, or moved away).
    let board = h.board();
    let kept: String = board
        .lines()
        .filter(|l| !l.contains("id:dm-2"))
        .map(|l| format!("{l}\n"))
        .collect();
    fs::write(h.board_path(), kept).unwrap();
    ok(&agent(
        &h,
        &["add", "fix(ui): third row of the board #size/s"],
    ));
    let mut got = ids(&h.board());
    got.sort();
    assert_eq!(got, ["dm-1", "dm-3"]);
    assert!(Path::new(&h.0.join("notes/projects/current/demo/.ids")).is_file());
}
