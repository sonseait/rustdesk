//! Internal-only managed authorization telemetry. This module intentionally
//! emits decision reasons but never credentials, tickets, keys, or peer data.

use std::{collections::VecDeque, net::SocketAddr, sync::{atomic::{AtomicU64, Ordering}, Mutex, OnceLock}};

use axum::{routing::get, Json, Router};
use chrono::Utc;
use hbb_common::tokio;
use hbb_common::log;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ManagedEvent {
    pub(crate) at: i64,
    pub(crate) surface: &'static str,
    pub(crate) allowed: bool,
    pub(crate) reason: String,
}

struct Telemetry {
    allowed: AtomicU64,
    denied: AtomicU64,
    events: Mutex<VecDeque<ManagedEvent>>,
}

fn telemetry() -> &'static Telemetry {
    static TELEMETRY: OnceLock<Telemetry> = OnceLock::new();
    TELEMETRY.get_or_init(|| Telemetry {
        allowed: AtomicU64::new(0),
        denied: AtomicU64::new(0),
        events: Mutex::new(VecDeque::with_capacity(256)),
    })
}

pub(crate) fn record(surface: &'static str, allowed: bool, reason: impl Into<String>) {
    let telemetry = telemetry();
    if allowed { telemetry.allowed.fetch_add(1, Ordering::Relaxed); } else { telemetry.denied.fetch_add(1, Ordering::Relaxed); }
    let mut events = telemetry.events.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if events.len() == 256 { events.pop_front(); }
    events.push_back(ManagedEvent { at: Utc::now().timestamp(), surface, allowed, reason: reason.into() });
}

pub(crate) fn recent_events() -> Vec<ManagedEvent> {
    telemetry().events.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).iter().cloned().collect()
}

pub(crate) fn prometheus() -> String {
    let telemetry = telemetry();
    format!(
        "# HELP rustdesk_managed_authorization_total Managed authorization decisions by result\n# TYPE rustdesk_managed_authorization_total counter\nrustdesk_managed_authorization_total{{result=\"allowed\"}} {}\nrustdesk_managed_authorization_total{{result=\"denied\"}} {}\n",
        telemetry.allowed.load(Ordering::Relaxed), telemetry.denied.load(Ordering::Relaxed),
    )
}

/// Starts an opt-in loopback-only observability listener. Operators must set a
/// component-specific address such as `HBBS_INTERNAL_METRICS_ADDR=127.0.0.1:21116`;
/// non-loopback addresses are rejected so runtime telemetry is never public.
pub(crate) fn start_if_configured(environment_name: &str, component: &'static str) {
    let Ok(value) = std::env::var(environment_name) else { return; };
    let Ok(address) = value.parse::<SocketAddr>() else {
        log::error!("{} must be a socket address", environment_name);
        return;
    };
    if !address.ip().is_loopback() {
        log::error!("{} must bind to a loopback address", environment_name);
        return;
    }
    tokio::spawn(async move {
        let app = Router::new()
            .route("/healthz", get(move || async move { format!("{{\"status\":\"ok\",\"component\":\"{component}\"}}") }))
            .route("/metrics", get(|| async { prometheus() }))
            .route("/events", get(|| async { Json(recent_events()) }));
        if let Err(error) = axum::Server::bind(&address).serve(app.into_make_service()).await {
            log::error!("internal observability listener failed: {}", error);
        }
    });
}
