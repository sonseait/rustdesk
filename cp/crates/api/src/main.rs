use std::{collections::HashMap, env, net::SocketAddr, sync::Arc, time::Instant};

use aes_gcm::{
    aead::{rand_core::RngCore, Aead, OsRng},
    Aes256Gcm, KeyInit, Nonce,
};

use anyhow::{Context, Result};
use axum::{
    extract::{Path, State},
    http::{
        header::{AUTHORIZATION, COOKIE, SET_COOKIE},
        HeaderMap, HeaderValue, StatusCode,
    },
    response::{IntoResponse, Json},
    routing::{delete, get, post},
    Router,
};
use chrono::{Duration, Utc};
use control_plane_auth::{hash_password, hash_session_token, new_session_token, verify_password};
use control_plane_db::{
    accept_heartbeat, active_device_exists, active_device_id_for_rustdesk_id, claim_enrollment,
    confirm_totp, connect, consume_totp_counter, create_enrollment_token, create_initial_admin,
    create_session, current_server_config, device_credential_subject, device_public_key,
    find_active_user_by_email, get_server_policy, has_users, is_admin, list_audit_events,
    list_devices, list_enrollment_tokens, list_remote_sessions, list_roles, list_server_nodes,
    list_users, migrate, record_remote_session_authorized, record_user_audit_event,
    report_server_node_health, revoke_device, revoke_enrollment_token, revoke_session,
    set_totp_secret, update_current_server_config, update_server_policy, user_for_session,
    Database, UserWithPassword,
};
use control_plane_domain::{
    AnonymousRemotePolicy, AuditEvent, CurrentServerConfig, Device, DeviceHeartbeatMetadata,
    EnrollmentClaim, EnrollmentToken, NewAdmin, NewEnrollmentToken, RemoteSession, Role,
    ServerNode, UpdateCurrentServerConfig, User, UserSummary,
};
use control_plane_node_agent::{
    AnonymousRemotePolicy as AgentAnonymousRemotePolicy, DesiredNodeConfig, ManagedMode, NodeHealth,
};
use control_plane_protocol::{
    DeviceCredentialClaims, DevicePolicyClaims, SessionTicketClaims, SignedDeviceCredential,
    SignedDevicePolicy, SignedSessionTicket, MANAGED_PROTOCOL_VERSION,
};
use serde::{Deserialize, Serialize};
use totp_rs::{Algorithm, Secret, TOTP};
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use tracing::{error, info};

#[derive(Clone)]
struct AppState {
    database: Database,
    bootstrap_token: Arc<str>,
    session_ttl: Duration,
    secure_cookie: bool,
    credential_signing_key: Option<ed25519_dalek::SigningKey>,
    deployment_config_signing_key: Option<ed25519_dalek::SigningKey>,
    totp_encryption_key: Option<[u8; 32]>,
    login_attempts: Arc<tokio::sync::Mutex<HashMap<String, (u8, Instant)>>>,
}

#[derive(Deserialize)]
struct BootstrapAdminRequest {
    email: String,
    display_name: String,
    password: String,
}

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
}

#[derive(Serialize)]
struct BootstrapAdminResponse {
    id: String,
    email: String,
    display_name: String,
}

#[derive(Deserialize)]
struct LoginRequest {
    email: String,
    password: String,
    #[serde(default)]
    totp_code: Option<String>,
}

#[derive(Serialize)]
struct TotpSetupResponse {
    otpauth_url: String,
}

#[derive(Deserialize)]
struct TotpConfirmationRequest {
    code: String,
}

#[derive(Serialize)]
struct CurrentUserResponse {
    id: String,
    email: String,
    display_name: String,
}

#[derive(Serialize)]
struct CreatedEnrollmentToken {
    token: EnrollmentToken,
    secret: String,
}
#[derive(Deserialize)]
struct Heartbeat {
    timestamp: i64,
    nonce: String,
    signature: String,
    #[serde(default)]
    metadata: Option<DeviceHeartbeatMetadata>,
}

#[derive(Deserialize)]
struct SessionTicketRequest {
    target_device_id: Option<uuid::Uuid>,
    target_rustdesk_id: Option<String>,
    permissions: Vec<String>,
    credential: SignedDeviceCredential,
}

#[derive(Deserialize)]
struct DevicePolicyRequest {
    credential: SignedDeviceCredential,
}

#[derive(Deserialize)]
struct ManagedConfigRequest {
    device_id: uuid::Uuid,
    timestamp: i64,
    nonce: String,
    signature: String,
}

#[derive(Serialize)]
struct DeploymentConfigClaims {
    version: u16,
    revision: i64,
    rendezvous_server: String,
    relay_server: String,
    server_public_key: String,
    issued_at: chrono::DateTime<Utc>,
}

