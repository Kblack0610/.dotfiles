//! `notes find <query>` - ranked free-text and tag lookup over the vault's prose.
//!
//! Read-only and on-demand, like `notes tags`: every call reads `Profile::search_dirs`, so
//! there is no index file to go stale and no timer to run. The scan is split across threads.
//!
//! Query syntax: bare words are OR-ed and ranked, `#tag` is a hard filter (frontmatter or
//! inline tag), `"a phrase"` earns a bonus when it appears verbatim, `-word` drops any note
//! containing the word. A query of only `#tag`s lists every note carrying them.
//!
//! Ranking is BM25 over weighted fields (title, tags, path, summary, headings, body), times
//! coverage squared (share of query words a note matches), so a note with every word beats
//! one with some, yet partial matches still show. A word missing from the vocabulary falls
//! back to vocabulary words it prefixes (for a half-typed last word), else to its nearest
//! word by edit distance (for a typo). Synonym groups are data, in
//! `<vault>/.search/aliases.toml`, never in this file.

use crate::config::Profile;
use crate::index::extract_tags;
use crate::md;
use crate::tags::collect_md;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

/// Directory names under a search root that hold machine-written logs, release notes or task
/// boards rather than knowledge: `_log` is the knowledge engine's diary, `versions` and
/// `agent` are lab release notes and agent boards (the largest files in lab/, and all rows).
const SKIP_DIRS: [&str; 3] = ["_log", "versions", "agent"];
/// Field weights for BM25F. Title, tags and path name the topic; the body only mentions it.
const W_TITLE: f64 = 3.0;
const W_TAGS: f64 = 3.0;
const W_PATH: f64 = 2.0;
const W_SUMMARY: f64 = 2.0;
const W_HEADING: f64 = 2.0;
const W_BODY: f64 = 1.0;
const K1: f64 = 1.2;
const B: f64 = 0.75;
/// Weight of a word reached through an alias group, a prefix or a typo fix, against 1.0 for
/// the word as typed.
const W_ALIAS: f64 = 0.6;
const W_PREFIX: f64 = 0.7;
const W_TYPO: f64 = 0.8;
/// How many vocabulary words a half-typed word may expand to (most common first).
const MAX_PREFIX: usize = 8;
/// A compiled knowledge article outranks a raw journal or lab note on the same words.
const KNOWLEDGE_BOOST: f64 = 1.25;
const PHRASE_BOOST: f64 = 1.5;
/// How deep `--eval` looks for an expected note before calling it a miss.
const EVAL_DEPTH: usize = 50;
/// Longest snippet printed per hit.
const SNIPPET_MAX: usize = 160;
/// Words too common to carry meaning in a question ("how did I set up sso").
const STOPWORDS: &[&str] = &[
    "a", "an", "and", "are", "as", "at", "be", "by", "can", "did", "do", "does", "for", "from",
    "has", "have", "how", "i", "in", "is", "it", "its", "me", "my", "of", "on", "or", "our", "set",
    "so", "that", "the", "this", "to", "up", "use", "was", "we", "what", "when", "where", "which",
    "who", "why", "with", "you",
];

/// A parsed query.
#[derive(Debug, Default, PartialEq)]
pub struct Query {
    pub words: Vec<String>,
    pub tags: Vec<String>,
    pub phrases: Vec<String>,
    pub exclude: Vec<String>,
    /// (word, the word joined to its neighbour): `back up` also asks for `backup`, `log in`
    /// for `login`. Taken before stopwords go, since the second half is often one.
    pub joins: Vec<(String, String)>,
}

pub fn parse_query(q: &str) -> Query {
    let mut out = Query::default();
    let mut rest = String::new();
    // Pull out "quoted phrases" first; their words also count as query words.
    let mut in_quote = false;
    let mut cur = String::new();
    for c in q.chars() {
        if c == '"' {
            if in_quote && !cur.trim().is_empty() {
                out.phrases.push(cur.trim().to_lowercase());
                rest.push(' ');
                rest.push_str(&cur);
                rest.push(' ');
            }
            cur.clear();
            in_quote = !in_quote;
        } else if in_quote {
            cur.push(c);
        } else {
            rest.push(c);
        }
    }
    if in_quote {
        rest.push_str(&cur); // an unclosed quote is just words
    }
    for tok in rest.split_whitespace() {
        if let Some(t) = tok.strip_prefix('#') {
            let t =
                t.trim_matches(|c: char| !c.is_alphanumeric() && c != '-' && c != '/' && c != '_');
            if !t.is_empty() {
                out.tags.push(t.to_lowercase());
            }
        } else if let Some(w) = tok.strip_prefix('-').filter(|w| !w.is_empty()) {
            out.exclude.extend(tokenize(w));
        } else {
            out.words.extend(tokenize(tok));
        }
    }
    for pair in out.words.windows(2) {
        let joined = stem(&format!("{}{}", pair[0], pair[1]));
        out.joins.push((pair[0].clone(), joined.clone()));
        out.joins.push((pair[1].clone(), joined));
    }
    let content: Vec<String> = out
        .words
        .iter()
        .filter(|w| !STOPWORDS.contains(&w.as_str()))
        .cloned()
        .collect();
    if !content.is_empty() {
        out.words = content;
    }
    let mut seen = HashSet::new();
    out.words.retain(|w| seen.insert(w.clone()));
    out
}

