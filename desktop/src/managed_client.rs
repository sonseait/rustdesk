//! Managed-platform enrollment core. UI callers receive status only; the
//! signing key is deliberately kept on the Rust side.

use chrono::{DateTime, Utc};
use ed25519_dalek::{Signature, SigningKey, Verifier, VerifyingKey};
use hbb_common::rendezvous_proto::{ManagedDeviceCredential, ManagedSessionTicket};
use hbb_common::{
    config::{Config, LocalConfig},
    log,
};
use rand_core::OsRng;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::{Mutex, OnceLock};

#[path = "../../libs/managed_claim.rs"]
mod managed_claim;
mod lifecycle;
mod store;
mod transport;

static OWNER: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static SNAPSHOT_CACHE: Mutex<Option<(std::time::Instant, String)>> = Mutex::new(None);

fn claim_worker(owner: &std::sync::atomic::AtomicBool) -> bool {
    !owner.swap(true, std::sync::atomic::Ordering::SeqCst)
}

/// Called only after binding the existing main IPC listener. Socket ownership
/// is the cross-process guard; this atomic also rejects duplicate local starts.
pub fn start_owner() {
    if !is_managed_only() || !claim_worker(&OWNER) { return; }
    if let Err(error) = std::thread::Builder::new().name("managed-lifecycle".into()).spawn(run_lifecycle) {
        OWNER.store(false, std::sync::atomic::Ordering::SeqCst);
        log::error!("Could not start managed lifecycle: {error}");
    }
}

