//! Free text as a title: what a queue item or an ask is, in a few words, the same on every
//! surface that shows it.

/// The longest title a view shows, in chars.
pub const TITLE_MAX: usize = 100;

/// A text's title and the rest of it. The title is the first non-empty line up to its first
/// sentence end, each file path as its name (`/a/b/plan.md` as `plan`), capped at `TITLE_MAX`.
/// The rest is what follows that sentence; when the title had to be cut it is the whole text,
/// so nothing is only in the cut-off part.
pub fn headline(text: &str) -> (String, String) {
    let text = text.trim();
    let (line, after) = text.split_once('\n').unwrap_or((text, ""));
    let line = line.trim();
    let end = [". ", "? ", "! "]
        .iter()
        .filter_map(|p| line.find(p))
        .map(|i| i + 1)
        .min()
        .unwrap_or(line.len());
    let words: Vec<String> = line[..end].split_whitespace().map(short_path).collect();
    let full = words.join(" ");
    let full = full.trim_end_matches('.');
    let title = cap(full, TITLE_MAX);
    let rest = if title != full {
        text.to_string()
    } else {
        [line[end..].trim(), after.trim()]
            .iter()
            .filter(|s| !s.is_empty())
            .copied()
            .collect::<Vec<_>>()
            .join("\n")
    };
    (title, rest)
}

/// A word that is a file path, as the file's name without its extension; the punctuation after
/// it is kept. Anything else as it is.
fn short_path(w: &str) -> String {
    let body = w.trim_end_matches([':', ',', ';', '.', ')']);
    if !(body.starts_with('/') || body.starts_with("~/")) || !body[1..].contains('/') {
        return w.to_string();
    }
    let name = body.rsplit('/').next().unwrap_or(body);
    let stem = name.rsplit_once('.').map_or(name, |(s, _)| s);
    format!("{stem}{}", &w[body.len()..])
}

/// `s` cut to `max` chars on a word boundary, with "..." when cut.
pub fn cap(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let cut: String = s.chars().take(max).collect();
    let cut = cut.rsplit_once(' ').map_or(cut.as_str(), |(a, _)| a);
    format!("{}...", cut.trim_end_matches([',', ';', ':']))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_title_is_the_first_sentence_and_the_rest_follows_it() {
        let (t, r) = headline("\nShip it? The build is green.\nOptions: yes, no");
        assert_eq!(t, "Ship it?");
        assert_eq!(r, "The build is green.\nOptions: yes, no");
        assert_eq!(
            headline("One line only."),
            ("One line only".into(), String::new())
        );
        assert_eq!(headline(""), (String::new(), String::new()));
    }

    #[test]
    fn a_path_in_the_title_reads_as_its_name_and_stays_whole_in_the_rest() {
        let (t, r) = headline("Read /a/b/plan.md: then go. See /a/b/plan.md too");
        assert_eq!(t, "Read plan: then go");
        assert_eq!(r, "See /a/b/plan.md too");
    }

    #[test]
    fn a_cut_title_leaves_the_whole_text_as_the_rest() {
        let long = "word ".repeat(40);
        let (t, r) = headline(&long);
        assert!(
            t.ends_with("word...") && t.chars().count() <= TITLE_MAX + 3,
            "{t}"
        );
        assert_eq!(r, long.trim());
    }
}
