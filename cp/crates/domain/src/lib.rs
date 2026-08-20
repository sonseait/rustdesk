use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NewAdmin {
    pub email: String,
    pub display_name: String,
    pub password: String,
}

impl NewAdmin {
    pub fn validate(&self) -> Result<(), ValidationError> {
        if self.email.trim().is_empty() || !self.email.contains('@') {
            return Err(ValidationError::InvalidEmail);
        }
        if self.display_name.trim().is_empty() || self.display_name.len() > 128 {
            return Err(ValidationError::InvalidDisplayName);
        }
        if self.password.len() < 12 || self.password.len() > 1024 {
            return Err(ValidationError::InvalidPassword);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct User {
    pub id: Uuid,
    pub email: String,
    pub display_name: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct UserSummary {
    pub user: User,
    pub roles: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Role {
    pub name: String,
    pub description: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct AuditEvent {
    pub id: Uuid,
    pub action: String,
    pub target_type: String,
    pub target_id: String,
    pub actor_email: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RemoteSession {
    pub id: Uuid,
    pub ticket_id: Uuid,
    pub source_device_id: Uuid,
    pub target_device_id: Uuid,
    pub permission: String,
    pub status: String,
    pub authorized_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ServerNode {
    pub id: Uuid,
    pub name: String,
    pub endpoint: String,
    pub status: String,
    pub health: Value,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NewEnrollmentToken {
    pub label: String,
    pub expires_in_hours: i32,
    pub max_enrollments: i32,
}

impl NewEnrollmentToken {
    pub fn validate(&self) -> Result<(), ValidationError> {
        if self.label.trim().is_empty() || self.label.len() > 128 {
            return Err(ValidationError::InvalidEnrollmentLabel);
        }
        if !(1..=24 * 30).contains(&self.expires_in_hours) {
            return Err(ValidationError::InvalidEnrollmentExpiry);
        }
        if !(1..=10_000).contains(&self.max_enrollments) {
            return Err(ValidationError::InvalidEnrollmentLimit);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct EnrollmentToken {
    pub id: Uuid,
    pub label: String,
    pub max_enrollments: i32,
    pub enrollment_count: i32,
    pub expires_at: DateTime<Utc>,
    pub revoked_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Device {
    pub id: Uuid,
    pub rustdesk_id: String,
    pub display_name: String,
    pub hostname: String,
    pub operating_system: String,
    pub client_version: String,
    pub enrolled_at: DateTime<Utc>,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub last_capabilities: Value,
    pub last_health: Value,
    pub revoked_at: Option<DateTime<Utc>>,
}

/// Non-secret operational information a device may report with a signed
/// heartbeat. It deliberately excludes user, screen, and connection data.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct DeviceHeartbeatMetadata {
    #[serde(default)]
    pub hostname: String,
    #[serde(default)]
    pub operating_system: String,
    #[serde(default)]
    pub client_version: String,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub health: Value,
}

/// Desired managed-protocol state for the single server deployment.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct CurrentServerConfig {
    pub revision: i64,
    pub managed_mode: String,
    pub credential_issuer_public_key: Option<String>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct UpdateCurrentServerConfig {
    pub managed_mode: String,
    pub credential_issuer_public_key: Option<String>,
}

impl UpdateCurrentServerConfig {
    pub fn validate(&self) -> Result<(), ValidationError> {
        match self.managed_mode.as_str() {
            "off" => Ok(()),
            "optional" | "required" => {
                let Some(key) = self.credential_issuer_public_key.as_deref() else {
                    return Err(ValidationError::InvalidIssuerPublicKey);
                };
                if key.len() != 64 || !key.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                    return Err(ValidationError::InvalidIssuerPublicKey);
                }
                Ok(())
            }
            _ => Err(ValidationError::InvalidManagedMode),
        }
    }
}

impl DeviceHeartbeatMetadata {
    pub fn validate(&self) -> Result<(), ValidationError> {
        if [
            self.hostname.as_str(),
            self.operating_system.as_str(),
            self.client_version.as_str(),
        ]
        .iter()
        .any(|value| value.len() > 256)
            || self.capabilities.len() > 32
            || self
                .capabilities
                .iter()
                .any(|value| value.is_empty() || value.len() > 64)
            || serde_json::to_vec(&self.health).map_or(true, |health| health.len() > 4096)
        {
            return Err(ValidationError::InvalidHeartbeatMetadata);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct EnrollmentClaim {
    pub token: String,
    pub display_name: String,
    pub hostname: String,
    pub operating_system: String,
    pub client_version: String,
    pub public_key_fingerprint: String,
    pub public_key: String,
    pub rustdesk_id: String,
}

impl EnrollmentClaim {
    pub fn validate(&self) -> Result<(), ValidationError> {
        if self.token.len() < 32
            || [
                self.display_name.as_str(),
                self.hostname.as_str(),
                self.operating_system.as_str(),
                self.client_version.as_str(),
                self.public_key_fingerprint.as_str(),
                self.public_key.as_str(),
                self.rustdesk_id.as_str(),
            ]
            .iter()
            .any(|value| value.trim().is_empty() || value.len() > 256)
        {
            return Err(ValidationError::InvalidEnrollmentClaim);
        }
        Ok(())
    }
}

/// Limits applied by hbbs/hbbr to sessions without a managed credential.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnonymousRemotePolicy {
    pub enabled: bool,
    pub max_session_minutes: i32,
    pub max_concurrent_devices: i32,
    pub max_devices_per_window: i32,
    pub window_minutes: i32,
}

impl AnonymousRemotePolicy {
    pub fn validate(&self) -> Result<(), ValidationError> {
        if !(1..=480).contains(&self.max_session_minutes) {
            return Err(ValidationError::InvalidAnonymousSessionDuration);
        }
        if !(1..=10_000).contains(&self.max_concurrent_devices) {
            return Err(ValidationError::InvalidAnonymousConcurrentDevices);
        }
        if !(1..=100_000).contains(&self.max_devices_per_window) {
            return Err(ValidationError::InvalidAnonymousDeviceWindowLimit);
        }
        if !(1..=1_440).contains(&self.window_minutes) {
            return Err(ValidationError::InvalidAnonymousWindow);
        }
        Ok(())
    }
}

#[derive(Debug, Error)]
pub enum ValidationError {
    #[error("email must be a valid address")]
    InvalidEmail,
    #[error("display name must be between 1 and 128 characters")]
    InvalidDisplayName,
    #[error("password must be between 12 and 1024 characters")]
    InvalidPassword,
    #[error("anonymous session duration must be between 1 and 480 minutes")]
    InvalidAnonymousSessionDuration,
    #[error("anonymous concurrent-device limit must be between 1 and 10000")]
    InvalidAnonymousConcurrentDevices,
    #[error("anonymous device window limit must be between 1 and 100000")]
    InvalidAnonymousDeviceWindowLimit,
    #[error("anonymous device window must be between 1 and 1440 minutes")]
    InvalidAnonymousWindow,
    #[error("enrollment token label must be between 1 and 128 characters")]
    InvalidEnrollmentLabel,
    #[error("enrollment token expiry must be between 1 hour and 30 days")]
    InvalidEnrollmentExpiry,
    #[error("enrollment count must be between 1 and 10000")]
    InvalidEnrollmentLimit,
    #[error("enrollment claim is invalid")]
    InvalidEnrollmentClaim,
    #[error("heartbeat metadata is invalid")]
    InvalidHeartbeatMetadata,
    #[error("managed mode must be off, optional, or required")]
    InvalidManagedMode,
    #[error("managed mode requires a 32-byte Ed25519 issuer public key")]
    InvalidIssuerPublicKey,
}

#[cfg(test)]
mod tests {
    use super::NewAdmin;

    #[test]
    fn admin_requires_a_strong_password() {
        let admin = NewAdmin {
            email: "admin@example.test".into(),
            display_name: "Admin".into(),
            password: "short".into(),
        };
        assert!(admin.validate().is_err());
    }
}
