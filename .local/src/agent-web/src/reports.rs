//! The Reports tab: what agents filed for the human, through `hub_core::reports` (the one reader;
//! the hub TUI draws the same view once ar-5259 lands). `GET /api/reports` is the view for the
//! local day; `POST /api/reports/read {id}` marks one report read through `notes report read`,
//! the stamp's one writer, and answers with the view as it is after. A report's body is the Daily
//! tab's reader (`/api/focus?t=<target>`), so this handler never touches the filesystem.

use axum::http::StatusCode;
use axum::Json;
use hub_core::reports::{self, View};
use hub_core::session_actions::System;
use serde::Deserialize;

use crate::{bad, ApiResult};

fn today() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}

pub async fn get() -> ApiResult<Json<View>> {
    tokio::task::spawn_blocking(|| reports::read(&System, &today()))
        .await
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Read {
    id: String,
}

pub async fn read(Json(r): Json<Read>) -> ApiResult<Json<View>> {
    // A bad id is refused here, before a thread or the CLI.
    reports::read_argv(&r.id).map_err(|m| bad(StatusCode::BAD_REQUEST, m))?;
    tokio::task::spawn_blocking(move || {
        reports::mark_read(&System, &r.id).map_err(|e| bad(StatusCode::CONFLICT, e))?;
        reports::read(&System, &today()).map_err(|e| bad(StatusCode::BAD_GATEWAY, e))
    })
    .await
    .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .map(Json)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_read_with_an_id_that_is_no_report_is_refused_before_the_cli() {
        for id in ["", "--all", "2026-11-24-../x", "2026-11-24-UPS", "x"] {
            let got = read(Json(Read { id: id.into() })).await;
            assert_eq!(
                got.err().map(|e| e.0),
                Some(StatusCode::BAD_REQUEST),
                "{id}"
            );
        }
    }

    #[test]
    fn today_is_the_local_date() {
        let t = today();
        assert!(
            chrono::NaiveDate::parse_from_str(&t, "%Y-%m-%d").is_ok(),
            "{t}"
        );
    }
}