fn run_lifecycle() {
    let started = std::time::Instant::now();
    let mut schedule = lifecycle::Schedule::default();
    loop {
        let now = started.elapsed().as_secs();
        if now >= schedule.retry_at {
            let previous = (schedule.policy_at, schedule.config_at, schedule.heartbeat_at);
            let result = reconcile(&mut schedule, now);
            let mut current = state().lock().unwrap_or_else(|e| e.into_inner());
            match result {
                Ok(()) => {
                    schedule.succeeded();
                    current.last_error.clear();
                    current.next_retry.clear();
                    if previous != (schedule.policy_at, schedule.config_at, schedule.heartbeat_at) {
                        let previous_sync = current.last_successful_sync.clone();
                        current.last_successful_sync = utc_now().to_rfc3339();
                        if let Err(code) = persist_credential(&current, &local_option(CONTROL_PLANE_URL_KEY)) {
                            current.last_successful_sync = previous_sync;
                            current.last_error = code;
                        }
                    }
                }
                Err(code) => {
                    let delay = schedule.failed(started.elapsed().as_secs(), rand_core::RngCore::next_u64(&mut OsRng));
                    current.last_error = code;
                    current.next_retry = (utc_now() + chrono::Duration::seconds(delay as i64)).to_rfc3339();
                }
            }
        }
        // Evaluate actual UTC expiry on every read/tick, independent of retry deadlines.
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
}

fn reconcile(schedule: &mut lifecycle::Schedule, monotonic: u64) -> Result<(), String> {
    let current = restored_snapshot();
    if current.revoked {
        if current.device_id.is_empty() || current.signing_key.is_none() {
            return Err("recovery_identity_missing".into());
        }
        // Retry a failed tombstone write without ever retrying enrollment.
        persist_credential(&current, &local_option(CONTROL_PLANE_URL_KEY))?;
        recover_access()?;
    }
    bootstrap_managed_only()?;
    let mut first_error = None;
    let current = restored_snapshot();
    ensure_active(&current)?;
    let now = utc_now().timestamp();
    if current.renew_required || current.credential.as_ref().map_or(true, |c| lifecycle::refresh_due(now,
        c.claims.issued_at.timestamp(), c.claims.expires_at.timestamp(), lifecycle::CREDENTIAL_REFRESH_MARGIN_SECS)) {
        if let Err(error) = renew_credential() { first_error = Some(error); }
    }
    let current = restored_snapshot();
    // Policy has no issued_at in v1. A five-minute successful refresh ceiling
    // avoids tight loops for short policies while still checking UTC expiry.
    if current.policy.as_ref().map_or(true, |p| p.claims.expires_at.timestamp() <= now)
        || monotonic >= schedule.policy_at {
        match sync_policy() {
            Ok(()) => {
                let current = restored_snapshot();
                let remaining = current.policy.as_ref().map(|p| (p.claims.expires_at.timestamp() - now).max(1) as u64).unwrap_or(1);
                schedule.policy_at = monotonic + (remaining * 3 / 4).max(1).min(lifecycle::POLICY_REFRESH_MARGIN_SECS as u64);
            }
            Err(error) => { first_error.get_or_insert(error); }
        }
    }
    if monotonic >= schedule.config_at || !restored_snapshot().config_validated {
        match sync_deployment_config() {
            Ok(()) => schedule.config_at = monotonic + lifecycle::CONFIG_REFRESH_INTERVAL_SECS,
            Err(error) => { first_error.get_or_insert(error); }
        }
    }
    // Config failure must not starve authenticated revoke detection.
    if monotonic >= schedule.heartbeat_at {
        match heartbeat() {
            Ok(()) => schedule.heartbeat_at = monotonic + lifecycle::HEARTBEAT_INTERVAL_SECS,
            Err(error) => { first_error.get_or_insert(error); }
        }
    }
    if restored_snapshot().revoked { return Err("device_revoked".into()); }
    first_error.map_or(Ok(()), Err)
}

/// UI snapshot polling performs IPC on a Rust thread, never on Flutter's
/// synchronous status call. It owns no lifecycle mutation or secret material.
pub fn start_snapshot_reader() {
    if !is_managed_only() { return; }
    static START: std::sync::Once = std::sync::Once::new();
    START.call_once(|| {
        let _ = std::thread::Builder::new().name("managed-status".into()).spawn(|| {
            while !OWNER.load(std::sync::atomic::Ordering::SeqCst) {
                #[cfg(not(any(target_os = "android", target_os = "ios")))]
                if let Ok(snapshot) = crate::ipc::managed_snapshot() {
                    *SNAPSHOT_CACHE.lock().unwrap_or_else(|e| e.into_inner()) = Some((std::time::Instant::now(), snapshot));
                }
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        });
    });
}

pub fn snapshot_json() -> String {
    if !is_managed_only() {
        return serde_json::to_string(&status()).unwrap_or_default();
    }
    if OWNER.load(std::sync::atomic::Ordering::SeqCst) {
        if let Ok(current) = state().try_lock() {
            let snapshot = serde_json::to_string(&status_of(&current, local_option(REVOKED_KEY) == "Y")).unwrap_or_default();
            *SNAPSHOT_CACHE.lock().unwrap_or_else(|e| e.into_inner()) = Some((std::time::Instant::now(), snapshot.clone()));
            return snapshot;
        }
    }
    if let Some((updated, snapshot)) = SNAPSHOT_CACHE.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
        if updated.elapsed() < std::time::Duration::from_secs(3) { return snapshot.clone(); }
    }
    let unavailable = ManagedState { loaded: true, last_error: "owner_unavailable".into(), ..Default::default() };
    serde_json::to_string(&status_of(&unavailable, false)).unwrap_or_default()
}

/// Native connection entry point. The owner remains the only lifecycle worker;
/// connection authorization uses the existing account's store and fails closed
/// when that account cannot access the owner's identity. Nothing secret crosses IPC.
pub fn prepare_connection(target: &str, capability: &str) -> Result<(), String> {
    let mut raw = snapshot_json();
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    if !OWNER.load(std::sync::atomic::Ordering::SeqCst) {
        raw = crate::ipc::managed_snapshot().map_err(|_| "owner_unavailable")?;
    }
    let snapshot: serde_json::Value = serde_json::from_str(&raw).map_err(|_| "owner_unavailable")?;
    if snapshot["ready"] != true { return Err("managed_access_unavailable".into()); }
    let _operation = operations().lock().unwrap_or_else(|e| e.into_inner());
    if !OWNER.load(std::sync::atomic::Ordering::SeqCst) {
        let mut fresh = ManagedState::default();
        restore_if_needed(&mut fresh);
        fresh.config_validated = snapshot["ready"] == true;
        let mut current = state().lock().unwrap_or_else(|e| e.into_inner());
        fresh.session_tickets = current.session_tickets.clone();
        *current = fresh;
    }
    let local = restored_snapshot();
    if snapshot["device_id"].as_str() != Some(local.device_id.as_str()) {
        return Err("credential_owner_unavailable".into());
    }
    if !policy_allows(&local, capability) { return Err("managed_capability_denied".into()); }
    drop(_operation);
    request_session_ticket_for_rustdesk_id(target.into())
}

#[cfg(not(test))]
fn utc_now() -> DateTime<Utc> { Utc::now() }
#[cfg(test)]
thread_local! { static TEST_NOW: std::cell::Cell<Option<DateTime<Utc>>> = const { std::cell::Cell::new(None) }; }
#[cfg(test)]
fn utc_now() -> DateTime<Utc> { TEST_NOW.with(|now| now.get().unwrap_or_else(Utc::now)) }

#[cfg(not(test))]
fn local_option(key: &str) -> String { LocalConfig::get_option(key) }
#[cfg(not(test))]
fn set_local_option(key: String, value: String) { LocalConfig::set_option(key, value); }
#[cfg(not(test))]
fn config_option(key: &str) -> String { Config::get_option(key) }
#[cfg(not(test))]
fn set_config_option(key: &str, value: String) { Config::set_option(key.into(), value); }
#[cfg(not(test))]
fn restart_mediator() { crate::rendezvous_mediator::RendezvousMediator::restart(); }
#[cfg(not(test))]
fn local_rustdesk_id() -> String { Config::get_id() }
#[cfg(test)]
thread_local! { static TEST_OPTIONS: std::cell::RefCell<std::collections::HashMap<String,String>> = Default::default(); }
#[cfg(test)]
fn local_option(key: &str) -> String { TEST_OPTIONS.with(|o| o.borrow().get(key).cloned().unwrap_or_default()) }
#[cfg(test)]
fn set_local_option(key: String, value: String) { TEST_OPTIONS.with(|o| { o.borrow_mut().insert(key,value); }); }
#[cfg(test)]
fn config_option(key: &str) -> String { local_option(&format!("effective-{key}")) }
#[cfg(test)]
fn set_config_option(key: &str, value: String) { set_local_option(format!("effective-{key}"), value); }
#[cfg(test)]
fn restart_mediator() { set_local_option("mediator-restarts".into(), (local_option("mediator-restarts").parse::<u64>().unwrap_or(0) + 1).to_string()); }
#[cfg(test)]
fn local_rustdesk_id() -> String { "123456789".into() }

const CONTROL_PLANE_URL_KEY: &str = "managed-control-plane-url";
const REVOKED_KEY: &str = "managed-device-revoked";

#[cfg(feature = "managed-only")]
mod managed_bootstrap {
    include!(concat!(env!("OUT_DIR"), "/managed_bootstrap.rs"));
}

#[derive(Debug, Clone, Serialize)]
pub struct ManagedStatus {
    pub managed_only: bool,
    pub enrolled: bool,
    pub state: &'static str,
    pub device_id: String,
    pub control_plane_url: String,
    pub rendezvous_server: String,
    pub relay_server: String,
    pub public_key_fingerprint: String,
    pub credential_expires_at: String,
    pub policy_expires_at: String,
    pub policy_state: &'static str,
    pub persistence: &'static str,
    pub last_error: String,
    pub ready: bool,
    pub last_successful_sync: String,
    pub next_retry: String,
    pub capabilities: Vec<String>,
}

#[derive(Default, Clone)]
struct ManagedState {
    loaded: bool,
    generation: u64,
    revoked: bool,
    pending_claim: Option<managed_claim::EnrollmentV2>,
    provisioning_hash: String,
    config_validated: bool,
    last_successful_sync: String,
    next_retry: String,
    renew_required: bool,
    device_id: String,
    public_key_fingerprint: String,
    signing_key: Option<SigningKey>,
    credential_expires_at: String,
    issuer_public_key: String,
    credential: Option<SignedDeviceCredential>,
    policy: Option<SignedDevicePolicy>,
    session_tickets: std::collections::HashMap<String, SignedSessionTicket>,
    // This is deliberately diagnostic-only. It must never contain the device
    // signing key, enrollment token, or a stored credential.
    last_error: String,
}

#[derive(Serialize, Deserialize)]
struct StoredCredential {
    #[serde(default = "record_version")]
    version: u16,
    #[serde(default)]
    generation: u64,
    #[serde(default)]
    revoked: bool,
    #[serde(default)]
    pending_claim: Option<managed_claim::EnrollmentV2>,
    #[serde(default)]
    provisioning_hash: String,
    device_id: String,
    control_plane_url: String,
    #[serde(default)]
    last_successful_sync: String,
    public_key_fingerprint: String,
    signing_key: String,
    #[serde(default)]
    credential_expires_at: String,
    #[serde(default)]
    issuer_public_key: String,
    #[serde(default)]
    credential: Option<SignedDeviceCredential>,
    #[serde(default)]
    policy: Option<SignedDevicePolicy>,
}

fn record_version() -> u16 { 1 }

// Writes are serialized separately; readers never wait for HTTP.
fn operations() -> &'static Mutex<()> {
    static OPERATIONS: Mutex<()> = Mutex::new(());
    &OPERATIONS
}