#[derive(Serialize)]
struct SignedDeploymentConfig {
    claims: DeploymentConfigClaims,
    signature: String,
    issuer_public_key: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let database_url = required_env("DATABASE_URL")?;
    let bootstrap_token = required_env("BOOTSTRAP_TOKEN")?;
    let bind_addr: SocketAddr = env::var("BIND_ADDR")
        .unwrap_or_else(|_| "0.0.0.0:8080".to_owned())
        .parse()
        .context("BIND_ADDR must be a socket address")?;
    let session_ttl_hours: i64 = env::var("SESSION_TTL_HOURS")
        .unwrap_or_else(|_| "24".to_owned())
        .parse()
        .context("SESSION_TTL_HOURS must be an integer")?;
    if session_ttl_hours < 1 || session_ttl_hours > 24 * 31 {
        anyhow::bail!("SESSION_TTL_HOURS must be between 1 and 744");
    }
    let secure_cookie = env::var("SESSION_COOKIE_SECURE")
        .map(|value| value != "false")
        .unwrap_or(!bind_addr.ip().is_loopback());
    let credential_signing_key = env::var("DEVICE_CREDENTIAL_SIGNING_KEY")
        .ok()
        .map(|value| {
            let bytes = hex::decode(value).context("DEVICE_CREDENTIAL_SIGNING_KEY must be hex")?;
            let bytes: [u8; 32] = bytes
                .as_slice()
                .try_into()
                .context("DEVICE_CREDENTIAL_SIGNING_KEY must be a 32-byte Ed25519 seed")?;
            Ok::<_, anyhow::Error>(ed25519_dalek::SigningKey::from_bytes(&bytes))
        })
        .transpose()?;
    let deployment_config_signing_key = env::var("BOOTSTRAP_CONFIG_SIGNING_KEY")
        .ok()
        .map(parse_ed25519_seed)
        .transpose()?;
    let totp_encryption_key = env::var("TOTP_ENCRYPTION_KEY")
        .ok()
        .map(|value| {
            let bytes = hex::decode(value).context("TOTP_ENCRYPTION_KEY must be hex")?;
            bytes
                .as_slice()
                .try_into()
                .context("TOTP_ENCRYPTION_KEY must be a 32-byte key")
        })
        .transpose()?;
    let database = connect(&database_url).await?;
    migrate(&database).await?;

