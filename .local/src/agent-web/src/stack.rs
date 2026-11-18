//! The Stack tab: what the agent system is made of, from hub-core's `stack`. One read holds its
//! four tables, each filtered and sorted here by `hub_core::table` under its own view keys, so the
//! page only draws.

use std::sync::Arc;

use hub_core::session_actions::System;
use hub_core::stack::{self, Agent, Hook, Rule, RuleFile, Skill, Stack};
use hub_core::table::{Row, Summary, View};
use serde::{Deserialize, Serialize};

use crate::cache::{off, ReadCache};

/// A read lists a few hundred files and runs `fleet-bench rules` (about 3 s), and the stack
/// changes by the PR, so tabs, reloads and each keystroke of a search share one read this long.
const CACHE_SECS: u64 = 120;

/// The view keys, as the page keeps them in its URL: Skills' bare, Agents' `g`-prefixed, Hooks'
/// `k`-prefixed and Rules' `r`-prefixed (static/stack.js `STACK_TABLES`).
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Query {
    pub q: String,
    pub s: String,
    pub sort: String,
    pub dir: String,
    pub gq: String,
    pub gs: String,
    pub gsort: String,
    pub gdir: String,
    pub kq: String,
    pub ks: String,
    pub ksort: String,
    pub kdir: String,
    pub rq: String,
    pub rs: String,
    pub rsort: String,
    pub rdir: String,
}

/// One table with the view applied: the rows it keeps and the controls that drew them.
#[derive(Serialize)]
struct Part<'a, T> {
    rows: Vec<&'a T>,
    table: Summary,
}

fn part<'a, T: Row>(rows: &'a [T], q: &str, s: &str, sort: &str, dir: &str) -> Part<'a, T> {
    let (rows, table) = View::new::<T>(q, s, sort, dir).summary(rows);
    Part { rows, table }
}

#[derive(Serialize)]
struct Shown<'a> {
    at: i64,
    /// Skills' rows and table at the top level, so the tab's first table reads like any other.
    rows: Vec<&'a Skill>,
    table: Summary,
    agents: Part<'a, Agent>,
    hooks: Part<'a, Hook>,
    rules: Part<'a, Rule>,
    rule_files: &'a [RuleFile],
    runners: usize,
    drift_day: &'a str,
    use_days: usize,
    strip: &'a std::collections::BTreeMap<String, usize>,
    errors: &'a [String],
}

pub struct Cache(ReadCache<Stack, CACHE_SECS>);

impl Default for Cache {
    fn default() -> Self {
        Self(ReadCache::new("stack"))
    }
}

fn render(s: &Stack, q: &Query) -> String {
    let skills = part(&s.skills, &q.q, &q.s, &q.sort, &q.dir);
    let out = Shown {
        at: s.at,
        rows: skills.rows,
        table: skills.table,
        agents: part(&s.agents, &q.gq, &q.gs, &q.gsort, &q.gdir),
        hooks: part(&s.hooks, &q.kq, &q.ks, &q.ksort, &q.kdir),
        rules: part(&s.rules, &q.rq, &q.rs, &q.rsort, &q.rdir),
        rule_files: &s.rule_files,
        runners: s.runners,
        drift_day: &s.drift_day,
        use_days: s.use_days,
        strip: &s.strip,
        errors: &s.errors,
    };
    serde_json::to_string(&out).unwrap_or_else(|e| failed(e.to_string()))
}

/// A body the tab can still render when reading itself failed.
fn failed(e: String) -> String {
    serde_json::json!({ "rows": [], "errors": [e] }).to_string()
}

impl Cache {
    /// The view `q` asks for, over the shared read and outside its lock.
    pub async fn get(&self, q: Query) -> String {
        self.read().await.map_or_else(failed, |s| render(&s, &q))
    }

    /// The kept read the tab's views are cut from; `warm` fills it at start (3.6 to 6.7 s cold).
    pub async fn read(&self) -> Result<Arc<Stack>, String> {
        let read = off(|| stack::read(&stack::Paths::from_env(), &System, hub_core::jobs::now()));
        self.0.get((), read).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_table_keeps_its_own_view() {
        let s = Stack {
            skills: vec![
                Skill {
                    name: "shepherd".into(),
                    ..Default::default()
                },
                Skill {
                    name: "debug".into(),
                    ..Default::default()
                },
            ],
            hooks: vec![
                Hook {
                    script: "gone.sh".into(),
                    found: false,
                    ..Default::default()
                },
                Hook {
                    script: "here.sh".into(),
                    found: true,
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let q = Query {
            q: "shep".into(),
            ks: stack::MISSING.into(),
            ..Default::default()
        };
        let v: serde_json::Value = serde_json::from_str(&render(&s, &q)).unwrap();
        assert_eq!(v["rows"].as_array().unwrap().len(), 1, "the skills search");
        assert_eq!(v["rows"][0]["name"], "shepherd");
        assert_eq!(
            v["hooks"]["rows"].as_array().unwrap().len(),
            1,
            "the hooks state"
        );
        assert_eq!(v["hooks"]["rows"][0]["script"], "gone.sh");
        assert_eq!(v["hooks"]["table"]["total"], 2);
        assert_eq!(
            v["table"]["total"], 2,
            "a hooks view does not filter the skills"
        );
    }

    #[test]
    fn a_failed_read_still_gives_the_tab_a_body() {
        let v: serde_json::Value = serde_json::from_str(&failed("gone".into())).unwrap();
        assert_eq!(v["errors"][0], "gone");
    }
}
