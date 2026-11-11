//! The standing-epic default link: a leaf written with no `#of/`, whose area is one of its
//! project's systems (an id or an alias), goes under that system's standing epic,
//! `epic(<system>): <system> to standard`, which lives on the project's human sheet
//! (`~/.local/src/docs/lifecycle.md`, "What an epic is"). The writer is `notes ptask`
//! (`project_tasks::link_standing`), so every caller of `add` and `file` gets the link
//! without composing it. The vocabulary is `project-stage-check <name> --list --json`, the one
//! list the triager also reads.

use crate::{epics, md, projects};

/// The command that prints a project's systems.
pub(crate) const SYSTEMS_BIN: &str = "project-stage-check";

/// One system of a project: its id and the area words that also name it.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct System {
    pub id: String,
    pub aliases: Vec<String>,
}

/// `name`'s systems, from `<bin> <name> --list --json`. None, with the reason on stderr, when
/// the command is missing or fails (an unknown project, a malformed map): the row is still
/// written, unlinked, since the lookup lives in the dotfiles and a machine without them still
/// has to add a row.
pub(crate) fn systems(bin: &str, name: &str) -> Option<Vec<System>> {
    list(bin, name)
        .map_err(|why| eprintln!("(no standing-epic link: {why})"))
        .ok()
}

/// [`systems`] with the reason returned, not printed: the sweep orders `### Epics` by this list
/// and a project with none (no lab dir, no map entry) is a plain case there, not a fault. Read
/// once per process: one `ptask add` links the row and sweeps the sheet, maybe twice.
pub(crate) fn list(bin: &str, name: &str) -> Result<Vec<System>, String> {
    type Memo = std::collections::HashMap<(String, String), Result<Vec<System>, String>>;
    static MEMO: std::sync::OnceLock<std::sync::Mutex<Memo>> = std::sync::OnceLock::new();
    let key = (bin.to_string(), name.to_string());
    let memo = MEMO.get_or_init(Default::default);
    if let Some(got) = memo.lock().unwrap().get(&key) {
        return got.clone();
    }
    let got = read(bin, name);
    memo.lock().unwrap().insert(key, got.clone());
    got
}

fn read(bin: &str, name: &str) -> Result<Vec<System>, String> {
    let out = match std::process::Command::new(bin)
        .args([name, "--list", "--json"])
        .output()
    {
        Ok(o) if o.status.success() => o.stdout,
        Ok(o) => {
            return Err(format!(
                "{bin} {name} --list exited {}: {}",
                o.status,
                String::from_utf8_lossy(&o.stderr).trim()
            ))
        }
        Err(e) => return Err(format!("{bin}: {e}")),
    };
    parse(&String::from_utf8_lossy(&out))
        .ok_or_else(|| format!("{bin} {name} --list --json printed no system list"))
}

/// The `--list --json` array as systems; None when it is not one.
fn parse(json: &str) -> Option<Vec<System>> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    v.as_array()?
        .iter()
        .map(|s| {
            Some(System {
                id: s.get("id")?.as_str()?.to_string(),
                aliases: s
                    .get("aliases")
                    .and_then(|a| a.as_array())
                    .map(|a| {
                        a.iter()
                            .filter_map(|w| w.as_str().map(str::to_string))
                            .collect()
                    })
                    .unwrap_or_default(),
            })
        })
        .collect()
}

/// The system `area` names: a system's id, else the system one of whose aliases it is.
pub(crate) fn system_of<'a>(systems: &'a [System], area: &str) -> Option<&'a str> {
    let area = area.to_lowercase();
    systems
        .iter()
        .find(|s| s.id == area)
        .or_else(|| systems.iter().find(|s| s.aliases.contains(&area)))
        .map(|s| s.id.as_str())
}

/// Does the row want the default link: a leaf (not an epic) with no `#of/`, typed, so it has
/// an area. Its area, when it does.
pub(crate) fn wants_link(text: &str) -> Option<String> {
    let line = format!("- [ ] {}", text.trim());
    if epics::is_epic(&line) || epics::parent_of(&line).is_some() {
        return None;
    }
    projects::row_type_area(&line).map(|(_, area)| area)
}

/// The text of `system`'s standing epic row.
pub(crate) fn title(system: &str) -> String {
    format!("epic({system}): {system} to standard")
}

/// The id of `system`'s open standing epic on `content` (a human sheet): an open epic row
/// whose area is `system` and whose title is `<system> to standard`, case aside.
pub(crate) fn find(content: &str, system: &str) -> Option<String> {
    content
        .lines()
        .filter(|l| md::is_open_task(l) && epics::is_epic(l))
        .find(|l| {
            projects::row_type_area(l).is_some_and(|(_, a)| a == system)
                && is_standing(system, &projects::row_title(l))
        })
        .and_then(md::row_id)
}

/// Whether an epic of `system` titled `title` is that system's standing epic, case aside.
pub(crate) fn is_standing(system: &str, title: &str) -> bool {
    title.eq_ignore_ascii_case(&format!("{system} to standard"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sys(id: &str, aliases: &[&str]) -> System {
        System {
            id: id.into(),
            aliases: aliases.iter().map(|a| a.to_string()).collect(),
        }
    }

    #[test]
    fn the_list_json_parses_and_anything_else_is_none() {
        let got = parse(
            r#"[{"id":"ui","source":"doc","aliases":[],"is":"x"},{"id":"dispatch","source":"own","aliases":["queue","wt"],"is":"y"}]"#,
        );
        assert_eq!(
            got,
            Some(vec![sys("ui", &[]), sys("dispatch", &["queue", "wt"])])
        );
        assert_eq!(parse("ui\tdoc\t\tx"), None, "the TSV form is not the list");
        assert_eq!(parse(r#"[{"source":"doc"}]"#), None, "an entry with no id");
    }

    #[test]
    fn an_area_names_a_system_by_id_or_alias_and_nothing_else() {
        let s = [sys("dispatch", &["queue"]), sys("ui", &[])];
        assert_eq!(system_of(&s, "ui"), Some("ui"));
        assert_eq!(system_of(&s, "Queue"), Some("dispatch"));
        // NEGATIVE CONTROL: a free word is no system, so the row stays unlinked.
        assert_eq!(system_of(&s, "audio"), None);
    }

    #[test]
    fn only_an_unlinked_typed_leaf_wants_the_link() {
        assert_eq!(
            wants_link("fix(ui): pause menu is slow #size/s").as_deref(),
            Some("ui")
        );
        assert_eq!(
            wants_link("fix(ui): pause menu #of/db-12"),
            None,
            "already linked"
        );
        assert_eq!(
            wants_link("epic(ui): ui to standard"),
            None,
            "an epic is no leaf"
        );
        assert_eq!(wants_link("the pause menu feels slow"), None, "untyped");
    }

    #[test]
    fn the_standing_epic_is_found_only_open_on_its_own_system() {
        let sheet = "## Tasks\n\
            - [x] epic(ui): ui to standard <!-- id:db-1 done:2026-11-01 -->\n\
            - [ ] epic(ui): pause menu redo #new <!-- id:db-2 -->\n\
            - [ ] epic(look): ui to standard <!-- id:db-3 -->\n\
            - [ ] epic(ui): UI to standard #c1106 #high <!-- id:db-4 -->\n";
        assert_eq!(find(sheet, "ui").as_deref(), Some("db-4"));
        assert_eq!(find(sheet, "docs"), None);
        assert_eq!(title("ui"), "epic(ui): ui to standard");
    }
}