    let app = Router::new()
        .route("/healthz", get(health))
        .route("/metrics", get(metrics))
        .route("/v1/bootstrap/admin", post(bootstrap_admin))
        .route("/v1/auth/login", post(login))
        .route("/v1/auth/logout", post(logout))
        .route("/v1/auth/me", get(current_user))
        .route("/v1/auth/totp", post(begin_totp_setup))
        .route("/v1/auth/totp/confirm", post(confirm_totp_setup))
        .route("/v1/server-policy", get(server_policy).put(update_policy))
        .route(
            "/v1/current-server/config",
            get(get_current_server_config).put(put_current_server_config),
        )
        .route("/v1/users", get(users))
        .route("/v1/roles", get(roles))
        .route("/v1/audit-events", get(audit_events))
        .route("/v1/remote-sessions", get(remote_sessions))
        .route("/v1/server-nodes", get(server_nodes))
        .route(
            "/v1/node-agent/desired-config",
            get(node_agent_desired_config),
        )
        .route("/v1/node-agent/health", post(node_agent_health))
        .route(
            "/v1/enrollment-tokens",
            get(enrollment_tokens).post(create_token),
        )
        .route("/v1/enrollment-tokens/:id", delete(revoke_token))
        .route("/v1/devices", get(devices))
        .route("/v1/devices/:id/revoke", post(revoke_managed_device))
        .route("/v1/enrollment/claim", post(claim_device))
        .route("/v1/devices/:id/heartbeat", post(heartbeat))
        .route("/v1/devices/:id/credential/renew", post(renew_credential))
        .route("/v1/device-policy", post(device_policy))
        .route("/v1/managed/config", post(managed_config))
        .route("/v1/session-tickets", post(create_session_ticket))
        .with_state(AppState {
            database,
            bootstrap_token: Arc::from(bootstrap_token),
            session_ttl: Duration::hours(session_ttl_hours),
            secure_cookie,
            credential_signing_key,
            deployment_config_signing_key,
            totp_encryption_key,
            login_attempts: Default::default(),
        })
        .layer(CorsLayer::new())
        .layer(TraceLayer::new_for_http())
        .layer(axum::middleware::from_fn(add_security_headers));
    let listener = tokio::net::TcpListener::bind(bind_addr).await?;
    info!(%bind_addr, "control plane API listening");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn login(
    State(state): State<AppState>,
    Json(request): Json<LoginRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let login_key = request.email.trim().to_ascii_lowercase();
    if !login_allowed(&state, &login_key).await {
        return Err(ApiError::too_many_requests());
    }
    let user = find_active_user_by_email(&state.database, &request.email)
        .await
        .map_err(ApiError::database)?;
    let Some(user) = user else {
        record_login_failure(&state, login_key).await;
        return Err(ApiError::unauthorized());
    };
    let valid = verify_password(&request.password, &user.password_hash)
        .map_err(|_| ApiError::unauthorized())?;
    if !valid {
        record_login_failure(&state, login_key).await;
        return Err(ApiError::unauthorized());
    }
    verify_login_totp(&state, &user, request.totp_code.as_deref()).await?;

    state.login_attempts.lock().await.remove(&login_key);

    let token = new_session_token();
    let expires_at = Utc::now() + state.session_ttl;
    create_session(
        &state.database,
        user.user.id,
        &hash_session_token(&token),
        expires_at,
    )
    .await
    .map_err(ApiError::database)?;
    let cookie = session_cookie(&token, state.session_ttl.num_seconds(), state.secure_cookie)
        .map_err(|_| ApiError::internal())?;
    Ok((
        [(SET_COOKIE, cookie)],
        Json(current_user_response(user.user)),
    ))
}

async fn begin_totp_setup(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<TotpSetupResponse>, ApiError> {
    require_same_origin(&headers)?;
    let user = authenticated_user(&state, &headers).await?;
    let key = state
        .totp_encryption_key
        .as_ref()
        .ok_or_else(ApiError::mfa_unavailable)?;
    let secret = Secret::generate_secret()
        .to_bytes()
        .map_err(|_| ApiError::internal())?;
    let encrypted = encrypt_totp_secret(key, &secret)?;
    set_totp_secret(&state.database, user.id, &encrypted)
        .await
        .map_err(ApiError::database)?;
    record_user_audit_event(
        &state.database,
        user.id,
        "totp_setup_started",
        serde_json::json!({}),
    )
    .await
    .map_err(ApiError::database)?;
    let totp = new_totp(secret, &user.email)?;
    Ok(Json(TotpSetupResponse {
        otpauth_url: totp.get_url(),
    }))
}

async fn confirm_totp_setup(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<TotpConfirmationRequest>,
) -> Result<StatusCode, ApiError> {
    require_same_origin(&headers)?;
    let user = authenticated_user(&state, &headers).await?;
    let full_user = find_active_user_by_email(&state.database, &user.email)
        .await
        .map_err(ApiError::database)?
        .ok_or_else(ApiError::unauthorized)?;
    let secret = decrypt_user_totp(&state, &full_user)?;
    let totp = new_totp(secret, &user.email)?;
    if !valid_totp_code(&totp, &request.code) {
        return Err(ApiError::unauthorized());
    }
    confirm_totp(&state.database, user.id)
        .await
        .map_err(ApiError::database)?;
    record_user_audit_event(
        &state.database,
        user.id,
        "totp_enabled",
        serde_json::json!({}),
    )
    .await
    .map_err(ApiError::database)?;
    Ok(StatusCode::NO_CONTENT)
}

async fn verify_login_totp(
    state: &AppState,
    user: &UserWithPassword,
    code: Option<&str>,
) -> Result<(), ApiError> {
    if user.totp_confirmed_at.is_none() {
        return Ok(());
    }
    let secret = decrypt_user_totp(state, user)?;
    let totp = new_totp(secret, &user.user.email)?;
    let code = code.ok_or_else(ApiError::mfa_required)?;
    if !valid_totp_code(&totp, code) {
        return Err(ApiError::unauthorized());
    }
    let counter = Utc::now().timestamp().div_euclid(30);
    if !consume_totp_counter(&state.database, user.user.id, counter)
        .await
        .map_err(ApiError::database)?
    {
        return Err(ApiError::unauthorized());
    }
    Ok(())
}

fn new_totp(secret: Vec<u8>, account_name: &str) -> Result<TOTP, ApiError> {
    TOTP::new(
        Algorithm::SHA1,
        6,
        1,
        30,
        secret,
        Some("RustDesk Control Plane".to_owned()),
        account_name.to_owned(),
    )
    .map_err(|_| ApiError::internal())
}

fn valid_totp_code(totp: &TOTP, code: &str) -> bool {
    code.len() == 6
        && code.bytes().all(|byte| byte.is_ascii_digit())
        && totp.check_current(code).unwrap_or(false)
}

fn encrypt_totp_secret(key: &[u8; 32], secret: &[u8]) -> Result<String, ApiError> {
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| ApiError::internal())?;
    let mut nonce = [0_u8; 12];
    OsRng.fill_bytes(&mut nonce);
    let ciphertext = cipher
        .encrypt(Nonce::from_slice(&nonce), secret)
        .map_err(|_| ApiError::internal())?;
    Ok(format!(
        "{}:{}",
        hex::encode(nonce),
        hex::encode(ciphertext)
    ))
}

fn decrypt_user_totp(state: &AppState, user: &UserWithPassword) -> Result<Vec<u8>, ApiError> {
    let key = state
        .totp_encryption_key
        .as_ref()
        .ok_or_else(ApiError::mfa_unavailable)?;
    let encrypted = user
        .totp_secret_encrypted
        .as_deref()
        .ok_or_else(ApiError::unauthorized)?;
    let (nonce, ciphertext) = encrypted
        .split_once(':')
        .ok_or_else(ApiError::unauthorized)?;
    let nonce = hex::decode(nonce).map_err(|_| ApiError::unauthorized())?;
    let ciphertext = hex::decode(ciphertext).map_err(|_| ApiError::unauthorized())?;
    let nonce: [u8; 12] = nonce
        .as_slice()
        .try_into()
        .map_err(|_| ApiError::unauthorized())?;
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| ApiError::internal())?;
    cipher
        .decrypt(Nonce::from_slice(&nonce), ciphertext.as_ref())
        .map_err(|_| ApiError::unauthorized())
}

async fn login_allowed(state: &AppState, key: &str) -> bool {
    let attempts = state.login_attempts.lock().await;
    attempts
        .get(key)
        .is_none_or(|(count, started)| *count < 5 || started.elapsed().as_secs() >= 300)
}

async fn record_login_failure(state: &AppState, key: String) {
    let mut attempts = state.login_attempts.lock().await;
    let entry = attempts.entry(key).or_insert((0, Instant::now()));
    if entry.1.elapsed().as_secs() >= 300 {
        *entry = (0, Instant::now());
    }
    entry.0 = entry.0.saturating_add(1);
}