fn restored_snapshot() -> ManagedState {
    let mut state = state().lock().unwrap_or_else(|e| e.into_inner());
    restore_if_needed(&mut state);
    state.clone()
}

fn commit(next: ManagedState, generation: u64, url: &str) -> Result<(), String> {
    let mut current = state().lock().unwrap_or_else(|e| e.into_inner());
    if current.generation != generation { return Err("stale_generation".into()); }
    persist_credential(&next, url)?;
    *current = next;
    Ok(())
}

fn request_json(url: &str, body: serde_json::Value, generation: u64) -> Result<serde_json::Value, String> {
    transport::post(url, &body).map_err(|error| response_error(error, generation))
}

fn response_error(error: transport::Failure, generation: u64) -> String {
    let status = error.status;
    let code = error.code;
    if status == 401 && code == "credential_expired" {
        let mut current = state().lock().unwrap_or_else(|e| e.into_inner());
        if current.generation == generation { current.renew_required = true; }
    }
    // Only our HTTPS/loopback control plane's explicit typed revoke is destructive.
    if status == 401 && code == "device_revoked" {
        let mut current = state().lock().unwrap_or_else(|e| e.into_inner());
        restore_if_needed(&mut current);
        if current.generation == generation {
            let mut revoked = current.clone();
            revoked.generation = generation.saturating_add(1);
            revoked.revoked = true;
            revoked.config_validated = false;
            revoked.session_tickets.clear();
            revoked.last_error = "device_revoked".into();
            // Fail closed in memory even if the credential store is temporarily unavailable.
            set_local_option(REVOKED_KEY.into(), "Y".into());
            let _ = persist_credential(&revoked, &local_option(CONTROL_PLANE_URL_KEY));
            *current = revoked;
        }
        return "device_revoked".into();
    }
    match code.as_str() {
        "credential_expired" | "invalid_device_proof" | "clock_skew" |
        "provisioning_invalid" | "provisioning_expired" | "identity_conflict" => code,
        _ if status >= 500 || status == 429 || status == 0 => "temporarily_unavailable".into(),
        _ => "authorization_rejected".into(),
    }
}

#[derive(Deserialize)]
struct EnrollmentResponse {
    id: String,
}

#[derive(Clone, Deserialize, Serialize)]
struct DeviceCredentialClaims {
    version: u16,
    device_id: uuid::Uuid,
    rustdesk_id: String,
    public_key_fingerprint: String,
    issued_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
}

#[derive(Clone, Deserialize, Serialize)]
struct SignedDeviceCredential {
    claims: DeviceCredentialClaims,
    signature: String,
    issuer_public_key: String,
}

#[derive(Clone, Deserialize, Serialize)]
struct SessionTicketClaims {
    version: u16,
    ticket_id: uuid::Uuid,
    source_device_id: uuid::Uuid,
    target_device_id: uuid::Uuid,
    expires_at: DateTime<Utc>,
    permissions: Vec<String>,
}

#[derive(Clone, Deserialize)]
struct SignedSessionTicket {
    claims: SessionTicketClaims,
    signature: String,
    issuer_public_key: String,
}

#[derive(Clone, Deserialize, Serialize)]
struct DevicePolicyClaims {
    version: u16,
    device_id: uuid::Uuid,
    revision: u64,
    expires_at: DateTime<Utc>,
    capabilities: Vec<String>,
}

#[derive(Clone, Deserialize, Serialize)]
struct SignedDevicePolicy {
    claims: DevicePolicyClaims,
    signature: String,
    issuer_public_key: String,
}

#[derive(Clone, Deserialize, Serialize)]
struct DeploymentConfigClaims {
    version: u16,
    revision: i64,
    rendezvous_server: String,
    relay_server: String,
    server_public_key: String,
    issued_at: DateTime<Utc>,
}

#[derive(Clone, Deserialize)]
struct SignedDeploymentConfig {
    claims: DeploymentConfigClaims,
    signature: String,
    issuer_public_key: String,
}

fn state() -> &'static Mutex<ManagedState> {
    static STATE: OnceLock<Mutex<ManagedState>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(ManagedState::default()))
}


fn restore_if_needed(guard: &mut ManagedState) {
    if guard.loaded {
        return;
    }
    let raw = match store::load() {
        Ok(Some(raw)) => raw,
        Ok(None) => {
            guard.loaded = true;
            guard.revoked = local_option(REVOKED_KEY) == "Y";
            if guard.revoked { guard.last_error = "recovery_identity_missing".into(); }
            return;
        }
        Err(code) => { guard.last_error = code; return; }
    };
    let stored = match serde_json::from_str::<StoredCredential>(&raw) {
        Ok(stored) => stored,
        Err(_) => {
            guard.last_error =
                "stored managed credential is malformed; re-enrollment is required".to_owned();
            return;
        }
    };
    if stored.version > 2 {
        guard.last_error = "credential_store_version".into();
        return;
    }
    #[cfg(feature = "managed-only")]
    if stored.control_plane_url != managed_bootstrap::CP_URL.trim_end_matches('/') {
        guard.last_error = "deployment_mismatch".into();
        return;
    }
    let bytes = match hex::decode(stored.signing_key) {
        Ok(bytes) => bytes,
        Err(_) => {
            guard.last_error =
                "stored managed signing key is malformed; re-enrollment is required".to_owned();
            return;
        }
    };
    let bytes = match <[u8; 32]>::try_from(bytes.as_slice()) {
        Ok(bytes) => bytes,
        Err(_) => {
            guard.last_error =
                "stored managed signing key has an invalid length; re-enrollment is required"
                    .to_owned();
            return;
        }
    };
    let key = SigningKey::from_bytes(&bytes);
    if hex::encode(Sha256::digest(key.verifying_key().as_bytes())) != stored.public_key_fingerprint {
        guard.last_error = "credential_store_identity_mismatch".into();
        return;
    }
    guard.device_id = stored.device_id;
    guard.loaded = true;
    guard.generation = stored.generation;
    guard.revoked = stored.revoked || local_option(REVOKED_KEY) == "Y";
    guard.pending_claim = stored.pending_claim;
    guard.provisioning_hash = stored.provisioning_hash;
    guard.public_key_fingerprint = stored.public_key_fingerprint;
    guard.signing_key = Some(key);
    guard.credential_expires_at = stored.credential_expires_at;
    guard.last_successful_sync = stored.last_successful_sync;
    guard.issuer_public_key = stored.issuer_public_key;
    guard.credential = stored.credential;
    guard.policy = stored.policy;
    if guard.credential.as_ref().is_some_and(|credential| verify_credential(credential, guard).is_err()) {
        guard.credential = None;
        guard.credential_expires_at.clear();
    }
    if guard.policy.as_ref().is_some_and(|policy| verify_policy(policy, guard).is_err()) {
        guard.policy = None;
    }
    guard.last_error.clear();
    log::info!("Restored managed credential from the OS credential store");
    // A managed-only build pins its CP URL at compile time. Do not let an
    // older Keychain record redirect a rebuilt client to a previous CP.
    #[cfg(not(feature = "managed-only"))]
    set_local_option(CONTROL_PLANE_URL_KEY.to_owned(), stored.control_plane_url);
}

