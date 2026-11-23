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
            .env_remove("AGENT_QUEUE_ITEM")
            .env_remove("CLAUDE_CODE_SESSION_ID")
            .env_remove("AGENTCTL_NAME");
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
fn a_multi_line_add_stamps_its_id_on_the_row_line_so_done_finds_it() {
    let h = Home::new("multi-line");
    ok(&agent(
        &h,
        &[
            "add",
            "fix(tests): menu fails some nights #size/s\n  Quarantined for the nightly.",
        ],
    ));
    let board = h.board();
    let row = board.lines().find(|l| l.starts_with("- [ ]")).unwrap();
    assert!(row.ends_with("<!-- id:dm-1 -->"), "{board}");
    assert!(
        board.contains("\n  Quarantined for the nightly.\n"),
        "{board}"
    );
    ok(&agent(&h, &["done", "--proof", "pr:9", "dm-1"]));
    assert!(
        h.board()
            .contains("- [x] fix(tests): menu fails some nights"),
        "{}",
        h.board()
    );

    // The human's own words still go to the inbox as typed, every line of them.
    ok(&h.run(&[
        "ptask",
        "demo",
        "add",
        "buy milk\n\n  - eggs\n    - a dozen",
    ]));
    assert!(
        h.sheet()
            .contains("- [ ] buy milk\n\n  - eggs\n    - a dozen"),
        "{}",
        h.sheet()
    );
}

