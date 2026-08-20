//! Managed authorization checks shared by the node agent and its loopback
//! hbbs/hbbr integration. No control-plane signing secret is accepted here.

use chrono::{DateTime, Utc};
use control_plane_protocol::{
    DeviceCredentialClaims, SessionTicketClaims, SignedDeviceCredential, SignedSessionTicket,
    MANAGED_PROTOCOL_VERSION,
};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Mutex};
use thiserror::Error;
use url::Url;
use uuid::Uuid;

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AgentConfig {
    pub control_plane_url: Url,
    pub node_id: String,
    pub anonymous_remote_policy: AnonymousRemotePolicy,
    #[serde(default)]
    pub managed_mode: ManagedMode,
    /// Hex-encoded public key for credentials and session tickets.
    #[serde(default)]
    pub credential_issuer_public_key: Option<String>,
    /// PEM materials used only for the outbound control-plane connection.
    /// The node agent never exposes its private key to hbbs/hbbr.
    #[serde(default)]
    pub mtls: MtlsConfig,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct MtlsConfig {
    pub ca_certificate_pem: String,
    /// A PEM bundle containing client certificate followed by private key.
    pub identity_pem: String,
}

/// Versioned desired state received by the single managed server. The agent
/// reports the accepted revision so the portal can distinguish desired from
/// effective configuration during a rollout.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DesiredNodeConfig {
    pub revision: u64,
    pub anonymous_remote_policy: AnonymousRemotePolicy,
    #[serde(default)]
    pub managed_mode: ManagedMode,
    #[serde(default)]
    pub credential_issuer_public_key: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct EffectiveNodeConfig {
    pub revision: u64,
    pub managed_mode: ManagedMode,
    pub anonymous_remote_policy: AnonymousRemotePolicy,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct NodeHealth {
    pub healthy: bool,
    pub effective_config: EffectiveNodeConfig,
    pub last_rollout: RolloutResult,
}

/// Result reported to the control plane after the local hbbs/hbbr runtime has
/// accepted a desired revision or been restored to its last known-good state.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RolloutResult {
    NotAttempted,
    Applied {
        revision: u64,
    },
    RolledBack {
        attempted_revision: u64,
        reason: String,
    },
}

/// Boundary for the loopback process controller. Implementations may use a
/// Unix socket, service manager, or a supervised child process, but the agent
/// never publishes that runtime console to the network.
pub trait RuntimeController {
    fn apply(&self, desired: &EffectiveNodeConfig) -> Result<(), String>;
    fn rollback(&self, known_good: &EffectiveNodeConfig) -> Result<(), String>;
}

/// Compatibility mode during the managed-protocol rollout.
#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ManagedMode {
    #[default]
    Off,
    Optional,
    Required,
}

