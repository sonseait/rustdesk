//! Managed-platform enrollment core. UI callers receive status only; the
//! signing key is deliberately kept on the Rust side.

use chrono::{DateTime, Utc};
use ed25519_dalek::{Signature, SigningKey, Verifier, VerifyingKey};
use hbb_common::rendezvous_proto::{ManagedDeviceCredential, ManagedSessionTicket};
use hbb_common::{
    config::{Config, LocalConfig},
    log,
};
use keyring::Entry;
use rand_core::OsRng;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::{Mutex, OnceLock};

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
}

#[derive(Default)]
struct ManagedState {
    device_id: String,
    public_key_fingerprint: String,
    signing_key: Option<SigningKey>,
    credential_expires_at: String,
    issuer_public_key: String,
    credential: Option<SignedDeviceCredential>,
    policy: Option<SignedDevicePolicy>,
    pending_session_ticket: Option<SignedSessionTicket>,
    // This is deliberately diagnostic-only. It must never contain the device
    // signing key, enrollment token, or a stored credential.
    last_error: String,
}

#[derive(Serialize, Deserialize)]
struct StoredCredential {
    device_id: String,
    control_plane_url: String,
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

#[derive(Serialize)]
struct EnrollmentRequest<'a> {
    token: &'a str,
    display_name: &'a str,
    hostname: &'a str,
    operating_system: &'a str,
    client_version: &'a str,
    public_key_fingerprint: &'a str,
    public_key: &'a str,
    rustdesk_id: &'a str,
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

fn credential_entry() -> Result<Entry, String> {
    Entry::new("com.rustdesk.managed-platform", "device-credential")
        .map_err(|error| format!("credential store is unavailable: {error}"))
}

fn restore_if_needed(guard: &mut ManagedState) {
    if !guard.device_id.is_empty() {
        return;
    }
    let entry = match credential_entry() {
        Ok(entry) => entry,
        Err(error) => {
            guard.last_error = error;
            return;
        }
    };
    let raw = match entry.get_password() {
        Ok(raw) => raw,
        // A missing credential is normal on the first managed launch.
        Err(keyring::Error::NoEntry) => return,
        Err(error) => {
            guard.last_error = format!("could not read managed credential: {error}");
            return;
        }
    };
    let stored = match serde_json::from_str::<StoredCredential>(&raw) {
        Ok(stored) => stored,
        Err(_) => {
            guard.last_error =
                "stored managed credential is malformed; re-enrollment is required".to_owned();
            return;
        }
    };
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
    guard.device_id = stored.device_id;
    guard.public_key_fingerprint = stored.public_key_fingerprint;
    guard.signing_key = Some(SigningKey::from_bytes(&bytes));
    guard.credential_expires_at = stored.credential_expires_at;
    guard.issuer_public_key = stored.issuer_public_key;
    guard.credential = stored.credential;
    guard.policy = stored.policy;
    guard.last_error.clear();
    log::info!("Restored managed credential from the OS credential store");
    // A managed-only build pins its CP URL at compile time. Do not let an
    // older Keychain record redirect a rebuilt client to a previous CP.
    #[cfg(not(feature = "managed-only"))]
    LocalConfig::set_option(CONTROL_PLANE_URL_KEY.to_owned(), stored.control_plane_url);
}

pub fn configure(control_plane_url: String) -> Result<(), String> {
    let url = control_plane_url.trim().trim_end_matches('/');
    if !(url.starts_with("https://")
        || url.starts_with("http://127.0.0.1")
        || url.starts_with("http://localhost"))
    {
        return Err(
            "control plane URL must use HTTPS (loopback HTTP is allowed for development)"
                .to_owned(),
        );
    }
    LocalConfig::set_option(CONTROL_PLANE_URL_KEY.to_owned(), url.to_owned());
    Ok(())
}

/// Starts the fixed managed deployment without exposing its bootstrap token to
/// Flutter. Non-managed builds intentionally keep the existing manual flow.
#[cfg(feature = "managed-only")]
pub fn bootstrap_managed_only() -> Result<(), String> {
    let result = (|| {
        configure(managed_bootstrap::CP_URL.to_owned())?;
        let mut guard = state()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        restore_if_needed(&mut guard);
        let needs_enrollment = guard.device_id.is_empty();
        let restore_error = guard.last_error.clone();
        drop(guard);
        if needs_enrollment {
            let enrollment = enroll(
                managed_bootstrap::BOOTSTRAP_TOKEN.to_owned(),
                "Managed RustDesk device".to_owned(),
            );
            if let Err(error) = enrollment {
                let reason = if restore_error.is_empty() {
                    "no stored managed credential was found".to_owned()
                } else {
                    format!("managed credential could not be restored: {restore_error}")
                };
                return Err(format!("{reason}; {error}"));
            }
            renew_credential()?;
        }
        sync_deployment_config()
    })();
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    match &result {
        Ok(()) => guard.last_error.clear(),
        Err(error) => guard.last_error = error.clone(),
    }
    result
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
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    restore_if_needed(&mut guard);
    let signing_key = guard
        .signing_key
        .as_ref()
        .ok_or_else(|| "device is not enrolled".to_owned())?;
    let control_plane_url = LocalConfig::get_option(CONTROL_PLANE_URL_KEY);
    let timestamp = Utc::now().timestamp();
    let nonce = uuid::Uuid::new_v4();
    use ed25519_dalek::Signer;
    let payload = format!("{}:{timestamp}:{nonce}:managed-config", guard.device_id);
    let signature = hex::encode(signing_key.sign(payload.as_bytes()).to_bytes());
    drop(guard);
    let response = reqwest::blocking::Client::builder().timeout(std::time::Duration::from_secs(15)).build()
        .map_err(|error| format!("could not create control plane client: {error}"))?
        .post(format!("{control_plane_url}/v1/managed/config"))
        .json(&serde_json::json!({"device_id": status().device_id, "timestamp": timestamp, "nonce": nonce, "signature": signature}))
        .send().map_err(|error| format!("managed configuration sync failed: {error}"))?;
    if !response.status().is_success() {
        return Err(format!(
            "managed configuration was rejected ({})",
            response.status()
        ));
    }
    let config: SignedDeploymentConfig = response
        .json()
        .map_err(|error| format!("invalid managed configuration: {error}"))?;
    verify_deployment_config(&config)?;
    apply_deployment_config(
        config.claims.revision,
        config.claims.rendezvous_server,
        config.claims.relay_server,
        config.claims.server_public_key,
    )?;
    crate::rendezvous_mediator::RendezvousMediator::restart();
    Ok(())
}

#[cfg(feature = "managed-only")]
fn apply_deployment_config(
    revision: i64,
    rendezvous_server: String,
    relay_server: String,
    server_public_key: String,
) -> Result<(), String> {
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        // The desktop mediator runs in the service process. Update it over IPC
        // rather than only changing the Flutter process's in-memory config.
        let mut options = crate::ipc::get_options();
        options.insert(
            "custom-rendezvous-server".to_owned(),
            rendezvous_server.clone(),
        );
        options.insert("relay-server".to_owned(), relay_server.clone());
        options.insert("key".to_owned(), server_public_key);
        // CP is not a RustDesk Pro API; leaving this set triggers :21114 requests.
        options.remove("api-server");
        crate::ipc::set_options(options).map_err(|error| {
            format!("could not apply managed deployment configuration: {error}")
        })?;
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        Config::set_option(
            "custom-rendezvous-server".to_owned(),
            rendezvous_server.clone(),
        );
        Config::set_option("relay-server".to_owned(), relay_server.clone());
        Config::set_option("key".to_owned(), server_public_key);
        Config::set_option("api-server".to_owned(), "".to_owned());
    }
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
    let enrolled = !guard.device_id.is_empty();
    let policy_state = match guard.policy.as_ref() {
        Some(policy) if policy.claims.expires_at > Utc::now() => "active",
        Some(_) => "expired",
        None => "unavailable",
    };
    ManagedStatus {
        managed_only: is_managed_only(),
        enrolled,
        state: if enrolled {
            "enrolled"
        } else if LocalConfig::get_option(REVOKED_KEY) == "Y" {
            "revoked"
        } else {
            "not_enrolled"
        },
        device_id: guard.device_id.clone(),
        control_plane_url: LocalConfig::get_option(CONTROL_PLANE_URL_KEY),
        rendezvous_server: Config::get_option("custom-rendezvous-server"),
        relay_server: Config::get_option("relay-server"),
        public_key_fingerprint: guard.public_key_fingerprint.clone(),
        credential_expires_at: guard.credential_expires_at.clone(),
        policy_expires_at: guard
            .policy
            .as_ref()
            .map(|policy| policy.claims.expires_at.to_rfc3339())
            .unwrap_or_default(),
        policy_state,
        persistence: "os-credential-store",
        last_error: guard.last_error.clone(),
    }
}