#[test]
fn the_agent_board_refuses_untyped_and_near_duplicate_rows_and_takes_an_unsized_one() {
    let h = Home::new("refuse");
    let before = h.board();
    let untyped = agent(&h, &["add", "menu flickers #size/s"]);
    assert_eq!(untyped.status.code(), Some(1));
    assert_eq!(h.board(), before, "a refused add writes nothing");

    // No size: the nightly `agentctl-inbox-triage --backlog --size` pass scores it.
    ok(&agent(
        &h,
        &["add", "fix(ui): the pause menu flickers on resume"],
    ));
    assert!(!h.board().contains("#size/"), "{}", h.board());
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
    // inbox-triage rewrites a filed row's area; the filer's same words again are still that row.
    let rescoped = agent(
        &h,
        &[
            "add",
            "fix(menu): the pause menu flickers on resume #size/s",
        ],
    );
    assert_eq!(
        rescoped.status.code(),
        Some(3),
        "the area does not make it a new row"
    );
    assert_eq!(ids(&h.board()), ["dm-1"]);

    ok(&agent(
        &h,
        &["add", "feat(gameplay): land PR #2539 (branch agent-1)"],
    ));
    let same_pr = agent(
        &h,
        &["add", "fix(ci): re-gate and land PR #2539 (worktree)"],
    );
    assert_eq!(
        same_pr.status.code(),
        Some(3),
        "a second row landing one PR"
    );
    assert!(
        String::from_utf8_lossy(&same_pr.stderr).contains("dm-2 already lands PR #2539"),
        "names the open row: {}",
        String::from_utf8_lossy(&same_pr.stderr)
    );
    assert_eq!(
        ids(&h.board()),
        ["dm-2", "dm-1"],
        "the refused add wrote nothing"
    );
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

// nc-86: `edit --text` keeps the old text's own tags (size, points); a typed one of the same
// name replaces it.
#[test]
fn edit_text_keeps_the_rows_size_and_points_tags() {
    let h = Home::new("edit-tags");
    ok(&agent(
        &h,
        &["add", "fix(ui): menu flickers #size/s #pts/2"],
    ));
    // A tag other than the sizing is what --text types: leaving #plan out clears it.
    ok(&agent(&h, &["add", "fix(ui): sound lags #plan #size/m"]));
    ok(&agent(
        &h,
        &["edit", "dm-2", "--text", "fix(ui): sound is late"],
    ));
    let row = h.board();
    assert!(
        row.contains("sound is late") && row.contains("#size/m") && !row.contains("#plan"),
        "{row}"
    );
    ok(&agent(
        &h,
        &["edit", "dm-1", "--text", "fix(ui): menu blinks"],
    ));
    let row = h.board();
    assert!(
        row.contains("menu blinks") && row.contains("#size/s") && row.contains("#pts/2"),
        "{row}"
    );
    ok(&agent(
        &h,
        &[
            "edit",
            "dm-1",
            "--text",
            "fix(ui): menu blinks on resume #size/m",
        ],
    ));
    let row = h.board();
    assert!(
        row.contains("#size/m") && !row.contains("#size/s") && !row.contains("#pts/2"),
        "{row}"
    );
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

#[test]
fn closing_a_play_build_row_closes_the_checks_its_pass_covered() {
    let h = Home::new("played");
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
    ok(&pt(&[
        "add",
        "--game",
        "Arena",
        "arena: throw: the ball arcs",
    ]));
    ok(&pt(&[
        "add",
        "--",
        "ball clips the wall (playtest Nov 21, sam)",
    ]));

    // The pass counts and stamps the two checks, not the tester's feedback.
    ok(&pt(&["pass", "--build", "b1"]));
    assert!(
        h.sheet().contains("play build b1, 2 checks in playtest.md"),
        "{}",
        h.sheet()
    );
    let id = h
        .sheet()
        .lines()
        .find(|l| l.contains("play build b1"))
        .and_then(|l| l.split("id:").nth(1))
        .and_then(|r| r.split_whitespace().next())
        .unwrap()
        .to_string();
    let laid = fs::read_to_string(&file).unwrap();
    assert_eq!(laid.matches(&format!("pass:{id}")).count(), 2, "{laid}");
    // The same build again is a twin: no second row, but a check added since gets the stamp.
    ok(&pt(&["add", "lobby: leave: the pad frees"]));
    assert_eq!(pt(&["pass", "--build", "b1"]).status.code(), Some(3));
    assert_eq!(h.sheet().matches("play build b1").count(), 1);
    let laid = fs::read_to_string(&file).unwrap();
    assert_eq!(laid.matches(&format!("pass:{id}")).count(), 3, "{laid}");
    // A pass for one game stamps only that game's checks.
    ok(&pt(&["pass", "--build", "b2", "--game", "Arena"]));

    // NEGATIVE CONTROL: dropping a play row (never played) closes nothing.
    ok(&h.run(&[
        "ptask",
        "demo",
        "drop",
        "play Arena build b2",
        "--why",
        "build broke",
    ]));
    assert_eq!(
        fs::read_to_string(&file).unwrap().matches("- [ ]").count(),
        4
    );

    // The play row closing done is the event: its checks close with it, the feedback stays.
    ok(&h.run(&[
        "ptask",
        "demo",
        "done",
        "play build b1",
        "--unverified",
        "played Nov 21",
    ]));
    let laid = fs::read_to_string(&file).unwrap();
    assert_eq!(laid.matches(&format!("played:{id}")).count(), 3, "{laid}");
    assert!(
        laid.contains("- [ ] ball clips the wall (playtest Nov 21, sam)"),
        "{laid}"
    );
    assert_eq!(laid.matches("- [ ]").count(), 1, "{laid}");
    // Idempotent: the next sweep finds nothing left to close.
    ok(&h.run(&["projects", "--sweep"]));
    assert_eq!(fs::read_to_string(&file).unwrap(), laid);

    // A play row ticked by hand closes its checks on the next sheet sweep.
    ok(&pt(&["add", "menu: back exits: you land on the title"]));
    ok(&pt(&["pass", "--build", "b3"]));
    let sheet = h.0.join("notes/projects/current/demo/README.md");
    let hand = h.sheet().replace(
        "- [ ] check(playtest): play build b3",
        "- [x] check(playtest): play build b3",
    );
    fs::write(&sheet, hand).unwrap();
    let out = h.run(&["projects", "--sweep"]);
    ok(&out);
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("1 playtest check(s) played in"),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
    let laid = fs::read_to_string(&file).unwrap();
    assert!(laid.contains("- [x] menu: back exits"), "{laid}");
}

/// A real plan brief: a paragraph break, a nested list, a fenced block with its own indent.
const BRIEF: &str = "goal: every row keeps its brief\n\nsteps:\n- add writes the full body\n  - not only the title\n    - and not a `full:` line\n\n```sh\nif [ -n \"$X\" ]; then\n    agent-queue return \"$X\"\nfi\n```\ncheck: the board prints it back";

/// The details `notes board --json` reports for the demo agent row `id`.
fn board_details(h: &Home, id: &str) -> Vec<String> {
    let out = h.run(&["board", "--json"]);
    ok(&out);
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    let rows = v["rows"].as_array().or(v.as_array()).expect("rows");
    let row = rows
        .iter()
        .find(|r| r["id"] == id)
        .unwrap_or_else(|| panic!("no row {id}"));
    row["details"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d.as_str().unwrap().to_string())
        .collect()
}

#[test]
fn a_brief_round_trips_through_add_edit_and_board_json_byte_for_byte() {
    let h = Home::new("brief-round-trip");
    ok(&agent(
        &h,
        &[
            "add",
            "feat(board): one record per task #size/s",
            "--detail",
            BRIEF,
        ],
    ));
    assert_eq!(board_details(&h, "dm-1").join("\n"), BRIEF, "{}", h.board());

    // A second --detail lands after the first, separated by what it carries.
    ok(&agent(
        &h,
        &[
            "edit",
            "dm-1",
            "--detail",
            "more:\n  indented\n\nafter a gap",
        ],
    ));
    let want = format!("{BRIEF}\nmore:\n  indented\n\nafter a gap");
    assert_eq!(board_details(&h, "dm-1").join("\n"), want, "{}", h.board());

    // A sweep (every save runs one) and a second row beside it change nothing in the brief.
    ok(&agent(
        &h,
        &["add", "fix(board): second row #size/s #urgent"],
    ));
    ok(&h.run(&["ptask", "demo", "--agent", "sweep"]));
    assert_eq!(board_details(&h, "dm-1").join("\n"), want, "{}", h.board());
    assert!(board_details(&h, "dm-2").is_empty());
}

#[test]
fn edit_brief_replaces_the_brief_and_a_checklist_in_it_files_no_row() {
    let h = Home::new("brief-replace");
    let checklist = "goal: x\n\n## Phases\n- [ ] P1 one\n- [x] P2 two";
    ok(&agent(
        &h,
        &[
            "add",
            "feat(board): a planned task #size/s",
            "--detail",
            checklist,
        ],
    ));
    assert_eq!(
        board_details(&h, "dm-1").join("\n"),
        checklist,
        "{}",
        h.board()
    );
    // NEGATIVE CONTROL for the escape: the checklist is no row of its own on the board.
    let out = h.run(&["board", "--json"]);
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    let rows = v["rows"].as_array().unwrap();
    assert!(
        !rows
            .iter()
            .any(|r| r["text"].as_str().is_some_and(|t| t.contains("P1 one"))),
        "{}",
        h.board()
    );

    ok(&agent(&h, &["edit", "dm-1", "--brief", BRIEF]));
    assert_eq!(board_details(&h, "dm-1").join("\n"), BRIEF, "{}", h.board());
    assert!(
        h.board().contains("feat(board): a planned task"),
        "{}",
        h.board()
    );
    // A brief that opens with a dash is a value, not a flag.
    ok(&agent(
        &h,
        &["edit", "dm-1", "--brief", "- step one\n- step two"],
    ));
    assert_eq!(
        board_details(&h, "dm-1").join("\n"),
        "- step one\n- step two",
        "{}",
        h.board()
    );
    // An empty brief clears it: agent-queue retask to a one-line task leaves the row its words alone.
    ok(&agent(&h, &["edit", "dm-1", "--brief", ""]));
    assert!(board_details(&h, "dm-1").is_empty(), "{}", h.board());

    let out = agent(
        &h,
        &["edit", "dm-1", "--brief", "x", "--text", "feat(board): y"],
    );
    assert!(!out.status.success(), "--brief with --text is refused");
}

/// `ptask demo --agent add <text> [flags]` as `env` writes it, on top of this HOME's clean env.
fn add_as(h: &Home, env: &[(&str, &str)], flags: &[&str], text: &str) -> Output {
    let mut args = vec!["ptask", "demo", "--agent", "add"];
    args.extend_from_slice(flags);
    args.push(text);
    let mut c = h.cmd(&args);
    for (k, v) in env {
        c.env(k, v);
    }
    c.output().unwrap()
}

fn outbox(h: &Home) -> String {
    let out = h.run(&["outbox", "list"]);
    String::from_utf8_lossy(&out.stdout).into_owned()
}

#[test]
fn a_queue_items_agent_add_goes_to_the_outbox_and_writes_no_row() {
    let h = Home::new("inboxed");
    let before = h.board();
    let o = add_as(
        &h,
        &[("AGENT_QUEUE_ITEM", "abcdef01")],
        &["--detail", "seen in the nightly"],
        "fix(ui): the pause menu flickers #size/s",
    );
    assert_eq!(
        o.status.code(),
        Some(4),
        "{}",
        String::from_utf8_lossy(&o.stderr)
    );
    assert!(String::from_utf8_lossy(&o.stdout).starts_with("inboxed:"));
    assert_eq!(h.board(), before, "no row on the board");
    let ob = outbox(&h);
    assert!(
        ob.contains("#agent #p:demo #from/abcdef01 fix(ui): the pause menu flickers #size/s"),
        "{ob}"
    );
    // A queue item names the writer by its slug, and the same line twice is one line.
    let item = [("AGENT_QUEUE_ITEM", "ar-9")];
    add_as(&h, &item, &[], "fix(ui): a second thing");
    add_as(&h, &item, &[], "fix(ui): a second thing");
    let ob = outbox(&h);
    assert_eq!(
        ob.matches("#from/ar-9 fix(ui): a second thing").count(),
        1,
        "{ob}"
    );
    assert!(ids(&h.board()).is_empty());
}

#[test]
fn a_twin_is_still_refused_before_a_session_line_waits_in_the_outbox() {
    let h = Home::new("inbox-twin");
    ok(&agent(
        &h,
        &["add", "fix(ui): the pause menu flickers #size/s"],
    ));
    let o = add_as(
        &h,
        &[("CLAUDE_CODE_SESSION_ID", "abcdef0123456789")],
        &[],
        "fix(ui): the pause menu flickers #size/s",
    );
    assert_eq!(o.status.code(), Some(3));
    assert!(!outbox(&h).contains("flickers"), "{}", outbox(&h));
}

/// `ptask demo <lane...> add <flags> <text>` run by a script named `script` (off PATH, so it
/// shadows no stub), so the notes process's parent is that script, as when a real filer runs it.
fn add_from(
    h: &Home,
    script: &str,
    env: &[(&str, &str)],
    lane: &[&str],
    flags: &[&str],
    text: &str,
) -> Output {
    let dir = h.0.join("filers");
    let stub = dir.join(script);
    if !stub.exists() {
        fs::create_dir_all(&dir).unwrap();
        // `exit $?` after the call keeps the shell from exec'ing notes in its own place.
        fs::write(&stub, "#!/bin/sh\n\"$NOTES_BIN\" \"$@\"\nexit $?\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let mut args = vec!["ptask", "demo"];
    args.extend_from_slice(lane);
    args.push("add");
    args.extend_from_slice(flags);
    args.push(text);
    let mut c = h.cmd(&args);
    c.env("NOTES_BIN", env!("CARGO_BIN_EXE_notes"));
    let real = c.get_args().map(|a| a.to_owned()).collect::<Vec<_>>();
    let mut c2 = Command::new(&stub);
    c2.args(real);
    for (k, v) in c.get_envs() {
        match v {
            Some(v) => c2.env(k, v),
            None => c2.env_remove(k),
        };
    }
    for (k, v) in env {
        c2.env(k, v);
    }
    // A test thread forking while the stub was open for writing holds it busy until its child
    // execs (ETXTBSY), an event no API reports, so the spawn is retried a bounded number of times.
    for _ in 0..100 {
        match c2.output() {
            Err(e) if e.kind() == std::io::ErrorKind::ExecutableFileBusy => {
                std::thread::yield_now()
            }
            r => return r.unwrap(),
        }
    }
    panic!("{} stayed busy", stub.display())
}

#[test]
fn a_flag_names_no_writer_the_process_does_not_vouch_for() {
    let h = Home::new("direct");
    let sess = ("AGENT_QUEUE_ITEM", "abcdef01");
    let code = |o: Output| o.status.code();
    // A queue item's own `--origin`, `--want` or `--origin plan` is its word, so the row waits.
    let typed = [
        (vec!["--origin", "plan"], "feat(ui): phase one #size/s"),
        (vec!["--want", "voice"], "feat(ui): the human asked #size/s"),
        (
            vec!["--origin", "agent-ask"],
            "chore(ask): a claimed tool #size/s",
        ),
    ];
    for (flags, text) in &typed {
        assert_eq!(code(add_as(&h, &[sess], flags, text)), Some(4), "{text}");
    }
    assert!(ids(&h.board()).is_empty(), "{}", h.board());
    let ob = outbox(&h);
    assert!(
        ob.contains("#agent #p:demo #from/abcdef01 #want/voice feat(ui): the human asked"),
        "{ob}"
    );
    // The same calls from the named script file: agent-ask, and agent-queue filing a plan's row.
    ok(&add_from(
        &h,
        "agent-ask",
        &[sess],
        &["--agent"],
        &["--origin", "agent-ask"],
        "chore(ask): a session's tool #size/s",
    ));
    ok(&add_from(
        &h,
        "agent-queue",
        &[sess, ("AQ_ITEM_PLAN", "/tmp/plan.md")],
        &["--agent"],
        &["--origin", "plan"],
        "feat(ui): phase two #size/s",
    ));
    // NEGATIVE CONTROL: agent-queue with no plan in its environment is not a plan's phases.
    assert_eq!(
        code(add_from(
            &h,
            "agent-queue",
            &[sess],
            &["--agent"],
            &["--origin", "plan"],
            "feat(ui): phase three #size/s",
        )),
        Some(4)
    );
    // A runner is named by AGENTCTL_NAME, which is also an --origin it may pass.
    ok(&add_as(
        &h,
        &[("AGENTCTL_NAME", "ask-sweep")],
        &[],
        "chore(ask): a filed ask #size/s",
    ));
    ok(&add_as(
        &h,
        &[("AGENTCTL_NAME", "ask-sweep")],
        &["--origin", "ask-sweep"],
        "chore(ask): a second ask #size/s",
    ));
    // A person's shell has no session, item or runner in its environment; its want files.
    ok(&add_as(&h, &[], &[], "fix(menu): typed by hand #size/s"));
    ok(&add_as(
        &h,
        &[],
        &["--want", "voice"],
        "fix(menu): said aloud #size/s",
    ));
    assert_eq!(ids(&h.board()).len(), 6, "{}", h.board());
    assert!(
        h.board()
            .lines()
            .any(|l| l.contains("said aloud") && l.contains("#requested")),
        "{}",
        h.board()
    );
}

#[test]
fn a_queue_items_human_lane_row_and_any_epic_go_to_the_outbox() {
    let h = Home::new("human-lane");
    let sess = ("AGENT_QUEUE_ITEM", "abcdef01");
    let human = |flags: &[&str], text: &str| {
        let mut args = vec!["ptask", "demo", "add"];
        args.extend_from_slice(flags);
        args.push(text);
        let mut c = h.cmd(&args);
        c.env(sess.0, sess.1);
        c.output().unwrap()
    };
    let before = h.sheet();
    assert_eq!(
        human(&[], "fix(ui): a human-lane row").status.code(),
        Some(4)
    );
    assert_eq!(human(&[], "epic(ui): a new epic").status.code(), Some(4));
    assert_eq!(
        human(&["--want", "human"], "fix(ui): a want by hand")
            .status
            .code(),
        Some(4)
    );
    // An epic on the board from a session is a proposal too, not a refusal.
    assert_eq!(
        add_as(&h, &[sess], &[], "epic(ui): a board epic")
            .status
            .code(),
        Some(4)
    );
    assert_eq!(h.sheet(), before, "no row on the human sheet");
    assert!(ids(&h.board()).is_empty());
    let ob = outbox(&h);
    for line in [
        "#p:demo #from/abcdef01 fix(ui): a human-lane row",
        "#p:demo #from/abcdef01 epic(ui): a new epic",
        "#p:demo #from/abcdef01 #want/human fix(ui): a want by hand",
        "#p:demo #from/abcdef01 epic(ui): a board epic",
    ] {
        assert!(ob.contains(line), "{line}\n{ob}");
    }
    assert!(
        // An epic lives on the human sheet, so even an --agent one carries no #agent for triage.
        !ob.contains("#agent #p:demo #from/abcdef01 fix(ui): a human")
            && !ob.contains("#agent #p:demo #from/abcdef01 epic(ui)"),
        "{ob}"
    );
    // A session's raw words still wait in the sheet's own inbox, and a direct filer's epic files.
    ok(&human(&[], "the menu flickers"));
    assert!(
        h.sheet().contains("## Inbox\n- [ ] the menu flickers"),
        "{}",
        h.sheet()
    );
    ok(&add_from(
        &h,
        "project-stage-check",
        &[sess],
        &[],
        &["--origin", "project-stage-check"],
        "epic(stage): beta to standard",
    ));
    assert!(
        h.sheet().contains("epic(stage): beta to standard"),
        "{}",
        h.sheet()
    );
    // NEGATIVE CONTROL: a direct filer's epic on the board is still refused.
    assert!(!add_as(
        &h,
        &[("AGENTCTL_NAME", "ask-sweep")],
        &[],
        "epic(ui): a direct board epic"
    )
    .status
    .success());
}

#[test]
fn edit_and_move_never_make_an_epic() {
    let h = Home::new("edit-epic");
    ok(&h.run(&["ptask", "demo", "add", "fix(ui): a plain row"]));
    ok(&h.run(&["ptask", "demo", "add", "epic(ui): an epic"]));
    let before = h.sheet();
    let o = h.run(&[
        "ptask",
        "demo",
        "edit",
        "plain row",
        "--text",
        "epic(ui): now an epic",
    ]);
    assert!(
        !o.status.success(),
        "{}",
        String::from_utf8_lossy(&o.stdout)
    );
    assert_eq!(h.sheet(), before);
    // An epic's own words may still change.
    ok(&h.run(&[
        "ptask",
        "demo",
        "edit",
        "an epic",
        "--text",
        "epic(ui): a better epic",
    ]));
    assert!(
        h.sheet().contains("epic(ui): a better epic"),
        "{}",
        h.sheet()
    );
    // An epic written onto the board by hand cannot be moved onto another board.
    let board = h.board_path();
    let b = h.board();
    fs::write(
        &board,
        b.replace("## Tasks\n", "## Tasks\n- [ ] epic(ui): hand-written\n"),
    )
    .unwrap();
    let o = h.run(&[
        "ptask",
        "demo",
        "--agent",
        "move",
        "hand-written",
        "--project",
        "demo",
    ]);
    assert!(!o.status.success());
    assert!(String::from_utf8_lossy(&o.stderr).contains("an epic belongs on the human sheet"));
}

#[test]
fn a_runner_off_the_list_or_a_session_that_inherited_a_runner_name_is_inboxed() {
    let h = Home::new("not-listed");
    let o = add_as(
        &h,
        &[("AGENTCTL_NAME", "some-runner")],
        &[],
        "fix(a): runner row #size/s",
    );
    assert_eq!(o.status.code(), Some(4));
    // The session's own claim is stronger than a runner name left in its environment.
    let o = add_as(
        &h,
        &[
            ("CLAUDE_CODE_SESSION_ID", "abcdef0123456789"),
            ("AGENTCTL_NAME", "ask-sweep"),
        ],
        &[],
        "fix(b): inherited name #size/s",
    );
    assert_eq!(o.status.code(), Some(4));
    assert!(ids(&h.board()).is_empty());
    let ob = outbox(&h);
    assert!(
        ob.contains("#from/some-runner fix(a)") && ob.contains("#from/abcdef01 fix(b)"),
        "{ob}"
    );
}

#[test]
fn agent_direct_filers_in_the_config_replaces_the_default_list() {
    let h = Home::new("filers-config");
    let cfg = h.0.join("config.toml");
    let body = fs::read_to_string(&cfg).unwrap();
    fs::write(&cfg, format!("agent_direct_filers = [\"only-me\"]\n{body}")).unwrap();
    let o = add_as(
        &h,
        &[("AGENTCTL_NAME", "ask-sweep")],
        &[],
        "fix(a): dropped from the list #size/s",
    );
    assert_eq!(o.status.code(), Some(4));
    ok(&add_as(
        &h,
        &[("AGENTCTL_NAME", "only-me")],
        &[],
        "fix(b): on the list #size/s",
    ));
    assert_eq!(ids(&h.board()).len(), 1, "{}", h.board());
}

/// A session the human opened: `CLAUDE_CODE_SESSION_ID` with no queue item or runner.
const HAND: (&str, &str) = ("CLAUDE_CODE_SESSION_ID", "abcdef0123456789");

/// [`add_as`] on the human lane, where an epic lives.
fn add_human(h: &Home, env: &[(&str, &str)], text: &str) -> Output {
    let mut c = h.cmd(&["ptask", "demo", "add", text]);
    for (k, v) in env {
        c.env(k, v);
    }
    c.output().unwrap()
}

fn ingest(h: &Home) -> String {
    fs::read_to_string(h.0.join(".local/state/notes/ingest.jsonl")).unwrap_or_default()
}

#[test]
fn a_hand_session_is_shown_the_similar_rows_then_files_once_it_names_them() {
    let h = Home::new("hand-shortlist");
    ok(&agent(
        &h,
        &["add", "fix(ui): the pause menu flickers #low #size/s"],
    ));
    let text = "fix(ui): the pause menu drops input on resume #low #size/s";
    let o = add_as(&h, &[HAND], &[], text);
    assert_eq!(
        o.status.code(),
        Some(5),
        "{}",
        String::from_utf8_lossy(&o.stderr)
    );
    let shown = String::from_utf8_lossy(&o.stdout);
    assert!(shown.starts_with("dm-1\t"), "{shown}");
    assert!(String::from_utf8_lossy(&o.stderr).contains("--checked dm-1"));
    assert_eq!(ids(&h.board()), ["dm-1"], "nothing filed yet");
    // An id that is not one shown is not a review of the shortlist.
    let o = add_as(&h, &[HAND], &["--checked", "dm-7"], text);
    assert_eq!(o.status.code(), Some(5));
    ok(&add_as(&h, &[HAND], &["--checked", "dm-1"], text));
    assert_eq!(ids(&h.board()).len(), 2, "{}", h.board());
    assert!(
        !outbox(&h).contains("drops input"),
        "a hand session files directly"
    );
    let log = ingest(&h);
    let ev = log.lines().find(|l| l.contains("drops input")).unwrap();
    assert!(
        ev.contains(r#""why":"self-check""#) && ev.contains(r#""checked":["dm-1"]"#),
        "{ev}"
    );
    // A row nothing resembles files on the first try.
    ok(&add_as(
        &h,
        &[HAND],
        &[],
        "docs(api): document the export endpoint #low #size/s",
    ));
}

#[test]
fn a_hand_session_files_no_row_without_a_priority_and_no_standing_epic() {
    let h = Home::new("hand-refusals");
    h.systems(Some(SYSTEMS));
    let o = add_as(&h, &[HAND], &[], "fix(ui): the pause menu flickers #size/s");
    assert_eq!(o.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&o.stderr).contains("rules/priority.md"));
    let o = add_human(&h, &[HAND], "epic(ui): ui to standard #low");
    assert_eq!(o.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&o.stderr).contains("standing epic"));
    assert!(ids(&h.board()).is_empty() && ids(&h.sheet()).is_empty());
    // A person's terminal keeps its old freedom: no priority needed.
    ok(&add_as(&h, &[], &[], "fix(ui): typed by a person #size/s"));
}

#[test]
fn an_epic_names_a_system_of_its_project_or_is_refused() {
    let h = Home::new("hand-epic-system");
    h.systems(Some(SYSTEMS));
    for text in [
        "epic(views): no such system #low",
        "epic(menu): an alias, not the id #low",
    ] {
        let o = add_human(&h, &[HAND], text);
        assert_eq!(o.status.code(), Some(1), "{text}");
        let err = String::from_utf8_lossy(&o.stderr);
        assert!(
            err.contains("names no system of demo") && err.contains("ui, docs"),
            "{err}"
        );
    }
    assert!(ids(&h.sheet()).is_empty(), "{}", h.sheet());
    ok(&add_human(
        &h,
        &[HAND],
        "epic(docs): every page has an owner #low",
    ));
    assert!(
        h.sheet().contains("epic(docs): every page has an owner"),
        "{}",
        h.sheet()
    );
    // A queue item's epic waits in the outbox before any system is looked up.
    let o = add_human(
        &h,
        &[("AGENT_QUEUE_ITEM", "ar-9")],
        "epic(views): proposed #low",
    );
    assert_eq!(o.status.code(), Some(4));
}

#[test]
fn a_hand_sessions_want_stamps_its_row_and_a_plan_phase_still_files() {
    let h = Home::new("hand-want");
    let o = add_as(
        &h,
        &[HAND],
        &["--want", "human"],
        "fix(ui): asked for by hand #low #size/s",
    );
    ok(&o);
    // The session is the human's own channel, so their want is the row's, as from their terminal.
    assert!(
        h.board()
            .lines()
            .any(|l| l.contains("asked for by hand") && l.contains("#requested")),
        "{}",
        h.board()
    );
    // NEGATIVE CONTROL: agent-queue filing a plan's phase files directly under a queue item.
    ok(&add_from(
        &h,
        "agent-queue",
        &[
            ("AGENT_QUEUE_ITEM", "ar-9"),
            ("AQ_ITEM_PLAN", "/tmp/plan.md"),
        ],
        &["--agent"],
        &["--origin", "plan"],
        "feat(ui): a plan's phase #size/s",
    ));
    assert_eq!(ids(&h.board()).len(), 2, "{}", h.board());
}

/// This HOME with a second project, `game`, that the registry versions from `demo` (it has
/// `buildTags` and `demo` a `tagGlob`), one human row and one agent row; `own` is the game
/// sheet's own `Version:` line, or "" for none.
fn with_game(h: &Home, own: &str) -> PathBuf {
    let game = h.0.join("notes/projects/current/game");
    fs::create_dir_all(game.join("agent")).unwrap();
    fs::write(
        h.0.join("notes/projects/index.md"),
        "## Current\n- [[projects/current/demo/summary|demo]]\n- [[projects/current/game/summary|game]]\n",
    )
    .unwrap();
    fs::write(game.join("summary.md"), "# game\n").unwrap();
    fs::write(
        game.join("README.md"),
        format!(
            "# game #alpha\n{own}\n## Tasks\n- [ ] feat(ui): a game row #size/s <!-- id:gm-1 -->\n"
        ),
    )
    .unwrap();
    fs::write(
        game.join("agent/README.md"),
        "# game - agent board\n\n## Tasks\n- [ ] fix(ui): a game agent row #size/s <!-- id:gm-2 -->\n",
    )
    .unwrap();
    fs::write(
        h.0.join("map.json"),
        r#"{"trackers": {"demo": {"type": "game", "code": "dm", "tagGlob": "v*"},
            "game": {"type": "game", "code": "gm", "repo": "demo", "buildTags": ["v*-game*"]}}}"#,
    )
    .unwrap();
    game
}

#[test]
fn a_game_with_no_version_of_its_own_is_on_its_parents_version_and_window() {
    let h = Home::new("one-version");
    with_game(&h, "");
    // Its open version is the parent's, and its head tags are still read off its README.
    let out = h.run(&["projects"]);
    ok(&out);
    let list = String::from_utf8_lossy(&out.stdout).into_owned();
    let game_line = list
        .lines()
        .find(|l| l.starts_with("game\t"))
        .unwrap_or_default();
    assert!(game_line.ends_with("\tv0.1.0"), "{list}");
    let out = h.run(&["projects", "--stage", "game"]);
    ok(&out);
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), "alpha");
    // The stats name the parent, which is how wave-roll and fleet-bench know not to cut it.
    let out = h.run(&["projects", "--stats", "--json"]);
    ok(&out);
    let stats = String::from_utf8_lossy(&out.stdout).into_owned();
    assert!(stats.contains(r#""version_parent":"demo""#), "{stats}");
    // A game has no window of its own to commit.
    let out = h.run(&["projects", "--commit", "game"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("demo's window"));
    // The parent's window commits the game's agent row beside its own.
    ok(&h.run(&["projects", "--commit", "demo"]));
    let note =
        fs::read_to_string(h.0.join("notes/projects/current/demo/sprints/v0.1.0.md")).unwrap();
    assert!(note.contains("id:gm-2"), "{note}");
}

#[test]
fn a_game_its_parent_versions_declares_itself_on_its_readme() {
    let h = Home::new("front-page");
    // notes prints the canonical path, so compare against it.
    let game = fs::canonicalize(with_game(&h, "")).unwrap();
    let front = |h: &Home| {
        let out = h.run(&["projects", "--front-page", game.to_str().unwrap()]);
        ok(&out);
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    };
    // The README has no `Version:` line, and its stage tag is still the one the shell reads.
    assert_eq!(front(&h), game.join("README.md").display().to_string());
    // NEGATIVE CONTROL: with no version parent in the registry, the same README is no sheet,
    // and the project declares itself on its summary.
    fs::write(
        h.0.join("map.json"),
        r#"{"trackers": {"demo": {"type": "game", "code": "dm", "tagGlob": "v*"},
            "game": {"type": "game", "code": "gm"}}}"#,
    )
    .unwrap();
    assert_eq!(front(&h), game.join("summary.md").display().to_string());
}