/// Call `f` with each token of `text`: a lowercase alphanumeric run of length 2+ (or any
/// digit run), stemmed. One reused buffer, no allocation per token: this loop is the scan.
fn for_each_token(text: &str, mut f: impl FnMut(&str)) {
    let mut buf = String::with_capacity(32);
    let mut flush = |buf: &mut String| {
        if !buf.is_empty() {
            if buf.len() >= 2 || buf.bytes().all(|c| c.is_ascii_digit()) {
                stem_in_place(buf);
                f(buf);
            }
            buf.clear();
        }
    };
    for c in text.chars() {
        if c.is_ascii_alphanumeric() {
            buf.push(c.to_ascii_lowercase());
        } else if c.is_alphanumeric() {
            buf.extend(c.to_lowercase());
        } else {
            flush(&mut buf);
        }
    }
    flush(&mut buf);
}

/// Tokens of `text` as owned strings (queries, aliases).
pub fn tokenize(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for_each_token(text, |t| out.push(t.to_string()));
    out
}

/// A light suffix stemmer: enough that "tests", "testing" and "tested" meet "test", applied
/// the same way to notes and queries, so its odd outputs ("bas" for "based") still match.
pub fn stem(w: &str) -> String {
    let mut s = w.to_string();
    stem_in_place(&mut s);
    s
}

fn stem_in_place(w: &mut String) {
    let n = w.len();
    if !w.is_ascii() {
        return;
    }
    if n > 4 && w.ends_with("ies") {
        w.truncate(n - 3);
        w.push('y');
    } else if n > 5 && w.ends_with("ing") {
        w.truncate(n - 3);
    } else if n > 4
        && ((w.ends_with("ed") && !w.ends_with("eed"))
            || w.ends_with("sses")
            || w.ends_with("xes")
            || w.ends_with("ches")
            || w.ends_with("shes"))
    {
        w.truncate(n - 2);
    } else if n > 3
        && w.ends_with('s')
        && !w.ends_with("ss")
        && !w.ends_with("us")
        && !w.ends_with("is")
    {
        w.truncate(n - 1);
    }
}

/// FxHash (the rustc hasher): the scan hashes every token of the vault, and std's SipHash,
/// built to resist hash flooding from untrusted keys, was half the CPU of a lookup.
#[derive(Default, Clone, Copy)]
struct Fx(u64);

impl std::hash::Hasher for Fx {
    fn write(&mut self, bytes: &[u8]) {
        for chunk in bytes.chunks(8) {
            let mut b = [0u8; 8];
            b[..chunk.len()].copy_from_slice(chunk);
            self.0 = (self.0.rotate_left(5) ^ u64::from_le_bytes(b))
                .wrapping_mul(0x51_7c_c1_b7_27_22_0a_95);
        }
    }
    fn write_u8(&mut self, i: u8) {
        self.0 = (self.0.rotate_left(5) ^ u64::from(i)).wrapping_mul(0x51_7c_c1_b7_27_22_0a_95);
    }
    fn finish(&self) -> u64 {
        self.0
    }
}

type TermMap = HashMap<String, f64, std::hash::BuildHasherDefault<Fx>>;

/// One searchable note: per-term weighted frequency, length, and what a hit prints.
struct Doc {
    path: PathBuf,
    title: String,
    tags: HashSet<String>,
    /// term -> field-weighted term frequency
    tf: TermMap,
    len: f64,
    knowledge: bool,
    /// Under the lab tree, where task rows are project sheets and boards, not notes.
    sheet: bool,
    /// Folder names on the path, stemmed: `#interview` also matches a note under `interviews/`.
    dirs: HashSet<String>,
    content: String,
}

fn front_matter(content: &str) -> (&str, &str) {
    if let Some(body) = content.strip_prefix("---\n") {
        if let Some(end) = body.find("\n---") {
            let after = &body[end + 4..];
            let after = after.strip_prefix('\n').unwrap_or(after);
            return (&body[..end], after);
        }
    }
    ("", content)
}