/// Produces the public, signed registration envelope for the managed wire
/// protocol. Private device key material never leaves this module.
pub fn registration_credential() -> Option<ManagedDeviceCredential> {
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    restore_if_needed(&mut guard);
    let credential = guard.credential.as_ref()?;
    if credential.claims.expires_at <= Utc::now() {
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
pub fn session_ticket() -> Option<ManagedSessionTicket> {
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    restore_if_needed(&mut guard);
    if !policy_allows(&guard, "remote-control") {
        return None;
    }
    let ticket = guard.pending_session_ticket.as_ref()?;
    if ticket.claims.expires_at <= Utc::now() {
        guard.pending_session_ticket = None;
        return None;
    }
    let claims = serde_json::to_vec(&ticket.claims).ok()?;
    let signature = hex::decode(&ticket.signature).ok()?;
    let issuer_public_key = hex::decode(&ticket.issuer_public_key).ok()?;
    Some(ManagedSessionTicket {
        version: u32::from(ticket.claims.version),
        claims: claims.into(),
        signature: signature.into(),
        issuer_public_key: issuer_public_key.into(),
        ..Default::default()
    })
}

/// Feature handlers must call this before enabling a managed capability. The
/// signed, expiring policy is the authority; portal state is never trusted at
/// the data-plane boundary.
pub fn capability_allowed(capability: &str) -> bool {
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
    let control_plane_url = LocalConfig::get_option(CONTROL_PLANE_URL_KEY);
    if control_plane_url.is_empty() {
        return Err("control plane URL is not configured".to_owned());
    }
    if enrollment_token.trim().is_empty() {
        return Err("enrollment token is required".to_owned());
    }
    let signing_key = SigningKey::generate(&mut OsRng);
    let fingerprint = hex::encode(Sha256::digest(signing_key.verifying_key().as_bytes()));
    let public_key = hex::encode(signing_key.verifying_key().as_bytes());
    let hostname = std::env::var("HOSTNAME").unwrap_or_else(|_| "unknown-host".to_owned());
    let rustdesk_id = Config::get_id();
    let response = reqwest::blocking::Client::new()
        .post(format!("{control_plane_url}/v1/enrollment/claim"))
        .json(&EnrollmentRequest {
            token: enrollment_token.trim(),
            display_name: display_name.trim(),
            hostname: &hostname,
            operating_system: std::env::consts::OS,
            client_version: env!("CARGO_PKG_VERSION"),
            public_key_fingerprint: &fingerprint,
            public_key: &public_key,
            rustdesk_id: &rustdesk_id,
        })
        .send()
        .map_err(|error| format!("enrollment request failed: {error}"))?;
    if !response.status().is_success() {
        return Err(format!("enrollment was rejected ({})", response.status()));
    }
    let enrolled: EnrollmentResponse = response
        .json()
        .map_err(|error| format!("invalid enrollment response: {error}"))?;
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    guard.device_id = enrolled.id;
    guard.public_key_fingerprint = fingerprint;
    guard.signing_key = Some(signing_key);
    persist_credential(&guard, &control_plane_url)?;
    LocalConfig::set_option(REVOKED_KEY.to_owned(), "".to_owned());
    drop(guard);
    // Enrollment remains durable if the initial policy fetch is interrupted,
    // but the client then has no cache and therefore cannot start a managed
    // session until a renewal fetches a valid signed policy.
    let _ = sync_policy();
    Ok(status())
}

/// Requests a short-lived, server-signed credential after proving possession
/// of the device key. An existing issuer key is pinned across renewals.
pub fn renew_credential() -> Result<(), String> {
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    restore_if_needed(&mut guard);
    let signing_key = guard
        .signing_key
        .as_ref()
        .ok_or_else(|| "device is not enrolled".to_owned())?;
    let control_plane_url = LocalConfig::get_option(CONTROL_PLANE_URL_KEY);
    let timestamp = Utc::now().timestamp();
    let nonce = uuid::Uuid::new_v4();
    use ed25519_dalek::Signer;
    let payload = format!("{}:{timestamp}:{nonce}", guard.device_id);
    let signature = hex::encode(signing_key.sign(payload.as_bytes()).to_bytes());
    let response = reqwest::blocking::Client::new()
        .post(format!(
            "{control_plane_url}/v1/devices/{}/credential/renew",
            guard.device_id
        ))
        .json(&serde_json::json!({"timestamp": timestamp, "nonce": nonce, "signature": signature}))
        .send()
        .map_err(|error| format!("credential renewal request failed: {error}"))?;
    if response.status().is_success() {
        let credential: SignedDeviceCredential = response
            .json()
            .map_err(|error| format!("invalid credential renewal response: {error}"))?;
        verify_credential(&credential, &guard)?;
        guard.credential_expires_at = credential.claims.expires_at.to_rfc3339();
        guard.issuer_public_key = credential.issuer_public_key.clone();
        guard.credential = Some(credential);
        persist_credential(&guard, &control_plane_url)?;
        drop(guard);
        sync_policy()?;
        return Ok(());
    }
    if response.status() == reqwest::StatusCode::UNAUTHORIZED
        || response.status() == reqwest::StatusCode::FORBIDDEN
    {
        drop(guard);
        deprovision(true)?;
        return Err("device credential was revoked by the control plane".to_owned());
    }
    Err(format!(
        "credential renewal was rejected ({})",
        response.status()
    ))
}

/// Refreshes the signed policy cache. It is intentionally separate from a
/// heartbeat so an unreachable control plane does not erase a still-valid
/// cache, while expired cache entries deny new managed sessions.
pub fn sync_policy() -> Result<(), String> {
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    restore_if_needed(&mut guard);
    let credential = guard
        .credential
        .as_ref()
        .ok_or_else(|| "renew managed access before syncing policy".to_owned())?;
    let control_plane_url = LocalConfig::get_option(CONTROL_PLANE_URL_KEY);
    let response = reqwest::blocking::Client::new()
        .post(format!("{control_plane_url}/v1/device-policy"))
        .json(&serde_json::json!({"credential": credential}))
        .send()
        .map_err(|error| format!("policy sync failed: {error}"))?;
    if response.status().is_success() {
        let policy: SignedDevicePolicy = response
            .json()
            .map_err(|error| format!("invalid policy response: {error}"))?;
        verify_policy(&policy, &guard)?;
        guard.policy = Some(policy);
        persist_credential(&guard, &control_plane_url)?;
        return Ok(());
    }
    if response.status() == reqwest::StatusCode::UNAUTHORIZED
        || response.status() == reqwest::StatusCode::FORBIDDEN
    {
        drop(guard);
        deprovision(true)?;
        return Err("device policy was revoked by the control plane".to_owned());
    }
    Err(format!("policy sync was rejected ({})", response.status()))
}

/// Obtains a five-minute, source/target-bound ticket for the managed server
/// protocol. The ticket is returned to the caller only when that protocol can
/// attach it to a connection; Flutter receives no credential material.
pub fn request_session_ticket(target_device_id: String) -> Result<(), String> {
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    restore_if_needed(&mut guard);
    if !policy_allows(&guard, "remote-control") {
        return Err("managed policy is unavailable or does not allow remote control".to_owned());
    }
    let target_device_id = target_device_id
        .parse::<uuid::Uuid>()
        .map_err(|_| "target device ID must be a UUID".to_owned())?;
    let credential = guard
        .credential
        .as_ref()
        .ok_or_else(|| "renew managed access before requesting a session".to_owned())?;
    let control_plane_url = LocalConfig::get_option(CONTROL_PLANE_URL_KEY);
    let response = reqwest::blocking::Client::new()
        .post(format!("{control_plane_url}/v1/session-tickets"))
        .json(&serde_json::json!({
            "target_device_id": target_device_id,
            "permissions": ["remote-control"],
            "credential": credential,
        }))
        .send()
        .map_err(|error| format!("session ticket request failed: {error}"))?;
    if !response.status().is_success() {
        return Err(format!(
            "session ticket was rejected ({})",
            response.status()
        ));
    }
    let ticket: SignedSessionTicket = response
        .json()
        .map_err(|error| format!("invalid session ticket response: {error}"))?;
    verify_session_ticket(&ticket, &guard, target_device_id)?;
    guard.pending_session_ticket = Some(ticket);
    Ok(())
}

/// Resolves the target through its RustDesk ID before requesting a bound
/// ticket. The control plane owns this mapping, not Flutter.
pub fn request_session_ticket_for_rustdesk_id(target_rustdesk_id: String) -> Result<(), String> {
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    restore_if_needed(&mut guard);
    if !policy_allows(&guard, "remote-control") {
        return Err("managed policy is unavailable or does not allow remote control".to_owned());
    }
    if target_rustdesk_id.trim().is_empty() || target_rustdesk_id.len() > 256 {
        return Err("target RustDesk ID is invalid".to_owned());
    }
    let credential = guard
        .credential
        .as_ref()
        .ok_or_else(|| "renew managed access before requesting a session".to_owned())?;
    let control_plane_url = LocalConfig::get_option(CONTROL_PLANE_URL_KEY);
    let response = reqwest::blocking::Client::new()
        .post(format!("{control_plane_url}/v1/session-tickets"))
        .json(&serde_json::json!({
            "target_rustdesk_id": target_rustdesk_id.trim(),
            "permissions": ["remote-control"],
            "credential": credential,
        }))
        .send()
        .map_err(|error| format!("session ticket request failed: {error}"))?;
    if !response.status().is_success() {
        return Err(format!(
            "session ticket was rejected ({})",
            response.status()
        ));
    }
    let ticket: SignedSessionTicket = response
        .json()
        .map_err(|error| format!("invalid session ticket response: {error}"))?;
    let target_device_id = ticket.claims.target_device_id;
    verify_session_ticket(&ticket, &guard, target_device_id)?;
    guard.pending_session_ticket = Some(ticket);
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
        || ticket.claims.expires_at <= Utc::now()
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
    state.policy.as_ref().is_some_and(|policy| {
        policy.claims.expires_at > Utc::now()
            && policy
                .claims
                .capabilities
                .iter()
                .any(|value| value == capability)
    })
}

fn verify_policy(policy: &SignedDevicePolicy, state: &ManagedState) -> Result<(), String> {
    if policy.claims.version != 1
        || policy.claims.device_id.to_string() != state.device_id
        || policy.claims.expires_at <= Utc::now()
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
        || credential.claims.expires_at <= Utc::now()
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
        device_id: state.device_id.clone(),
        control_plane_url: control_plane_url.to_owned(),
        public_key_fingerprint: state.public_key_fingerprint.clone(),
        signing_key: hex::encode(signing_key.to_bytes()),
        credential_expires_at: state.credential_expires_at.clone(),
        issuer_public_key: state.issuer_public_key.clone(),
        credential: state.credential.clone(),
        policy: state.policy.clone(),
    };
    let encoded = serde_json::to_string(&stored)
        .map_err(|error| format!("could not encode managed credential: {error}"))?;
    credential_entry()?
        .set_password(&encoded)
        .map_err(|error| format!("could not persist managed credential: {error}"))?;
    log::info!("Persisted managed credential in the OS credential store");
    Ok(())
}

pub fn heartbeat() -> Result<(), String> {
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    restore_if_needed(&mut guard);
    let signing_key = guard
        .signing_key
        .as_ref()
        .ok_or_else(|| "device is not enrolled".to_owned())?;
    let control_plane_url = LocalConfig::get_option(CONTROL_PLANE_URL_KEY);
    let timestamp = chrono::Utc::now().timestamp();
    let nonce = uuid::Uuid::new_v4();
    use ed25519_dalek::Signer;
    let payload = format!("{}:{timestamp}:{nonce}", guard.device_id);
    let signature = hex::encode(signing_key.sign(payload.as_bytes()).to_bytes());
    let response = reqwest::blocking::Client::new()
        .post(format!(
            "{control_plane_url}/v1/devices/{}/heartbeat",
            guard.device_id
        ))
        .json(&serde_json::json!({
            "timestamp": timestamp,
            "nonce": nonce,
            "signature": signature,
            "metadata": {
                "hostname": std::env::var("HOSTNAME").unwrap_or_else(|_| "unknown-host".to_owned()),
                "operating_system": std::env::consts::OS,
                "client_version": env!("CARGO_PKG_VERSION"),
                "capabilities": ["remote-control", "file-transfer", "clipboard"],
                "health": {"status": "healthy"}
            }
        }))
        .send()
        .map_err(|error| format!("heartbeat request failed: {error}"))?;
    if response.status().is_success() {
        return Ok(());
    }
    if response.status() == reqwest::StatusCode::UNAUTHORIZED
        || response.status() == reqwest::StatusCode::FORBIDDEN
    {
        drop(guard);
        deprovision(true)?;
        return Err("device credential was revoked by the control plane".to_owned());
    }
    Err(format!("heartbeat was rejected ({})", response.status()))
}

pub fn deprovision(revoked: bool) -> Result<(), String> {
    if let Ok(entry) = credential_entry() {
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => {}
            Err(error) => return Err(format!("could not delete managed credential: {error}")),
        }
    }
    let mut guard = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    *guard = ManagedState::default();
    LocalConfig::set_option(
        REVOKED_KEY.to_owned(),
        if revoked { "Y" } else { "" }.to_owned(),
    );
    if revoked {
        log::warn!("Cleared managed credential after control plane revocation");
    }
    Ok(())
}
