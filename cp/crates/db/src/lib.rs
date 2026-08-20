use chrono::{DateTime, Utc};
use control_plane_domain::{
    AnonymousRemotePolicy, AuditEvent, CurrentServerConfig, Device, DeviceHeartbeatMetadata,
    EnrollmentToken, RemoteSession, Role, ServerNode, UpdateCurrentServerConfig, User, UserSummary,
};
use serde_json::json;
use sqlx::{postgres::PgPoolOptions, PgPool, Row};
use thiserror::Error;
use uuid::Uuid;

pub type Database = PgPool;

#[derive(Debug, Clone)]
pub struct UserWithPassword {
    pub user: User,
    pub password_hash: String,
    pub totp_secret_encrypted: Option<String>,
    pub totp_confirmed_at: Option<DateTime<Utc>>,
    pub totp_last_counter: Option<i64>,
}

#[derive(Debug, Error)]
pub enum DatabaseError {
    #[error("database query failed")]
    Query(#[from] sqlx::Error),
    #[error("database migration failed")]
    Migration(#[from] sqlx::migrate::MigrateError),
}

pub async fn connect(database_url: &str) -> Result<Database, DatabaseError> {
    PgPoolOptions::new()
        .max_connections(10)
        .connect(database_url)
        .await
        .map_err(DatabaseError::Query)
}

pub async fn migrate(database: &Database) -> Result<(), DatabaseError> {
    sqlx::migrate!("../../migrations").run(database).await?;
    Ok(())
}

pub async fn has_users(database: &Database) -> Result<bool, DatabaseError> {
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
        .fetch_one(database)
        .await?;
    Ok(count > 0)
}

pub async fn find_active_user_by_email(
    database: &Database,
    email: &str,
) -> Result<Option<UserWithPassword>, DatabaseError> {
    let row = sqlx::query(
        "SELECT id, email, display_name, password_hash, created_at, totp_secret_encrypted, totp_confirmed_at, totp_last_counter \
         FROM users WHERE email = $1 AND disabled_at IS NULL",
    )
    .bind(email.trim().to_ascii_lowercase())
    .fetch_optional(database)
    .await?;
    Ok(row.map(|row| UserWithPassword {
        user: User {
            id: row.get("id"),
            email: row.get("email"),
            display_name: row.get("display_name"),
            created_at: row.get("created_at"),
        },
        password_hash: row.get("password_hash"),
        totp_secret_encrypted: row.get("totp_secret_encrypted"),
        totp_confirmed_at: row.get("totp_confirmed_at"),
        totp_last_counter: row.get("totp_last_counter"),
    }))
}

pub async fn set_totp_secret(
    database: &Database,
    user_id: Uuid,
    encrypted_secret: &str,
) -> Result<(), DatabaseError> {
    sqlx::query("UPDATE users SET totp_secret_encrypted = $2, totp_confirmed_at = NULL, totp_last_counter = NULL WHERE id = $1")
        .bind(user_id).bind(encrypted_secret).execute(database).await?;
    Ok(())
}

pub async fn confirm_totp(database: &Database, user_id: Uuid) -> Result<(), DatabaseError> {
    sqlx::query("UPDATE users SET totp_confirmed_at = NOW(), totp_last_counter = NULL WHERE id = $1 AND totp_secret_encrypted IS NOT NULL")
        .bind(user_id).execute(database).await?;
    Ok(())
}

/// Advances the accepted moving counter atomically, rejecting a reused TOTP.
pub async fn consume_totp_counter(
    database: &Database,
    user_id: Uuid,
    counter: i64,
) -> Result<bool, DatabaseError> {
    let changed = sqlx::query("UPDATE users SET totp_last_counter = $2 WHERE id = $1 AND (totp_last_counter IS NULL OR totp_last_counter < $2)")
        .bind(user_id).bind(counter).execute(database).await?.rows_affected() == 1;
    Ok(changed)
}

pub async fn record_user_audit_event(
    database: &Database,
    actor_user_id: Uuid,
    action: &str,
    detail: serde_json::Value,
) -> Result<(), DatabaseError> {
    sqlx::query("INSERT INTO audit_events (id, actor_user_id, action, target_type, target_id, detail) VALUES ($1, $2, $3, 'user', $2, $4)")
        .bind(Uuid::new_v4()).bind(actor_user_id).bind(action).bind(detail).execute(database).await?;
    Ok(())
}

pub async fn create_session(
    database: &Database,
    user_id: Uuid,
    token_hash: &str,
    expires_at: DateTime<Utc>,
) -> Result<(), DatabaseError> {
    sqlx::query(
        "INSERT INTO sessions (id, user_id, token_hash, expires_at) VALUES ($1, $2, $3, $4)",
    )
    .bind(Uuid::new_v4())
    .bind(user_id)
    .bind(token_hash)
    .bind(expires_at)
    .execute(database)
    .await?;
    Ok(())
}

/// Records a control-plane authorization before its signed ticket is returned.
/// Data-plane transition reporting can later move this row to connected/ended.
pub async fn record_remote_session_authorized(
    database: &Database,
    ticket_id: Uuid,
    source_device_id: Uuid,
    target_device_id: Uuid,
    permission: &str,
    expires_at: DateTime<Utc>,
) -> Result<(), DatabaseError> {
    let mut transaction = database.begin().await?;
    sqlx::query(
        "INSERT INTO remote_sessions (id, ticket_id, source_device_id, target_device_id, permission, status, expires_at) \
         VALUES ($1, $2, $3, $4, $5, 'authorized', $6)",
    )
    .bind(Uuid::new_v4())
    .bind(ticket_id)
    .bind(source_device_id)
    .bind(target_device_id)
    .bind(permission)
    .bind(expires_at)
    .execute(&mut *transaction)
    .await?;
    sqlx::query(
        "INSERT INTO audit_events (id, action, target_type, target_id, detail) \
         VALUES ($1, 'remote_session_authorized', 'remote_session', $2, $3)",
    )
    .bind(Uuid::new_v4())
    .bind(ticket_id.to_string())
    .bind(json!({"source_device_id": source_device_id, "target_device_id": target_device_id, "permission": permission, "expires_at": expires_at}))
    .execute(&mut *transaction)
    .await?;
    transaction.commit().await?;
    Ok(())
}

pub async fn list_remote_sessions(
    database: &Database,
) -> Result<Vec<RemoteSession>, DatabaseError> {
    let rows = sqlx::query("SELECT id, ticket_id, source_device_id, target_device_id, permission, status, authorized_at, expires_at FROM remote_sessions ORDER BY authorized_at DESC LIMIT 500")
        .fetch_all(database).await?;
    Ok(rows
        .into_iter()
        .map(|row| RemoteSession {
            id: row.get("id"),
            ticket_id: row.get("ticket_id"),
            source_device_id: row.get("source_device_id"),
            target_device_id: row.get("target_device_id"),
            permission: row.get("permission"),
            status: row.get("status"),
            authorized_at: row.get("authorized_at"),
            expires_at: row.get("expires_at"),
        })
        .collect())
}

pub async fn list_server_nodes(database: &Database) -> Result<Vec<ServerNode>, DatabaseError> {
    let rows = sqlx::query("SELECT id, name, endpoint, status, health, last_seen_at, created_at FROM server_nodes ORDER BY name")
        .fetch_all(database).await?;
    Ok(rows
        .into_iter()
        .map(|row| ServerNode {
            id: row.get("id"),
            name: row.get("name"),
            endpoint: row.get("endpoint"),
            status: row.get("status"),
            health: row.get("health"),
            last_seen_at: row.get("last_seen_at"),
            created_at: row.get("created_at"),
        })
        .collect())
}

pub async fn report_server_node_health(
    database: &Database,
    node_id: Uuid,
    health: &serde_json::Value,
) -> Result<(), DatabaseError> {
    let status = health
        .get("healthy")
        .and_then(|value| value.as_bool())
        .unwrap_or(false)
        .then_some("healthy")
        .unwrap_or("unhealthy");
    sqlx::query("INSERT INTO server_nodes (id, name, endpoint, status, health, last_seen_at) VALUES ($1, $2, '', $3, $4, NOW()) ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status, health = EXCLUDED.health, last_seen_at = NOW()")
        .bind(node_id).bind(node_id.to_string()).bind(status).bind(health).execute(database).await?;
    Ok(())
}

pub async fn user_for_session(
    database: &Database,
    token_hash: &str,
) -> Result<Option<User>, DatabaseError> {
    let row = sqlx::query(
        "SELECT u.id, u.email, u.display_name, u.created_at \
         FROM sessions s JOIN users u ON u.id = s.user_id \
         WHERE s.token_hash = $1 AND s.revoked_at IS NULL AND s.expires_at > NOW() \
         AND u.disabled_at IS NULL",
    )
    .bind(token_hash)
    .fetch_optional(database)
    .await?;
    Ok(row.map(|row| User {
        id: row.get("id"),
        email: row.get("email"),
        display_name: row.get("display_name"),
        created_at: row.get("created_at"),
    }))
}

pub async fn revoke_session(database: &Database, token_hash: &str) -> Result<(), DatabaseError> {
    sqlx::query(
        "UPDATE sessions SET revoked_at = NOW() WHERE token_hash = $1 AND revoked_at IS NULL",
    )
    .bind(token_hash)
    .execute(database)
    .await?;
    Ok(())
}

pub async fn is_admin(database: &Database, user_id: Uuid) -> Result<bool, DatabaseError> {
    sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id \
         WHERE ur.user_id = $1 AND r.name = 'admin')",
    )
    .bind(user_id)
    .fetch_one(database)
    .await
    .map_err(DatabaseError::Query)
}

