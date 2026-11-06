//! Which Claude account a session runs on: a port of `config_dir_of`, `norm_dir` and
//! `name_of` in `.local/bin/claude-acct`, which owns the accounts file. Read-only here.
//!
//! An account is a `CLAUDE_CONFIG_DIR`. The accounts file has one `name dir` per line, `-`
//! for the default (`~/.claude`) account and `#` for a comment; a process with no
//! `CLAUDE_CONFIG_DIR`, or one set to `~/.claude`, is on the default account. A process with
//! `ANTHROPIC_BASE_URL` set (claude-lazer) runs on the Lazer gateway, on no account: it is
//! named `gateway`, the `account:` a queue item started on a gateway harness records.

use std::fs;
use std::path::{Path, PathBuf};

/// One line of the accounts file. `dir` is empty for the default account.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Account {
    pub name: String,
    pub dir: String,
}

/// `$CLAUDE_ACCT_CONFIG`, else `${XDG_CONFIG_HOME:-$HOME/.config}/claude-acct/accounts`.
pub fn accounts_file() -> PathBuf {
    if let Some(p) = std::env::var_os("CLAUDE_ACCT_CONFIG") {
        return PathBuf::from(p);
    }
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::session::home().join(".config"));
    base.join("claude-acct").join("accounts")
}

/// `$CLAUDE_ACCT_PROC`, else `/proc`: the same override claude-acct's tests use.
pub fn proc_root() -> PathBuf {
    std::env::var_os("CLAUDE_ACCT_PROC")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/proc"))
}

/// Parse the accounts file text, as claude-acct `accounts` reads it (`~` is `home`).
pub fn parse(text: &str, home: &Path) -> Vec<Account> {
    text.lines()
        .filter_map(|l| {
            let mut f = l.split_whitespace();
            let name = f.next()?;
            if name.starts_with('#') {
                return None;
            }
            let dir = f.next().unwrap_or("");
            let dir = match dir {
                "-" => String::new(),
                d => match d.strip_prefix('~') {
                    Some(rest) => format!("{}{rest}", home.display()),
                    None => d.to_string(),
                },
            };
            Some(Account {
                name: name.to_string(),
                dir,
            })
        })
        .collect()
}

/// The accounts in the accounts file; empty when there is none.
pub fn load() -> Vec<Account> {
    let home = crate::session::home();
    parse(
        &fs::read_to_string(accounts_file()).unwrap_or_default(),
        &home,
    )
}

/// The account dir as the accounts file spells it: no trailing `/`, empty for `~/.claude`.
pub fn norm_dir(dir: &str, home: &Path) -> String {
    let d = dir.strip_suffix('/').unwrap_or(dir);
    if Path::new(d) == home.join(".claude") {
        String::new()
    } else {
        d.to_string()
    }
}

/// The value of `var` in process `pid`'s environment; empty when unset or unreadable.
fn env_of(proc_root: &Path, pid: u32, var: &str) -> String {
    let raw = fs::read(proc_root.join(pid.to_string()).join("environ")).unwrap_or_default();
    let key = format!("{var}=");
    raw.split(|b| *b == 0)
        .find_map(|kv| kv.strip_prefix(key.as_bytes()))
        .map(|v| String::from_utf8_lossy(v).into_owned())
        .unwrap_or_default()
}

/// The `CLAUDE_CONFIG_DIR` process `pid` runs under, normalised; empty for the default
/// account or when its environment cannot be read.
pub fn config_dir_of(proc_root: &Path, pid: u32, home: &Path) -> String {
    norm_dir(&env_of(proc_root, pid, "CLAUDE_CONFIG_DIR"), home)
}

/// The account's name for a dir, else the dir itself, else `default`.
pub fn name_of(dir: &str, accounts: &[Account]) -> String {
    accounts
        .iter()
        .find(|a| a.dir == dir)
        .map(|a| a.name.clone())
        .unwrap_or_else(|| {
            if dir.is_empty() {
                "default".into()
            } else {
                dir.into()
            }
        })
}

/// The account name process `pid` runs on, or `gateway` for one on the Lazer gateway: the
/// shepherd must never move or park that one onto an account.
pub fn of_pid(proc_root: &Path, pid: u32, home: &Path, accounts: &[Account]) -> String {
    if !env_of(proc_root, pid, "ANTHROPIC_BASE_URL").is_empty() {
        return "gateway".into();
    }
    name_of(&config_dir_of(proc_root, pid, home), accounts)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(tag: &str) -> PathBuf {
        let root =
            std::env::temp_dir().join(format!("agent-panel-acct-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        root
    }

    fn environ(root: &Path, pid: u32, vars: &[&str]) {
        let d = root.join(pid.to_string());
        fs::create_dir_all(&d).unwrap();
        let mut b = vec![];
        for v in vars {
            b.extend_from_slice(v.as_bytes());
            b.push(0);
        }
        fs::write(d.join("environ"), b).unwrap();
    }

    #[test]
    fn parses_the_accounts_file_like_claude_acct() {
        let home = Path::new("/home/u");
        let got = parse(
            "# comment\nmain -\n\nalt ~/.claude-personal\nbnb /home/u/.claude-bnb\n",
            home,
        );
        let names: Vec<(&str, &str)> = got
            .iter()
            .map(|a| (a.name.as_str(), a.dir.as_str()))
            .collect();
        assert_eq!(
            names,
            [
                ("main", ""),
                ("alt", "/home/u/.claude-personal"),
                ("bnb", "/home/u/.claude-bnb")
            ]
        );
    }

    #[test]
    fn resolves_a_process_to_its_account() {
        let home = Path::new("/home/u");
        let accts = parse("main -\nbnb ~/.claude-bnb\n", home);
        let proc = fixture("resolve");
        environ(
            &proc,
            10,
            &["TERM=x", "CLAUDE_CONFIG_DIR=/home/u/.claude-bnb/"],
        );
        environ(&proc, 11, &["TERM=x"]);
        environ(&proc, 12, &["CLAUDE_CONFIG_DIR=/home/u/.claude"]);
        environ(&proc, 13, &["CLAUDE_CONFIG_DIR=/srv/other"]);
        // claude-lazer: no CLAUDE_CONFIG_DIR, so the default dir, but on the gateway.
        environ(
            &proc,
            14,
            &["TERM=x", "ANTHROPIC_BASE_URL=https://llm.example"],
        );
        let got: Vec<String> = [10, 11, 12, 13, 14, 99]
            .iter()
            .map(|p| of_pid(&proc, *p, home, &accts))
            .collect();
        let _ = fs::remove_dir_all(&proc);
        // 13 is in no account line, so it is named by its dir; 99 has no /proc entry.
        assert_eq!(
            got,
            ["bnb", "main", "main", "/srv/other", "gateway", "main"]
        );
    }

    #[test]
    fn with_no_accounts_file_the_default_dir_is_default() {
        assert_eq!(name_of("", &[]), "default");
        assert_eq!(norm_dir("/home/u/.claude/", Path::new("/home/u")), "");
    }
}