pub fn configure(control_plane_url: String) -> Result<(), String> {
    let url = control_plane_url.trim().trim_end_matches('/');
    #[cfg(feature = "managed-only")]
    if url != managed_bootstrap::CP_URL.trim_end_matches('/') { return Err("managed_by_administrator".into()); }
    let parsed = url::Url::parse(url).map_err(|_| "invalid_control_plane_url".to_owned())?;
    let loopback = match parsed.host() {
        Some(url::Host::Domain(host)) => host == "localhost",
        Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
        Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
        None => false,
    };
    if parsed.host().is_none() || !parsed.username().is_empty() || parsed.password().is_some()
        || parsed.query().is_some() || parsed.fragment().is_some()
        || !(parsed.scheme() == "https" || (parsed.scheme() == "http" && loopback)) {
        return Err(
            "control plane URL must use HTTPS (loopback HTTP is allowed for development)"
                .to_owned(),
        );
    }
    set_local_option(CONTROL_PLANE_URL_KEY.to_owned(), url.to_owned());
    Ok(())
}

/// Starts the fixed managed deployment without exposing its bootstrap token to
/// Flutter. Non-managed builds intentionally keep the existing manual flow.
#[cfg(feature = "managed-only")]
pub fn bootstrap_managed_only() -> Result<(), String> {
    configure(managed_bootstrap::CP_URL.to_owned())?;
    let current = restored_snapshot();
    if current.revoked || local_option(REVOKED_KEY) == "Y" { return Err("device_revoked".into()); }
    if current.device_id.is_empty() {
        enroll(managed_bootstrap::BOOTSTRAP_TOKEN.into(), crate::common::hostname())?;
    }
    Ok(())
}

#[cfg(not(feature = "managed-only"))]
pub fn bootstrap_managed_only() -> Result<(), String> {
    Ok(())
}

#[cfg(feature = "managed-only")]
pub fn is_managed_only() -> bool {
    true
}

#[cfg(not(feature = "managed-only"))]
pub fn is_managed_only() -> bool {
    false
}

#[cfg(feature = "managed-only")]
pub fn sync_deployment_config() -> Result<(), String> {
    let _operation = operations().lock().unwrap_or_else(|e| e.into_inner());
    let current = restored_snapshot();
    ensure_active(&current)?;
    let timestamp = utc_now().timestamp();
    let nonce = uuid::Uuid::new_v4();
    use ed25519_dalek::Signer;
    let payload = format!("{}:{timestamp}:{nonce}:managed-config", current.device_id);
    let signature = hex::encode(current.signing_key.as_ref().ok_or("identity_unavailable")?.sign(payload.as_bytes()).to_bytes());
    let response = request_json(&format!("{}/v1/managed/config", local_option(CONTROL_PLANE_URL_KEY)),
        serde_json::json!({"device_id":current.device_id, "timestamp":timestamp, "nonce":nonce, "signature":signature}), current.generation)?;
    let config: SignedDeploymentConfig = serde_json::from_value(response).map_err(|_| "invalid_config_response")?;
    verify_deployment_config(&config)?;
    let mut guard = state().lock().unwrap_or_else(|e| e.into_inner());
    if guard.generation != current.generation || guard.revoked { return Err("stale_generation".into()); }
    let changed = config_option("custom-rendezvous-server") != config.claims.rendezvous_server
        || config_option("relay-server") != config.claims.relay_server
        || config_option("key") != config.claims.server_public_key;
    apply_deployment_config(config.claims.revision, config.claims.rendezvous_server,
        config.claims.relay_server, config.claims.server_public_key)?;
    guard.config_validated = true;
    drop(guard);
    if changed { restart_mediator(); }
    Ok(())
}

#[cfg(feature = "managed-only")]
fn apply_deployment_config(
    revision: i64,
    rendezvous_server: String,
    relay_server: String,
    server_public_key: String,
) -> Result<(), String> {
    set_config_option("custom-rendezvous-server", rendezvous_server.clone());
    set_config_option("relay-server", relay_server.clone());
    set_config_option("key", server_public_key);
    set_config_option("api-server", String::new());
    log::info!(
        "Applied managed deployment revision {revision}: hbbs={rendezvous_server}, hbbr={relay_server}"
    );
    Ok(())
}

#[cfg(not(feature = "managed-only"))]
pub fn sync_deployment_config() -> Result<(), String> {
    Ok(())
}

#[cfg(feature = "managed-only")]
fn verify_deployment_config(config: &SignedDeploymentConfig) -> Result<(), String> {
    if config.claims.version != 1
        || config.claims.revision < 1
        || config.claims.rendezvous_server.trim().is_empty()
        || config.claims.relay_server.trim().is_empty()
        || config.claims.server_public_key.trim().is_empty()
        || config.issuer_public_key != managed_bootstrap::CONFIG_PUBLIC_KEY
    {
        return Err("managed configuration claims are invalid".to_owned());
    }
    let key = hex::decode(&config.issuer_public_key)
        .map_err(|_| "managed configuration issuer is malformed".to_owned())?;
    let key: [u8; 32] = key
        .as_slice()
        .try_into()
        .map_err(|_| "managed configuration issuer has invalid length".to_owned())?;
    let key = VerifyingKey::from_bytes(&key)
        .map_err(|_| "managed configuration issuer is invalid".to_owned())?;
    let signature = hex::decode(&config.signature)
        .ok()
        .and_then(|bytes| Signature::from_slice(&bytes).ok())
        .ok_or_else(|| "managed configuration signature is invalid".to_owned())?;
    let payload = serde_json::to_vec(&config.claims)
        .map_err(|error| format!("could not verify managed configuration: {error}"))?;
    key.verify(&payload, &signature)
        .map_err(|_| "managed configuration signature verification failed".to_owned())
}