pub async fn get_server_policy(
    database: &Database,
) -> Result<AnonymousRemotePolicy, DatabaseError> {
    let row = sqlx::query(
        "SELECT anonymous_remote_enabled, anonymous_max_session_minutes, anonymous_max_concurrent_devices, \
         anonymous_max_devices_per_window, anonymous_window_minutes FROM server_policy WHERE singleton = TRUE",
    )
    .fetch_one(database)
    .await?;
    Ok(AnonymousRemotePolicy {
        enabled: row.get("anonymous_remote_enabled"),
        max_session_minutes: row.get("anonymous_max_session_minutes"),
        max_concurrent_devices: row.get("anonymous_max_concurrent_devices"),
        max_devices_per_window: row.get("anonymous_max_devices_per_window"),
        window_minutes: row.get("anonymous_window_minutes"),
    })
}

pub async fn update_server_policy(
    database: &Database,
    actor_user_id: Uuid,
    policy: &AnonymousRemotePolicy,
) -> Result<(), DatabaseError> {
    let mut transaction = database.begin().await?;
    sqlx::query(
        "UPDATE server_policy SET anonymous_remote_enabled = $1, anonymous_max_session_minutes = $2, \
         anonymous_max_concurrent_devices = $3, anonymous_max_devices_per_window = $4, \
         anonymous_window_minutes = $5, updated_by_user_id = $6, updated_at = NOW() WHERE singleton = TRUE",
    )
    .bind(policy.enabled)
    .bind(policy.max_session_minutes)
    .bind(policy.max_concurrent_devices)
    .bind(policy.max_devices_per_window)
    .bind(policy.window_minutes)
    .bind(actor_user_id)
    .execute(&mut *transaction)
    .await?;
    sqlx::query(
        "INSERT INTO audit_events (id, actor_user_id, action, target_type, target_id, detail) \
         VALUES ($1, $2, 'server_policy_updated', 'server_policy', 'current', $3)",
    )
    .bind(Uuid::new_v4())
    .bind(actor_user_id)
    .bind(json!({"anonymous_remote": policy}))
    .execute(&mut *transaction)
    .await?;
    transaction.commit().await?;
    Ok(())
}