fn add(tf: &mut TermMap, text: &str, w: f64) -> usize {
    let mut n = 0;
    for_each_token(text, |t| {
        n += 1;
        match tf.get_mut(t) {
            Some(v) => *v += w,
            None => {
                tf.insert(t.to_string(), w);
            }
        }
    });
    n
}

fn parse_doc(path: &Path, content: &str, roots: &Roots) -> Doc {
    let (fm, body) = front_matter(content);
    let mut tf = TermMap::default();
    let mut len = 0usize;
    let title = md::parse_yaml_scalar(fm, "title")
        .or_else(|| {
            body.lines()
                .find_map(|l| l.strip_prefix("# ").map(|t| t.trim().to_string()))
        })
        .unwrap_or_else(|| {
            path.file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string()
        });
    len += add(&mut tf, &title, W_TITLE);
    let mut tags: HashSet<String> = extract_tags(content)
        .into_iter()
        .map(|t| t.to_lowercase())
        .collect();
    for line in body.lines().filter(|l| l.contains('#')) {
        for t in md::find_hashtags(line) {
            tags.insert(t);
        }
    }
    for t in &tags {
        len += add(&mut tf, t, W_TAGS);
    }
    // Relative to the vault, so path words and `#folder` filters never see the home dir; a
    // note outside the vault (a custom search dir) scores by its file name alone.
    let rel = path
        .strip_prefix(&roots.vault)
        .unwrap_or_else(|_| Path::new(path.file_name().unwrap_or_default()));
    len += add(&mut tf, &rel.with_extension("").to_string_lossy(), W_PATH);
    for key in ["summary", "description"] {
        if let Some(s) = md::parse_yaml_scalar(fm, key) {
            len += add(&mut tf, &s, W_SUMMARY);
        }
    }
    let knowledge = path.starts_with(&roots.knowledge);
    let sheet = path.starts_with(&roots.sheets);
    for line in body.lines() {
        let t = line.trim_start();
        // A task row on a lab sheet is a to-do, not knowledge: the boards are thousands of
        // them, and counted they bury the prose. Elsewhere a checklist is how a note was
        // written (interview notes are often all `- [ ]` rows), so it counts.
        if sheet && md::is_task(t) {
            continue;
        }
        let w = if t.starts_with('#') && t.trim_start_matches('#').starts_with(' ') {
            W_HEADING
        } else {
            W_BODY
        };
        len += add(&mut tf, t, w);
    }
    Doc {
        path: path.to_path_buf(),
        title,
        tags,
        tf,
        len: len as f64,
        knowledge,
        sheet,
        dirs: rel
            .parent()
            .map(|d| tokenize(&d.to_string_lossy()).into_iter().collect())
            .unwrap_or_default(),
        content: content.to_string(),
    }
}

/// Every `.md` under the search dirs, minus [`SKIP_DIRS`] and hidden dirs, each read once.
fn files(dirs: &[PathBuf]) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for d in dirs {
        let mut found = Vec::new();
        collect_md(d, &mut found);
        // Only the part below the search dir counts: a root that itself sits under a dir
        // named `agent` or `versions` must not lose every note.
        found.retain(|p| {
            !p.strip_prefix(d).unwrap_or(p).components().any(|c| {
                c.as_os_str()
                    .to_str()
                    .is_some_and(|s| SKIP_DIRS.contains(&s))
            })
        });
        out.append(&mut found);
    }
    out.sort();
    out.dedup();
    out
}

/// The trees a note's place is judged by: the vault (paths are shown and tokenized relative
/// to it), knowledge/ (boosted) and lab/, the project sheets (task rows skipped).
struct Roots {
    vault: PathBuf,
    knowledge: PathBuf,
    sheets: PathBuf,
}

impl Roots {
    fn of(p: &Profile) -> Self {
        Roots {
            vault: p.vault.clone(),
            knowledge: p.knowledge.clone(),
            sheets: p.vault.join("lab"),
        }
    }
}

/// Parse every file across the machine's cores (std threads, no crate). Workers pull the
/// next file from a shared counter, so one thread never gets every big file.
fn load(dirs: &[PathBuf], roots: &Roots) -> Vec<Doc> {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let paths = files(dirs);
    let next = AtomicUsize::new(0);
    let n = std::thread::available_parallelism()
        .map_or(4, |n| n.get())
        .min(16);
    std::thread::scope(|s| {
        let handles: Vec<_> = (0..n)
            .map(|_| {
                s.spawn(|| {
                    let mut out = Vec::new();
                    loop {
                        let i = next.fetch_add(1, Ordering::Relaxed);
                        let Some(p) = paths.get(i) else { break };
                        if let Ok(c) = fs::read_to_string(p) {
                            out.push(parse_doc(p, &c, roots));
                        }
                    }
                    out
                })
            })
            .collect();
        let mut docs: Vec<Doc> = handles
            .into_iter()
            // A worker that panicked would otherwise drop its share of the vault silently.
            .flat_map(|h| h.join().unwrap_or_else(|e| std::panic::resume_unwind(e)))
            .collect();
        docs.sort_by(|a, b| a.path.cmp(&b.path));
        docs
    })
}