/// Desired configuration applied to the one managed hbbs/hbbr deployment.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct AnonymousRemotePolicy {
    pub enabled: bool,
    pub max_session_minutes: u16,
    pub max_concurrent_devices: u32,
    pub max_devices_per_window: u32,
    pub window_minutes: u16,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ConfigError {
    #[error("node id must not be empty")]
    EmptyNodeId,
    #[error("managed mode requires a valid Ed25519 issuer public key")]
    InvalidIssuerPublicKey,
    #[error("mTLS CA certificate and client identity must be PEM encoded")]
    InvalidMtlsIdentity,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ApplyConfigError {
    #[error("desired configuration revision is stale")]
    StaleRevision,
    #[error(transparent)]
    Invalid(#[from] ConfigError),
    #[error("runtime rejected desired configuration: {0}")]
    RuntimeRejected(String),
}

impl AgentConfig {
    pub fn validate(&self) -> Result<(), ConfigError> {
        if self.node_id.trim().is_empty() {
            return Err(ConfigError::EmptyNodeId);
        }
        if self.managed_mode != ManagedMode::Off {
            ManagedAuthorizer::from_hex(
                self.managed_mode,
                self.credential_issuer_public_key.as_deref(),
            )?;
        }
        self.mtls.validate()?;
        Ok(())
    }
}

impl MtlsConfig {
    pub fn validate(&self) -> Result<(), ConfigError> {
        if !self
            .ca_certificate_pem
            .contains("-----BEGIN CERTIFICATE-----")
            || !self.identity_pem.contains("-----BEGIN CERTIFICATE-----")
            || !self.identity_pem.contains("-----BEGIN")
        {
            return Err(ConfigError::InvalidMtlsIdentity);
        }
        Ok(())
    }
}

#[derive(Debug, Error)]
pub enum TransportError {
    #[error(transparent)]
    InvalidConfig(#[from] ConfigError),
    #[error("could not construct mTLS client: {0}")]
    Client(String),
    #[error("control-plane request failed: {0}")]
    Request(String),
    #[error("control-plane returned HTTP {0}")]
    UnexpectedStatus(reqwest::StatusCode),
    #[error("control-plane response was invalid: {0}")]
    InvalidResponse(String),
}

/// Outbound-only mTLS transport. The control plane must expose this endpoint
/// on its node-agent listener and require a client certificate at the TLS
/// terminator; no bearer token or publicly reachable node runtime is used.
pub struct MtlsControlPlaneTransport {
    base_url: Url,
    node_id: Uuid,
    client: reqwest::blocking::Client,
}

impl MtlsControlPlaneTransport {
    pub fn new(
        control_plane_url: Url,
        node_id: Uuid,
        mtls: &MtlsConfig,
    ) -> Result<Self, TransportError> {
        mtls.validate()?;
        if control_plane_url.scheme() != "https" {
            return Err(TransportError::Client(
                "node-agent control plane URL must use HTTPS".into(),
            ));
        }
        let ca = reqwest::Certificate::from_pem(mtls.ca_certificate_pem.as_bytes())
            .map_err(|error| TransportError::Client(error.to_string()))?;
        let identity = reqwest::Identity::from_pem(mtls.identity_pem.as_bytes())
            .map_err(|error| TransportError::Client(error.to_string()))?;
        let client = reqwest::blocking::Client::builder()
            .add_root_certificate(ca)
            .identity(identity)
            .https_only(true)
            .build()
            .map_err(|error| TransportError::Client(error.to_string()))?;
        Ok(Self {
            base_url: control_plane_url,
            node_id,
            client,
        })
    }

    pub fn fetch_desired_config(&self) -> Result<DesiredNodeConfig, TransportError> {
        let url = self
            .base_url
            .join("v1/node-agent/desired-config")
            .map_err(|error| TransportError::Request(error.to_string()))?;
        let response = self
            .client
            .get(url)
            .header("x-node-agent-id", self.node_id.to_string())
            .send()
            .map_err(|error| TransportError::Request(error.to_string()))?;
        if !response.status().is_success() {
            return Err(TransportError::UnexpectedStatus(response.status()));
        }
        response
            .json()
            .map_err(|error| TransportError::InvalidResponse(error.to_string()))
    }

    pub fn report_health(&self, health: &NodeHealth) -> Result<(), TransportError> {
        let url = self
            .base_url
            .join("v1/node-agent/health")
            .map_err(|error| TransportError::Request(error.to_string()))?;
        let response = self
            .client
            .post(url)
            .header("x-node-agent-id", self.node_id.to_string())
            .json(health)
            .send()
            .map_err(|error| TransportError::Request(error.to_string()))?;
        if response.status().is_success() {
            Ok(())
        } else {
            Err(TransportError::UnexpectedStatus(response.status()))
        }
    }
}

/// Applies desired configuration through a loopback-only runtime API. This is
/// deliberately distinct from the mTLS control-plane transport.
pub struct LoopbackRuntimeController {
    base_url: Url,
    client: reqwest::blocking::Client,
}

impl LoopbackRuntimeController {
    pub fn new(base_url: Url) -> Result<Self, TransportError> {
        if !matches!(
            base_url.host_str(),
            Some("127.0.0.1") | Some("localhost") | Some("::1")
        ) {
            return Err(TransportError::Client(
                "runtime endpoint must be loopback-only".into(),
            ));
        }
        let client = reqwest::blocking::Client::builder()
            .build()
            .map_err(|error| TransportError::Client(error.to_string()))?;
        Ok(Self { base_url, client })
    }

    fn send_config(&self, config: &EffectiveNodeConfig) -> Result<(), String> {
        let url = self
            .base_url
            .join("config")
            .map_err(|error| error.to_string())?;
        let response = self
            .client
            .put(url)
            .json(config)
            .send()
            .map_err(|error| error.to_string())?;
        response
            .status()
            .is_success()
            .then_some(())
            .ok_or_else(|| format!("runtime returned HTTP {}", response.status()))
    }
}

impl RuntimeController for LoopbackRuntimeController {
    fn apply(&self, desired: &EffectiveNodeConfig) -> Result<(), String> {
        self.send_config(desired)
    }
    fn rollback(&self, known_good: &EffectiveNodeConfig) -> Result<(), String> {
        self.send_config(known_good)
    }
}

impl DesiredNodeConfig {
    pub fn validate(&self) -> Result<(), ConfigError> {
        if self.managed_mode != ManagedMode::Off {
            ManagedAuthorizer::from_hex(
                self.managed_mode,
                self.credential_issuer_public_key.as_deref(),
            )?;
        }
        Ok(())
    }

    fn effective(&self) -> EffectiveNodeConfig {
        EffectiveNodeConfig {
            revision: self.revision,
            managed_mode: self.managed_mode,
            anonymous_remote_policy: self.anonymous_remote_policy.clone(),
        }
    }
}

/// Holds only the effective, non-secret runtime configuration. Process
/// restart and mTLS transport are intentionally outside this state machine.
pub struct DesiredConfigStore {
    effective: Mutex<EffectiveNodeConfig>,
    last_rollout: Mutex<RolloutResult>,
}

impl DesiredConfigStore {
    pub fn new(initial: DesiredNodeConfig) -> Result<Self, ConfigError> {
        initial.validate()?;
        Ok(Self {
            effective: Mutex::new(initial.effective()),
            last_rollout: Mutex::new(RolloutResult::NotAttempted),
        })
    }

    pub fn apply(
        &self,
        desired: DesiredNodeConfig,
    ) -> Result<EffectiveNodeConfig, ApplyConfigError> {
        desired.validate()?;
        let mut effective = self
            .effective
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if desired.revision <= effective.revision {
            return Err(ApplyConfigError::StaleRevision);
        }
        *effective = desired.effective();
        Ok(effective.clone())
    }

    /// Applies a higher desired revision to the local runtime before exposing
    /// it as effective. If apply fails, the runtime is explicitly restored to
    /// the prior revision and the control plane receives the failure detail.
    pub fn apply_with_runtime(
        &self,
        desired: DesiredNodeConfig,
        runtime: &dyn RuntimeController,
    ) -> Result<EffectiveNodeConfig, ApplyConfigError> {
        desired.validate()?;
        let next = desired.effective();
        let mut effective = self
            .effective
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if next.revision <= effective.revision {
            return Err(ApplyConfigError::StaleRevision);
        }
        if let Err(reason) = runtime.apply(&next) {
            let rollback_reason = runtime.rollback(&effective).err();
            let detail = rollback_reason.map_or(reason.clone(), |rollback| {
                format!("{reason}; rollback failed: {rollback}")
            });
            *self
                .last_rollout
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = RolloutResult::RolledBack {
                attempted_revision: next.revision,
                reason: detail.clone(),
            };
            return Err(ApplyConfigError::RuntimeRejected(detail));
        }
        *effective = next;
        *self
            .last_rollout
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = RolloutResult::Applied {
            revision: effective.revision,
        };
        Ok(effective.clone())
    }

    pub fn health(&self) -> NodeHealth {
        let effective = self
            .effective
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        let last_rollout = self
            .last_rollout
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        NodeHealth {
            healthy: true,
            effective_config: effective,
            last_rollout,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegistrationAuthorization {
    Legacy,
    Managed {
        device_id: Uuid,
        rustdesk_id: String,
    },
}

#[derive(Debug, Clone, Error, PartialEq, Eq)]
pub enum AuthorizationError {
    #[error("managed credential is required")]
    CredentialRequired,
    #[error("managed credential is invalid")]
    InvalidCredential,
    #[error("managed credential is expired")]
    ExpiredCredential,
    #[error("session ticket is invalid")]
    InvalidTicket,
    #[error("session ticket is expired")]
    ExpiredTicket,
    #[error("session ticket does not match this session")]
    WrongTicketBinding,
    #[error("session ticket was already used")]
    ReplayedTicket,
}

/// Verifies control-plane signatures and remembers consumed ticket IDs until
/// their expiry. Call it before peer lookup, hole punching, or relay setup.
pub struct ManagedAuthorizer {
    mode: ManagedMode,
    issuer: Option<VerifyingKey>,
    used_tickets: Mutex<HashMap<Uuid, DateTime<Utc>>>,
}

impl ManagedAuthorizer {
    pub fn from_hex(
        mode: ManagedMode,
        issuer_public_key: Option<&str>,
    ) -> Result<Self, ConfigError> {
        let issuer = match mode {
            ManagedMode::Off => None,
            ManagedMode::Optional | ManagedMode::Required => Some(parse_issuer(issuer_public_key)?),
        };
        Ok(Self {
            mode,
            issuer,
            used_tickets: Mutex::new(HashMap::new()),
        })
    }

    /// A supplied credential never silently falls back to anonymous access.
    pub fn authorize_registration(
        &self,
        credential: Option<&SignedDeviceCredential>,
        now: DateTime<Utc>,
    ) -> Result<RegistrationAuthorization, AuthorizationError> {
        if self.mode == ManagedMode::Off {
            return Ok(RegistrationAuthorization::Legacy);
        }
        let Some(credential) = credential else {
            return if self.mode == ManagedMode::Required {
                Err(AuthorizationError::CredentialRequired)
            } else {
                Ok(RegistrationAuthorization::Legacy)
            };
        };
        let issuer = self
            .issuer
            .as_ref()
            .ok_or(AuthorizationError::InvalidCredential)?;
        let claims = verify_device_credential(issuer, credential, now)?;
        Ok(RegistrationAuthorization::Managed {
            device_id: claims.device_id,
            rustdesk_id: claims.rustdesk_id,
        })
    }

    pub fn authorize_session(
        &self,
        ticket: &SignedSessionTicket,
        source_device_id: Uuid,
        target_device_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<SessionTicketClaims, AuthorizationError> {
        let issuer = self
            .issuer
            .as_ref()
            .ok_or(AuthorizationError::InvalidTicket)?;
        let claims = verify_session_ticket(issuer, ticket, now)?;
        if claims.source_device_id != source_device_id
            || claims.target_device_id != target_device_id
        {
            return Err(AuthorizationError::WrongTicketBinding);
        }
        let mut used = self
            .used_tickets
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        used.retain(|_, expires_at| *expires_at > now);
        if used.insert(claims.ticket_id, claims.expires_at).is_some() {
            return Err(AuthorizationError::ReplayedTicket);
        }
        Ok(claims)
    }
}

fn parse_issuer(value: Option<&str>) -> Result<VerifyingKey, ConfigError> {
    let bytes = value
        .and_then(|value| hex::decode(value).ok())
        .and_then(|bytes| <[u8; 32]>::try_from(bytes.as_slice()).ok())
        .ok_or(ConfigError::InvalidIssuerPublicKey)?;
    VerifyingKey::from_bytes(&bytes).map_err(|_| ConfigError::InvalidIssuerPublicKey)
}

fn verify_device_credential(
    issuer: &VerifyingKey,
    credential: &SignedDeviceCredential,
    now: DateTime<Utc>,
) -> Result<DeviceCredentialClaims, AuthorizationError> {
    if credential.claims.version != MANAGED_PROTOCOL_VERSION {
        return Err(AuthorizationError::InvalidCredential);
    }
    if credential.claims.expires_at <= now {
        return Err(AuthorizationError::ExpiredCredential);
    }
    if credential.issuer_public_key != hex::encode(issuer.as_bytes()) {
        return Err(AuthorizationError::InvalidCredential);
    }
    verify_signature(
        issuer,
        &credential.claims,
        &credential.signature,
        AuthorizationError::InvalidCredential,
    )?;
    Ok(credential.claims.clone())
}

fn verify_session_ticket(
    issuer: &VerifyingKey,
    ticket: &SignedSessionTicket,
    now: DateTime<Utc>,
) -> Result<SessionTicketClaims, AuthorizationError> {
    if ticket.claims.version != MANAGED_PROTOCOL_VERSION
        || ticket.claims.permissions.as_slice() != ["remote-control"]
    {
        return Err(AuthorizationError::InvalidTicket);
    }
    if ticket.claims.expires_at <= now {
        return Err(AuthorizationError::ExpiredTicket);
    }
    if ticket.issuer_public_key != hex::encode(issuer.as_bytes()) {
        return Err(AuthorizationError::InvalidTicket);
    }
    verify_signature(
        issuer,
        &ticket.claims,
        &ticket.signature,
        AuthorizationError::InvalidTicket,
    )?;
    Ok(ticket.claims.clone())
}

fn verify_signature<T: Serialize>(
    issuer: &VerifyingKey,
    claims: &T,
    encoded_signature: &str,
    error: AuthorizationError,
) -> Result<(), AuthorizationError> {
    let signature_bytes = hex::decode(encoded_signature).map_err(|_| error.clone())?;
    let signature = Signature::from_slice(&signature_bytes).map_err(|_| error.clone())?;
    let payload = serde_json::to_vec(claims).map_err(|_| error.clone())?;
    issuer.verify(&payload, &signature).map_err(|_| error)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;
    use ed25519_dalek::{Signer, SigningKey};

    fn signer() -> SigningKey {
        SigningKey::from_bytes(&[7; 32])
    }

    struct FailingRuntime;

    impl RuntimeController for FailingRuntime {
        fn apply(&self, _: &EffectiveNodeConfig) -> Result<(), String> {
            Err("health check failed".into())
        }
        fn rollback(&self, _: &EffectiveNodeConfig) -> Result<(), String> {
            Ok(())
        }
    }

    fn ticket(
        source_device_id: Uuid,
        target_device_id: Uuid,
        expires_at: DateTime<Utc>,
    ) -> SignedSessionTicket {
        let signer = signer();
        let claims = SessionTicketClaims {
            version: MANAGED_PROTOCOL_VERSION,
            ticket_id: Uuid::new_v4(),
            source_device_id,
            target_device_id,
            expires_at,
            permissions: vec!["remote-control".into()],
        };
        let payload = serde_json::to_vec(&claims).unwrap();
        SignedSessionTicket {
            claims,
            signature: hex::encode(signer.sign(&payload).to_bytes()),
            issuer_public_key: hex::encode(signer.verifying_key().as_bytes()),
        }
    }

    fn credential(device_id: Uuid) -> SignedDeviceCredential {
        let signer = signer();
        let claims = DeviceCredentialClaims {
            version: MANAGED_PROTOCOL_VERSION,
            device_id,
            rustdesk_id: "123456789".into(),
            public_key_fingerprint: "test-fingerprint".into(),
            issued_at: Utc::now(),
            expires_at: Utc::now() + Duration::hours(1),
        };
        let payload = serde_json::to_vec(&claims).unwrap();
        SignedDeviceCredential {
            claims,
            signature: hex::encode(signer.sign(&payload).to_bytes()),
            issuer_public_key: hex::encode(signer.verifying_key().as_bytes()),
        }
    }

    #[test]
    fn session_tickets_are_bound_and_single_use() {
        let signer = signer();
        let authorizer = ManagedAuthorizer::from_hex(
            ManagedMode::Required,
            Some(&hex::encode(signer.verifying_key().as_bytes())),
        )
        .unwrap();
        let source = Uuid::new_v4();
        let target = Uuid::new_v4();
        let ticket = ticket(source, target, Utc::now() + Duration::minutes(5));
        assert!(authorizer
            .authorize_session(&ticket, source, target, Utc::now())
            .is_ok());
        assert!(matches!(
            authorizer.authorize_session(&ticket, source, target, Utc::now()),
            Err(AuthorizationError::ReplayedTicket)
        ));
    }

    #[test]
    fn required_mode_rejects_legacy_registration() {
        let signer = signer();
        let authorizer = ManagedAuthorizer::from_hex(
            ManagedMode::Required,
            Some(&hex::encode(signer.verifying_key().as_bytes())),
        )
        .unwrap();
        assert_eq!(
            authorizer.authorize_registration(None, Utc::now()),
            Err(AuthorizationError::CredentialRequired)
        );
    }

    #[test]
    fn optional_mode_accepts_valid_credentials_but_rejects_forged_ones() {
        let signer = signer();
        let authorizer = ManagedAuthorizer::from_hex(
            ManagedMode::Optional,
            Some(&hex::encode(signer.verifying_key().as_bytes())),
        )
        .unwrap();
        let device_id = Uuid::new_v4();
        let valid = credential(device_id);
        assert_eq!(
            authorizer.authorize_registration(Some(&valid), Utc::now()),
            Ok(RegistrationAuthorization::Managed {
                device_id,
                rustdesk_id: "123456789".into()
            })
        );
        let mut forged = valid;
        forged.claims.public_key_fingerprint = "changed".into();
        assert_eq!(
            authorizer.authorize_registration(Some(&forged), Utc::now()),
            Err(AuthorizationError::InvalidCredential)
        );
    }

    #[test]
    fn desired_config_only_moves_forward() {
        let policy = AnonymousRemotePolicy {
            enabled: false,
            max_session_minutes: 30,
            max_concurrent_devices: 1,
            max_devices_per_window: 10,
            window_minutes: 60,
        };
        let store = DesiredConfigStore::new(DesiredNodeConfig {
            revision: 4,
            anonymous_remote_policy: policy.clone(),
            managed_mode: ManagedMode::Off,
            credential_issuer_public_key: None,
        })
        .unwrap();
        assert_eq!(store.health().effective_config.revision, 4);
        assert!(matches!(
            store.apply(DesiredNodeConfig {
                revision: 4,
                anonymous_remote_policy: policy.clone(),
                managed_mode: ManagedMode::Off,
                credential_issuer_public_key: None
            }),
            Err(ApplyConfigError::StaleRevision)
        ));
        assert_eq!(
            store
                .apply(DesiredNodeConfig {
                    revision: 5,
                    anonymous_remote_policy: policy,
                    managed_mode: ManagedMode::Off,
                    credential_issuer_public_key: None
                })
                .unwrap()
                .revision,
            5
        );
    }

    #[test]
    fn failed_runtime_rollout_preserves_last_known_good_configuration() {
        let policy = AnonymousRemotePolicy {
            enabled: false,
            max_session_minutes: 30,
            max_concurrent_devices: 1,
            max_devices_per_window: 10,
            window_minutes: 60,
        };
        let store = DesiredConfigStore::new(DesiredNodeConfig {
            revision: 4,
            anonymous_remote_policy: policy.clone(),
            managed_mode: ManagedMode::Off,
            credential_issuer_public_key: None,
        })
        .unwrap();
        let result = store.apply_with_runtime(
            DesiredNodeConfig {
                revision: 5,
                anonymous_remote_policy: policy,
                managed_mode: ManagedMode::Off,
                credential_issuer_public_key: None,
            },
            &FailingRuntime,
        );
        assert!(matches!(result, Err(ApplyConfigError::RuntimeRejected(_))));
        assert_eq!(store.health().effective_config.revision, 4);
        assert!(matches!(
            store.health().last_rollout,
            RolloutResult::RolledBack {
                attempted_revision: 5,
                ..
            }
        ));
    }

    #[test]
    fn session_ticket_rejects_wrong_target_and_expiry() {
        let signer = signer();
        let authorizer = ManagedAuthorizer::from_hex(
            ManagedMode::Required,
            Some(&hex::encode(signer.verifying_key().as_bytes())),
        )
        .unwrap();
        let source = Uuid::new_v4();
        let target = Uuid::new_v4();
        let valid = ticket(source, target, Utc::now() + Duration::minutes(5));
        assert!(matches!(
            authorizer.authorize_session(&valid, source, Uuid::new_v4(), Utc::now()),
            Err(AuthorizationError::WrongTicketBinding)
        ));
        let expired = ticket(source, target, Utc::now() - Duration::seconds(1));
        assert!(matches!(
            authorizer.authorize_session(&expired, source, target, Utc::now()),
            Err(AuthorizationError::ExpiredTicket)
        ));
    }
}
