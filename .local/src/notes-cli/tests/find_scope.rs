//! `notes find` run as the real binary against a throwaway vault: with no `search_dirs` set,
//! a note is found wherever it was filed, and the machine-written dirs stay out.

use std::fs;
use std::process::Command;

#[test]
fn the_default_scope_is_the_whole_vault() {
    let root = std::env::temp_dir().join(format!("find-scope-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    let vault = root.join("notes");
    for (rel, body) in [
        (
            "self/life/Kt gifts_250406.md",
            "- a scarf\n- the record player\n",
        ),
        (
            "journal/daily/2026-11-17.md",
            "# 2026-11-17\nordered the kt gift today\n",
        ),
        (
            "knowledge/home/router.md",
            "# Router\nopenwrt on the edge box\n",
        ),
        ("lab/demo/agent/README.md", "- [ ] kt gift board row\n"),
    ] {
        let p = vault.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    let config = root.join("config.toml");
    fs::write(
        &config,
        format!(
            "vault = \"{v}\"\n[profile.personal]\nroot = \"{v}\"\n",
            v = vault.display()
        ),
    )
    .unwrap();

    let out = Command::new(env!("CARGO_BIN_EXE_notes"))
        .args(["find", "--", "kt gift"])
        .env("HOME", &root)
        .env("NOTES_CONFIG", &config)
        .env("NOTES_PROFILE", "personal")
        .output()
        .unwrap();
    let _ = fs::remove_dir_all(&root);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let found: Vec<String> = String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .map(|l| {
            l.split('\t')
                .next()
                .unwrap()
                .rsplit("/notes/")
                .next()
                .unwrap()
                .to_string()
        })
        .collect();
    assert_eq!(
        found,
        [
            "self/life/Kt gifts_250406.md",
            "journal/daily/2026-11-17.md"
        ],
        "the gifts note leads, the daily note follows, the agent board stays out"
    );
}