pub fn status() -> ManagedStatus {
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    restore_if_needed(&mut guard);
    status_of(&guard, local_option(REVOKED_KEY) == "Y")
}

fn status_of(guard: &ManagedState, revoked: bool) -> ManagedStatus {
    let enrolled = !guard.device_id.is_empty();
    let revoked = revoked || guard.revoked;
    let ready = !revoked && diagnostic_allows_cache(&guard.last_error)
        && (!is_managed_only() || guard.config_validated) && credential_valid(guard)
        && guard.policy.as_ref().is_some_and(|p| p.claims.expires_at > utc_now());
    let policy_state = match guard.policy.as_ref() {
        Some(policy) if policy.claims.expires_at > utc_now() => "active",
        Some(_) => "expired",
        None => "unavailable",
    };
    ManagedStatus {
        managed_only: is_managed_only(),
        enrolled,
        state: if revoked {
            "revoked"
        } else if !guard.last_error.is_empty() {
            if guard.last_error == "temporarily_unavailable" { "reconnecting" } else { "waiting_for_admin" }
        } else if ready {
            "ready"
        } else {
            "setting_up"
        },
        device_id: guard.device_id.clone(),
        control_plane_url: local_option(CONTROL_PLANE_URL_KEY),
        rendezvous_server: config_option("custom-rendezvous-server"),
        relay_server: config_option("relay-server"),
        public_key_fingerprint: guard.public_key_fingerprint.clone(),
        credential_expires_at: guard.credential_expires_at.clone(),
        policy_expires_at: guard
            .policy
            .as_ref()
            .map(|policy| policy.claims.expires_at.to_rfc3339())
            .unwrap_or_default(),
        policy_state,
        persistence: "os-credential-store",
        last_error: diagnostic_code(&guard.last_error).into(),
        ready,
        last_successful_sync: guard.last_successful_sync.clone(),
        next_retry: guard.next_retry.clone(),
        capabilities: if ready { guard.policy.as_ref().map(|p| p.claims.capabilities.clone()).unwrap_or_default() } else { Vec::new() },
    }
}

#[cfg(test)]
#[path = "managed_client/executor_tests.rs"]
mod executor_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enrollment_alone_is_not_ready() {
        let state = ManagedState { device_id: uuid::Uuid::new_v4().to_string(), ..Default::default() };
        assert_eq!(status_of(&state, false).state, "setting_up");
    }

    #[test]
    fn revoked_overrides_cached_enrollment() {
        let state = ManagedState { device_id: uuid::Uuid::new_v4().to_string(), ..Default::default() };
        assert_eq!(status_of(&state, true).state, "revoked");
    }

    #[test]
    fn expired_credential_denies_new_session() {
        let mut state = ManagedState::default();
        state.policy = Some(SignedDevicePolicy {
            claims: DevicePolicyClaims { version: 1, device_id: uuid::Uuid::new_v4(), revision: 1,
                expires_at: utc_now() + chrono::Duration::hours(1), capabilities: vec!["remote-control".into()] },
            signature: String::new(), issuer_public_key: String::new(),
        });
        assert!(!policy_allows(&state, "remote-control"));
    }
}

/// Produces the public, signed registration envelope for the managed wire
/// protocol. Private device key material never leaves this module.
pub fn registration_credential() -> Option<ManagedDeviceCredential> {
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    restore_if_needed(&mut guard);
    if guard.revoked || (is_managed_only() && !status_of(&guard, false).ready) { return None; }
    let credential = guard.credential.as_ref()?;
    if credential.claims.expires_at <= utc_now() {
        return None;
    }
    let claims = serde_json::to_vec(&credential.claims).ok()?;
    let signature = hex::decode(&credential.signature).ok()?;
    let issuer_public_key = hex::decode(&credential.issuer_public_key).ok()?;
    Some(ManagedDeviceCredential {
        version: u32::from(credential.claims.version),
        claims: claims.into(),
        signature: signature.into(),
        issuer_public_key: issuer_public_key.into(),
        ..Default::default()
    })
}

/// Returns the current public session authorization envelope. The client core
/// owns the signed ticket; callers cannot inspect or alter its claims.
pub fn session_ticket_for(target: &str) -> Option<ManagedSessionTicket> {
    let guard = restored_snapshot();
    ticket_envelope(&guard, target)
}

fn ticket_envelope(guard: &ManagedState, target: &str) -> Option<ManagedSessionTicket> {
    if !policy_allows(guard, "remote-control") { return None; }
    let ticket = guard.session_tickets.get(target)?;
    if ticket.claims.expires_at <= utc_now() { return None; }
    Some(ManagedSessionTicket {
        version: u32::from(ticket.claims.version),
        claims: serde_json::to_vec(&ticket.claims).ok()?.into(),
        signature: hex::decode(&ticket.signature).ok()?.into(),
        issuer_public_key: hex::decode(&ticket.issuer_public_key).ok()?.into(),
        ..Default::default()
    })
}

/// Feature handlers must call this before enabling a managed capability. The
/// signed, expiring policy is the authority; portal state is never trusted at
/// the data-plane boundary.
pub fn capability_allowed(capability: &str) -> bool {
    if is_managed_only() {
        let snapshot: serde_json::Value = serde_json::from_str(&snapshot_json()).unwrap_or_default();
        if snapshot["ready"] != true { return false; }
        if !OWNER.load(std::sync::atomic::Ordering::SeqCst) {
            let valid_until = |field: &str| snapshot[field].as_str().and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                .is_some_and(|date| date > utc_now());
            return valid_until("credential_expires_at") && valid_until("policy_expires_at")
                && snapshot["capabilities"].as_array().is_some_and(|caps| caps.iter().any(|c| c.as_str() == Some(capability)));
        }
    }
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    restore_if_needed(&mut guard);
    matches!(
        capability,
        "remote-control"
            | "clipboard"
            | "file-transfer"
            | "terminal"
            | "port-forwarding"
            | "recording"
    ) && policy_allows(&guard, capability)
}

