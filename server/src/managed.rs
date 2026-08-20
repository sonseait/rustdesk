//! Managed control-plane authorization at the hbbs protocol boundary.
//!
//! The server is deliberately configured with only the issuer public key. It
//! never receives a control-plane signing key or treats credentials as relay
//! authorization.

use chrono::Utc;
use control_plane_node_agent::{AuthorizationError, ManagedAuthorizer, ManagedMode, RegistrationAuthorization};
use control_plane_protocol::{DeviceCredentialClaims, SessionTicketClaims, SignedDeviceCredential, SignedSessionTicket};
use hbb_common::protobuf::MessageField;
use hbb_common::rendezvous_proto::{ManagedDeviceCredential, ManagedSessionTicket};
use once_cell::sync::Lazy;
use uuid::Uuid;

enum RuntimeAuthorizer {
    Disabled,
    Ready(ManagedAuthorizer),
    Invalid,
}

static AUTHORIZER: Lazy<RuntimeAuthorizer> = Lazy::new(|| {
    let mode = match crate::common::get_arg("managed-mode").trim().to_ascii_lowercase().as_str() {
        "" | "off" => ManagedMode::Off,
        "optional" => ManagedMode::Optional,
        "required" => ManagedMode::Required,
        _ => return RuntimeAuthorizer::Invalid,
    };
    if mode == ManagedMode::Off {
        return RuntimeAuthorizer::Disabled;
    }
    match ManagedAuthorizer::from_hex(
        mode,
        crate::common::get_arg_opt("managed-credential-issuer-public-key").as_deref(),
    ) {
        Ok(authorizer) => RuntimeAuthorizer::Ready(authorizer),
        Err(_) => RuntimeAuthorizer::Invalid,
    }
});

/// Returns the managed device and RustDesk identities for a verified
/// registration. `None` means legacy access is permitted by optional/off mode.
pub(crate) fn authorize_registration(
    envelope: &MessageField<ManagedDeviceCredential>,
) -> Result<Option<(Uuid, String)>, AuthorizationError> {
    let RuntimeAuthorizer::Ready(authorizer) = &*AUTHORIZER else {
        return match &*AUTHORIZER {
            RuntimeAuthorizer::Disabled => Ok(None),
            RuntimeAuthorizer::Invalid => Err(AuthorizationError::InvalidCredential),
            RuntimeAuthorizer::Ready(_) => unreachable!(),
        };
    };
    let credential = envelope.as_ref().map(parse_credential).transpose()?;
    match authorizer.authorize_registration(credential.as_ref(), Utc::now()) {
        Ok(RegistrationAuthorization::Legacy) => { crate::managed_observability::record("registration", true, "legacy"); Ok(None) }
        Ok(RegistrationAuthorization::Managed { device_id, rustdesk_id }) => { crate::managed_observability::record("registration", true, "managed"); Ok(Some((device_id, rustdesk_id))) }
        Err(error) => { crate::managed_observability::record("registration", false, error.to_string()); Err(error) }
    }
}

/// Validates a ticket before the target peer lookup. The signed source device
/// claim is the ticket holder identity; the target identity comes from the
/// target's live, verified registration.
pub(crate) fn authorize_session(
    envelope: &MessageField<ManagedSessionTicket>,
    target_device_id: Option<Uuid>,
) -> Result<(), AuthorizationError> {
    let RuntimeAuthorizer::Ready(authorizer) = &*AUTHORIZER else {
        return match &*AUTHORIZER {
            RuntimeAuthorizer::Disabled => Ok(()),
            RuntimeAuthorizer::Invalid => Err(AuthorizationError::InvalidTicket),
            RuntimeAuthorizer::Ready(_) => unreachable!(),
        };
    };
    let Some(envelope) = envelope.as_ref() else {
        return authorizer
            .authorize_registration(None, Utc::now())
            .map(|_| ())
            .map_err(|_| AuthorizationError::InvalidTicket);
    };
    let ticket = parse_ticket(envelope)?;
    let untrusted_claims: SessionTicketClaims = serde_json::from_slice(&envelope.claims)
        .map_err(|_| AuthorizationError::InvalidTicket)?;
    let target_device_id = target_device_id.ok_or(AuthorizationError::WrongTicketBinding)?;
    let result = authorizer
        .authorize_session(&ticket, untrusted_claims.source_device_id, target_device_id, Utc::now())
        .map(|_| ());
    crate::managed_observability::record("session", result.is_ok(), result.as_ref().err().map_or("ticket accepted".to_owned(), ToString::to_string));
    result
}

/// hbbr sees only the relay rendezvous UUID, not the live peer map held by
/// hbbs. It therefore validates the short-lived signed relay envelope itself;
/// hbbs has already bound the ticket to the target before forwarding this
/// request. A missing envelope is allowed solely in optional/off rollout mode.
pub(crate) fn authorize_relay(
    envelope: &MessageField<ManagedSessionTicket>,
) -> Result<bool, AuthorizationError> {
    let RuntimeAuthorizer::Ready(authorizer) = &*AUTHORIZER else {
        return match &*AUTHORIZER {
            RuntimeAuthorizer::Disabled => Ok(false),
            RuntimeAuthorizer::Invalid => Err(AuthorizationError::InvalidTicket),
            RuntimeAuthorizer::Ready(_) => unreachable!(),
        };
    };
    let Some(envelope) = envelope.as_ref() else {
        return authorizer
            .authorize_registration(None, Utc::now())
            .map(|_| false)
            .map_err(|_| AuthorizationError::InvalidTicket);
    };
    let ticket = parse_ticket(envelope)?;
    let claims: SessionTicketClaims = serde_json::from_slice(&envelope.claims)
        .map_err(|_| AuthorizationError::InvalidTicket)?;
    let result = authorizer
        .authorize_session(&ticket, claims.source_device_id, claims.target_device_id, Utc::now())
        .map(|_| true);
    crate::managed_observability::record("relay", result.is_ok(), result.as_ref().err().map_or("ticket accepted".to_owned(), ToString::to_string));
    result
}

pub(crate) fn relay_authorization_required() -> bool {
    crate::common::get_arg("managed-mode").trim().eq_ignore_ascii_case("required")
}

fn parse_credential(envelope: &ManagedDeviceCredential) -> Result<SignedDeviceCredential, AuthorizationError> {
    let claims: DeviceCredentialClaims = serde_json::from_slice(&envelope.claims)
        .map_err(|_| AuthorizationError::InvalidCredential)?;
    if envelope.version != u32::from(claims.version) {
        return Err(AuthorizationError::InvalidCredential);
    }
    Ok(SignedDeviceCredential {
        claims,
        signature: hex::encode(&envelope.signature),
        issuer_public_key: hex::encode(&envelope.issuer_public_key),
    })
}

fn parse_ticket(envelope: &ManagedSessionTicket) -> Result<SignedSessionTicket, AuthorizationError> {
    let claims: SessionTicketClaims = serde_json::from_slice(&envelope.claims)
        .map_err(|_| AuthorizationError::InvalidTicket)?;
    if envelope.version != u32::from(claims.version) {
        return Err(AuthorizationError::InvalidTicket);
    }
    Ok(SignedSessionTicket {
        claims,
        signature: hex::encode(&envelope.signature),
        issuer_public_key: hex::encode(&envelope.issuer_public_key),
    })
}
