//! `notes ptask` as one hardened writer, run as the real binary against a throwaway HOME:
//! every verb writes one event naming its row's id, the agent board refuses untyped,
//! size-less and near-duplicate rows, and concurrent writers mint distinct ids under the lock.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

struct Home(PathBuf);

#[test]
fn sweep_keeps_footers_out_of_tasks_and_reports() {
    let h = Home::new("sweep-footers");
    let path = h.0.join("notes/projects/current/demo/README.md");
    fs::write(
        &path,
        "# demo\nVersion: v0.1.0\n\n## Tasks\n- [ ] fix(ui): repair menu #low #v0.0.1 <!-- id:dm-1 -->\n\n---\n### Done\n",
    )
    .unwrap();

    for args in [
        vec!["ptask", "demo", "sweep", "--dry-run"],
        vec!["ptask", "demo", "sweep"],
    ] {
        let output = h.run(&args);
        ok(&output);
        let report = String::from_utf8(output.stdout).unwrap();
        assert!(report.contains("#v0.0.1 closed"), "{report}");
        assert!(!report.contains("---"), "{report}");
        assert!(!report.contains("### Done"), "{report}");
    }

    let swept = h.sheet();
    assert_eq!(swept.matches("---").count(), 1, "{swept}");
    assert_eq!(swept.matches("### Done").count(), 1, "{swept}");
    assert_eq!(swept.matches("- [ ]").count(), 2, "{swept}");
    assert!(
        swept.contains("- [ ] fix(ui): repair menu #low <!-- id:dm-1 -->"),
        "{swept}"
    );
    let output = h.run(&["ptask", "demo", "sweep"]);
    ok(&output);
    assert!(String::from_utf8(output.stdout)
        .unwrap()
        .contains("already swept"));
    assert_eq!(h.sheet(), swept);
}

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
fn edit_link_puts_an_existing_row_under_its_systems_standing_epic() {
    let h = Home::new("standing-edit");
    ok(&agent(
        &h,
        &["add", "fix(sound): pause menu is slow #size/s"],
    ));
    ok(&agent(&h, &["add", "fix(sound): resume flickers #size/s"]));
    h.systems(Some(SYSTEMS));
    // NEGATIVE CONTROL: a plain edit to a system area writes no link.
    ok(&agent(
        &h,
        &["edit", "dm-2", "--text", "fix(ui): resume flickers #size/s"],
    ));
    assert!(!h.board().contains("#of/"), "{}", h.board());
    ok(&agent(
        &h,
        &[
            "edit",
            "dm-1",
            "--link",
            "--text",
            "fix(menu): pause menu is slow #size/s",
        ],
    ));
    let row = h
        .board()
        .lines()
        .find(|l| l.contains("pause menu is slow"))
        .map(str::to_string)
        .unwrap();
    assert!(
        row.contains("fix(menu):") && row.contains("#of/dm-3") && row.contains("id:dm-1"),
        "the row keeps its id and goes under the filed epic: {row}"
    );
    assert_eq!(h.sheet().matches("epic(ui): ui to standard").count(), 1);
    // A free area word under --link is refused: nothing is edited and no second epic is filed.
    let out = agent(
        &h,
        &[
            "edit",
            "dm-2",
            "--link",
            "--text",
            "fix(sound): resume flickers again #size/s",
        ],
    );
    assert_eq!(
        out.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(
        !h.board().contains("resume flickers again"),
        "{}",
        h.board()
    );
    // An edit that matches no row files no standing epic before it fails.
    let out = agent(
        &h,
        &[
            "edit",
            "no such row",
            "--link",
            "--text",
            "docs(docs): a setup guide #size/s",
        ],
    );
    assert_eq!(
        out.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(h.sheet().matches("to standard").count(), 1, "{}", h.sheet());
}

#[test]
fn closing_an_epics_last_leaf_leaves_the_epic_open_and_files_no_row() {
    // The verify is a queue item fleet-dispatch's reap files from the rollup (reconcile_epics),
    // so the close itself writes nothing beyond its own row.
    let h = Home::new("verify");
    ok(&h.run(&[
        "ptask",
        "demo",
        "add",
        "epic(ui): the pause menu feels instant",
    ]));
    ok(&agent(
        &h,
        &["add", "fix(ui): pause menu is slow #size/s #of/dm-1"],
    ));
    ok(&agent(
        &h,
        &["add", "feat(ui): a resume button #size/s #of/dm-1"],
    ));
    let before = h.sheet();
    // A close that leaves a leaf open, then the last one: neither writes the human sheet.
    ok(&agent(&h, &["done", "dm-2", "--proof", "pr:1"]));
    assert_eq!(h.sheet(), before, "a leaf still open");
    ok(&agent(&h, &["done", "dm-3", "--proof", "pr:2"]));
    let sheet = h.sheet();
    assert_eq!(sheet, before, "the human sheet is untouched");
    assert!(!sheet.contains("verify dm-1"), "{sheet}");
    assert!(
        sheet.contains("- [ ] epic(ui): the pause menu feels instant"),
        "nothing closes the epic: {sheet}"
    );
}

#[test]
fn a_playtest_pass_files_one_counted_row_and_ticked_checks_keep_the_done_window() {
    let h = Home::new("playtest");
    let pt = |verb: &[&str]| {
        let mut args = vec!["ptask", "demo", "--playtest"];
        args.extend_from_slice(verb);
        h.run(&args)
    };
    let file = h.0.join("notes/projects/current/demo/playtest.md");
    ok(&pt(&[
        "add",
        "--pr",
        "7",
        "lobby: two pads join: both spawn",
    ]));
    ok(&pt(&["add", "--pr", "12", "arena: throw: the ball arcs"]));
    ok(&pt(&["add", "menu: back exits: you land on the title"]));
    let laid = fs::read_to_string(&file).unwrap();
    let at = |s: &str| laid.find(s).unwrap_or_else(|| panic!("no {s}:\n{laid}"));
    assert!(
        at("### PR 12") < at("arena")
            && at("arena") < at("### PR 7")
            && at("### PR 7") < at("lobby"),
        "newest PR first:\n{laid}"
    );
    assert!(at("### No PR") > at("lobby"), "no PR last:\n{laid}");

    // A pass counts the open checks into one human sheet row; the same build again is a twin.
    ok(&pt(&["pass", "--build", "b2101"]));
    assert!(
        h.sheet()
            .contains("- [ ] check(playtest): play build b2101, 3 checks in playtest.md #"),
        "{}",
        h.sheet()
    );
    assert_eq!(pt(&["pass", "--build", "b2101"]).status.code(), Some(3));
    assert_eq!(h.sheet().matches("check(playtest)").count(), 1);
    // A tag or a marker in the build would retag the row.
    assert!(!pt(&["pass", "--build", "b9 #v9.9.9"]).status.success());
    // The next build is its own row, though only its id differs.
    ok(&pt(&["pass", "--build", "b2102"]));
    assert!(
        h.sheet().contains("play build b2102, 3 checks"),
        "{}",
        h.sheet()
    );

    // A tick is dated and stays in Done; the nightly sweep rolls off only what the window drops.
    ok(&pt(&["done", "lobby", "--unverified", "played it"]));
    let laid = fs::read_to_string(&file).unwrap();
    let done = laid.find("### Done").expect("a Done section");
    let row = laid.find("- [x] lobby").expect("the ticked check");
    assert!(row > done && laid[row..].contains("done:"), "{laid}");
    ok(&pt(&[
        "drop",
        "menu",
        "--why",
        "superseded by the arena check",
    ]));
    ok(&h.run(&["projects", "--sweep"]));
    let laid = fs::read_to_string(&file).unwrap();
    assert!(laid.contains("- [x] lobby"), "kept in the window:\n{laid}");
    assert!(
        !laid.contains("menu: back"),
        "a dropped check rolls off:\n{laid}"
    );
    let note = fs::read_to_string(h.0.join("notes/projects/current/demo/agent/versions/v0.1.0.md"))
        .unwrap();
    assert!(
        note.contains("## Playtest done: General\n- [x] menu: back exits"),
        "{note}"
    );
    assert_eq!(
        pt(&["pass", "--build", "x", "--game", "Nope"])
            .status
            .code(),
        Some(0),
        "no open checks under that game files nothing"
    );
    assert_eq!(h.sheet().matches("check(playtest)").count(), 2);
}