pub fn enroll(enrollment_token: String, display_name: String) -> Result<ManagedStatus, String> {
    let _operation = operations().lock().unwrap_or_else(|e| e.into_inner());
    let url = local_option(CONTROL_PLANE_URL_KEY);
    if url.is_empty() { return Err("deployment_unavailable".into()); }
    let current = restored_snapshot();
    if current.revoked || local_option(REVOKED_KEY) == "Y" { return Err("device_revoked".into()); }
    if !current.loaded { return Err("credential_store_unavailable".into()); }
    if !current.device_id.is_empty() { return Ok(status_of(&current, false)); }
    let token = enrollment_token.trim();
    if token.is_empty() { return Err("provisioning_invalid".into()); }
    let token_hash = hex::encode(Sha256::digest(token.as_bytes()));
    let mut pending = current.clone();
    if pending.signing_key.is_none() {
        let key = SigningKey::generate(&mut OsRng);
        pending.public_key_fingerprint = hex::encode(Sha256::digest(key.verifying_key().as_bytes()));
        pending.pending_claim = Some(managed_claim::EnrollmentV2 {
            token: String::new(), request_id: uuid::Uuid::new_v4(), timestamp: 0, signature: String::new(),
            public_key_fingerprint: pending.public_key_fingerprint.clone(),
            public_key: hex::encode(key.verifying_key().as_bytes()), rustdesk_id: local_rustdesk_id(),
            display_name: display_name.trim().into(),
            hostname: crate::common::hostname(),
            operating_system: std::env::consts::OS.into(), client_version: env!("CARGO_PKG_VERSION").into(),
        });
        pending.signing_key = Some(key);
        pending.provisioning_hash = token_hash.clone();
        pending.generation += 1;
        commit(pending.clone(), current.generation, &url)?;
    }
    if pending.provisioning_hash != token_hash { return Err("provisioning_changed".into()); }
    let mut claim = pending.pending_claim.clone().ok_or("pending_identity_unavailable")?;
    claim.token = token.into();
    claim.timestamp = utc_now().timestamp();
    use ed25519_dalek::Signer;
    claim.signature = hex::encode(pending.signing_key.as_ref().ok_or("pending_identity_unavailable")?.sign(&claim.payload()).to_bytes());
    let response = request_json(&format!("{url}/v1/enrollment/claim-v2"),
        serde_json::to_value(&claim).map_err(|_| "invalid_request")?, pending.generation)?;
    let enrolled: EnrollmentResponse = serde_json::from_value(response).map_err(|_| "invalid_enrollment_response")?;
    enrolled.id.parse::<uuid::Uuid>().map_err(|_| "invalid_enrollment_response")?;
    pending.device_id = enrolled.id;
    pending.pending_claim = None;
    pending.last_error.clear();
    let generation = pending.generation;
    commit(pending, generation, &url)?;
    Ok(status())
}

fn recover_access() -> Result<(), String> {
    let _operation = operations().lock().unwrap_or_else(|e| e.into_inner());
    let mut next = restored_snapshot();
    if !next.revoked { return Err("stale_generation".into()); }
    let generation = next.generation;
    let url = local_option(CONTROL_PLANE_URL_KEY);
    let proof = signed_proof(&next, "device-recovery", serde_json::Value::Null)?;
    let response = request_json(&format!("{url}/v1/devices/{}/recovery",next.device_id),proof.clone(),generation)?;
    let recovery: managed_claim::SignedRecovery<SignedDeviceCredential,SignedDevicePolicy> =
        serde_json::from_value(response).map_err(|_| "invalid_recovery_response")?;
    let claims = &recovery.claims;
    let now = utc_now().timestamp();
    if claims.version != 1 || claims.purpose != "device-recovery"
        || claims.device_id != next.device_id || claims.nonce != proof["nonce"].as_str().unwrap_or_default()
        || Some(claims.timestamp) != proof["timestamp"].as_i64()
        || now.abs_diff(claims.timestamp) > 300 || now.abs_diff(claims.issued_at) > 300
        || claims.expires_at <= now || claims.expires_at <= claims.issued_at
        || claims.expires_at > claims.issued_at.saturating_add(60)
        || recovery.issuer_public_key != claims.credential.issuer_public_key
        || claims.credential.claims.rustdesk_id != local_rustdesk_id()
        || claims.credential.claims.issued_at.timestamp() != claims.issued_at
        || claims.credential.claims.expires_at <= claims.credential.claims.issued_at {
        return Err("invalid_recovery_response".into());
    }
    verify_credential(&claims.credential,&next)?;
    next.issuer_public_key = claims.credential.issuer_public_key.clone();
    verify_policy(&claims.policy,&next)?;
    let issuer: [u8;32] = hex::decode(&recovery.issuer_public_key).map_err(|_| "invalid_recovery_response")?
        .try_into().map_err(|_| "invalid_recovery_response")?;
    let signature = hex::decode(&recovery.signature).map_err(|_| "invalid_recovery_response")?;
    let signature = Signature::from_slice(&signature).map_err(|_| "invalid_recovery_response")?;
    VerifyingKey::from_bytes(&issuer).map_err(|_| "invalid_recovery_response")?
        .verify(&serde_json::to_vec(claims).map_err(|_| "invalid_recovery_response")?,&signature)
        .map_err(|_| "invalid_recovery_response")?;
    next.credential_expires_at = claims.credential.claims.expires_at.to_rfc3339();
    next.credential = Some(claims.credential.clone());
    next.policy = Some(claims.policy.clone());
    next.renew_required = false;
    next.config_validated = false;
    next.revoked = false;
    next.last_error.clear();
    // Hold the generation fence across the single atomic secret-store write and
    // marker clear. A failed write leaves both in-memory and durable tombstones.
    let mut current = state().lock().unwrap_or_else(|e| e.into_inner());
    if current.generation != generation || !current.revoked { return Err("stale_generation".into()); }
    persist_credential(&next,&url)?;
    set_local_option(REVOKED_KEY.into(),String::new());
    *current = next;
    Ok(())
}

