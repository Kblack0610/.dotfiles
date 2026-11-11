//! The shortcuts page (alt-? or F1 in the chooser): every key, the sorts with the current one
//! marked, and the row legend. The panel draws no header bar; this page is where the keys live.

use std::io::{IsTerminal, Write};
use std::process::Command;

use crate::sort::{Sort, KEYS};

const BOLD: &str = "\x1b[1m";
const DIM: &str = "\x1b[2m";
const RESET: &str = "\x1b[0m";

const SECTIONS: &[(&str, &[(&str, &str)])] = &[
    (
        "Move around",
        &[
            ("Enter", "jump to the session"),
            ("Up / Down", "next row (project headers are skipped)"),
            ("type", "search rows, titles, prompts, branch and files"),
            ("A-n", "jump to the next session that needs you"),
            ("C-s", "the shepherd pass running now"),
        ],
    ),
    (
        "Arrange",
        &[
            (
                "S-Tab",
                "grab the row; Up / Down carry it; S-Tab, Enter or Esc drop it",
            ),
            ("", "a grab switches to your order, which the panel keeps"),
            ("C-o", "next sort"),
            ("A-o", "reverse the sort"),
            ("C-y", "only the sessions waiting on you, and back"),
        ],
    ),
    (
        "Act",
        &[
            ("C-n", "new agent in a fresh worktree beside this one"),
            ("C-t", "flip manual (investigate-only) mode"),
            ("C-l", "edit labels (+add -drop ^flip)"),
        ],
    ),
    (
        "Preview",
        &[
            ("C-/", "stacked, side by side, hidden"),
            ("C-d / C-u", "half a page down / up"),
            ("PgDn / PgUp", "a page"),
        ],
    ),
];

const LEGEND: &[(&str, &str)] = &[
    ("\x1b[1;31m!\x1b[0m", "waiting at a prompt or dialog"),
    ("\x1b[1;33m~\x1b[0m", "busy"),
    ("\x1b[1;32m✓\x1b[0m", "idle"),
    ("\x1b[35mP\x1b[0m / M", "plan mode / manual mode"),
    ("\x1b[34mA\x1b[0m", "holds a pending ask"),
    (
        "45m",
        "open this long (under recent: since its last activity)",
    ),
];

/// The page text, the current sort marked.
pub fn text(current: Sort) -> String {
    let mut out = format!("{BOLD}agent panel shortcuts{RESET}\n");
    for (title, keys) in SECTIONS {
        out.push_str(&format!("\n{BOLD}{title}{RESET}\n"));
        for (key, what) in *keys {
            out.push_str(&format!("  {key:<12} {what}\n"));
        }
    }
    out.push_str(&format!(
        "\n{BOLD}Sorts{RESET} {DIM}(C-o steps through them){RESET}\n"
    ));
    for (key, word, label) in KEYS {
        let line = format!("{word:<8} {label}");
        if key == current.key {
            let dir = if current.reverse { ", reversed" } else { "" };
            out.push_str(&format!("> {BOLD}{line}{dir}{RESET}\n"));
        } else {
            out.push_str(&format!("  {DIM}{line}{RESET}\n"));
        }
    }
    out.push_str(&format!("\n{BOLD}Row{RESET}\n"));
    for (mark, what) in LEGEND {
        out.push_str(&format!("  {mark}  {what}\n"));
    }
    out
}

/// Print the page; on a terminal, clear it first and hold the page until a key is pressed.
pub fn run(current: Sort) -> anyhow::Result<()> {
    let tty = std::io::stdout().is_terminal();
    let mut out = std::io::stdout();
    if tty {
        write!(out, "\x1b[2J\x1b[H")?;
    }
    write!(out, "{}", text(current))?;
    if tty {
        write!(out, "\n{DIM}any key to go back{RESET}")?;
        out.flush()?;
        // One key, raw, from the terminal; the settings are put back as they were.
        let _ = Command::new("sh")
            .arg("-c")
            .arg("s=$(stty -g </dev/tty); stty -icanon -echo min 1 </dev/tty; dd bs=1 count=1 </dev/tty >/dev/null 2>&1; stty \"$s\" </dev/tty")
            .status();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sort::Key;

    #[test]
    fn the_page_names_every_key_the_panel_binds_and_marks_the_current_sort() {
        let page = text(Sort {
            key: Key::Recent,
            reverse: true,
        });
        for key in [
            "S-Tab", "C-o", "A-o", "C-y", "C-n", "C-t", "C-l", "C-s", "A-n", "C-/",
        ] {
            assert!(page.contains(key), "{key} missing");
        }
        assert!(page.contains(&format!(
            "> {BOLD}recent   most recent activity first, reversed"
        )));
        // Negative control: a sort that is not current carries no marker.
        assert!(page.contains(&format!("  {DIM}project  by project{RESET}")));
        assert!(!page.contains("> \x1b[1mproject"));
    }
}
