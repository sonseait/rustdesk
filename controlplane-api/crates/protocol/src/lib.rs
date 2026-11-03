//! Versioned, signed credentials exchanged by managed clients and nodes.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const MANAGED_PROTOCOL_VERSION: u16 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceCredentialClaims {
    pub version: u16,
    pub device_id: Uuid,
    /// The rendezvous identity this credential may register.
    pub rustdesk_id: String,
    pub public_key_fingerprint: String,
    pub issued_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedDeviceCredential {
    pub claims: DeviceCredentialClaims,
    pub signature: String,
    pub issuer_public_key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionTicketClaims {
    pub version: u16,
    pub ticket_id: Uuid,
    pub source_device_id: Uuid,
    pub target_device_id: Uuid,
    pub expires_at: DateTime<Utc>,
    pub permissions: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedSessionTicket {
    pub claims: SessionTicketClaims,
    pub signature: String,
    pub issuer_public_key: String,
}

/// A short-lived, issuer-signed policy snapshot. Clients can use this while
/// offline, but must fail closed when it expires or is revoked locally.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DevicePolicyClaims {
    pub version: u16,
    pub device_id: Uuid,
    pub revision: u64,
    pub expires_at: DateTime<Utc>,
    pub capabilities: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedDevicePolicy {
    pub claims: DevicePolicyClaims,
    pub signature: String,
    pub issuer_public_key: String,
}
