//! `notes meeting new "<title>"` — create a structured meeting log with a
//! timestamp id and agenda/notes/decisions/action-item scaffolding.

use crate::config::Profile;
use crate::logging::Logger;
use anyhow::Result;

pub fn new_note(p: &Profile, log: &Logger, title: &str) -> Result<()> {
    crate::zettel::create(
        &p.meetings,
        log,
        "meeting",
        "meeting",
        title,
        |id, title, now| {
            format!(
            "---\nid: {id}\ntitle: \"{title}\"\ndate: {date}\ntype: meeting\ntags: [meeting]\nattendees: []\nlinks: []\n---\n\n# {title}\n\n- **When:** {when}\n- **Attendees:**\n\n## Agenda\n\n## Notes\n\n## Decisions\n\n## Action Items\n- [ ]\n",
            date = now.format("%Y-%m-%d"),
            when = now.format("%Y-%m-%d %H:%M"),
        )
        },
    )
}