pub async fn current_server_config(
    database: &Database,
) -> Result<CurrentServerConfig, DatabaseError> {
    let row = sqlx::query("SELECT revision, managed_mode, credential_issuer_public_key, updated_at FROM current_server_desired_config WHERE singleton = TRUE")
        .fetch_one(database).await?;
    Ok(CurrentServerConfig {
        revision: row.get("revision"),
        managed_mode: row.get("managed_mode"),
        credential_issuer_public_key: row.get("credential_issuer_public_key"),
        updated_at: row.get("updated_at"),
    })
}

pub async fn update_current_server_config(
    database: &Database,
    actor_user_id: Uuid,
    config: &UpdateCurrentServerConfig,
) -> Result<CurrentServerConfig, DatabaseError> {
    let mut transaction = database.begin().await?;
    let row = sqlx::query("UPDATE current_server_desired_config SET revision = revision + 1, managed_mode = $1, credential_issuer_public_key = $2, updated_by_user_id = $3, updated_at = NOW() WHERE singleton = TRUE RETURNING revision, managed_mode, credential_issuer_public_key, updated_at")
        .bind(&config.managed_mode).bind(&config.credential_issuer_public_key).bind(actor_user_id).fetch_one(&mut *transaction).await?;
    let updated = CurrentServerConfig {
        revision: row.get("revision"),
        managed_mode: row.get("managed_mode"),
        credential_issuer_public_key: row.get("credential_issuer_public_key"),
        updated_at: row.get("updated_at"),
    };
    sqlx::query("INSERT INTO audit_events (id, actor_user_id, action, target_type, target_id, detail) VALUES ($1, $2, 'current_server_config_updated', 'current_server', 'current', $3)")
        .bind(Uuid::new_v4()).bind(actor_user_id).bind(json!({"revision": updated.revision, "managed_mode": updated.managed_mode})).execute(&mut *transaction).await?;
    transaction.commit().await?;
    Ok(updated)
}

