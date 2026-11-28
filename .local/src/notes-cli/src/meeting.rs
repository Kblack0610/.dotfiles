//! `notes meeting new "<title>"` — create a structured meeting log with a
//! timestamp id and agenda/notes/decisions/action-item scaffolding.

use crate::config::Profile;
use crate::logging::Logger;
use anyhow::Result;
use chrono::{DateTime, Local};

pub fn new_note(p: &Profile, log: &Logger, title: &str) -> Result<()> {
    crate::zettel::create(&p.meetings, log, "meeting", "meeting", title, meeting_text)
}

fn meeting_text(id: &str, title: &str, now: DateTime<Local>) -> String {
    format!(
        "---\nid: {id}\ntitle: {q}\ndate: {date}\ntype: meeting\ntags: [meeting]\nattendees: []\nlinks: []\n---\n\n# {title}\n\n- **When:** {when}\n- **Attendees:**\n\n## Agenda\n\n## Notes\n\n## Decisions\n\n## Action Items\n- [ ]\n",
        q = crate::md::yaml_quote(title),
        date = now.format("%Y-%m-%d"),
        when = now.format("%Y-%m-%d %H:%M"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn meeting_title_survives_the_front_matter() {
        let t = "Q2 \"kickoff\" \\ plan";
        let text = meeting_text("id", t, Local::now());
        assert_eq!(
            crate::md::parse_yaml_scalar(&text, "title").as_deref(),
            Some(t)
        );
    }
}
