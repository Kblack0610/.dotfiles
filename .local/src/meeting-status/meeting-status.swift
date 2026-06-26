// meeting-status — print the single most relevant "real meeting" from the system
// Calendar (the same store SketchyBar/MeetingBar read), via EventKit.
//
// Why this exists: icalBuddy (what the bar used before) cannot expose two signals the
// meeting bar needs — your RSVP status (accepted / tentative / declined) and whether an
// event actually has a video-conferencing link. EventKit gives both, plus epochs straight
// from NSDate (no `date -j` string round-trip, which on BSD silently drifted the seconds
// field and broke the "same meeting?" latch — see lessons/dotfiles.md).
//
// Output contract (one tab-separated line on stdout), mirroring lib/calendar.sh's old
// calendar_scan so the shell side stays a thin wrapper:
//   ERR<TAB><message>                                       no Calendar access
//   TIMED<TAB><start_epoch><TAB><end_epoch><TAB><rsvp><TAB><title>
//   ALLDAY<TAB><title>                                      no timed meeting, an all-day event exists
//   NONE                                                    nothing relevant
//
// "Real meeting" filter for TIMED (all must hold):
//   • has a recognized conferencing link in title/notes/url/location, AND
//   • event is not cancelled (EKEventStatus.canceled), AND
//   • you have not declined it.
// Link-less personal events (jiu jitsu, focus blocks) and declined/cancelled invites are
// therefore skipped — exactly what should NOT light up a *meeting* bar. <rsvp> is one of
// ACCEPTED | TENTATIVE | PENDING | NONE and drives the bar color (tentative → amber).
//
// Fail-safe: on any auth failure prints "ERR<TAB>no cal access" and exits 0, never crashes
// the 2s SketchyBar tick.

import EventKit
import Foundation

func emit(_ s: String) { print(s) }

let store = EKEventStore()
let sema = DispatchSemaphore(value: 0)
var granted = false
if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { ok, _ in granted = ok; sema.signal() }
} else {
    store.requestAccess(to: .event) { ok, _ in granted = ok; sema.signal() }
}
_ = sema.wait(timeout: .now() + 5)

guard granted else { emit("ERR\tno cal access"); exit(0) }

let now = Date()
let cal = Calendar.current
let end = cal.date(byAdding: .day, value: 2, to: now) ?? now.addingTimeInterval(172_800)
let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-86_400),
                                    end: end, calendars: nil)

// Recognized video-conferencing hosts. Substring match against the event's combined text.
let conferenceHosts = [
    "meet.google.com", "zoom.us", "zoom.com", "teams.microsoft.com",
    "teams.live.com", "webex.com", "whereby.com", "around.co", "chime.aws",
]

func rsvp(_ ev: EKEvent) -> String {
    guard let me = ev.attendees?.first(where: { $0.isCurrentUser }) else { return "NONE" }
    switch me.participantStatus {
    case .accepted:  return "ACCEPTED"
    case .tentative: return "TENTATIVE"
    case .declined:  return "DECLINED"
    case .pending:   return "PENDING"
    default:         return "NONE"
    }
}

func hasConferenceLink(_ ev: EKEvent) -> Bool {
    let blob = [ev.title, ev.notes, ev.url?.absoluteString, ev.location]
        .compactMap { $0 }.joined(separator: " ").lowercased()
    return conferenceHosts.contains { blob.contains($0) }
}

let events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }

var firstAllDay: String? = nil

for ev in events {
    if ev.isAllDay {
        if firstAllDay == nil { firstAllDay = ev.title ?? "" }
        continue
    }
    if ev.endDate <= now { continue }                 // already ended
    if ev.status == .canceled { continue }            // organizer cancelled it
    let status = rsvp(ev)
    if status == "DECLINED" { continue }              // you declined — don't nag
    if !hasConferenceLink(ev) { continue }            // not a real (video) meeting

    let s = Int(ev.startDate.timeIntervalSince1970)
    let e = Int(ev.endDate.timeIntervalSince1970)
    let title = (ev.title ?? "").replacingOccurrences(of: "\t", with: " ")
    emit("TIMED\t\(s)\t\(e)\t\(status)\t\(title)")
    exit(0)
}

if let ad = firstAllDay {
    emit("ALLDAY\t\(ad.replacingOccurrences(of: "\t", with: " "))")
} else {
    emit("NONE")
}