pub async fn list_users(database: &Database) -> Result<Vec<UserSummary>, DatabaseError> {
    let rows = sqlx::query(
        "SELECT u.id, u.email, u.display_name, u.created_at, \
         COALESCE(array_agg(r.name) FILTER (WHERE r.name IS NOT NULL), '{}') AS roles \
         FROM users u LEFT JOIN user_roles ur ON ur.user_id = u.id \
         LEFT JOIN roles r ON r.id = ur.role_id GROUP BY u.id ORDER BY u.created_at ASC",
    )
    .fetch_all(database)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| UserSummary {
            user: User {
                id: row.get("id"),
                email: row.get("email"),
                display_name: row.get("display_name"),
                created_at: row.get("created_at"),
            },
            roles: row.get("roles"),
        })
        .collect())
}

pub async fn list_roles(database: &Database) -> Result<Vec<Role>, DatabaseError> {
    let rows = sqlx::query("SELECT name, description FROM roles ORDER BY name")
        .fetch_all(database)
        .await?;
    Ok(rows
        .into_iter()
        .map(|row| Role {
            name: row.get("name"),
            description: row.get("description"),
        })
        .collect())
}

pub async fn list_audit_events(database: &Database) -> Result<Vec<AuditEvent>, DatabaseError> {
    let rows = sqlx::query(
        "SELECT a.id, a.action, a.target_type, a.target_id, u.email AS actor_email, a.created_at \
         FROM audit_events a LEFT JOIN users u ON u.id = a.actor_user_id ORDER BY a.created_at DESC LIMIT 100",
    )
    .fetch_all(database)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| AuditEvent {
            id: row.get("id"),
            action: row.get("action"),
            target_type: row.get("target_type"),
            target_id: row.get("target_id"),
            actor_email: row.get("actor_email"),
            created_at: row.get("created_at"),
        })
        .collect())
}