/// Synonym groups from `<vault>/.search/aliases.toml`: `groups = [["oauth", "sso"], ...]`.
#[derive(Deserialize, Default)]
struct AliasFile {
    #[serde(default)]
    groups: Vec<Vec<String>>,
}

pub fn aliases_path(p: &Profile) -> PathBuf {
    p.vault.join(".search/aliases.toml")
}

fn load_aliases(path: &Path) -> Result<HashMap<String, Vec<String>>> {
    let mut map: HashMap<String, Vec<String>> = HashMap::new();
    let Ok(text) = fs::read_to_string(path) else {
        return Ok(map);
    };
    let f: AliasFile =
        toml::from_str(&text).with_context(|| format!("parse {}", path.display()))?;
    for g in f.groups {
        let words: Vec<String> = g.iter().flat_map(|w| tokenize(w)).collect();
        for w in &words {
            let e = map.entry(w.clone()).or_default();
            e.extend(words.iter().filter(|o| *o != w).cloned());
        }
    }
    Ok(map)
}

/// Optimal-string-alignment distance (an adjacent swap like "secruity" is one edit),
/// bounded: None once every cell in a row passes `max`.
fn edit_distance(a: &str, b: &str, max: usize) -> Option<usize> {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    if a.len().abs_diff(b.len()) > max {
        return None;
    }
    let mut prev2: Vec<usize> = vec![0; b.len() + 1];
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut cur = vec![i; b.len() + 1];
        for j in 1..=b.len() {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                cur[j] = cur[j].min(prev2[j - 2] + 1);
            }
        }
        if cur.iter().min().is_some_and(|m| *m > max) {
            return None;
        }
        prev2 = std::mem::replace(&mut prev, cur);
    }
    (prev[b.len()] <= max).then_some(prev[b.len()])
}

/// Each query word -> the (term, weight) list it scores with.
fn expand(
    words: &[String],
    joins: &[(String, String)],
    docs: &[Doc],
    aliases: &HashMap<String, Vec<String>>,
) -> Vec<Vec<(String, f64)>> {
    let present = |w: &str| docs.iter().any(|d| d.tf.contains_key(w));
    let missing: Vec<bool> = words.iter().map(|w| !present(w)).collect();
    // The whole vocabulary (term -> doc count) is built only when a word needs a prefix or
    // typo fallback: it is the costly part of a lookup.
    // Fallback candidates share the missing word's first letter: a typo or a half-typed word
    // nearly always keeps it, and the filter skips most of the vocabulary.
    let firsts: HashSet<char> = words
        .iter()
        .zip(&missing)
        .filter(|(_, m)| **m)
        .filter_map(|(w, _)| w.chars().next())
        .collect();
    let mut df: HashMap<&str, usize, std::hash::BuildHasherDefault<Fx>> = HashMap::default();
    if !firsts.is_empty() {
        for d in docs {
            for t in d.tf.keys() {
                if t.chars().next().is_some_and(|c| firsts.contains(&c)) {
                    *df.entry(t.as_str()).or_default() += 1;
                }
            }
        }
    }
    words
        .iter()
        .map(|w| {
            let mut terms = vec![(w.clone(), 1.0)];
            if let Some(al) = aliases.get(w) {
                terms.extend(al.iter().map(|a| (a.clone(), W_ALIAS)));
            }
            for (_, joined) in joins.iter().filter(|(jw, j)| jw == w && present(j)) {
                terms.push((joined.clone(), 1.0));
            }
            if !present(w) {
                let mut pre: Vec<(&str, usize)> = if w.chars().count() >= 3 {
                    df.iter()
                        .filter(|(t, _)| t.starts_with(w.as_str()) && t.len() > w.len())
                        .map(|(t, n)| (*t, *n))
                        .collect()
                } else {
                    Vec::new()
                };
                if !pre.is_empty() {
                    pre.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
                    terms.extend(
                        pre.iter()
                            .take(MAX_PREFIX)
                            .map(|(t, _)| (t.to_string(), W_PREFIX)),
                    );
                } else if w.chars().count() >= 5 {
                    // Under five letters a word sits one edit from too many others (`raft` and
                    // `pkce` each found an unrelated note), so a short unknown word gets no fuzz.
                    let max = if w.chars().count() <= 6 { 1 } else { 2 };
                    let best = df
                        .iter()
                        .filter_map(|(t, n)| {
                            edit_distance(w, t, max).map(|d| (d, std::cmp::Reverse(*n), *t))
                        })
                        .min();
                    if let Some((_, _, t)) = best {
                        terms.push((t.to_string(), W_TYPO));
                        if let Some(al) = aliases.get(t) {
                            terms.extend(al.iter().map(|a| (a.clone(), W_ALIAS * W_TYPO)));
                        }
                    }
                }
            }
            terms
        })
        .collect()
}

