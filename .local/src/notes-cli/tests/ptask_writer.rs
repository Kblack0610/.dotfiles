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
        let h = Home(root);
        // The systems lookup knows no project unless a test gives it a list, so a
        // project-stage-check on the caller's PATH never decides a row's parent here.
        h.systems(None);
        h
    }

    /// `project-stage-check` on this HOME's PATH: `--list --json` prints `json`, or exits 2 as
    /// for an unknown project when `json` is None.
    fn systems(&self, json: Option<&str>) {
        let bin = self.0.join("bin");
        fs::create_dir_all(&bin).unwrap();
        let body = match json {
            Some(j) => format!("#!/bin/sh\ncat <<'JSON'\n{j}\nJSON\n"),
            None => "#!/bin/sh\necho 'unknown project' >&2\nexit 2\n".to_string(),
        };
        let stub = bin.join("project-stage-check");
        fs::write(&stub, body).unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn sheet(&self) -> String {
        fs::read_to_string(self.0.join("notes/projects/current/demo/README.md")).unwrap()
    }

    fn cmd(&self, args: &[&str]) -> Command {
        let mut c = Command::new(env!("CARGO_BIN_EXE_notes"));
        c.args(args)
            .env("HOME", &self.0)
            .env("NOTES_CONFIG", self.0.join("config.toml"))
            .env("NOTES_PROFILE", "personal")
            .env("PROJECT_MAP_FILE", self.0.join("map.json"))
            .env(
                "PATH",
                format!(
                    "{}:{}",
                    self.0.join("bin").display(),
                    std::env::var("PATH").unwrap_or_default()
                ),
            )
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
fn propose_types_what_add_would_refuse_and_writes_nothing() {
    let h = Home::new("propose");
    let before = h.board();
    let out = agent(&h, &["propose", "--", "the menu fails on resume #high"]);
    ok(&out);
    let row = String::from_utf8_lossy(&out.stdout).trim().to_string();
    assert_eq!(row, "fix(demo): the menu fails on resume");
    assert_eq!(h.board(), before, "propose writes nothing");
    assert!(h.events().is_empty(), "propose records nothing");

    ok(&agent(&h, &["add", &format!("{row} #size/s")]));
    assert_eq!(ids(&h.board()), ["dm-1"]);
}

#[test]
fn doctor_lists_each_untyped_row_with_the_edit_that_types_it() {
    let h = Home::new("untyped");
    let path = h.board_path();
    let board = h.board();
    fs::write(
        &path,
        format!("{board}\n- [ ] the menu fails on resume <!-- id:dm-7 -->\n"),
    )
    .unwrap();
    let out = h.run(&["doctor", "--projects", "--untyped"]);
    ok(&out);
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(
        text.contains("personal/demo\tdm-7\tfix(demo): the menu fails on resume"),
        "{text}"
    );
    assert!(text.contains("1 untyped row(s)"), "{text}");
    assert!(fs::read_to_string(&path)
        .unwrap()
        .contains("- [ ] the menu fails"));

    ok(&agent(
        &h,
        &[
            "edit",
            "--was",
            "--text",
            "fix(demo): the menu fails on resume",
            "--",
            "dm-7",
        ],
    ));
    let out = h.run(&["doctor", "--projects", "--untyped"]);
    assert!(String::from_utf8_lossy(&out.stdout).contains("0 untyped row(s)"));
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

// nc-47: start and drop (rm) refuse an ambiguous match like done does.
#[test]
fn start_and_drop_refuse_ambiguous_words_too() {
    let h = Home::new("ambig-verbs");
    ok(&agent(&h, &["add", "fix(ui): menu flickers #size/s"]));
    ok(&agent(&h, &["add", "fix(ui): menu lags on load #size/s"]));
    let before = h.board();
    for verb in [
        &["start", "menu"][..],
        &["drop", "--why", "stale", "menu"][..],
    ] {
        let o = agent(&h, verb);
        assert_eq!(o.status.code(), Some(1), "{verb:?}");
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(err.contains("dm-1") && err.contains("dm-2"), "{err}");
        assert_eq!(h.board(), before, "{verb:?} wrote");
    }
    ok(&agent(&h, &["start", "flickers"]));
    assert_ne!(h.board(), before);
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

/// The demo project's systems: `ui` (also `menu`) and `docs`.
const SYSTEMS: &str = r#"[{"id":"ui","source":"doc","aliases":["menu"],"is":"x"},{"id":"docs","source":"doc","aliases":[],"is":"y"}]"#;

#[test]
fn an_unlinked_leaf_goes_under_its_systems_standing_epic_filed_once() {
    let h = Home::new("standing");
    h.systems(Some(SYSTEMS));
    let first = agent(&h, &["add", "fix(ui): pause menu is slow #size/s"]);
    ok(&first);
    let sheet = h.sheet();
    assert!(
        sheet.contains("- [ ] epic(ui): ui to standard") && sheet.contains("id:dm-1"),
        "the missing standing epic is filed on the human sheet: {sheet}"
    );
    let board = h.board();
    assert!(
        board.contains("fix(ui): pause menu is slow") && board.contains("#of/dm-1"),
        "{board}"
    );
    assert_eq!(ids(&board), ["dm-2"], "the row's id follows the epic's");
    // agent-queue merges stderr and reads the first `id:` as its row's: the epic's must not be it.
    let merged = format!(
        "{}{}",
        String::from_utf8_lossy(&first.stderr),
        String::from_utf8_lossy(&first.stdout)
    );
    let first_id = merged.lines().find_map(|l| l.split("id:").nth(1)).unwrap();
    assert!(first_id.starts_with("dm-2"), "{merged}");

    // An alias names the same system, and the epic is reused, never filed twice.
    ok(&agent(&h, &["add", "feat(menu): a resume button #size/s"]));
    ok(&h.run(&["ptask", "demo", "add", "docs(ui): the pause menu keys"]));
    let sheet = h.sheet();
    assert_eq!(
        sheet.matches("epic(ui): ui to standard").count(),
        1,
        "{sheet}"
    );
    assert_eq!(
        h.board().matches("#of/dm-1").count(),
        2,
        "both agent rows: {}",
        h.board()
    );
    assert!(
        sheet
            .lines()
            .any(|l| l.contains("the pause menu keys") && l.contains("#of/dm-1")),
        "a human-sheet leaf links too: {sheet}"
    );
    assert_eq!(
        h.events().iter().filter(|(a, _)| a == "added").count(),
        4,
        "one event for the epic and one per row"
    );
}

#[test]
fn a_free_area_a_parent_or_no_system_list_leaves_the_row_as_written() {
    let h = Home::new("standing-neg");
    // NEGATIVE CONTROL: no system list (the lookup exits 2), and the row is still written.
    ok(&agent(&h, &["add", "fix(ui): pause menu is slow #size/s"]));
    assert!(!h.board().contains("#of/"), "{}", h.board());
    h.systems(Some(SYSTEMS));
    ok(&agent(
        &h,
        &["add", "fix(audio): the gun sound plays late #size/s"],
    ));
    ok(&agent(
        &h,
        &["add", "fix(ui): resume flickers #size/s #of/dm-9"],
    ));
    let board = h.board();
    assert!(
        board
            .lines()
            .any(|l| l.contains("gun sound") && !l.contains("#of/")),
        "a free area word is no system: {board}"
    );
    assert!(
        board
            .lines()
            .any(|l| l.contains("resume flickers") && l.contains("#of/dm-9")),
        "a row's own parent stands: {board}"
    );
    assert!(
        !h.sheet().contains("to standard"),
        "no epic was filed: {}",
        h.sheet()
    );
}

#[test]
fn a_line_filed_from_the_inbox_links_like_an_add() {
    let h = Home::new("standing-file");
    h.systems(Some(SYSTEMS));
    let readme = h.0.join("notes/projects/current/demo/README.md");
    fs::write(
        &readme,
        "# demo\nVersion: v0.1.0\n\n## Inbox\n- the pause menu feels slow\n\n## Tasks\n",
    )
    .unwrap();
    ok(&h.run(&[
        "ptask",
        "demo",
        "file",
        "pause menu",
        "--as",
        "fix(ui): the pause menu opens slowly #size/s",
    ]));
    let sheet = h.sheet();
    assert!(
        !sheet.contains("- the pause menu feels slow"),
        "taken off the inbox: {sheet}"
    );
    assert_eq!(
        sheet.matches("epic(ui): ui to standard").count(),
        1,
        "{sheet}"
    );
    let row = sheet
        .lines()
        .find(|l| l.contains("the pause menu opens slowly"))
        .unwrap_or_else(|| panic!("not filed: {sheet}"));
    assert!(row.contains("#of/dm-1") && row.contains("id:dm-2"), "{row}");
    assert!(sheet.contains("was: the pause menu feels slow"), "{sheet}");
}

#[test]
fn closing_an_epics_last_leaf_files_one_verify_row_on_the_human_sheet() {
    let h = Home::new("verify");
    ok(&h.run(&[
        "ptask",
        "demo",
        "add",
        "epic(ui): the pause menu feels instant",
    ]));
    assert!(h.sheet().contains("id:dm-1"), "{}", h.sheet());
    ok(&agent(
        &h,
        &["add", "fix(ui): pause menu is slow #size/s #of/dm-1"],
    ));
    ok(&agent(
        &h,
        &["add", "feat(ui): a resume button #size/s #of/dm-1"],
    ));
    let verify = |h: &Home| {
        h.sheet()
            .lines()
            .filter(|l| l.contains("check(ui): verify dm-1 the pause menu feels instant"))
            .count()
    };
    // NEGATIVE CONTROL: a close that leaves a leaf open asks nothing.
    ok(&agent(&h, &["done", "dm-2", "--proof", "pr:1"]));
    assert_eq!(verify(&h), 0, "{}", h.sheet());

    ok(&agent(&h, &["done", "dm-3", "--proof", "pr:2"]));
    assert_eq!(verify(&h), 1, "{}", h.sheet());
    let sheet = h.sheet();
    let row = sheet.lines().find(|l| l.contains("verify dm-1")).unwrap();
    assert!(row.starts_with("- [ ] ") && row.contains("#high"), "{row}");
    assert!(
        !row.contains("#of/"),
        "the ask is no leaf of the epic: {row}"
    );
    assert!(
        sheet.contains("- [ ] epic(ui): the pause menu feels instant"),
        "nothing closes the epic: {sheet}"
    );

    // Ticking the ask finishes nothing again, so it is never filed twice.
    let id = ids(&sheet).into_iter().find(|i| i != "dm-1").unwrap();
    ok(&h.run(&[
        "ptask",
        "demo",
        "done",
        &id,
        "--proof",
        "looked: it opens in 40ms",
    ]));
    // A re-close of the finished leaf (a re-run landing) matches no open row, so it files none.
    let _ = agent(&h, &["done", "dm-3", "--proof", "pr:2"]);
    assert_eq!(h.sheet().matches("verify dm-1").count(), 1, "{}", h.sheet());
}