pub async fn create_enrollment_token(
    database: &Database,
    actor_user_id: Uuid,
    token_hash: &str,
    label: &str,
    max_enrollments: i32,
    expires_at: DateTime<Utc>,
) -> Result<EnrollmentToken, DatabaseError> {
    let id = Uuid::new_v4();
    let mut transaction = database.begin().await?;
    let row = sqlx::query(
        "INSERT INTO enrollment_tokens (id, token_hash, label, max_enrollments, expires_at, created_by_user_id) \
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING enrollment_count, revoked_at",
    ).bind(id).bind(token_hash).bind(label.trim()).bind(max_enrollments).bind(expires_at).bind(actor_user_id)
        .fetch_one(&mut *transaction).await?;
    sqlx::query(
        "INSERT INTO audit_events (id, actor_user_id, action, target_type, target_id, detail) \
         VALUES ($1, $2, 'enrollment_token_created', 'enrollment_token', $3, $4)",
    ).bind(Uuid::new_v4()).bind(actor_user_id).bind(id.to_string())
        .bind(json!({"label": label.trim(), "max_enrollments": max_enrollments, "expires_at": expires_at})).execute(&mut *transaction).await?;
    transaction.commit().await?;
    Ok(EnrollmentToken {
        id,
        label: label.trim().to_owned(),
        max_enrollments,
        enrollment_count: row.get("enrollment_count"),
        expires_at,
        revoked_at: row.get("revoked_at"),
    })
}

pub async fn list_enrollment_tokens(
    database: &Database,
) -> Result<Vec<EnrollmentToken>, DatabaseError> {
    let rows = sqlx::query("SELECT id, label, max_enrollments, enrollment_count, expires_at, revoked_at FROM enrollment_tokens ORDER BY created_at DESC")
        .fetch_all(database).await?;
    Ok(rows
        .into_iter()
        .map(|row| EnrollmentToken {
            id: row.get("id"),
            label: row.get("label"),
            max_enrollments: row.get("max_enrollments"),
            enrollment_count: row.get("enrollment_count"),
            expires_at: row.get("expires_at"),
            revoked_at: row.get("revoked_at"),
        })
        .collect())
}

pub async fn revoke_enrollment_token(
    database: &Database,
    actor_user_id: Uuid,
    token_id: Uuid,
) -> Result<bool, DatabaseError> {
    let mut transaction = database.begin().await?;
    let changed = sqlx::query(
        "UPDATE enrollment_tokens SET revoked_at = NOW() WHERE id = $1 AND revoked_at IS NULL",
    )
    .bind(token_id)
    .execute(&mut *transaction)
    .await?
    .rows_affected()
        > 0;
    if changed {
        sqlx::query("INSERT INTO audit_events (id, actor_user_id, action, target_type, target_id) VALUES ($1, $2, 'enrollment_token_revoked', 'enrollment_token', $3)")
        .bind(Uuid::new_v4()).bind(actor_user_id).bind(token_id.to_string()).execute(&mut *transaction).await?;
    }
    transaction.commit().await?;
    Ok(changed)
}

pub async fn list_devices(database: &Database) -> Result<Vec<Device>, DatabaseError> {
    let rows = sqlx::query("SELECT id, rustdesk_id, display_name, hostname, operating_system, client_version, enrolled_at, last_seen_at, last_capabilities, last_health, revoked_at FROM devices ORDER BY enrolled_at DESC")
        .fetch_all(database).await?;
    Ok(rows
        .into_iter()
        .map(|row| Device {
            id: row.get("id"),
            rustdesk_id: row.get("rustdesk_id"),
            display_name: row.get("display_name"),
            hostname: row.get("hostname"),
            operating_system: row.get("operating_system"),
            client_version: row.get("client_version"),
            enrolled_at: row.get("enrolled_at"),
            last_seen_at: row.get("last_seen_at"),
            last_capabilities: row.get("last_capabilities"),
            last_health: row.get("last_health"),
            revoked_at: row.get("revoked_at"),
        })
        .collect())
}

pub async fn revoke_device(
    database: &Database,
    actor_user_id: Uuid,
    device_id: Uuid,
) -> Result<bool, DatabaseError> {
    let mut transaction = database.begin().await?;
    let changed =
        sqlx::query("UPDATE devices SET revoked_at = NOW() WHERE id = $1 AND revoked_at IS NULL")
            .bind(device_id)
            .execute(&mut *transaction)
            .await?
            .rows_affected()
            > 0;
    if changed {
        sqlx::query("INSERT INTO audit_events (id, actor_user_id, action, target_type, target_id) VALUES ($1, $2, 'device_revoked', 'device', $3)")
        .bind(Uuid::new_v4()).bind(actor_user_id).bind(device_id.to_string()).execute(&mut *transaction).await?;
    }
    transaction.commit().await?;
    Ok(changed)
}