#[derive(Serialize, Debug, Clone)]
pub struct Hit {
    pub path: PathBuf,
    pub line: usize,
    pub score: f64,
    /// Share of query words this note matched, 0..=1.
    pub coverage: f64,
    pub title: String,
    pub snippet: String,
}

/// The line that carries the most distinct query terms (earliest wins), skipping frontmatter.
fn best_line(content: &str, terms: &[Vec<(String, f64)>], skip_tasks: bool) -> (usize, String) {
    let want: Vec<HashSet<&str>> = terms
        .iter()
        .map(|ts| ts.iter().map(|(t, _)| t.as_str()).collect())
        .collect();
    let skip = if let Some(rest) = content.strip_prefix("---\n") {
        rest.find("\n---")
            .map_or(0, |e| content[..e + 4].lines().count() + 1)
    } else {
        0
    };
    let mut best = (0usize, 0usize, String::new());
    for (i, line) in content.lines().enumerate().skip(skip) {
        if skip_tasks && md::is_task(line) {
            continue;
        }
        let toks: HashSet<String> = tokenize(line).into_iter().collect();
        let n = want
            .iter()
            .filter(|w| w.iter().any(|t| toks.contains(*t)))
            .count();
        if n > best.0 {
            best = (n, i + 1, line.trim().to_string());
        }
    }
    if best.1 == 0 {
        let first = content
            .lines()
            .enumerate()
            .skip(skip)
            .find(|(_, l)| !l.trim().is_empty())
            .map_or((1, String::new()), |(i, l)| (i + 1, l.trim().to_string()));
        return first;
    }
    (best.1, best.2)
}

fn snip(s: &str) -> String {
    let s = s.replace('\t', " ");
    if s.chars().count() <= SNIPPET_MAX {
        return s;
    }
    let cut: String = s.chars().take(SNIPPET_MAX - 3).collect();
    format!("{cut}...")
}

/// Rank `docs` for `q`, best first, at most `limit` hits (the snippet is the costly part, so
/// only kept hits get one). Pure over its inputs, so tests drive it with a fixture vault.
fn rank(docs: &[Doc], q: &Query, aliases: &HashMap<String, Vec<String>>, limit: usize) -> Vec<Hit> {
    let n = docs.len().max(1) as f64;
    let avg = docs.iter().map(|d| d.len).sum::<f64>() / n;
    if q.words.is_empty() && q.tags.is_empty() {
        return Vec::new();
    }
    let terms = expand(&q.words, &q.joins, docs, aliases);
    let mut df: HashMap<&str, usize> = HashMap::new();
    for (t, _) in terms.iter().flatten() {
        let c = docs.iter().filter(|d| d.tf.contains_key(t)).count();
        df.insert(t.as_str(), c);
    }
    let exclude: Vec<&str> = q.exclude.iter().map(String::as_str).collect();

    let mut hits = Vec::new();
    for d in docs {
        if !q
            .tags
            .iter()
            .all(|t| d.tags.contains(t) || d.dirs.contains(&stem(t)))
        {
            continue;
        }
        if exclude.iter().any(|t| d.tf.contains_key(*t)) {
            continue;
        }
        let norm = K1 * (1.0 - B + B * d.len / avg.max(1.0));
        let mut score = 0.0;
        let mut matched = 0usize;
        for group in &terms {
            let mut best = 0.0f64;
            for (t, w) in group {
                let Some(&tf) = d.tf.get(t) else { continue };
                let dfi = *df.get(t.as_str()).unwrap_or(&0) as f64;
                let idf = (1.0 + (n - dfi + 0.5) / (dfi + 0.5)).ln();
                best = best.max(w * idf * tf * (K1 + 1.0) / (tf + norm));
            }
            if best > 0.0 {
                matched += 1;
                score += best;
            }
        }
        let coverage = if terms.is_empty() {
            1.0
        } else {
            matched as f64 / terms.len() as f64
        };
        if terms.is_empty() {
            score = 1.0; // a tags-only query lists every tagged note
        } else if matched == 0 {
            continue;
        }
        score *= coverage * coverage;
        if !q.phrases.is_empty() && {
            let lower = d.content.to_lowercase();
            q.phrases.iter().any(|p| lower.contains(p.as_str()))
        } {
            score *= PHRASE_BOOST;
        }
        if d.knowledge {
            score *= KNOWLEDGE_BOOST;
        }
        hits.push((d, score, coverage));
    }
    hits.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.0.path.cmp(&b.0.path))
    });
    hits.truncate(limit);
    hits.into_iter()
        .map(|(d, score, coverage)| {
            let (line, text) = best_line(&d.content, &terms, d.sheet);
            Hit {
                path: d.path.clone(),
                line,
                score: (score * 1000.0).round() / 1000.0,
                coverage,
                title: d.title.clone(),
                snippet: snip(&text),
            }
        })
        .collect()
}