#[test]
fn a_game_that_keeps_its_own_version_stays_out_of_its_parents_window() {
    // NEGATIVE CONTROL for the test above: a game sheet still carrying a `Version:` line is
    // its own number until it is migrated, so nothing reads it twice.
    let h = Home::new("own-version");
    with_game(&h, "Version: v2.1.7\n");
    let out = h.run(&["projects"]);
    let list = String::from_utf8_lossy(&out.stdout).into_owned();
    let game_line = list
        .lines()
        .find(|l| l.starts_with("game\t"))
        .unwrap_or_default();
    assert!(game_line.ends_with("\tv2.1.7"), "{list}");
    let out = h.run(&["projects", "--stats", "--json"]);
    assert!(String::from_utf8_lossy(&out.stdout).contains(r#""version_parent":null"#));
    ok(&h.run(&["projects", "--commit", "demo"]));
    let note =
        fs::read_to_string(h.0.join("notes/projects/current/demo/sprints/v0.1.0.md")).unwrap();
    assert!(!note.contains("id:gm-2"), "{note}");
}

#[test]
fn a_new_game_row_from_a_session_waits_for_the_next_window_of_a_focus_parent() {
    let h = Home::new("game-freeze");
    let game = with_game(&h, "");
    fs::write(
        h.0.join("notes/projects/current/demo/README.md"),
        "# demo\nVersion: v0.1.0 #prio/focus\n\n## Inbox\n\n## Tasks\n",
    )
    .unwrap();
    ok(&h.run(&["projects", "--commit", "demo"]));
    let mut c = h.cmd(&["ptask", "game", "add", "fix(ui): a later game bug #low"]);
    c.env("AGENTCTL_NAME", "inbox-triage");
    ok(&c.output().unwrap());
    let sheet = fs::read_to_string(game.join("README.md")).unwrap();
    let row = sheet
        .lines()
        .find(|l| l.contains("a later game bug"))
        .unwrap_or_default();
    assert!(row.contains("#v0.1.1"), "{sheet}");
}