pub async fn claim_enrollment(
    database: &Database,
    token_hash: &str,
    display_name: &str,
    hostname: &str,
    operating_system: &str,
    client_version: &str,
    public_key_fingerprint: &str,
    public_key: &str,
    rustdesk_id: &str,
) -> Result<Option<Device>, DatabaseError> {
    let mut transaction = database.begin().await?;
    let token_id: Option<Uuid> = sqlx::query_scalar(
        "SELECT id FROM enrollment_tokens WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > NOW() AND enrollment_count < max_enrollments FOR UPDATE",
    ).bind(token_hash).fetch_optional(&mut *transaction).await?;
    let Some(token_id) = token_id else {
        transaction.rollback().await?;
        return Ok(None);
    };
    let id = Uuid::new_v4();
    let row = sqlx::query(
        "INSERT INTO devices (id, rustdesk_id, display_name, hostname, operating_system, client_version, public_key_fingerprint, public_key, enrollment_token_id) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING enrolled_at, last_seen_at, revoked_at",
    ).bind(id).bind(rustdesk_id.trim()).bind(display_name.trim()).bind(hostname.trim()).bind(operating_system.trim()).bind(client_version.trim()).bind(public_key_fingerprint.trim()).bind(public_key.trim()).bind(token_id)
        .fetch_one(&mut *transaction).await?;
    sqlx::query(
        "UPDATE enrollment_tokens SET enrollment_count = enrollment_count + 1 WHERE id = $1",
    )
    .bind(token_id)
    .execute(&mut *transaction)
    .await?;
    sqlx::query("INSERT INTO audit_events (id, action, target_type, target_id, detail) VALUES ($1, 'device_enrolled', 'device', $2, $3)")
        .bind(Uuid::new_v4()).bind(id.to_string()).bind(json!({"hostname": hostname.trim(), "operating_system": operating_system.trim()})).execute(&mut *transaction).await?;
    transaction.commit().await?;
    Ok(Some(Device {
        id,
        rustdesk_id: rustdesk_id.trim().to_owned(),
        display_name: display_name.trim().to_owned(),
        hostname: hostname.trim().to_owned(),
        operating_system: operating_system.trim().to_owned(),
        client_version: client_version.trim().to_owned(),
        enrolled_at: row.get("enrolled_at"),
        last_seen_at: row.get("last_seen_at"),
        last_capabilities: json!([]),
        last_health: json!({}),
        revoked_at: row.get("revoked_at"),
    }))
}

pub async fn device_public_key(
    database: &Database,
    device_id: Uuid,
) -> Result<Option<String>, DatabaseError> {
    sqlx::query_scalar("SELECT public_key FROM devices WHERE id = $1 AND revoked_at IS NULL")
        .bind(device_id)
        .fetch_optional(database)
        .await
        .map_err(DatabaseError::Query)
}

/// Returns the immutable device identity material for proof-of-possession
/// requests. Revoked devices are deliberately excluded.
pub async fn device_credential_subject(
    database: &Database,
    device_id: Uuid,
) -> Result<Option<(String, String, String)>, DatabaseError> {
    let row = sqlx::query(
        "SELECT public_key, public_key_fingerprint, rustdesk_id FROM devices \
         WHERE id = $1 AND revoked_at IS NULL",
    )
    .bind(device_id)
    .fetch_optional(database)
    .await?;
    Ok(row.map(|row| {
        (
            row.get("public_key"),
            row.get("public_key_fingerprint"),
            row.get("rustdesk_id"),
        )
    }))
}

pub async fn active_device_exists(
    database: &Database,
    device_id: Uuid,
) -> Result<bool, DatabaseError> {
    sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM devices WHERE id = $1 AND revoked_at IS NULL)")
        .bind(device_id)
        .fetch_one(database)
        .await
        .map_err(DatabaseError::Query)
}