async fn current_user(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<CurrentUserResponse>, ApiError> {
    let user = authenticated_user(&state, &headers).await?;
    Ok(Json(current_user_response(user)))
}

async fn server_policy(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<AnonymousRemotePolicy>, ApiError> {
    require_admin(&state, &headers).await?;
    get_server_policy(&state.database)
        .await
        .map(Json)
        .map_err(ApiError::database)
}

async fn update_policy(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(policy): Json<AnonymousRemotePolicy>,
) -> Result<Json<AnonymousRemotePolicy>, ApiError> {
    require_same_origin(&headers)?;
    let user = require_admin(&state, &headers).await?;
    policy
        .validate()
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    update_server_policy(&state.database, user.id, &policy)
        .await
        .map_err(ApiError::database)?;
    Ok(Json(policy))
}

async fn get_current_server_config(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<CurrentServerConfig>, ApiError> {
    require_admin(&state, &headers).await?;
    current_server_config(&state.database)
        .await
        .map(Json)
        .map_err(ApiError::database)
}

async fn put_current_server_config(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(config): Json<UpdateCurrentServerConfig>,
) -> Result<Json<CurrentServerConfig>, ApiError> {
    require_same_origin(&headers)?;
    let user = require_admin(&state, &headers).await?;
    config
        .validate()
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    if config.managed_mode != "off" {
        let bytes = config
            .credential_issuer_public_key
            .as_deref()
            .and_then(|key| hex::decode(key).ok())
            .and_then(|bytes| <[u8; 32]>::try_from(bytes.as_slice()).ok())
            .ok_or_else(|| {
                ApiError::bad_request("credential issuer public key is invalid".into())
            })?;
        ed25519_dalek::VerifyingKey::from_bytes(&bytes)
            .map_err(|_| ApiError::bad_request("credential issuer public key is invalid".into()))?;
    }
    update_current_server_config(&state.database, user.id, &config)
        .await
        .map(Json)
        .map_err(ApiError::database)
}

async fn users(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<UserSummary>>, ApiError> {
    require_admin(&state, &headers).await?;
    list_users(&state.database)
        .await
        .map(Json)
        .map_err(ApiError::database)
}

async fn roles(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<Role>>, ApiError> {
    require_admin(&state, &headers).await?;
    list_roles(&state.database)
        .await
        .map(Json)
        .map_err(ApiError::database)
}

async fn audit_events(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<AuditEvent>>, ApiError> {
    require_admin(&state, &headers).await?;
    list_audit_events(&state.database)
        .await
        .map(Json)
        .map_err(ApiError::database)
}

async fn remote_sessions(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<RemoteSession>>, ApiError> {
    require_admin(&state, &headers).await?;
    list_remote_sessions(&state.database)
        .await
        .map(Json)
        .map_err(ApiError::database)
}

async fn server_nodes(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<ServerNode>>, ApiError> {
    require_admin(&state, &headers).await?;
    list_server_nodes(&state.database)
        .await
        .map(Json)
        .map_err(ApiError::database)
}

async fn node_agent_desired_config(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<DesiredNodeConfig>, ApiError> {
    require_mtls_node(&headers)?;
    let config = current_server_config(&state.database)
        .await
        .map_err(ApiError::database)?;
    let policy = get_server_policy(&state.database)
        .await
        .map_err(ApiError::database)?;
    let managed_mode = match config.managed_mode.as_str() {
        "off" => ManagedMode::Off,
        "optional" => ManagedMode::Optional,
        "required" => ManagedMode::Required,
        _ => return Err(ApiError::internal()),
    };
    Ok(Json(DesiredNodeConfig {
        revision: config.revision as u64,
        anonymous_remote_policy: AgentAnonymousRemotePolicy {
            enabled: policy.enabled,
            max_session_minutes: policy.max_session_minutes as u16,
            max_concurrent_devices: policy.max_concurrent_devices as u32,
            max_devices_per_window: policy.max_devices_per_window as u32,
            window_minutes: policy.window_minutes as u16,
        },
        managed_mode,
        credential_issuer_public_key: config.credential_issuer_public_key,
    }))
}

async fn node_agent_health(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(health): Json<NodeHealth>,
) -> Result<StatusCode, ApiError> {
    let node_id = require_mtls_node(&headers)?;
    report_server_node_health(
        &state.database,
        node_id,
        &serde_json::to_value(health)
            .map_err(|_| ApiError::bad_request("invalid node health".into()))?,
    )
    .await
    .map_err(ApiError::database)?;
    Ok(StatusCode::NO_CONTENT)
}

fn require_mtls_node(headers: &HeaderMap) -> Result<uuid::Uuid, ApiError> {
    // Caddy strips incoming client-certificate headers and writes this value
    // only after successful TLS client authentication. The API remains private
    // behind that proxy in production.
    if headers
        .get("x-mtls-verified")
        .and_then(|value| value.to_str().ok())
        != Some("true")
    {
        return Err(ApiError::forbidden());
    }
    headers
        .get("x-node-agent-id")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse().ok())
        .ok_or_else(ApiError::unauthorized)
}

async fn enrollment_tokens(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<EnrollmentToken>>, ApiError> {
    require_admin(&state, &headers).await?;
    list_enrollment_tokens(&state.database)
        .await
        .map(Json)
        .map_err(ApiError::database)
}

async fn create_token(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<NewEnrollmentToken>,
) -> Result<(StatusCode, Json<CreatedEnrollmentToken>), ApiError> {
    require_same_origin(&headers)?;
    let user = require_admin(&state, &headers).await?;
    request
        .validate()
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    let secret = new_session_token();
    let token = create_enrollment_token(
        &state.database,
        user.id,
        &hash_session_token(&secret),
        &request.label,
        request.max_enrollments,
        Utc::now() + Duration::hours(i64::from(request.expires_in_hours)),
    )
    .await
    .map_err(ApiError::database)?;
    Ok((
        StatusCode::CREATED,
        Json(CreatedEnrollmentToken { token, secret }),
    ))
}

async fn revoke_token(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(token_id): Path<uuid::Uuid>,
) -> Result<StatusCode, ApiError> {
    require_same_origin(&headers)?;
    let user = require_admin(&state, &headers).await?;
    if revoke_enrollment_token(&state.database, user.id, token_id)
        .await
        .map_err(ApiError::database)?
    {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::not_found())
    }
}

async fn devices(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<Device>>, ApiError> {
    require_admin(&state, &headers).await?;
    list_devices(&state.database)
        .await
        .map(Json)
        .map_err(ApiError::database)
}

async fn revoke_managed_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(device_id): Path<uuid::Uuid>,
) -> Result<StatusCode, ApiError> {
    require_same_origin(&headers)?;
    let user = require_admin(&state, &headers).await?;
    if revoke_device(&state.database, user.id, device_id)
        .await
        .map_err(ApiError::database)?
    {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::not_found())
    }
}

async fn claim_device(
    State(state): State<AppState>,
    Json(claim): Json<EnrollmentClaim>,
) -> Result<(StatusCode, Json<Device>), ApiError> {
    claim
        .validate()
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    let device = claim_enrollment(
        &state.database,
        &hash_session_token(&claim.token),
        &claim.display_name,
        &claim.hostname,
        &claim.operating_system,
        &claim.client_version,
        &claim.public_key_fingerprint,
        &claim.public_key,
        &claim.rustdesk_id,
    )
    .await
    .map_err(ApiError::database)?
    .ok_or_else(ApiError::unauthorized)?;
    Ok((StatusCode::CREATED, Json(device)))
}

async fn heartbeat(
    State(state): State<AppState>,
    Path(device_id): Path<uuid::Uuid>,
    Json(request): Json<Heartbeat>,
) -> Result<StatusCode, ApiError> {
    if (Utc::now().timestamp() - request.timestamp).abs() > 300 {
        return Err(ApiError::unauthorized());
    }
    if let Some(metadata) = &request.metadata {
        metadata
            .validate()
            .map_err(|error| ApiError::bad_request(error.to_string()))?;
    }
    let nonce = request
        .nonce
        .parse::<uuid::Uuid>()
        .map_err(|_| ApiError::bad_request("invalid heartbeat nonce".into()))?;
    let public_key = device_public_key(&state.database, device_id)
        .await
        .map_err(ApiError::database)?
        .ok_or_else(ApiError::unauthorized)?;
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};
    let key = hex::decode(public_key)
        .ok()
        .and_then(|bytes| <[u8; 32]>::try_from(bytes.as_slice()).ok())
        .and_then(|bytes| VerifyingKey::from_bytes(&bytes).ok())
        .ok_or_else(ApiError::unauthorized)?;
    let signature = hex::decode(request.signature)
        .ok()
        .and_then(|bytes| Signature::from_slice(&bytes).ok())
        .ok_or_else(ApiError::unauthorized)?;
    let payload = format!("{device_id}:{}:{}", request.timestamp, request.nonce);
    key.verify(payload.as_bytes(), &signature)
        .map_err(|_| ApiError::unauthorized())?;
    if !accept_heartbeat(&state.database, device_id, nonce, request.metadata.as_ref())
        .await
        .map_err(ApiError::database)?
    {
        return Err(ApiError::conflict("heartbeat replay detected"));
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn renew_credential(
    State(state): State<AppState>,
    Path(device_id): Path<uuid::Uuid>,
    Json(request): Json<Heartbeat>,
) -> Result<Json<SignedDeviceCredential>, ApiError> {
    let signing_key = state
        .credential_signing_key
        .as_ref()
        .ok_or_else(ApiError::service_unavailable)?;
    if (Utc::now().timestamp() - request.timestamp).abs() > 300 {
        return Err(ApiError::unauthorized());
    }
    let nonce = request
        .nonce
        .parse::<uuid::Uuid>()
        .map_err(|_| ApiError::bad_request("invalid renewal nonce".into()))?;
    let (public_key, public_key_fingerprint, rustdesk_id) =
        device_credential_subject(&state.database, device_id)
            .await
            .map_err(ApiError::database)?
            .ok_or_else(ApiError::unauthorized)?;
    use ed25519_dalek::{Signature, Signer, Verifier, VerifyingKey};
    let key = hex::decode(public_key.clone())
        .ok()
        .and_then(|bytes| <[u8; 32]>::try_from(bytes.as_slice()).ok())
        .and_then(|bytes| VerifyingKey::from_bytes(&bytes).ok())
        .ok_or_else(ApiError::unauthorized)?;
    let signature = hex::decode(request.signature)
        .ok()
        .and_then(|bytes| Signature::from_slice(&bytes).ok())
        .ok_or_else(ApiError::unauthorized)?;
    key.verify(
        format!("{device_id}:{}:{}", request.timestamp, request.nonce).as_bytes(),
        &signature,
    )
    .map_err(|_| ApiError::unauthorized())?;
    // Consuming the nonce prevents a captured renewal request being replayed.
    if !accept_heartbeat(&state.database, device_id, nonce, None)
        .await
        .map_err(ApiError::database)?
    {
        return Err(ApiError::conflict("credential renewal replay detected"));
    }
    let now = Utc::now();
    let claims = DeviceCredentialClaims {
        version: MANAGED_PROTOCOL_VERSION,
        device_id,
        rustdesk_id,
        public_key_fingerprint,
        issued_at: now,
        expires_at: now + Duration::hours(24),
    };
    let payload = serde_json::to_vec(&claims).map_err(|_| ApiError::internal())?;
    Ok(Json(SignedDeviceCredential {
        claims,
        signature: hex::encode(signing_key.sign(&payload).to_bytes()),
        issuer_public_key: hex::encode(signing_key.verifying_key().as_bytes()),
    }))
}

async fn create_session_ticket(
    State(state): State<AppState>,
    Json(request): Json<SessionTicketRequest>,
) -> Result<Json<SignedSessionTicket>, ApiError> {
    use ed25519_dalek::Signer;
    let signing_key = state
        .credential_signing_key
        .as_ref()
        .ok_or_else(ApiError::service_unavailable)?;
    let source_device_id =
        verify_device_credential(&state.database, signing_key, &request.credential).await?;
    let target_device_id = match (
        request.target_device_id,
        request.target_rustdesk_id.as_deref(),
    ) {
        (Some(device_id), None)
            if active_device_exists(&state.database, device_id)
                .await
                .map_err(ApiError::database)? =>
        {
            device_id
        }
        (None, Some(rustdesk_id)) if !rustdesk_id.is_empty() && rustdesk_id.len() <= 256 => {
            active_device_id_for_rustdesk_id(&state.database, rustdesk_id)
                .await
                .map_err(ApiError::database)?
                .ok_or_else(ApiError::not_found)?
        }
        (Some(_), None) | (None, Some(_)) => return Err(ApiError::not_found()),
        _ => {
            return Err(ApiError::bad_request(
                "provide exactly one target device identifier".into(),
            ))
        }
    };
    if request.permissions.as_slice() != ["remote-control"] {
        return Err(ApiError::bad_request(
            "only remote-control is currently supported".into(),
        ));
    }
    let now = Utc::now();
    let claims = SessionTicketClaims {
        version: MANAGED_PROTOCOL_VERSION,
        ticket_id: uuid::Uuid::new_v4(),
        source_device_id,
        target_device_id,
        expires_at: now + Duration::minutes(5),
        permissions: request.permissions,
    };
    record_remote_session_authorized(
        &state.database,
        claims.ticket_id,
        claims.source_device_id,
        claims.target_device_id,
        "remote-control",
        claims.expires_at,
    )
    .await
    .map_err(ApiError::database)?;
    let payload = serde_json::to_vec(&claims).map_err(|_| ApiError::internal())?;
    Ok(Json(SignedSessionTicket {
        claims,
        signature: hex::encode(signing_key.sign(&payload).to_bytes()),
        issuer_public_key: hex::encode(signing_key.verifying_key().as_bytes()),
    }))
}

async fn device_policy(
    State(state): State<AppState>,
    Json(request): Json<DevicePolicyRequest>,
) -> Result<Json<SignedDevicePolicy>, ApiError> {
    use ed25519_dalek::Signer;
    let signing_key = state
        .credential_signing_key
        .as_ref()
        .ok_or_else(ApiError::service_unavailable)?;
    let device_id =
        verify_device_credential(&state.database, signing_key, &request.credential).await?;
    let claims = DevicePolicyClaims {
        version: MANAGED_PROTOCOL_VERSION,
        device_id,
        revision: 1,
        // Policy snapshots deliberately expire sooner than credentials so an
        // offline client cannot retain capabilities indefinitely after a
        // control-plane change or revocation event.
        expires_at: Utc::now() + Duration::hours(4),
        capabilities: vec!["remote-control".to_owned()],
    };
    let payload = serde_json::to_vec(&claims).map_err(|_| ApiError::internal())?;
    Ok(Json(SignedDevicePolicy {
        claims,
        signature: hex::encode(signing_key.sign(&payload).to_bytes()),
        issuer_public_key: hex::encode(signing_key.verifying_key().as_bytes()),
    }))
}

async fn managed_config(
    State(state): State<AppState>,
    Json(request): Json<ManagedConfigRequest>,
) -> Result<Json<SignedDeploymentConfig>, ApiError> {
    let signing_key = state
        .deployment_config_signing_key
        .as_ref()
        .ok_or_else(ApiError::service_unavailable)?;
    verify_device_proof(
        &state.database,
        request.device_id,
        request.timestamp,
        &request.nonce,
        &request.signature,
        "managed-config",
    )
    .await?;
    let config = current_server_config(&state.database)
        .await
        .map_err(ApiError::database)?;
    if config.rendezvous_server.is_empty()
        || config.relay_server.is_empty()
        || config.server_public_key.is_empty()
    {
        return Err(ApiError::service_unavailable());
    }
    let claims = DeploymentConfigClaims {
        version: 1,
        revision: config.revision,
        rendezvous_server: config.rendezvous_server,
        relay_server: config.relay_server,
        server_public_key: config.server_public_key,
        issued_at: Utc::now(),
    };
    use ed25519_dalek::Signer;
    let payload = serde_json::to_vec(&claims).map_err(|_| ApiError::internal())?;
    Ok(Json(SignedDeploymentConfig {
        signature: hex::encode(signing_key.sign(&payload).to_bytes()),
        issuer_public_key: hex::encode(signing_key.verifying_key().as_bytes()),
        claims,
    }))
}

async fn verify_device_proof(
    database: &Database,
    device_id: uuid::Uuid,
    timestamp: i64,
    nonce: &str,
    signature: &str,
    purpose: &str,
) -> Result<(), ApiError> {
    if (Utc::now().timestamp() - timestamp).abs() > 300 {
        return Err(ApiError::unauthorized());
    }
    let public_key = device_public_key(database, device_id)
        .await
        .map_err(ApiError::database)?
        .ok_or_else(ApiError::unauthorized)?;
    let bytes = hex::decode(public_key).map_err(|_| ApiError::unauthorized())?;
    let bytes: [u8; 32] = bytes
        .as_slice()
        .try_into()
        .map_err(|_| ApiError::unauthorized())?;
    let key =
        ed25519_dalek::VerifyingKey::from_bytes(&bytes).map_err(|_| ApiError::unauthorized())?;
    let signature = hex::decode(signature)
        .ok()
        .and_then(|bytes| ed25519_dalek::Signature::from_slice(&bytes).ok())
        .ok_or_else(ApiError::unauthorized)?;
    use ed25519_dalek::Verifier;
    key.verify(
        format!("{device_id}:{timestamp}:{nonce}:{purpose}").as_bytes(),
        &signature,
    )
    .map_err(|_| ApiError::unauthorized())
}

async fn verify_device_credential(
    database: &Database,
    signing_key: &ed25519_dalek::SigningKey,
    credential: &SignedDeviceCredential,
) -> Result<uuid::Uuid, ApiError> {
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};
    if credential.claims.version != MANAGED_PROTOCOL_VERSION
        || credential.claims.expires_at <= Utc::now()
    {
        return Err(ApiError::unauthorized());
    }
    let issuer_bytes = hex::decode(&credential.issuer_public_key)
        .ok()
        .and_then(|bytes| <[u8; 32]>::try_from(bytes.as_slice()).ok())
        .ok_or_else(ApiError::unauthorized)?;
    if issuer_bytes != *signing_key.verifying_key().as_bytes() {
        return Err(ApiError::unauthorized());
    }
    let issuer = VerifyingKey::from_bytes(&issuer_bytes).map_err(|_| ApiError::unauthorized())?;
    let signature = hex::decode(&credential.signature)
        .ok()
        .and_then(|bytes| Signature::from_slice(&bytes).ok())
        .ok_or_else(ApiError::unauthorized)?;
    let payload = serde_json::to_vec(&credential.claims).map_err(|_| ApiError::internal())?;
    issuer
        .verify(&payload, &signature)
        .map_err(|_| ApiError::unauthorized())?;
    let (_, fingerprint, _) = device_credential_subject(database, credential.claims.device_id)
        .await
        .map_err(ApiError::database)?
        .filter(|(_, fingerprint, rustdesk_id)| {
            fingerprint == &credential.claims.public_key_fingerprint
                && rustdesk_id == &credential.claims.rustdesk_id
        })
        .ok_or_else(ApiError::unauthorized)?;
    let _ = fingerprint;
    Ok(credential.claims.device_id)
}

async fn logout(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, ApiError> {
    let token = session_token(&headers).ok_or_else(ApiError::unauthorized)?;
    revoke_session(&state.database, &hash_session_token(token))
        .await
        .map_err(ApiError::database)?;
    let expired = session_cookie("", 0, state.secure_cookie).map_err(|_| ApiError::internal())?;
    Ok(([(SET_COOKIE, expired)], StatusCode::NO_CONTENT))
}

async fn authenticated_user(state: &AppState, headers: &HeaderMap) -> Result<User, ApiError> {
    let token = session_token(headers).ok_or_else(ApiError::unauthorized)?;
    user_for_session(&state.database, &hash_session_token(token))
        .await
        .map_err(ApiError::database)?
        .ok_or_else(ApiError::unauthorized)
}

async fn require_admin(state: &AppState, headers: &HeaderMap) -> Result<User, ApiError> {
    let user = authenticated_user(state, headers).await?;
    if is_admin(&state.database, user.id)
        .await
        .map_err(ApiError::database)?
    {
        Ok(user)
    } else {
        Err(ApiError::forbidden())
    }
}

fn session_token(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .find_map(|part| {
            let (name, value) = part.trim().split_once('=')?;
            (name == "rustdesk_session").then_some(value)
        })
}

fn session_cookie(
    token: &str,
    max_age_seconds: i64,
    secure: bool,
) -> Result<HeaderValue, http::header::InvalidHeaderValue> {
    let secure_attribute = if secure { "; Secure" } else { "" };
    HeaderValue::from_str(&format!("rustdesk_session={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={max_age_seconds}{secure_attribute}"))
}

fn current_user_response(user: User) -> CurrentUserResponse {
    CurrentUserResponse {
        id: user.id.to_string(),
        email: user.email,
        display_name: user.display_name,
    }
}

fn required_env(name: &str) -> Result<String> {
    env::var(name).with_context(|| format!("{name} must be set"))
}

fn parse_ed25519_seed(value: String) -> Result<ed25519_dalek::SigningKey> {
    let bytes = hex::decode(value).context("Ed25519 signing key must be hex")?;
    let bytes: [u8; 32] = bytes
        .as_slice()
        .try_into()
        .context("Ed25519 signing key must be a 32-byte seed")?;
    Ok(ed25519_dalek::SigningKey::from_bytes(&bytes))
}

async fn health(State(state): State<AppState>) -> Result<Json<HealthResponse>, ApiError> {
    // A process-only health response makes an unhealthy database look ready to
    // an orchestrator, so readiness includes a checked-out database connection.
    let _connection = state
        .database
        .acquire()
        .await
        .map_err(|_| ApiError::internal())?;
    Ok(Json(HealthResponse { status: "ok" }))
}

/// The control plane is normally bound to a private address. Keep this small
/// scrape surface dependency-free until a dedicated observability exporter is
/// introduced.
async fn metrics() -> String {
    "# HELP control_plane_up Whether the control plane process is running\n# TYPE control_plane_up gauge\ncontrol_plane_up 1\n".to_owned()
}

async fn bootstrap_admin(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<BootstrapAdminRequest>,
) -> Result<impl IntoResponse, ApiError> {
    require_bootstrap_token(&headers, &state.bootstrap_token)?;
    let admin = NewAdmin {
        email: request.email,
        display_name: request.display_name,
        password: request.password,
    };
    admin
        .validate()
        .map_err(|error| ApiError::bad_request(error.to_string()))?;
    if has_users(&state.database)
        .await
        .map_err(ApiError::database)?
    {
        return Err(ApiError::conflict("bootstrap has already completed"));
    }
    let password_hash = hash_password(&admin.password).map_err(|_| ApiError::internal())?;
    let user = create_initial_admin(
        &state.database,
        &admin.email,
        &admin.display_name,
        &password_hash,
    )
    .await
    .map_err(ApiError::database)?
    .ok_or_else(|| ApiError::conflict("bootstrap has already completed"))?;
    Ok((
        StatusCode::CREATED,
        Json(BootstrapAdminResponse {
            id: user.id.to_string(),
            email: user.email,
            display_name: user.display_name,
        }),
    ))
}

fn require_bootstrap_token(headers: &HeaderMap, expected: &str) -> Result<(), ApiError> {
    let value = headers
        .get(AUTHORIZATION)
        .and_then(|header| header.to_str().ok());
    let valid = value
        .and_then(|header| header.strip_prefix("Bearer "))
        .is_some_and(|token| token == expected);
    if valid {
        Ok(())
    } else {
        Err(ApiError::unauthorized())
    }
}

/// Cookie-authenticated state changes must originate from the same portal
/// origin. Device enrollment and heartbeat routes use signed device proofs,
/// not portal cookies, and intentionally do not pass through this check.
fn require_same_origin(headers: &HeaderMap) -> Result<(), ApiError> {
    let origin = headers.get("origin").and_then(|value| value.to_str().ok());
    let host = headers.get("host").and_then(|value| value.to_str().ok());
    let valid = origin.zip(host).is_some_and(|(origin, host)| {
        origin == format!("https://{host}") || origin == format!("http://{host}")
    });
    if valid {
        Ok(())
    } else {
        Err(ApiError::forbidden())
    }
}

async fn add_security_headers(
    request: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let mut response = next.run(request).await;
    response.headers_mut().insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    response
        .headers_mut()
        .insert("x-frame-options", HeaderValue::from_static("DENY"));
    response.headers_mut().insert(
        "referrer-policy",
        HeaderValue::from_static("strict-origin-when-cross-origin"),
    );
    response.headers_mut().insert(
        "permissions-policy",
        HeaderValue::from_static("camera=(), microphone=(), geolocation=()"),
    );
    response
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn bad_request(message: String) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message,
        }
    }
    fn unauthorized() -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            message: "unauthorized".into(),
        }
    }
    fn mfa_required() -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            message: "multi-factor authentication code is required".into(),
        }
    }
    fn mfa_unavailable() -> Self {
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            message: "multi-factor authentication is not configured".into(),
        }
    }
    fn too_many_requests() -> Self {
        Self {
            status: StatusCode::TOO_MANY_REQUESTS,
            message: "too many login attempts".into(),
        }
    }
    fn conflict(message: &str) -> Self {
        Self {
            status: StatusCode::CONFLICT,
            message: message.into(),
        }
    }
    fn forbidden() -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            message: "forbidden".into(),
        }
    }
    fn not_found() -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            message: "not found".into(),
        }
    }
    fn service_unavailable() -> Self {
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            message: "device credential issuer is not configured".into(),
        }
    }
    fn database(error: control_plane_db::DatabaseError) -> Self {
        if matches!(error, control_plane_db::DatabaseError::ActiveRustDeskId) {
            return Self::conflict(
                "an active device already uses this RustDesk ID; revoke it before re-enrolling",
            );
        }
        error!(error = ?error, "control plane database operation failed");
        Self::internal()
    }
    fn internal() -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: "internal server error".into(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        (
            self.status,
            Json(serde_json::json!({"error": self.message})),
        )
            .into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn totp_secrets_are_encrypted_and_codes_verify() {
        let key = [9_u8; 32];
        let secret = Secret::generate_secret().to_bytes().unwrap();
        let encrypted = encrypt_totp_secret(&key, &secret).unwrap();
        assert!(!encrypted.contains(&hex::encode(&secret)));

        let (nonce, ciphertext) = encrypted.split_once(':').unwrap();
        let nonce = hex::decode(nonce).unwrap();
        let ciphertext = hex::decode(ciphertext).unwrap();
        let nonce: [u8; 12] = nonce.as_slice().try_into().unwrap();
        let cipher = Aes256Gcm::new_from_slice(&key).unwrap();
        let restored = cipher
            .decrypt(Nonce::from_slice(&nonce), ciphertext.as_ref())
            .unwrap();
        let totp = new_totp(restored, "admin@example.test").unwrap();
        let code = totp.generate_current().unwrap();
        assert!(valid_totp_code(&totp, &code));
    }

    #[test]
    fn node_agent_routes_require_the_proxy_mtls_marker() {
        let node_id = uuid::Uuid::new_v4();
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-node-agent-id",
            HeaderValue::from_str(&node_id.to_string()).unwrap(),
        );
        assert!(require_mtls_node(&headers).is_err());
        headers.insert("x-mtls-verified", HeaderValue::from_static("false"));
        assert!(require_mtls_node(&headers).is_err());
        headers.insert("x-mtls-verified", HeaderValue::from_static("true"));
        assert_eq!(require_mtls_node(&headers).unwrap(), node_id);
    }
}
