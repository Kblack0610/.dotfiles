//! Who owns a red, from its fix rows (`fleet-bench reds`, [`crate::reds`]): the one join a
//! surface draws a red's owner by, so a red reads the same owner on every surface. Alerts calls
//! it today; Releases > Apps' owner cell is next (plan pasted-content-id-7aea-prancy-muffin P1).

use crate::reds::Red;

/// A red's owner as its fix rows say it.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct FixOwner<'a> {
    /// The fix row chosen ([`fix_owner`]), or none.
    pub fix: Option<&'a Red>,
    /// `<slug> <outcome>` of that row, else `-`.
    pub owner: String,
    /// The tmux session (else the slug) working a fix in hand that is not waiting and is due
    /// no later than now; empty otherwise.
    pub fixing_by: String,
    /// `fixing` (a fix in hand or one that needs merging), `queued`, `unfixed` (a fix row whose
    /// fix did not hold: it has an owner to ask), or `no owner` (no fix row at all).
    pub state: &'static str,
}

/// The owner of a red from the open fix rows `filed` picks out: the one in hand (queued or
/// fixing), else the first (open rows are worst first). A fix in hand that is not waiting and has
/// a `due` not past at `now` sets `fixing_by`; no `due` (too few merged fixes to judge by) is not
/// on time. A `needs merge` fix is not in hand: its session ended with the PR open, so someone
/// has to land it.
pub fn fix_owner<'a>(fixes: &'a [Red], filed: impl Fn(&Red) -> bool, now: i64) -> FixOwner<'a> {
    let in_hand = |r: &Red| matches!(r.outcome.as_str(), "queued" | "fixing");
    let mut rows = fixes.iter().filter(|r| filed(r));
    let first = rows.clone().next();
    let fix = rows.find(|r| in_hand(r)).or(first);
    let Some(r) = fix else {
        return FixOwner {
            owner: "-".into(),
            state: "no owner",
            ..FixOwner::default()
        };
    };
    // A waiting item waits on an ask or another item and one in review on a merge: either may
    // be waiting on the human.
    let on_time = in_hand(r)
        && !matches!(r.state.as_str(), "waiting" | "review")
        && r.due.is_some_and(|d| now <= d);
    FixOwner {
        fix,
        owner: format!("{} {}", r.slug, r.outcome),
        fixing_by: if on_time {
            r.session
                .as_deref()
                .map_or(r.slug.as_str(), crate::home::tmux_name)
                .to_string()
        } else {
            String::new()
        },
        state: match r.outcome.as_str() {
            "fixing" | "needs merge" => "fixing",
            "queued" => "queued",
            _ => "unfixed",
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn red(slug: &str, key: &str, outcome: &str) -> Red {
        Red {
            slug: slug.into(),
            red: key.into(),
            outcome: outcome.into(),
            state: "running".into(),
            ..Red::default()
        }
    }

    #[test]
    fn the_fix_in_hand_wins_over_an_earlier_open_row_and_none_filed_has_no_owner() {
        let fixes = [
            red("old", "watch w", "came back"),
            red("new", "watch w", "fixing"),
            red("other", "watch x", "fixing"),
        ];
        let o = fix_owner(&fixes, |r| r.red == "watch w", 0);
        assert_eq!((o.owner.as_str(), o.state), ("new fixing", "fixing"));
        let o = fix_owner(&fixes[..1], |r| r.red == "watch w", 0);
        assert_eq!((o.owner.as_str(), o.state), ("old came back", "unfixed"));
        // Negative control: a row filed under another key never owns this red.
        let o = fix_owner(&fixes, |r| r.red == "watch y", 0);
        assert_eq!((o.owner.as_str(), o.state, o.fix), ("-", "no owner", None));
    }

    #[test]
    fn fixing_by_needs_a_fix_in_hand_on_time_and_not_waiting() {
        let mut r = red("s", "k", "fixing");
        r.due = Some(100);
        r.session = Some("lab:dotfiles-agent-9".into());
        let by = |r: &Red, now| fix_owner(std::slice::from_ref(r), |_| true, now).fixing_by;
        assert_eq!(by(&r, 100), crate::home::tmux_name("lab:dotfiles-agent-9"));
        assert_eq!(by(&r, 101), "");
        r.state = "waiting".into();
        assert_eq!(by(&r, 50), "");
    }
}
