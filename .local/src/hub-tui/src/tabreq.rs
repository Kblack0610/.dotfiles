//! `hub tab <name>`: ask the running hub to show a page. The running hub listens on a Unix
//! socket, so a request arrives as an event and needs no file watch (inotify can be full: an
//! open Unity Editor takes nearly all of it). With no hub listening, the request is left in a
//! file that the next hub to start takes, which is how a Prefix key that creates hub:board
//! lands on its page.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::time::Duration;

use crate::app::{Msg, Tab};

/// A guard on reading one request: the client writes a word and closes.
const READ_GUARD: Duration = Duration::from_secs(1);

/// `$XDG_STATE_HOME/hub` (default `~/.local/state/hub`): the request file and the socket.
pub fn dir() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state")
        })
        .join("hub")
}

/// Send `t` to the hub listening in `dir`, else leave it in `dir/tab` for the next one.
pub fn request(dir: &Path, t: Tab) -> std::io::Result<()> {
    let word = t.title().to_lowercase();
    if let Ok(mut s) = UnixStream::connect(dir.join("tab.sock")) {
        if writeln!(s, "{word}").is_ok() {
            return Ok(());
        }
    }
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join("tab.tmp");
    std::fs::write(&tmp, word)?;
    std::fs::rename(&tmp, dir.join("tab"))
}

/// Take the request left while no hub ran: read it and remove it, so it is acted on once.
pub fn take(dir: &Path) -> Option<Tab> {
    let f = dir.join("tab");
    let s = std::fs::read_to_string(&f).ok()?;
    let _ = std::fs::remove_file(&f);
    Tab::parse(s.trim())
}

/// Listen for requests, unless another hub already does (None: that one gets them). A socket
/// left by a hub that died answers nothing and is replaced.
pub fn listen(dir: &Path) -> std::io::Result<Option<UnixListener>> {
    let sock = dir.join("tab.sock");
    if UnixStream::connect(&sock).is_ok() {
        return Ok(None);
    }
    std::fs::create_dir_all(dir)?;
    let _ = std::fs::remove_file(&sock);
    UnixListener::bind(&sock).map(Some)
}

/// Turn each request on `l` into a `Msg::Tab`, until the app is gone.
pub fn serve(l: UnixListener, tx: Sender<Msg>) {
    for s in l.incoming().flatten() {
        let _ = s.set_read_timeout(Some(READ_GUARD));
        let mut line = String::new();
        if BufReader::new(s).read_line(&mut line).is_err() {
            continue;
        }
        if let Some(t) = Tab::parse(line.trim()) {
            if tx.send(Msg::Tab(t)).is_err() {
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    /// A fresh directory for one test, removed when the guard drops (pass or fail).
    struct Scratch(PathBuf);
    impl Scratch {
        fn new(name: &str) -> Scratch {
            let d = std::env::temp_dir().join(format!("hub-tab-{}-{name}", std::process::id()));
            let _ = std::fs::remove_dir_all(&d);
            Scratch(d)
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn with_no_hub_running_a_request_waits_in_the_file_and_is_taken_once() {
        let d = Scratch::new("file");
        for t in Tab::ALL {
            request(&d.0, t).unwrap();
            assert_eq!(take(&d.0), Some(t));
            assert_eq!(take(&d.0), None, "a request is acted on once");
        }
        std::fs::write(d.0.join("tab"), "nonsense\n").unwrap();
        assert_eq!(take(&d.0), None);
        assert!(
            !d.0.join("tab").exists(),
            "a bad request is removed too, so it cannot stick"
        );
    }

    #[test]
    fn a_running_hub_gets_every_request_over_its_socket() {
        let d = Scratch::new("sock");
        let l = listen(&d.0).unwrap().expect("first hub listens");
        assert!(
            listen(&d.0).unwrap().is_none(),
            "a second hub leaves the socket to the first"
        );
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || serve(l, tx));
        for t in [Tab::Fleet, Tab::Today, Tab::Overview] {
            request(&d.0, t).unwrap();
            match rx.recv_timeout(Duration::from_secs(5)) {
                Ok(Msg::Tab(got)) => assert_eq!(got, t),
                _ => panic!("no tab message for {t:?}"),
            }
        }
        assert!(!d.0.join("tab").exists(), "nothing left for the next hub");
    }

    #[test]
    fn a_socket_left_by_a_dead_hub_is_replaced_and_its_requests_go_to_the_file() {
        let d = Scratch::new("stale");
        drop(listen(&d.0).unwrap().unwrap());
        assert!(
            d.0.join("tab.sock").exists(),
            "the dead hub's socket is left"
        );
        request(&d.0, Tab::History).unwrap();
        assert_eq!(take(&d.0), Some(Tab::History));
        assert!(
            listen(&d.0).unwrap().is_some(),
            "the next hub takes it over"
        );
    }
}
