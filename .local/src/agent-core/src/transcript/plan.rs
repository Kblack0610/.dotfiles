//! The plan a session works, from what it wrote, copied and landed.

use std::path::Path;

use serde_json::Value;

use super::read::own_turn;

/// `<dir>/new-curious-garden.md` -> `new-curious-garden`.
pub(super) fn plan_slug(file: &str) -> String {
    Path::new(file)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// The plan file: the last `planFilePath` Claude recorded (plan mode writes it), unless the
/// session later landed a phase against another plan (`agent-land --plan`), copied or moved its
/// plan-mode file under a name of its own, or created a plan of its own and went on writing it
/// (`plans_carried`): it works the plan it lands, copied to or ticks, whichever came last
/// (2026-11-11, unity-core-playground-agent-82 landed every phase of a copy and read the 2/4
/// plan-mode file; 2026-11-12, hub/dotfiles:7 copied its plan to binks-gtm.md, ticked every phase
/// there and read 0/6 from the plan-mode file, ar-2067; 2026-11-20, a takeover that resumed an
/// older plan wrote its own and ticked it there while the older one read 5/6, ar-201). Only a
/// landing, a copy, or a Write or `>` followed by another write of that plan moves it, so
/// editing another plan, or drafting one it never ticks (a follow-up for a queued row, a backup),
/// does not, and writing the plan-mode file again takes it back. Else the plan
/// the session last wrote (`plans_written`), else, until its first reply, the plan its prompt
/// named most: a plan handed in is all a fresh session has, and once it works one it writes it.
/// A plan the session only named (read, grepped, listed, quoted), one a hook attachment lists
/// and one a later prompt names (a pasted screen, a shepherd nudge) are not its plan. Why: a
/// session that grepped another's finished plan took it and was told to wind down (2026-11-03).
/// A session whose last plan-mode entry is an exit with `planExists: false` left plan mode
/// without writing the file, so the plan-mode path is not its plan (a reminder while it drafts
/// carries the same flag and still is). Why: a chat that only toggled out of plan mode read
/// STALLED "its plan file is missing" and was told to restore it (2026-11-18, ar-3088).
pub(super) fn plan_file(text: &str) -> String {
    const KEY: &str = "\"planFilePath\":\"";
    const REATTACHED: &str = "\"type\":\"plan_file_reference\"";
    let plans = crate::session::home().join(".claude/plans");
    let line_of = |at: usize| {
        let start = text[..at].rfind('\n').map_or(0, |s| s + 1);
        &text[start..text[at..].find('\n').map_or(text.len(), |e| at + e)]
    };
    let unwritten_exit = |line: &str| {
        line.contains("\"type\":\"plan_mode_exit\"") && line.contains("\"planExists\":false")
    };
    if let Some(i) = text.rfind(KEY).filter(|&i| !unwritten_exit(line_of(i))) {
        // A compaction re-attaches the plan-mode file (a plan_file_reference attachment): that
        // is not the session choosing it again, so landings count from the last real entry.
        let chosen = text
            .rmatch_indices(KEY)
            .map(|(at, _)| at)
            .find(|&at| !line_of(at).contains(REATTACHED))
            .unwrap_or(i);
        let rest = &text[chosen + KEY.len()..];
        let mode = rest.find('"').map(|end| &rest[..end]);
        // The same file through another account's plans dir (a link to ~/.claude/plans) keeps
        // the path plan mode wrote.
        let mode_name = mode.and_then(|m| m.rsplit('/').next()).unwrap_or("");
        if let Some(name) = plans_carried(&text[chosen..], mode_name).pop() {
            if mode_name != name {
                return plans.join(name).to_string_lossy().into_owned();
            }
        }
        if let Some(m) = mode {
            return m.to_string();
        }
    }
    if let Some(name) = plans_written(text).pop() {
        return plans.join(name).to_string_lossy().into_owned();
    }
    const DIR: &str = "/.claude/plans/";
    const ASSISTANT: &str = "\"type\":\"assistant\"";
    let mut prompt = std::collections::HashMap::new();
    for line in text.lines() {
        if !line.contains(DIR) && !line.contains(ASSISTANT) {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if own_turn(&v) {
            return String::new();
        }
        if v.get("type").and_then(Value::as_str) == Some("user")
            && v.get("isMeta").and_then(Value::as_bool) != Some(true)
        {
            // A typed prompt is a string; a tool result is an array, and is not the prompt.
            if let Some(s) = v.pointer("/message/content").and_then(Value::as_str) {
                count_plans(s, &mut prompt);
            }
        }
    }
    prompt
        .into_iter()
        .max_by(|a, b| a.1.cmp(&b.1).then(b.0.cmp(&a.0)))
        .map(|(name, _)| plans.join(name).to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Which plan references `plans_touched` keeps.
#[derive(Clone, Copy)]
enum Touch<'a> {
    /// Every write: an edit tool (`.config/agent-panel/edit-tools.conf`) and the shell writes of
    /// `bash_plan_refs`.
    Written,
    /// What moves a session's plan off or back onto the plan-mode file named here: an
    /// `agent-land --plan`, the target of a `cp` or `mv` of it, a write of the plan-mode file
    /// itself, and a plan the session created and then wrote again (`Ev::Create`, `Ev::Tick`),
    /// so the last of them is the plan it works.
    Carried(&'a str),
}

/// How a tool call touched a plan under `Touch::Carried`.
#[derive(Clone, Copy, PartialEq)]
enum Ev {
    /// Moves the plan: a landing, a copy of the plan-mode file, a write of it, or any write under
    /// `Touch::Written`.
    Move,
    /// Creates a plan: a Write, a MultiEdit that starts from an empty string, a `>` or a
    /// non-append `tee`. A plan only created is no plan it works: a follow-up it drafts for a
    /// queued row, a backup or an export is not.
    Create,
    /// Writes a plan again: an Edit, `sed -i`, `>>` or `tee -a`. After a `Create` of the same
    /// plan, the session is ticking it.
    Tick,
}

/// The plans the session's own tool calls wrote, oldest first: an edit tool's file_path
/// (edit-tools.conf), or a Bash command that writes one (see `bash_plan_refs`).
fn plans_written(text: &str) -> Vec<String> {
    plans_touched(text, Touch::Written)
        .into_iter()
        .map(|(name, _)| name)
        .collect()
}

/// The plans the session's own tool calls carried its plan `mode` to, oldest first (see
/// `Touch::Carried`): a landing, a copy of `mode`, a write of `mode` that takes it back, or a
/// plan it created and then wrote again.
fn plans_carried(text: &str, mode: &str) -> Vec<String> {
    let mut created = std::collections::HashSet::new();
    let mut out = Vec::new();
    for (name, ev) in plans_touched(text, Touch::Carried(mode)) {
        match ev {
            Ev::Move => out.push(name),
            Ev::Create => {
                created.insert(name);
            }
            Ev::Tick if created.contains(&name) => out.push(name),
            Ev::Tick => {}
        }
    }
    out
}

fn plans_touched(text: &str, touch: Touch) -> Vec<(String, Ev)> {
    let mut out = Vec::new();
    for v in text
        .lines()
        .filter(|l| l.contains("\"tool_use\"") && l.contains("/plans/"))
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(own_turn)
    {
        let Some(blocks) = v.pointer("/message/content").and_then(Value::as_array) else {
            continue;
        };
        for c in blocks
            .iter()
            .filter(|c| c.get("type").and_then(Value::as_str) == Some("tool_use"))
        {
            let input = |k: &str| {
                c.pointer(&format!("/input/{k}"))
                    .and_then(Value::as_str)
                    .unwrap_or("")
            };
            match c.get("name").and_then(Value::as_str).unwrap_or("") {
                // NotebookEdit names notebook_path, so plan_name finds no plan in it.
                tool if super::usage::is_edit_tool(tool) => {
                    let Some(name) = plan_name(input("file_path")) else {
                        continue;
                    };
                    let starts_empty = c
                        .pointer("/input/edits/0/old_string")
                        .and_then(Value::as_str)
                        .is_some_and(str::is_empty);
                    let ev = match touch {
                        Touch::Carried(mode) if name != mode => {
                            if tool == "Write" || (tool == "MultiEdit" && starts_empty) {
                                Ev::Create
                            } else {
                                Ev::Tick
                            }
                        }
                        _ => Ev::Move,
                    };
                    out.push((name.to_string(), ev));
                }
                "Bash" => out.extend(bash_plan_events(input("command"), touch)),
                _ => {}
            }
        }
    }
    out
}

/// The plans a shell command writes: the target of a `>` or `>>` redirect, of `tee` or of
/// `sed -i`, or the `--plan` that agent-land ticks. Reading, grepping, listing or passing one
/// to another command is not writing it. With `Touch::Carried(mode)`, only the agent-land
/// `--plan` ones, the target of a `cp` or `mv` whose source is the plan `mode`, and a write of
/// `mode` itself move it; any other write is a `Create` (a `>` or non-append `tee`) or a `Tick`.
fn bash_plan_events(cmd: &str, touch: Touch) -> Vec<(String, Ev)> {
    const STOP: &[char] = &[' ', '\t', '\n', '\'', '"', '>', '=', '(', '<'];
    if !cmd.contains("/plans/") {
        return Vec::new();
    }
    let cmd = &without_heredoc_bodies(cmd);
    let mut out = Vec::new();
    for (i, _) in cmd.match_indices("/plans/") {
        let start = cmd[..i].rfind(STOP).map_or(0, |s| s + 1);
        let end = cmd[i..]
            .find(|c: char| {
                !(c.is_ascii_alphanumeric()
                    || matches!(c, '-' | '_' | '.' | '/' | '~' | '$' | '{' | '}'))
            })
            .map_or(cmd.len(), |e| i + e);
        let Some(name) = plan_name(&cmd[start..end]) else {
            continue;
        };
        // Only the path's own opening quote goes, so a quoted `'->'` pattern before it is no redirect.
        let before = cmd[..start]
            .strip_suffix(['\'', '"'])
            .unwrap_or(&cmd[..start])
            .trim_end();
        let words = command_words(&before[segment_start(before)..]);
        let cmd_is = |name: &str| {
            words
                .first()
                .is_some_and(|w| w.rsplit('/').next() == Some(name))
        };
        let sed_in_place = |w: &&str| {
            *w == "--in-place" || (w.starts_with('-') && !w.starts_with("--") && w.contains('i'))
        };
        let lands =
            cmd_is("agent-land") && (before.ends_with("--plan") || before.ends_with("--plan="));
        // The source of a copy is the last operand before the target: `cp [-f] <src> <dst>`.
        let copies_mode = |mode: &str| {
            (cmd_is("cp") || cmd_is("mv"))
                && words[1..]
                    .iter()
                    .rev()
                    .find(|w| !w.starts_with('-'))
                    .and_then(|w| plan_name(w.trim_matches(['\'', '"'])))
                    == Some(mode)
        };
        let writes = before.ends_with('>')
            || cmd_is("tee")
            || (cmd_is("sed") && words.iter().any(sed_in_place));
        // A `>` that starts a word (not `->`, `=>` or `>>`), or a `tee` that does not append.
        let creates = before
            .strip_suffix('>')
            .is_some_and(|rest| rest.is_empty() || rest.ends_with(char::is_whitespace))
            || (cmd_is("tee")
                && !words.iter().any(|w| {
                    *w == "--append"
                        || (w.starts_with('-') && !w.starts_with("--") && w.contains('a'))
                }));
        let ev = match touch {
            _ if lands => Ev::Move,
            Touch::Written if writes => Ev::Move,
            Touch::Carried(mode) if copies_mode(mode) || (writes && name == mode) => Ev::Move,
            Touch::Carried(_) if creates => Ev::Create,
            Touch::Carried(_) if writes => Ev::Tick,
            _ => continue,
        };
        out.push((name.to_string(), ev));
    }
    out
}

/// The words of one shell command from its name on: leading `VAR=x` assignments and the
/// wrappers that run the command after them (`timeout`, `env`, `nice`, `nohup`, with their
/// options, an option's argument and timeout's duration) are dropped.
fn command_words(segment: &str) -> Vec<&str> {
    const WRAPPERS: &[&str] = &["timeout", "env", "nice", "nohup"];
    // The wrapper options that take the next word: env -u/-C/-S, timeout -s/-k, nice -n.
    const TAKES_ARG: &[&str] = &["-u", "-C", "-S", "-s", "-k", "-n"];
    let mut words = segment
        .trim_start_matches([' ', '('])
        .split_whitespace()
        .peekable();
    while words
        .next_if(|w| w.contains('=') && !w.starts_with('-'))
        .is_some()
    {}
    while words.next_if(|w| WRAPPERS.contains(w)).is_some() {
        while let Some(w) = words.next_if(|w| {
            w.starts_with('-')
                || w.starts_with(|c: char| c.is_ascii_digit())
                || (w.contains('=') && !w.starts_with('-'))
        }) {
            if TAKES_ARG.contains(&w) {
                words.next();
            }
        }
    }
    words.collect()
}

/// The command with each heredoc body dropped: its lines are data fed to a command (a script, a
/// file's text), not shell, so a plan path in them is no write or landing. The marker line stays,
/// with any redirect on it. A body whose terminator never comes is kept, so a `<<` the scan
/// misreads cannot hide the rest of the command.
fn without_heredoc_bodies(cmd: &str) -> String {
    let mut out = String::with_capacity(cmd.len());
    let mut pending: std::collections::VecDeque<(String, bool)> = Default::default();
    let mut body = String::new();
    for line in cmd.split_inclusive('\n') {
        if let Some((word, dash)) = pending.front() {
            let text = line.trim_end_matches(['\n', '\r']);
            let text = if *dash {
                text.trim_start_matches('\t')
            } else {
                text
            };
            if text == word {
                pending.pop_front();
                if pending.is_empty() {
                    body.clear();
                }
            } else {
                body.push_str(line);
            }
            continue;
        }
        out.push_str(line);
        pending.extend(heredoc_words(line));
    }
    out.push_str(&body);
    out
}

/// The terminators of the heredocs a line opens, in order (`<<EOF`, `<<-'EOF'`, `<< "EOF"`,
/// `<<\EOF`), each with whether it is `<<-` (tab-indented terminator). A `<<` inside quotes, a
/// `<<<` here-string and a shift (`1<<3`) open none.
fn heredoc_words(line: &str) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    let mut quote = None;
    let mut skip_to = 0;
    for (i, c) in line.char_indices() {
        if i < skip_to {
            continue;
        }
        match quote {
            Some(q) if c == q => quote = None,
            Some(_) => {}
            None if c == '\'' || c == '"' => quote = Some(c),
            None if line[i..].starts_with("<<<") => skip_to = i + 3,
            None if line[i..].starts_with("<<") => {
                skip_to = i + 2;
                let rest = &line[i + 2..];
                let dash = rest.starts_with('-');
                let rest = rest.strip_prefix('-').unwrap_or(rest).trim_start();
                let word: String = rest
                    .trim_start_matches(['\'', '"', '\\'])
                    .chars()
                    .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                    .collect();
                if word.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_') {
                    out.push((word, dash));
                }
            }
            None => {}
        }
    }
    out
}

/// Where the last shell command in `s` starts: just past its last `|`, `;`, `&` or newline
/// outside quotes, so a sed script's `;` or `&` does not split it.
fn segment_start(s: &str) -> usize {
    let (mut quote, mut start) = (None, 0);
    for (i, c) in s.char_indices() {
        match (quote, c) {
            (None, '\'' | '"') => quote = Some(c),
            (Some(q), _) if c == q => quote = None,
            (None, '|' | ';' | '&' | '\n') => start = i + 1,
            _ => {}
        }
    }
    start
}

/// The `<name>.md` of a path in a Claude plans dir in the home dir (`~/.claude/plans`, or an
/// account's `~/.claude-<acct>/plans`, a link to it), else None; a repo's `.claude/plans` is not.
fn plan_name(path: &str) -> Option<&str> {
    let (dir, name) = path.rsplit_once('/')?;
    let (config, plans) = dir.rsplit_once('/')?;
    let (home, config) = config.rsplit_once('/')?;
    let in_home = matches!(home, "~" | "$HOME" | "${HOME}")
        || std::path::Path::new(home) == crate::session::home();
    (in_home
        && plans == "plans"
        && config.starts_with(".claude")
        && name.len() > 3
        && name.ends_with(".md"))
    .then_some(name)
}

/// Count each `~/.claude/plans/<name>.md` that `text` names into `counts`.
fn count_plans(text: &str, counts: &mut std::collections::HashMap<String, usize>) {
    const DIR: &str = "/.claude/plans/";
    for (i, _) in text.match_indices(DIR) {
        let rest = &text[i + DIR.len()..];
        let name_len = rest
            .find(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.')))
            .unwrap_or(rest.len());
        let name = &rest[..name_len];
        if name.ends_with(".md") && name.len() > 3 {
            *counts.entry(name.to_string()).or_default() += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::fleet_info;
    use crate::transcript::test_util::*;
    use std::fs;

    fn bash_plan_refs(cmd: &str, touch: Touch) -> Vec<String> {
        bash_plan_events(cmd, touch)
            .into_iter()
            .map(|(name, _)| name)
            .collect()
    }

    #[test]
    fn plan_writes_follow_the_edit_tool_list() {
        let call = |tool: &str, key: &str| {
            format!(
                r#"{{"type":"assistant","message":{{"content":[{{"type":"tool_use","name":"{tool}","input":{{"{key}":"~/.claude/plans/p.md"}}}}]}}}}"#
            )
        };
        // Every name in edit-tools.conf writes the plan its file_path names, so plan.rs keeps
        // no tool list of its own.
        for &(tool, _) in super::super::usage::edit_tools() {
            assert_eq!(plans_written(&call(tool, "file_path")), ["p.md"], "{tool}");
        }
        assert!(plans_written(&call("NotebookEdit", "notebook_path")).is_empty());
        assert!(plans_written(&call("Read", "file_path")).is_empty());
    }

    #[test]
    fn plan_file_falls_back_to_most_named() {
        let p = tmpfile(
            "planref",
            &[
                r#"{"type":"user","message":{"content":"run ~/.claude/plans/a-b.md then /x/.claude/plans/a-b.md, not /x/.claude/plans/c.md"}}"#,
            ],
        );
        assert!(fleet_info(&p).plan_file.ends_with("/.claude/plans/a-b.md"));
        fs::remove_file(&p).ok();
        let none = fleet_info(Path::new("/no/such/file.jsonl"));
        assert_eq!((none.context_tokens, none.plan_file.as_str()), (0, ""));
    }

    #[test]
    fn plan_file_ignores_a_plan_mode_exit_that_never_wrote_one() {
        let exit = r#"{"type":"attachment","attachment":{"type":"plan_mode_exit","planFilePath":"/h/.claude/plans/never.md","planExists":false}}"#;
        let p = tmpfile("neverplan", &[exit, exit]);
        assert_eq!(fleet_info(&p).plan_file, "");
        fs::remove_file(&p).ok();
        let written = r#"{"type":"attachment","attachment":{"type":"plan_mode_exit","planFilePath":"/h/.claude/plans/real.md","planExists":true}}"#;
        let p = tmpfile("realplan", &[exit, written]);
        assert_eq!(fleet_info(&p).plan_file, "/h/.claude/plans/real.md");
        fs::remove_file(&p).ok();
        // Still drafting: plan mode's reminder carries planExists false, and it is the plan.
        let drafting = r#"{"type":"attachment","attachment":{"type":"plan_mode","reminderType":"full","planFilePath":"/h/.claude/plans/draft.md","planExists":false}}"#;
        let p = tmpfile("draftplan", &[drafting]);
        assert_eq!(fleet_info(&p).plan_file, "/h/.claude/plans/draft.md");
        fs::remove_file(&p).ok();
    }

    #[test]
    fn plan_file_ignores_plans_only_the_preflight_and_others_name() {
        // The SessionStart preflight lists other sessions' plans in a hook attachment, a
        // reminder and a tool result echo them; the session's own Read is its plan.
        let preflight = r#"{"type":"attachment","attachment":{"type":"hook_additional_context","content":["Plans: ~/.claude/plans/theirs.md, ~/.claude/plans/theirs.md"]}}"#;
        let p = tmpfile(
            "preflight",
            &[
                preflight,
                r#"{"type":"user","isMeta":true,"message":{"content":"<system-reminder>~/.claude/plans/theirs.md</system-reminder>"}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"~/.claude/plans/mine.md","content":"Phases"}}]}}"#,
                r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"see /h/.claude/plans/theirs.md"}]}}"#,
                r#"{"type":"api-request-blob","message":"~/.claude/plans/theirs.md ~/.claude/plans/theirs.md"}"#,
            ],
        );
        assert!(fleet_info(&p).plan_file.ends_with("/.claude/plans/mine.md"));
        fs::remove_file(&p).ok();

        // 2026-11-03, dotfiles-c2: the human's session grepped, listed and read another
        // session's finished plan; naming it in its own tool calls and text is not writing it.
        let p = tmpfile(
            "grepped",
            &[
                r#"{"type":"user","message":{"content":"why did the probe stall?"}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"grep -in probe ~/.claude/plans/theirs.md; ls ~/.claude/plans/theirs.md"}}]}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/h/.claude/plans/theirs.md"}}]}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"text","text":"/h/.claude/plans/theirs.md has 12 phases"}]}}"#,
            ],
        );
        assert_eq!(fleet_info(&p).plan_file, "");
        fs::remove_file(&p).ok();

        // The plan it wrote last wins over one handed in by its prompt, and an account's plans
        // dir (a link to ~/.claude/plans) is the same dir.
        let p = tmpfile(
            "wrote",
            &[
                r#"{"type":"user","message":{"content":"finish ~/.claude/plans/handed.md"}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"~/.claude/plans/handed.md","old_string":"","new_string":""}}]}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"~/.claude-bnb/plans/mine.md","content":""}}]}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/h/notes/plans/other.md","content":""}}]}}"#,
            ],
        );
        assert!(fleet_info(&p).plan_file.ends_with("/.claude/plans/mine.md"));
        fs::remove_file(&p).ok();

        // A heredoc or redirect writes it, and agent-land --plan ticks it; cat and grep only read.
        let p = tmpfile(
            "bash-wrote",
            &[
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat > ~/.claude/plans/mine.md <<'EOF'\nPhases\nEOF"}}]}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat ~/.claude/plans/theirs.md; grep -n x /h/.claude/plans/theirs.md"}}]}}"#,
            ],
        );
        assert!(fleet_info(&p).plan_file.ends_with("/.claude/plans/mine.md"));
        fs::remove_file(&p).ok();

        // A plan-mode session that copied its plan and landed against the copy works the copy
        // (ar-201), and a compaction re-attaching the plan-mode file does not undo that; editing
        // another plan after plan mode does not move it.
        let mode = r#"{"type":"user","message":{"content":"ok"},"planFilePath":"/h/.claude/plans/mode-file.md"}"#;
        let copied = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cp ~/.claude/plans/mode-file.md ~/.claude/plans/copy.md && agent-land 9 --item x --plan ~/.claude/plans/copy.md --phase 1"}}]}}"#;
        let reattached = r#"{"type":"attachment","attachment":{"type":"plan_file_reference","planFilePath":"/h/.claude/plans/mode-file.md"}}"#;
        let edited = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"~/.claude/plans/sibling.md","old_string":"","new_string":""}}]}}"#;
        let other_mode = r#"{"type":"user","message":{"content":"ok"},"planFilePath":"/h/.claude/plans/other-mode.md"}"#;
        // 2026-11-12, hub/dotfiles:7 (ar-2067): plan mode wrote an account's copy, the session
        // copied it to a name of its own and ticked every phase there.
        let personal_mode = r#"{"type":"attachment","attachment":{"type":"plan_mode"},"planFilePath":"/h/.claude-personal/plans/lazy-soaring-babbage.md"}"#;
        let reattached_personal = r#"{"type":"attachment","attachment":{"type":"plan_file_reference","planFilePath":"/h/.claude-personal/plans/lazy-soaring-babbage.md"}}"#;
        let cp_to_own = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cp ~/.claude-personal/plans/lazy-soaring-babbage.md ~/.claude/plans/binks-gtm.md 2>/dev/null || true; ls -la ~/.claude/plans/binks-gtm.md"}}]}}"#;
        let mv_to_own = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"mv -f \"$HOME/.claude-personal/plans/lazy-soaring-babbage.md\" ~/.claude/plans/binks-gtm.md"}}]}}"#;
        let edited_own = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"~/.claude/plans/binks-gtm.md","old_string":"- [ ]","new_string":"- [x]"}}]}}"#;
        let cp_back = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cp ~/.claude/plans/binks-gtm.md ~/.claude-personal/plans/lazy-soaring-babbage.md; grep -n x ~/.claude-personal/plans/lazy-soaring-babbage.md"}}]}}"#;
        let cp_other = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat ~/.claude-personal/plans/lazy-soaring-babbage.md; cp ~/.claude/plans/theirs.md ~/.claude/plans/binks-gtm.md"}}]}}"#;
        let landed_third = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"agent-land 9 --item x --plan ~/.claude/plans/third.md --phase 1"}}]}}"#;
        let edited_mode = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"~/.claude-personal/plans/lazy-soaring-babbage.md","old_string":"- [ ]","new_string":"- [x]"}}]}}"#;
        let sed_mode = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"sed -i 's/- \\[ \\]/- [x]/' ~/.claude-personal/plans/lazy-soaring-babbage.md"}}]}}"#;
        for (name, lines, want) in [
            // A backup copy taken before it went on writing the plan-mode file is not its plan.
            (
                "backup-then-edited",
                vec![personal_mode, cp_to_own, edited_mode],
                "/h/.claude-personal/plans/lazy-soaring-babbage.md",
            ),
            (
                "backup-then-sed",
                vec![personal_mode, cp_to_own, sed_mode, reattached_personal],
                "/h/.claude-personal/plans/lazy-soaring-babbage.md",
            ),
            (
                "copied-then-edited",
                vec![personal_mode, cp_to_own, edited_own, reattached_personal],
                "/.claude/plans/binks-gtm.md",
            ),
            // Copying the worked plan back over the plan-mode file does not undo the copy.
            (
                "synced-back",
                vec![personal_mode, cp_to_own, edited_own, cp_back],
                "/.claude/plans/binks-gtm.md",
            ),
            (
                "moved",
                vec![personal_mode, mv_to_own],
                "/.claude/plans/binks-gtm.md",
            ),
            // A copy of another plan, or reading the plan-mode file, does not move it.
            (
                "copied-other",
                vec![personal_mode, cp_other, edited_own],
                "/h/.claude-personal/plans/lazy-soaring-babbage.md",
            ),
            // A landing after the copy still wins: the later of the two.
            (
                "copied-then-landed",
                vec![personal_mode, cp_to_own, landed_third],
                "/.claude/plans/third.md",
            ),
            (
                "reattached-older",
                vec![mode, other_mode, reattached],
                "/h/.claude/plans/other-mode.md",
            ),
            ("landed-copy", vec![mode, copied], "/.claude/plans/copy.md"),
            (
                "compacted",
                vec![mode, copied, reattached],
                "/.claude/plans/copy.md",
            ),
            (
                "landed-then-mode",
                vec![copied, mode],
                "/h/.claude/plans/mode-file.md",
            ),
            (
                "edited-sibling",
                vec![mode, edited],
                "/h/.claude/plans/mode-file.md",
            ),
        ] {
            let p = tmpfile(name, &lines);
            assert!(
                fleet_info(&p).plan_file.ends_with(want),
                "{name}: {}",
                fleet_info(&p).plan_file
            );
            fs::remove_file(&p).ok();
        }

        // Named only there, the session has no plan of its own: not someone else's.
        let p = tmpfile(
            "preflight-only",
            &[
                preflight,
                r#"{"type":"assistant","message":{"content":[{"type":"text","text":"on it"}]}}"#,
            ],
        );
        assert_eq!(fleet_info(&p).plan_file, "");
        fs::remove_file(&p).ok();

        // 2026-10-28, dotfiles-4c: a pasted screen quoting a shepherd nudge to another
        // session named its plan; once the session has replied without touching it, it is not its plan.
        let p = tmpfile(
            "pasted",
            &[
                r#"{"type":"user","message":{"content":"Message from @other: every phase in /h/.claude/plans/theirs.md is ticked"}}"#,
                r#"{"type":"assistant","message":{"content":[{"type":"text","text":"checking the log"}]}}"#,
            ],
        );
        assert_eq!(fleet_info(&p).plan_file, "");
        fs::remove_file(&p).ok();
    }

    // 2026-11-20 (ar-201): a takeover resumed an older plan-mode plan, wrote its own and ticked it
    // there; the plan it created and ticked is its plan until it takes the plan-mode file back. A
    // plan it only drafts (a follow-up, a backup), or appends to or sed-s without having created
    // it, is not.
    #[test]
    fn plan_file_follows_a_plan_the_session_creates_and_ticks() {
        let mode = r#"{"type":"user","message":{"content":"ok"},"planFilePath":"/h/.claude/plans/mode-file.md"}"#;
        let reattached = r#"{"type":"attachment","attachment":{"type":"plan_file_reference","planFilePath":"/h/.claude/plans/mode-file.md"}}"#;
        let wrote_own = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"~/.claude/plans/own.md","content":"Phases"}}]}}"#;
        let heredoc_own = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat > ~/.claude/plans/own.md <<'EOF'\nPhases\nEOF"}}]}}"#;
        let appended_other = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo x >> ~/.claude/plans/sibling.md; echo y | tee -a ~/.claude/plans/sibling.md"}}]}}"#;
        let ticked_own = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"~/.claude/plans/own.md","old_string":"- [ ]","new_string":"- [x]"}}]}}"#;
        let sed_own = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"sed -i 's/- \\[ \\]/- [x]/' ~/.claude/plans/own.md"}}]}}"#;
        let multiedit_own = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"MultiEdit","input":{"file_path":"~/.claude/plans/own.md","edits":[{"old_string":"","new_string":"Phases"}]}}]}}"#;
        let backup_redirect = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat ~/.claude/plans/mode-file.md > ~/.claude/plans/mode-file.bak.md; echo ok=> ~/.claude/plans/x.md"}}]}}"#;
        let appended_tee = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo y | tee --append ~/.claude/plans/sibling.md; echo z | tee -ai ~/.claude/plans/sibling.md"}}]}}"#;
        let sed_sibling = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"sed -i 's/a/b/' ~/.claude/plans/sibling.md"}}]}}"#;
        let edited_mode_plain = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"~/.claude/plans/mode-file.md","old_string":"- [ ]","new_string":"- [x]"}}]}}"#;
        for (name, lines, want) in [
            (
                "wrote-own-ticked",
                vec![mode, wrote_own, ticked_own],
                "/.claude/plans/own.md",
            ),
            (
                "heredoc-own-sed",
                vec![mode, heredoc_own, sed_own, reattached],
                "/.claude/plans/own.md",
            ),
            (
                "multiedit-own",
                vec![mode, multiedit_own, ticked_own],
                "/.claude/plans/own.md",
            ),
            (
                "drafted-only",
                vec![mode, wrote_own],
                "/h/.claude/plans/mode-file.md",
            ),
            (
                "backup-redirect",
                vec![mode, backup_redirect],
                "/h/.claude/plans/mode-file.md",
            ),
            (
                "wrote-own-then-mode",
                vec![mode, wrote_own, ticked_own, edited_mode_plain],
                "/h/.claude/plans/mode-file.md",
            ),
            (
                "appended-sibling",
                vec![mode, appended_other, sed_sibling, appended_tee],
                "/h/.claude/plans/mode-file.md",
            ),
        ] {
            let p = tmpfile(name, &lines);
            assert!(
                fleet_info(&p).plan_file.ends_with(want),
                "{name}: {}",
                fleet_info(&p).plan_file
            );
            fs::remove_file(&p).ok();
        }
    }
    #[test]
    fn bash_plan_writes_are_redirects_tee_sed_and_agent_land() {
        for (cmd, want) in [
            ("cat > ~/.claude/plans/a.md <<'EOF'", vec!["a.md"]),
            ("printf x >> \"$HOME/.claude/plans/a.md\"", vec!["a.md"]),
            ("echo x | tee -a ~/.claude-bnb/plans/a.md", vec!["a.md"]),
            (
                "sed -i 's/- \\[ \\]/- [x]/' ~/.claude/plans/a.md",
                vec!["a.md"],
            ),
            (
                "agent-land 12 --item x --plan ~/.claude/plans/a.md --phase y",
                vec!["a.md"],
            ),
            ("agent-land 12 --plan=~/.claude/plans/a.md", vec!["a.md"]),
            (
                "cd ~/w && (A=1 ./.local/bin/agent-land 9 --plan ~/.claude/plans/a.md)",
                vec!["a.md"],
            ),
            (
                "sed -Ei 's/a/b/;s/c/&d/' ~/.claude/plans/a.md && echo ok",
                vec!["a.md"],
            ),
            (
                "sed --in-place -e 's/x|y/z/' ~/.claude/plans/a.md",
                vec!["a.md"],
            ),
            (
                "echo x | tee \"$HOME/.claude/plans/a.md\" >/dev/null",
                vec!["a.md"],
            ),
            ("agent-queue add --plan ~/.claude/plans/a.md", vec![]),
            ("grep -n '->' ~/.claude/plans/a.md", vec![]),
            ("rg \"x>\" ~/.claude/plans/a.md 2>&1", vec![]),
            ("sed -n 's/;/x/p' ~/.claude/plans/a.md", vec![]),
            ("cat > /repo/.claude/plans/a.md", vec![]),
            ("cat ~/.claude/plans/a.md > /tmp/b.md", vec![]),
            ("grep -n x ~/.claude/plans/a.md | sed -n 1p", vec![]),
            (
                "ls -la ~/.claude/plans/a.md ~/.agent/plans/dotfiles/a.md",
                vec![],
            ),
            ("diff ~/.claude/plans/a.md ~/.claude/plans/b.md", vec![]),
            ("cat > ~/notes/plans/a.md", vec![]),
            // A wrapper runs the command after it; a heredoc body is data, its marker line is not.
            (
                "timeout 590 agent-land 9 --item x --plan ~/.claude/plans/a.md",
                vec!["a.md"],
            ),
            (
                "cd ~/w; env A=1 nice -n 5 agent-land 9 --plan=~/.claude/plans/a.md",
                vec!["a.md"],
            ),
            (
                "env -u FOO timeout -s KILL 5 agent-land 9 --plan ~/.claude/plans/a.md",
                vec!["a.md"],
            ),
            ("command -v agent-land --plan ~/.claude/plans/a.md", vec![]),
            ("-x agent-land 9 --plan ~/.claude/plans/a.md", vec![]),
            (
                "cd ~/w; python3 - <<'EOF'\ns = \"x && agent-land 9 --plan ~/.claude/plans/b.md\"\nEOF\ngit status",
                vec![],
            ),
            (
                "cat > ~/.claude/plans/a.md <<-\"END\"\necho y > ~/.claude/plans/b.md\nEND\necho z >> ~/.claude/plans/c.md",
                vec!["a.md", "c.md"],
            ),
            (
                "jq . <<<x\necho y > ~/.claude/plans/a.md",
                vec!["a.md"],
            ),
            (
                "python3 -c \"print(1<<3)\"\necho \"a <<EOF\"\necho y > ~/.claude/plans/a.md",
                vec!["a.md"],
            ),
            (
                "cat <<\\EOF\nagent-land 9 --plan ~/.claude/plans/b.md\nEOF\necho y > ~/.claude/plans/a.md",
                vec!["a.md"],
            ),
            (
                "paste - - <<A 3<<B\necho y > ~/.claude/plans/b.md\nA\necho z > ~/.claude/plans/c.md\nB\necho y > ~/.claude/plans/a.md",
                vec!["a.md"],
            ),
            (
                "cat <<EOF\n  EOF\necho y > ~/.claude/plans/b.md\nEOF",
                vec![],
            ),
            (
                "echo \u{e9}\u{2014} <<EOF\necho y > ~/.claude/plans/b.md\nEOF",
                vec![],
            ),
        ] {
            assert_eq!(bash_plan_refs(cmd, Touch::Written), want, "{cmd}");
        }
        let abs = format!(
            "cat > {}/.claude/plans/a.md",
            crate::session::home().display()
        );
        assert_eq!(bash_plan_refs(&abs, Touch::Written), ["a.md"]);
    }
}