/// Search the profile's `search_dirs` for `query`; at most `limit` hits.
pub fn search(p: &Profile, query: &str, limit: usize) -> Result<Vec<Hit>> {
    let docs = load(&p.search_dirs, &Roots::of(p));
    let aliases = load_aliases(&aliases_path(p))?;
    let hits = rank(&docs, &parse_query(query), &aliases, limit);
    // The process exits right after printing: freeing millions of term strings one by one
    // only spends CPU the OS reclaims anyway.
    std::mem::forget(docs);
    Ok(hits)
}

/// `notes find <query>`: `path<TAB>line<TAB>score<TAB>title<TAB>snippet`, or JSON.
pub fn run(p: &Profile, query: &str, limit: usize, json: bool) -> Result<()> {
    let hits = search(p, query, limit)?;
    if json {
        println!("{}", serde_json::to_string_pretty(&hits)?);
        return Ok(());
    }
    for h in &hits {
        println!(
            "{}\t{}\t{}\t{}\t{}",
            h.path.display(),
            h.line,
            h.score,
            h.title.replace('\t', " "),
            h.snippet
        );
    }
    Ok(())
}

/// One eval case: a query and the notes that should answer it (vault-relative path suffixes,
/// `.md` optional), or none, meaning no note should match every word.
struct Case {
    query: String,
    expect: Vec<String>,
}

fn read_cases(path: &Path) -> Result<Vec<Case>> {
    let text = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let mut out = Vec::new();
    for line in text.lines() {
        if line.trim().is_empty() || line == "#" || line.starts_with("# ") {
            continue;
        }
        let (q, e) = line.split_once('\t').unwrap_or((line, "-"));
        let expect = if e.trim() == "-" {
            Vec::new()
        } else {
            e.split(';')
                .map(|s| s.trim().trim_end_matches(".md").to_string())
                .filter(|s| !s.is_empty())
                .collect()
        };
        out.push(Case {
            query: q.trim().to_string(),
            expect,
        });
    }
    Ok(out)
}

/// Eval result, also what `notes doctor` reads.
pub struct EvalScore {
    pub cases: usize,
    pub recall1: f64,
    pub recall5: f64,
    pub mrr: f64,
    pub negatives: usize,
    pub negatives_ok: usize,
    pub misses: Vec<String>,
    pub millis_per_query: f64,
}

pub fn eval(p: &Profile, file: &Path) -> Result<EvalScore> {
    let cases = read_cases(file)?;
    let t0 = std::time::Instant::now();
    let docs = load(&p.search_dirs, &Roots::of(p));
    let load_ms = t0.elapsed().as_secs_f64() * 1000.0;
    let aliases = load_aliases(&aliases_path(p))?;
    let root = &p.vault;
    let (mut r1, mut r5, mut rr, mut pos, mut neg, mut neg_ok) =
        (0usize, 0usize, 0.0, 0usize, 0usize, 0usize);
    let mut misses = Vec::new();
    let t1 = std::time::Instant::now();
    for c in &cases {
        let hits = rank(&docs, &parse_query(&c.query), &aliases, EVAL_DEPTH);
        if c.expect.is_empty() {
            neg += 1;
            match hits.iter().find(|h| h.coverage >= 1.0) {
                None => neg_ok += 1,
                Some(h) => misses.push(format!(
                    "NEG  {}  matched {}",
                    c.query,
                    h.path.strip_prefix(root).unwrap_or(&h.path).display()
                )),
            }
            continue;
        }
        pos += 1;
        let rank_of = hits.iter().position(|h| {
            let rel = h
                .path
                .strip_prefix(root)
                .unwrap_or(&h.path)
                .with_extension("");
            let rel = rel.to_string_lossy();
            c.expect
                .iter()
                .any(|e| rel == e.as_str() || rel.ends_with(&format!("/{e}")))
        });
        match rank_of {
            Some(0) => {
                r1 += 1;
                r5 += 1;
                rr += 1.0;
            }
            Some(i) => {
                if i < 5 {
                    r5 += 1;
                } else {
                    misses.push(format!("RANK {}  {}  at {}", c.query, c.expect[0], i + 1));
                }
                rr += 1.0 / (i + 1) as f64;
            }
            None => misses.push(format!("MISS {}  {}", c.query, c.expect[0])),
        }
        if rank_of.is_some_and(|i| i >= 5) || rank_of.is_none() {
            if let Some(top) = hits.first() {
                let last = misses.pop().unwrap_or_default();
                misses.push(format!(
                    "{last}  (top: {})",
                    top.path.strip_prefix(root).unwrap_or(&top.path).display()
                ));
            }
        }
    }
    let query_ms = t1.elapsed().as_secs_f64() * 1000.0 / cases.len().max(1) as f64;
    let pf = pos.max(1) as f64;
    Ok(EvalScore {
        cases: cases.len(),
        recall1: r1 as f64 / pf,
        recall5: r5 as f64 / pf,
        mrr: rr / pf,
        negatives: neg,
        negatives_ok: neg_ok,
        misses,
        millis_per_query: load_ms + query_ms,
    })
}