pub fn renew_credential() -> Result<(), String> {
    let _operation = operations().lock().unwrap_or_else(|e| e.into_inner());
    let mut next = restored_snapshot();
    ensure_active(&next)?;
    let generation = next.generation;
    let url = local_option(CONTROL_PLANE_URL_KEY);
    let proof = signed_proof(&next, "credential-renew", serde_json::Value::Null)?;
    let response = request_json(&format!("{url}/v1/devices/{}/credential/renew", next.device_id), proof, generation)?;
    let credential: SignedDeviceCredential = serde_json::from_value(response).map_err(|_| "invalid_credential_response")?;
    verify_credential(&credential, &next)?;
    next.credential_expires_at = credential.claims.expires_at.to_rfc3339();
    next.issuer_public_key = credential.issuer_public_key.clone();
    next.credential = Some(credential);
    next.renew_required = false;
    commit(next, generation, &url)
}

pub fn sync_policy() -> Result<(), String> {
    let _operation = operations().lock().unwrap_or_else(|e| e.into_inner());
    let mut next = restored_snapshot();
    ensure_active(&next)?;
    let generation = next.generation;
    let url = local_option(CONTROL_PLANE_URL_KEY);
    let credential = next.credential.as_ref().ok_or("credential_expired")?;
    let response = request_json(&format!("{url}/v1/device-policy"), serde_json::json!({"credential": credential}), generation)?;
    let policy: SignedDevicePolicy = serde_json::from_value(response).map_err(|_| "invalid_policy_response")?;
    verify_policy(&policy, &next)?;
    next.policy = Some(policy);
    commit(next, generation, &url)
}

fn ensure_active(state: &ManagedState) -> Result<(), String> {
    if state.revoked { return Err("device_revoked".into()); }
    if state.device_id.is_empty() || state.signing_key.is_none() { return Err("identity_unavailable".into()); }
    Ok(())
}

fn signed_proof(state: &ManagedState, purpose: &str, metadata: serde_json::Value) -> Result<serde_json::Value, String> {
    if purpose != "device-recovery" { ensure_active(state)?; }
    if state.device_id.is_empty() || state.signing_key.is_none() { return Err("identity_unavailable".into()); }
    let timestamp = utc_now().timestamp();
    let nonce = uuid::Uuid::new_v4().to_string();
    let payload = managed_claim::device_proof(&state.device_id, timestamp, &nonce, purpose, &metadata);
    use ed25519_dalek::Signer;
    let signature = state.signing_key.as_ref().ok_or("identity_unavailable")?.sign(payload.as_bytes());
    Ok(serde_json::json!({"proof_version":2, "timestamp":timestamp, "nonce":nonce,
        "signature":hex::encode(signature.to_bytes()), "metadata": metadata}))
}

pub fn request_session_ticket(target_device_id: String) -> Result<(), String> {
    target_device_id.parse::<uuid::Uuid>().map_err(|_| "invalid_target")?;
    request_ticket(target_device_id, false)
}

pub fn request_session_ticket_for_rustdesk_id(target_rustdesk_id: String) -> Result<(), String> {
    if target_rustdesk_id.trim().is_empty() || target_rustdesk_id.len() > 256 { return Err("invalid_target".into()); }
    request_ticket(target_rustdesk_id.trim().into(), true)
}

fn request_ticket(target: String, rustdesk_id: bool) -> Result<(), String> {
    let _operation = operations().lock().unwrap_or_else(|e| e.into_inner());
    let mut next = restored_snapshot();
    if !policy_allows(&next, "remote-control") { return Err("managed_access_unavailable".into()); }
    let generation = next.generation;
    let mut body = serde_json::json!({"credential":next.credential, "permissions":["remote-control"]});
    body[if rustdesk_id { "target_rustdesk_id" } else { "target_device_id" }] = target.clone().into();
    let response = request_json(&format!("{}/v1/session-tickets", local_option(CONTROL_PLANE_URL_KEY)), body, generation)?;
    let ticket: SignedSessionTicket = serde_json::from_value(response).map_err(|_| "invalid_ticket_response")?;
    verify_session_ticket(&ticket, &next, ticket.claims.target_device_id)?;
    if !rustdesk_id && ticket.claims.target_device_id.to_string() != target { return Err("invalid_ticket_target".into()); }
    next.session_tickets.retain(|_, ticket| ticket.claims.expires_at > utc_now());
    next.session_tickets.insert(target, ticket);
    let mut current = state().lock().unwrap_or_else(|e| e.into_inner());
    if current.generation != generation || current.revoked { return Err("stale_generation".into()); }
    current.session_tickets = next.session_tickets;
    Ok(())
}

fn verify_session_ticket(
    ticket: &SignedSessionTicket,
    state: &ManagedState,
    target_device_id: uuid::Uuid,
) -> Result<(), String> {
    if ticket.claims.version != 1
        || ticket.claims.source_device_id.to_string() != state.device_id
        || ticket.claims.target_device_id != target_device_id
        || ticket.claims.expires_at <= utc_now()
        || ticket.claims.permissions.as_slice() != ["remote-control"]
        || ticket.issuer_public_key != state.issuer_public_key
    {
        return Err("session ticket response has invalid claims".to_owned());
    }
    let issuer_bytes = hex::decode(&ticket.issuer_public_key)
        .map_err(|_| "session ticket issuer key is malformed".to_owned())?;
    let issuer_bytes: [u8; 32] = issuer_bytes
        .as_slice()
        .try_into()
        .map_err(|_| "session ticket issuer key has an invalid length".to_owned())?;
    let issuer = VerifyingKey::from_bytes(&issuer_bytes)
        .map_err(|_| "session ticket issuer key is invalid".to_owned())?;
    let signature_bytes = hex::decode(&ticket.signature)
        .map_err(|_| "session ticket signature is malformed".to_owned())?;
    let signature = Signature::from_slice(&signature_bytes)
        .map_err(|_| "session ticket signature is invalid".to_owned())?;
    let payload = serde_json::to_vec(&ticket.claims)
        .map_err(|error| format!("could not validate session ticket: {error}"))?;
    issuer
        .verify(&payload, &signature)
        .map_err(|_| "session ticket signature verification failed".to_owned())
}

fn policy_allows(state: &ManagedState, capability: &str) -> bool {
    !state.revoked && diagnostic_allows_cache(&state.last_error)
        && (!is_managed_only() || state.config_validated)
        && credential_valid(state) && state.policy.as_ref().is_some_and(|policy| {
        policy.claims.expires_at > utc_now()
            && policy
                .claims
                .capabilities
                .iter()
                .any(|value| value == capability)
    })
}

fn diagnostic_allows_cache(code: &str) -> bool {
    code.is_empty() || code == "temporarily_unavailable"
}