pub async fn active_device_id_for_rustdesk_id(
    database: &Database,
    rustdesk_id: &str,
) -> Result<Option<Uuid>, DatabaseError> {
    sqlx::query_scalar("SELECT id FROM devices WHERE rustdesk_id = $1 AND revoked_at IS NULL")
        .bind(rustdesk_id.trim())
        .fetch_optional(database)
        .await
        .map_err(DatabaseError::Query)
}

pub async fn accept_heartbeat(
    database: &Database,
    device_id: Uuid,
    nonce: Uuid,
    metadata: Option<&DeviceHeartbeatMetadata>,
) -> Result<bool, DatabaseError> {
    let mut transaction = database.begin().await?;
    let accepted = sqlx::query("INSERT INTO device_heartbeat_nonces (nonce, device_id) VALUES ($1, $2) ON CONFLICT DO NOTHING")
        .bind(nonce).bind(device_id).execute(&mut *transaction).await?.rows_affected() == 1;
    if !accepted {
        transaction.rollback().await?;
        return Ok(false);
    }
    if let Some(metadata) = metadata {
        sqlx::query("UPDATE devices SET last_seen_at = NOW(), hostname = COALESCE(NULLIF($2, ''), hostname), operating_system = COALESCE(NULLIF($3, ''), operating_system), client_version = COALESCE(NULLIF($4, ''), client_version), last_capabilities = $5, last_health = $6 WHERE id = $1")
            .bind(device_id).bind(&metadata.hostname).bind(&metadata.operating_system).bind(&metadata.client_version).bind(serde_json::to_value(&metadata.capabilities).unwrap_or_else(|_| json!([]))).bind(&metadata.health).execute(&mut *transaction).await?;
    } else {
        sqlx::query("UPDATE devices SET last_seen_at = NOW() WHERE id = $1")
            .bind(device_id)
            .execute(&mut *transaction)
            .await?;
    }
    transaction.commit().await?;
    Ok(true)
}

pub async fn create_initial_admin(
    database: &Database,
    email: &str,
    display_name: &str,
    password_hash: &str,
) -> Result<Option<User>, DatabaseError> {
    let mut transaction = database.begin().await?;
    // Lock the table so concurrent first-start requests cannot create two admins.
    sqlx::query("LOCK TABLE users IN EXCLUSIVE MODE")
        .execute(&mut *transaction)
        .await?;

    let already_bootstrapped: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM users)")
        .fetch_one(&mut *transaction)
        .await?;
    if already_bootstrapped {
        transaction.rollback().await?;
        return Ok(None);
    }

    let admin_role_id = Uuid::new_v4();
    let user_id = Uuid::new_v4();
    let row = sqlx::query(
        "INSERT INTO users (id, email, password_hash, display_name) \
         VALUES ($1, $2, $3, $4) \
         RETURNING id, email, display_name, created_at",
    )
    .bind(user_id)
    .bind(email.trim().to_ascii_lowercase())
    .bind(password_hash)
    .bind(display_name.trim())
    .fetch_one(&mut *transaction)
    .await?;

    sqlx::query(
        "INSERT INTO roles (id, name, description) VALUES ($1, 'admin', 'Platform administrator')",
    )
    .bind(admin_role_id)
    .execute(&mut *transaction)
    .await?;
    sqlx::query("INSERT INTO user_roles (user_id, role_id) VALUES ($1, $2)")
        .bind(user_id)
        .bind(admin_role_id)
        .execute(&mut *transaction)
        .await?;
    sqlx::query(
        "INSERT INTO audit_events (id, actor_user_id, action, target_type, target_id, detail) \
         VALUES ($1, $2, 'bootstrap_admin_created', 'user', $3, $4)",
    )
    .bind(Uuid::new_v4())
    .bind(user_id)
    .bind(user_id.to_string())
    .bind(json!({"email": email.trim().to_ascii_lowercase()}))
    .execute(&mut *transaction)
    .await?;
    transaction.commit().await?;

    Ok(Some(User {
        id: row.get("id"),
        email: row.get("email"),
        display_name: row.get("display_name"),
        created_at: row.get::<DateTime<Utc>, _>("created_at"),
    }))
}