/// The eval file's own floor, a comment line such as `# floor: recall5=0.90 ms=400`: the
/// score `notes doctor` holds the engine to. Kept beside the cases it scores, so raising the
/// bar after a tuning pass is one edit to the data.
#[derive(Default, Debug, PartialEq)]
pub struct Floor {
    pub recall5: Option<f64>,
    pub ms: Option<f64>,
}

pub fn read_floor(path: &Path) -> Floor {
    let mut f = Floor::default();
    let Ok(text) = fs::read_to_string(path) else {
        return f;
    };
    for line in text.lines() {
        let Some(rest) = line
            .strip_prefix('#')
            .map(str::trim)
            .and_then(|l| l.strip_prefix("floor:"))
        else {
            continue;
        };
        for kv in rest.split_whitespace() {
            match kv.split_once('=') {
                Some(("recall5", v)) => f.recall5 = v.parse().ok(),
                Some(("ms", v)) => f.ms = v.parse().ok(),
                _ => {}
            }
        }
    }
    f
}

pub fn eval_path(p: &Profile) -> PathBuf {
    p.vault.join(".search/eval.tsv")
}

pub fn run_eval(p: &Profile, file: &Path) -> Result<()> {
    let s = eval(p, file)?;
    for m in &s.misses {
        println!("{m}");
    }
    println!(
        "cases {}  recall@1 {:.1}%  recall@5 {:.1}%  mrr {:.3}  negatives {}/{}  {:.0} ms per lookup",
        s.cases,
        s.recall1 * 100.0,
        s.recall5 * 100.0,
        s.mrr,
        s.negatives_ok,
        s.negatives,
        s.millis_per_query
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(rel: &str, content: &str) -> Doc {
        let roots = Roots {
            vault: PathBuf::from("/v"),
            knowledge: PathBuf::from("/v/knowledge"),
            sheets: PathBuf::from("/v/lab"),
        };
        parse_doc(&Path::new("/v").join(rel), content, &roots)
    }

    fn corpus() -> Vec<Doc> {
        vec![
            doc(
                "knowledge/software/sso.md",
                "---\ntitle: Single sign-on for the dashboard\nsummary: OIDC login wired through the gateway\ntags: [software, auth]\n---\n# SSO\nThe dashboard uses OIDC with a client secret.\n",
            ),
            doc(
                "knowledge/software/mobile-app.md",
                "---\ntitle: Mobile app release\ntags: [software, mobile]\n---\nThe mobile build ships through the store.\nCertificate pinning keeps the security team happy.\n",
            ),
            doc(
                "employment/prep/security.md",
                "# Security interview prep\nThreat models, OWASP top ten, token storage.\n#interview\n",
            ),
            doc(
                "lab/board.md",
                "# Board\n- [ ] epic(security): mobile security to standard\n",
            ),
            doc(
                "employment/prep/pizza-app.md",
                "# Pizza app code interview\n- [ ] decided on mongoose model for schema validation\n",
            ),
            doc(
                "knowledge/home/phone-backup.md",
                "# Phone backup\nThe phone backup runs nightly to the NAS.\n",
            ),
            doc(
                "lab/notes/garden.md",
                "# Garden\nTomatoes and basil out back.\n",
            ),
        ]
    }

    fn names(hits: &[Hit]) -> Vec<String> {
        hits.iter()
            .map(|h| h.path.file_stem().unwrap().to_string_lossy().to_string())
            .collect()
    }

    fn q(s: &str) -> Vec<Hit> {
        let mut al = HashMap::new();
        al.insert(
            "oauth".to_string(),
            vec!["oidc".to_string(), "sso".to_string()],
        );
        al.insert(
            "oidc".to_string(),
            vec!["oauth".to_string(), "sso".to_string()],
        );
        al.insert(
            "sso".to_string(),
            vec!["oauth".to_string(), "oidc".to_string()],
        );
        rank(&corpus(), &parse_query(s), &al, 50)
    }

    #[test]
    fn parse_splits_tags_phrases_excludes_and_drops_stopwords() {
        let p = parse_query(r#"how did I do #AI "token storage" -garden oauth"#);
        assert_eq!(p.tags, vec!["ai"]);
        assert_eq!(p.phrases, vec!["token storage"]);
        assert_eq!(p.exclude, vec!["garden"]);
        assert_eq!(p.words, vec!["token", "storage", "oauth"]);
    }

    #[test]
    fn two_words_that_are_one_word_in_the_note_still_cover_the_query() {
        let h = q("how do i back up my phone");
        assert_eq!(names(&h)[0], "phone-backup");
        assert_eq!(h[0].coverage, 1.0, "back up should cover via backup");
    }

    #[test]
    fn all_words_beat_some_words() {
        let h = q("mobile security");
        assert_eq!(names(&h)[0], "mobile-app", "{:?}", names(&h));
        assert!(names(&h).contains(&"security".to_string()));
    }

    #[test]
    fn task_rows_count_except_on_lab_sheets() {
        assert!(!names(&q("mobile security")).contains(&"board".to_string()));
        assert_eq!(names(&q("mongoose model"))[0], "pizza-app");
    }

    #[test]
    fn alias_group_finds_the_synonym() {
        assert_eq!(names(&q("oauth"))[0], "sso");
    }

    #[test]
    fn typo_and_half_typed_word_still_land() {
        assert!(names(&q("secruity")).contains(&"security".to_string()));
        assert_eq!(names(&q("tomat"))[0], "garden");
    }

    #[test]
    fn tag_filter_phrase_and_exclude() {
        assert_eq!(names(&q("#interview")), vec!["security"]);
        assert_eq!(names(&q("#mobile security")), vec!["mobile-app"]);
        assert_eq!(names(&q("\"token storage\" security"))[0], "security");
        assert!(!names(&q("security -pinning")).contains(&"mobile-app".to_string()));
    }

    #[test]
    fn negative_control_unrelated_words_and_unknown_tag_find_nothing() {
        assert!(q("quantum chromodynamics").is_empty());
        assert!(q("").is_empty());
        assert!(q("   ").is_empty());
        assert!(q("#nosuchtag").is_empty());
        assert!(q("#nosuchtag security").is_empty());
    }

    #[test]
    fn stem_meets_inflections() {
        assert_eq!(stem("tests"), stem("testing"));
        assert_eq!(stem("tested"), "test");
        assert_eq!(stem("policies"), "policy");
        assert_eq!(stem("class"), "class");
    }

    #[test]
    fn edit_distance_counts_a_swap_as_one() {
        assert_eq!(edit_distance("secruity", "security", 2), Some(1));
        assert_eq!(edit_distance("abc", "xyz", 1), None);
    }

    #[test]
    fn floor_is_read_from_the_eval_file_comment() {
        let d = std::env::temp_dir().join(format!("notes-find-floor-{}", std::process::id()));
        fs::create_dir_all(&d).unwrap();
        let f = d.join("eval.tsv");
        fs::write(
            &f,
            "# a note\n# floor: recall5=0.9 ms=400\nai oauth\tknowledge/sso\n",
        )
        .unwrap();
        assert_eq!(
            read_floor(&f),
            Floor {
                recall5: Some(0.9),
                ms: Some(400.0)
            }
        );
        assert_eq!(read_cases(&f).unwrap().len(), 1);
        fs::write(&f, "ai oauth\tknowledge/sso\n").unwrap();
        assert_eq!(read_floor(&f), Floor::default());
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn skip_dirs_count_only_below_the_search_dir() {
        // The root itself sits under a dir named `agent`: its notes must still be found,
        // while an `_log` dir inside it is skipped.
        let d = std::env::temp_dir().join(format!("notes-find-skip-{}", std::process::id()));
        let root = d.join("agent/vault");
        fs::create_dir_all(root.join("_log")).unwrap();
        fs::write(root.join("keep.md"), "# Keep\n").unwrap();
        fs::write(root.join("_log/drop.md"), "# Drop\n").unwrap();
        let got = files(std::slice::from_ref(&root));
        fs::remove_dir_all(&d).unwrap();
        assert_eq!(got, vec![root.join("keep.md")]);
    }
}