fn diagnostic_code(code: &str) -> &str {
    match code {
        "" | "device_revoked" | "credential_expired" | "invalid_device_proof" | "clock_skew"
        | "provisioning_invalid" | "provisioning_expired" | "provisioning_changed" | "identity_conflict"
        | "temporarily_unavailable" | "authorization_rejected" | "owner_unavailable"
        | "credential_store_unavailable" | "credential_store_unsupported" | "deployment_mismatch"
        | "credential_store_version" | "pending_identity_unavailable" | "recovery_identity_missing" => code,
        "credential_store_too_large" | "credential_store_access_denied" | "credential_store_encoding" => code,
        _ => "managed_validation_failed",
    }
}

fn credential_valid(state: &ManagedState) -> bool {
    state.credential.as_ref().is_some_and(|c| c.claims.expires_at > utc_now())
}

fn verify_policy(policy: &SignedDevicePolicy, state: &ManagedState) -> Result<(), String> {
    if policy.claims.version != 1
        || policy.claims.device_id.to_string() != state.device_id
        || policy.claims.expires_at <= utc_now()
        || policy.issuer_public_key != state.issuer_public_key
        || policy
            .claims
            .capabilities
            .iter()
            .any(|capability| capability.is_empty() || capability.len() > 64)
    {
        return Err("policy response has invalid claims".to_owned());
    }
    let issuer_bytes = hex::decode(&policy.issuer_public_key)
        .map_err(|_| "policy issuer key is malformed".to_owned())?;
    let issuer_bytes: [u8; 32] = issuer_bytes
        .as_slice()
        .try_into()
        .map_err(|_| "policy issuer key has an invalid length".to_owned())?;
    let issuer = VerifyingKey::from_bytes(&issuer_bytes)
        .map_err(|_| "policy issuer key is invalid".to_owned())?;
    let signature_bytes =
        hex::decode(&policy.signature).map_err(|_| "policy signature is malformed".to_owned())?;
    let signature = Signature::from_slice(&signature_bytes)
        .map_err(|_| "policy signature is invalid".to_owned())?;
    let payload = serde_json::to_vec(&policy.claims)
        .map_err(|error| format!("could not validate policy claims: {error}"))?;
    issuer
        .verify(&payload, &signature)
        .map_err(|_| "policy signature verification failed".to_owned())
}

fn verify_credential(
    credential: &SignedDeviceCredential,
    state: &ManagedState,
) -> Result<(), String> {
    if credential.claims.version != 1
        || credential.claims.device_id.to_string() != state.device_id
        || credential.claims.public_key_fingerprint != state.public_key_fingerprint
        || credential.claims.expires_at <= utc_now()
    {
        return Err("credential renewal response has invalid claims".to_owned());
    }
    if !state.issuer_public_key.is_empty()
        && state.issuer_public_key != credential.issuer_public_key
    {
        return Err("credential issuer key changed; re-enrollment is required".to_owned());
    }
    let issuer_bytes = hex::decode(&credential.issuer_public_key)
        .map_err(|_| "credential issuer key is malformed".to_owned())?;
    let issuer_bytes: [u8; 32] = issuer_bytes
        .as_slice()
        .try_into()
        .map_err(|_| "credential issuer key has an invalid length".to_owned())?;
    let issuer = VerifyingKey::from_bytes(&issuer_bytes)
        .map_err(|_| "credential issuer key is invalid".to_owned())?;
    let signature_bytes = hex::decode(&credential.signature)
        .map_err(|_| "credential signature is malformed".to_owned())?;
    let signature = Signature::from_slice(&signature_bytes)
        .map_err(|_| "credential signature is invalid".to_owned())?;
    let payload = serde_json::to_vec(&credential.claims)
        .map_err(|error| format!("could not validate credential claims: {error}"))?;
    issuer
        .verify(&payload, &signature)
        .map_err(|_| "credential signature verification failed".to_owned())
}

fn persist_credential(state: &ManagedState, control_plane_url: &str) -> Result<(), String> {
    let signing_key = state
        .signing_key
        .as_ref()
        .ok_or_else(|| "device signing key is unavailable".to_owned())?;
    let stored = StoredCredential {
        version: 2,
        generation: state.generation,
        revoked: state.revoked,
        pending_claim: state.pending_claim.clone(),
        provisioning_hash: state.provisioning_hash.clone(),
        device_id: state.device_id.clone(),
        control_plane_url: control_plane_url.to_owned(),
        last_successful_sync: state.last_successful_sync.clone(),
        public_key_fingerprint: state.public_key_fingerprint.clone(),
        signing_key: hex::encode(signing_key.to_bytes()),
        credential_expires_at: state.credential_expires_at.clone(),
        issuer_public_key: state.issuer_public_key.clone(),
        credential: state.credential.clone(),
        policy: state.policy.clone(),
    };
    let encoded = serde_json::to_string(&stored)
        .map_err(|error| format!("could not encode managed credential: {error}"))?;
    store::save(&encoded)?;
    log::info!("Persisted managed credential in the OS credential store");
    Ok(())
}

pub fn heartbeat() -> Result<(), String> {
    let _operation = operations().lock().unwrap_or_else(|e| e.into_inner());
    let current = restored_snapshot();
    let proof = signed_proof(&current, "heartbeat", serde_json::json!({
        "hostname": crate::common::hostname(),
        "operating_system": std::env::consts::OS, "client_version": env!("CARGO_PKG_VERSION"),
        "capabilities": ["remote-control", "file-transfer", "clipboard"], "health": {"status":"healthy"}
    }))?;
    request_json(&format!("{}/v1/devices/{}/heartbeat", local_option(CONTROL_PLANE_URL_KEY), current.device_id), proof, current.generation)?;
    Ok(())
}

pub fn deprovision(revoked: bool) -> Result<(), String> {
    if is_managed_only() && !revoked { return Err("managed_by_administrator".into()); }
    let _operation = operations().lock().unwrap_or_else(|e| e.into_inner());
    if revoked {
        let generation = restored_snapshot().generation;
        response_error(transport::Failure{status:401,code:"device_revoked".into()},generation);
        return Ok(());
    }
    store::delete()?;
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    *guard = ManagedState::default();
    set_local_option(
        REVOKED_KEY.to_owned(),
        if revoked { "Y" } else { "" }.to_owned(),
    );
    if revoked {
        log::warn!("Cleared managed credential after control plane revocation");
    }
    Ok(())
}
