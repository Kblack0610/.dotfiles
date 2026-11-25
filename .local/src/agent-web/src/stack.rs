//! The Stack tab: what the agent system is made of, from hub-core's `stack`. One read holds its
//! five tables, each filtered and sorted here by `hub_core::table` under its own view keys, so the
//! page only draws.

use std::sync::Arc;

use hub_core::layout;
use hub_core::session_actions::System;
use hub_core::stack::{self, Agent, Flow, Hook, Rule, RuleFile, Skill, Stack};
use hub_core::table::{self, Row, Summary, View};
use serde::{Deserialize, Serialize};

use crate::cache::{failed, off, ReadCache};

/// A read lists a few hundred files and runs `fleet-bench rules` (about 3 s), and the stack
/// changes by the PR, so tabs, reloads and each keystroke of a search share one read this long.
const CACHE_SECS: u64 = 120;

/// The view keys, as the page keeps them in its URL: Skills' bare, Flows' `f`-prefixed, Agents'
/// `g`-prefixed, Hooks' `k`-prefixed and Rules' `r`-prefixed (static/stack.js `STACK_TABLES`).
/// `pg` is the page.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Query {
    pub fq: String,
    pub fs: String,
    pub fsort: String,
    pub fdir: String,
    pub fpg: String,
    pub q: String,
    pub s: String,
    pub sort: String,
    pub dir: String,
    pub pg: String,
    pub gq: String,
    pub gs: String,
    pub gsort: String,
    pub gdir: String,
    pub gpg: String,
    pub kq: String,
    pub ks: String,
    pub ksort: String,
    pub kdir: String,
    pub kpg: String,
    pub rq: String,
    pub rs: String,
    pub rsort: String,
    pub rdir: String,
    pub rpg: String,
}

/// One table with the view applied: the rows of the page it is on and the controls that drew them.
#[derive(Serialize)]
struct Part<'a, T> {
    rows: Vec<&'a T>,
    table: Summary,
}

/// `section` is the table's inner tab, whose `layout::page_rows` is its page size.
fn part<'a, T: Row>(rows: &'a [T], section: &str, q: [&str; 5]) -> Part<'a, T> {
    let [q, s, sort, dir, pg] = q;
    let (mut rows, mut table) = View::new::<T>(q, s, sort, dir).summary(rows);
    let page = pg.parse().unwrap_or(1);
    table::page(&mut rows, &mut table, page, layout::page_rows(section));
    Part { rows, table }
}

#[derive(Serialize)]
struct Shown<'a> {
    at: i64,
    /// Skills' rows and table at the top level, so the tab's first table reads like any other.
    rows: Vec<&'a Skill>,
    table: Summary,
    flows: Part<'a, Flow>,
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
    let skills = part(&s.skills, "skills", [&q.q, &q.s, &q.sort, &q.dir, &q.pg]);
    let out = Shown {
        at: s.at,
        rows: skills.rows,
        table: skills.table,
        flows: part(&s.flows, "flows", [&q.fq, &q.fs, &q.fsort, &q.fdir, &q.fpg]),
        agents: part(
            &s.agents,
            "agents",
            [&q.gq, &q.gs, &q.gsort, &q.gdir, &q.gpg],
        ),
        hooks: part(&s.hooks, "hooks", [&q.kq, &q.ks, &q.ksort, &q.kdir, &q.kpg]),
        rules: part(&s.rules, "rules", [&q.rq, &q.rs, &q.rsort, &q.rdir, &q.rpg]),
        rule_files: &s.rule_files,
        runners: s.runners,
        drift_day: &s.drift_day,
        use_days: s.use_days,
        strip: &s.strip,
        errors: &s.errors,
    };
    serde_json::to_string(&out).unwrap_or_else(|e| failed(&["rows"], e.to_string()))
}

impl Cache {
    /// The view `q` asks for, over the shared read and outside its lock.
    pub async fn get(&self, q: Query) -> String {
        self.read()
            .await
            .map_or_else(|e| failed(&["rows"], e), |s| render(&s, &q))
    }

    /// Flow `name`'s doc section, read from its file now so an edit shows on the next open, and
    /// whether it has a picture. A name the table does not list is an error.
    pub async fn flow(&self, name: String) -> Result<String, String> {
        let f = self.find(&name).await?;
        // Only a picture the route will serve, so the page never draws a broken image.
        let picture = f
            .svg
            .as_ref()
            .is_some_and(|p| p.is_file() && p.extension().is_some_and(|e| e == "svg"));
        let text = off(move || stack::flow_section(&f)).await?;
        let text = text.ok_or_else(|| format!("{name}: its doc section is gone"))?;
        Ok(serde_json::json!({ "flow": name, "text": text, "picture": picture }).to_string())
    }

    /// Flow `name`'s picture, only the `.svg` its table row names: the route serves no other file.
    pub async fn picture(&self, name: String) -> Result<Vec<u8>, String> {
        let f = self.find(&name).await?;
        let path = f
            .svg
            .filter(|p| p.extension().is_some_and(|x| x == "svg"))
            .ok_or_else(|| format!("{name}: no svg picture"))?;
        off(move || std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))).await?
    }

    async fn find(&self, name: &str) -> Result<Flow, String> {
        self.read()
            .await?
            .flows
            .iter()
            .find(|f| f.flow == name)
            .cloned()
            .ok_or_else(|| format!("no flow {name}"))
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
                    ran: vec![stack::SkillRun {
                        session_id: "6f296b73-b7a5".into(),
                        link: hub_core::links::Link::to(
                            hub_core::links::Kind::Session,
                            "6f296b73-b7a5",
                        ),
                        project: "dotfiles".into(),
                        title: String::new(),
                        updated: String::new(),
                        calls: 2,
                    }],
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
            v["rows"][0]["ran"][0]["link"], "#sessions/sessions/6f296b73-b7a5",
            "a skill row carries the sessions that ran it, each as its page link"
        );
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
    fn each_table_pages_under_its_own_key() {
        let per = layout::page_rows("rules");
        let s = Stack {
            rules: (0..per * 2 + 5)
                .map(|i| Rule {
                    rule: format!("r{i:03}"),
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        };
        let q = Query {
            rpg: "2".into(),
            rsort: "rule".into(),
            rdir: "asc".into(),
            ..Default::default()
        };
        let v: serde_json::Value = serde_json::from_str(&render(&s, &q)).unwrap();
        let rules = &v["rules"];
        assert_eq!(rules["rows"].as_array().unwrap().len(), per);
        assert_eq!(
            rules["rows"][0]["rule"],
            format!("r{per:03}"),
            "page 2 starts after page 1"
        );
        assert_eq!(rules["table"]["pager"]["page"], 2);
        assert_eq!(rules["table"]["pager"]["pages"], 3);
        assert_eq!(
            rules["table"]["shown"],
            per * 2 + 5,
            "shown counts every page"
        );
        assert!(
            v["table"].get("pager").is_none(),
            "an empty skills table is unpaged"
        );
    }
}
