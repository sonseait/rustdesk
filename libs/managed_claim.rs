//! Canonical managed enrollment v2 contract, compiled by both client and API.
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EnrollmentV2 {
    pub token: String,
    pub request_id: uuid::Uuid,
    pub timestamp: i64,
    pub signature: String,
    pub public_key_fingerprint: String,
    pub public_key: String,
    pub rustdesk_id: String,
    pub display_name: String,
    pub hostname: String,
    pub operating_system: String,
    pub client_version: String,
}

#[derive(Serialize)]
struct ClaimPayload<'a> {
    version: u16,
    purpose: &'static str,
    request_id: uuid::Uuid,
    timestamp: i64,
    token_hash: String,
    public_key: &'a str,
    rustdesk_id: &'a str,
    display_name: &'a str,
    hostname: &'a str,
    operating_system: &'a str,
    client_version: &'a str,
}

impl EnrollmentV2 {
    pub fn payload(&self) -> Vec<u8> {
        // Serializing these fixed fields is infallible (no floating point/map keys).
        serde_json::to_vec(&ClaimPayload {
            version: 2, purpose: "enrollment-claim-v2", request_id: self.request_id,
            timestamp: self.timestamp, token_hash: hex::encode(Sha256::digest(self.token.as_bytes())),
            public_key: &self.public_key, rustdesk_id: &self.rustdesk_id,
            display_name: &self.display_name, hostname: &self.hostname,
            operating_system: &self.operating_system, client_version: &self.client_version,
        }).unwrap_or_default()
    }

    pub fn binding(&self) -> String {
        let mut immutable = self.clone();
        immutable.timestamp = 0;
        hex::encode(Sha256::digest(immutable.payload()))
    }

    pub fn verify(&self, now: i64) -> Result<(), &'static str> {
        if now.abs_diff(self.timestamp) > 300 { return Err("clock_skew"); }
        if self.request_id.is_nil() || !(32..=4096).contains(&self.token.len()) || [
            &self.rustdesk_id, &self.display_name, &self.hostname,
            &self.operating_system, &self.client_version,
        ].iter().any(|v| v.trim().is_empty() || v.len() > 256 || v.trim() != v.as_str()) {
            return Err("invalid_request");
        }
        let public = hex::decode(&self.public_key).map_err(|_| "invalid_device_proof")?;
        let public: [u8; 32] = public.try_into().map_err(|_| "invalid_device_proof")?;
        if self.public_key != hex::encode(public)
            || self.public_key_fingerprint != hex::encode(Sha256::digest(public)) {
            return Err("invalid_device_proof");
        }
        let key = VerifyingKey::from_bytes(&public).map_err(|_| "invalid_device_proof")?;
        let signature = hex::decode(&self.signature).map_err(|_| "invalid_device_proof")?;
        let signature = Signature::from_slice(&signature).map_err(|_| "invalid_device_proof")?;
        key.verify(&self.payload(), &signature).map_err(|_| "invalid_device_proof")
    }
}

/// V2 purpose separation also binds the exact heartbeat metadata representation.
pub fn device_proof(device_id: &str, timestamp: i64, nonce: &str, purpose: &str, metadata: &serde_json::Value) -> String {
    format!("2:{purpose}:{device_id}:{timestamp}:{nonce}:{}", hex::encode(Sha256::digest(metadata.to_string().as_bytes())))
}

/// Issuer authorization for exactly one recovery attempt. Signing the complete
/// envelope binds both independently signed artifacts to the fresh request.
#[derive(Clone, Serialize, Deserialize)]
pub struct RecoveryClaims<C, P> {
    pub version: u16,
    pub purpose: String,
    pub device_id: String,
    pub nonce: String,
    pub timestamp: i64,
    pub issued_at: i64,
    pub expires_at: i64,
    pub credential: C,
    pub policy: P,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct SignedRecovery<C, P> {
    pub claims: RecoveryClaims<C, P>,
    pub signature: String,
    pub issuer_public_key: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    fn claim() -> EnrollmentV2 {
        let key = SigningKey::from_bytes(&[3; 32]);
        let mut claim = EnrollmentV2 {
            token: "synthetic-only-token-not-for-deployment".into(),
            request_id: uuid::Uuid::from_u128(42), timestamp: 1800000000, signature: String::new(),
            public_key: hex::encode(key.verifying_key().as_bytes()),
            public_key_fingerprint: hex::encode(Sha256::digest(key.verifying_key().as_bytes())),
            rustdesk_id: "123456789".into(), display_name: "Test device".into(), hostname: "test-host".into(),
            operating_system: "synthetic".into(), client_version: "test".into(),
        };
        claim.signature = hex::encode(key.sign(&claim.payload()).to_bytes());
        claim
    }

    #[test]
    fn shared_fixture_matches_canonical_bytes() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!("../docs/architecture/fixtures/managed-enrollment-v2.json")).unwrap();
        let claim: EnrollmentV2 = serde_json::from_value(fixture["claim"].clone()).unwrap();
        assert_eq!(String::from_utf8(claim.payload()).unwrap(), fixture["payload"]);
        assert_eq!(claim.binding(), fixture["binding"]);
        assert!(claim.verify(claim.timestamp).is_ok());
    }

    #[test]
    fn claim_v2_rejects_changed_identity_and_fingerprint() {
        let mut claim = claim();
        assert!(claim.verify(claim.timestamp).is_ok());
        claim.rustdesk_id = "987654321".into();
        assert_eq!(claim.verify(claim.timestamp), Err("invalid_device_proof"));
        let mut claim = self::claim();
        claim.public_key_fingerprint = "wrong".into();
        assert_eq!(claim.verify(claim.timestamp), Err("invalid_device_proof"));
    }

    #[test]
    fn retry_binding_ignores_time_but_binds_token_and_identity() {
        let claim = claim();
        let mut retry = claim.clone();
        retry.timestamp += 100;
        assert_eq!(claim.binding(), retry.binding());
        retry.token.push('x');
        assert_ne!(claim.binding(), retry.binding());
    }

    #[test]
    fn heartbeat_metadata_is_bound_and_renewal_is_separated() {
        let metadata = serde_json::json!({"hostname":"test"});
        let heartbeat = device_proof("device", 1, "nonce", "heartbeat", &metadata);
        assert_ne!(heartbeat, device_proof("device", 1, "nonce", "heartbeat", &serde_json::json!({"hostname":"changed"})));
        assert_ne!(heartbeat, device_proof("device", 1, "nonce", "credential-renew", &metadata));
    }
}
