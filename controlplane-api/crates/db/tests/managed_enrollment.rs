mod support;
use control_plane_db::{claim_enrollment_v2, Database, DatabaseError};
use control_plane_domain::EnrollmentClaim;
use uuid::Uuid;

fn claim() -> EnrollmentClaim {
    EnrollmentClaim { token: "synthetic-only-token-not-for-deployment".into(), display_name: "Test".into(),
        hostname: "test".into(), operating_system: "test".into(), client_version: "test".into(),
        public_key_fingerprint: Uuid::new_v4().to_string(), public_key: "synthetic".into(), rustdesk_id: Uuid::new_v4().to_string() }
}
async fn token(db: &Database, hash: &str) {
    sqlx::query("INSERT INTO enrollment_tokens (id,token_hash,label,max_enrollments,expires_at) VALUES ($1,$2,'synthetic',1,NOW() + INTERVAL '1 hour')")
        .bind(Uuid::new_v4()).bind(hash).execute(db).await.unwrap();
}

#[tokio::test]
#[ignore = "requires explicit disposable MANAGED_TEST_DATABASE_URL; never production"]
async fn claim_retry_returns_same_device() {
    support::isolated(|db| async move {
        token(&db, "synthetic-hash").await;
        let request = Uuid::new_v4(); let claim = claim();
        let first = claim_enrollment_v2(&db, request, "binding", "synthetic-hash", &claim).await.unwrap();
        // Simulates a committed response being lost, followed by expiry/exhaustion.
        sqlx::query("UPDATE enrollment_tokens SET expires_at = NOW() - INTERVAL '1 hour'").execute(&db).await.unwrap();
        let retry = claim_enrollment_v2(&db, request, "binding", "synthetic-hash", &claim).await.unwrap();
        assert_eq!(first.id, retry.id);
        let count: i32 = sqlx::query_scalar("SELECT enrollment_count FROM enrollment_tokens").fetch_one(&db).await.unwrap();
        assert_eq!(count, 1);
        assert!(matches!(claim_enrollment_v2(&db, request, "changed-key-binding", "synthetic-hash", &claim).await, Err(DatabaseError::Managed("identity_conflict"))));
        sqlx::query("UPDATE devices SET revoked_at = NOW()").execute(&db).await.unwrap();
        assert!(matches!(claim_enrollment_v2(&db, request, "binding", "synthetic-hash", &claim).await, Err(DatabaseError::Managed("device_revoked"))));
    }).await;
}

#[tokio::test]
#[ignore = "requires explicit disposable MANAGED_TEST_DATABASE_URL; never production"]
async fn concurrent_claim_consumes_token_once() {
    support::isolated(|db| async move {
        token(&db, "synthetic-hash").await;
        let request = Uuid::new_v4(); let claim = claim();
        let (a,b) = tokio::join!(claim_enrollment_v2(&db, request, "binding", "synthetic-hash", &claim),
            claim_enrollment_v2(&db, request, "binding", "synthetic-hash", &claim));
        assert_eq!(a.unwrap().id, b.unwrap().id);
        let count: i32 = sqlx::query_scalar("SELECT enrollment_count FROM enrollment_tokens").fetch_one(&db).await.unwrap();
        assert_eq!(count, 1);
        sqlx::query("UPDATE enrollment_tokens SET revoked_at = NOW()").execute(&db).await.unwrap();
        assert!(matches!(claim_enrollment_v2(&db, request, "binding", "synthetic-hash", &claim).await, Err(DatabaseError::Managed("provisioning_invalid"))));
    }).await;
}

#[tokio::test]
#[ignore = "requires explicit disposable MANAGED_TEST_DATABASE_URL; never production"]
async fn different_tokens_same_rustdesk_id_is_conflict() {
    support::isolated(|db| async move {
        token(&db, "a").await; token(&db, "b").await;
        let mut claim = claim();
        claim_enrollment_v2(&db, Uuid::new_v4(), "binding-a", "a", &claim).await.unwrap();
        claim.public_key_fingerprint = Uuid::new_v4().to_string();
        assert!(matches!(claim_enrollment_v2(&db, Uuid::new_v4(), "binding-b", "b", &claim).await, Err(DatabaseError::Managed("identity_conflict"))));
    }).await;
}

#[tokio::test]
#[ignore = "requires explicit disposable MANAGED_TEST_DATABASE_URL; never production"]
async fn restore_is_transactional_audited_idempotent_and_recovery_is_fenced() {
    use control_plane_db::{accept_device_recovery, accept_heartbeat, restore_device, revoke_device};
    support::isolated(|db| async move {
        token(&db,"restore").await;
        let device = claim_enrollment_v2(&db,Uuid::new_v4(),"restore","restore",&claim()).await.unwrap();
        let actor = control_plane_db::create_initial_admin(&db,"admin@example.test","Admin","synthetic-hash").await.unwrap().unwrap().id;
        let nonce = Uuid::new_v4();
        assert!(accept_device_recovery(&db,device.id,nonce).await.is_err(),"never restored");
        assert!(revoke_device(&db,actor,device.id).await.unwrap());
        assert!(matches!(accept_heartbeat(&db,device.id,nonce,None).await,Err(DatabaseError::Managed("device_revoked"))));
        assert!(accept_device_recovery(&db,device.id,nonce).await.is_err());
        // A failed audit insert must roll back restore.
        assert!(restore_device(&db,Uuid::new_v4(),device.id).await.is_err());
        assert!(control_plane_db::device_identity(&db,device.id).await.unwrap().unwrap().3);
        assert!(restore_device(&db,actor,device.id).await.unwrap());
        assert!(restore_device(&db,actor,device.id).await.unwrap());
        assert!(!restore_device(&db,actor,Uuid::new_v4()).await.unwrap());
        let audits: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_events WHERE action='device_restored' AND actor_user_id=$1 AND target_id=$2")
            .bind(actor).bind(device.id.to_string()).fetch_one(&db).await.unwrap();
        assert_eq!(audits,1);
        assert!(accept_device_recovery(&db,device.id,nonce).await.unwrap().is_some());
        assert!(accept_device_recovery(&db,device.id,nonce).await.unwrap().is_none());
        assert!(revoke_device(&db,actor,device.id).await.unwrap());
        assert!(accept_device_recovery(&db,device.id,Uuid::new_v4()).await.is_err());
    }).await;
}

#[tokio::test]
#[ignore = "requires explicit disposable MANAGED_TEST_DATABASE_URL; never production"]
async fn restore_collision_keeps_revoke_and_has_no_audit() {
    support::isolated(|db| async move {
        token(&db,"old").await; token(&db,"new").await;
        let old_claim = claim();
        let old = claim_enrollment_v2(&db,Uuid::new_v4(),"old","old",&old_claim).await.unwrap();
        let actor = control_plane_db::create_initial_admin(&db,"admin@example.test","Admin","synthetic").await.unwrap().unwrap().id;
        control_plane_db::revoke_device(&db,actor,old.id).await.unwrap();
        let mut replacement = claim(); replacement.rustdesk_id = old_claim.rustdesk_id;
        claim_enrollment_v2(&db,Uuid::new_v4(),"new","new",&replacement).await.unwrap();
        assert!(matches!(control_plane_db::restore_device(&db,actor,old.id).await,Err(DatabaseError::ActiveRustDeskId)));
        assert!(control_plane_db::device_identity(&db,old.id).await.unwrap().unwrap().3);
        let audits: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_events WHERE action='device_restored'").fetch_one(&db).await.unwrap();
        assert_eq!(audits,0);
    }).await;
}

#[tokio::test]
#[ignore = "requires explicit disposable MANAGED_TEST_DATABASE_URL; never production"]
async fn nonce_acceptance_serializes_with_inflight_revoke() {
    support::isolated(|db| async move {
        token(&db,"race").await;
        let device = claim_enrollment_v2(&db,Uuid::new_v4(),"race","race",&claim()).await.unwrap();
        let actor = control_plane_db::create_initial_admin(&db,"admin@example.test","Admin","synthetic").await.unwrap().unwrap().id;
        control_plane_db::revoke_device(&db,actor,device.id).await.unwrap();
        control_plane_db::restore_device(&db,actor,device.id).await.unwrap();
        let mut tx = db.begin().await.unwrap();
        sqlx::query("UPDATE devices SET revoked_at=NOW(),access_restored_at=NULL WHERE id=$1")
            .bind(device.id).execute(&mut *tx).await.unwrap();
        let heartbeat_db = db.clone(); let recovery_db = db.clone(); let id = device.id;
        let heartbeat = tokio::spawn(async move { control_plane_db::accept_heartbeat(&heartbeat_db,id,Uuid::new_v4(),None).await });
        let recovery = tokio::spawn(async move { control_plane_db::accept_device_recovery(&recovery_db,id,Uuid::new_v4()).await });
        tokio::task::yield_now().await;
        tx.commit().await.unwrap();
        assert!(matches!(heartbeat.await.unwrap(),Err(DatabaseError::Managed("device_revoked"))));
        assert!(matches!(recovery.await.unwrap(),Err(DatabaseError::Managed("device_revoked"))));
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM device_heartbeat_nonces WHERE device_id=$1")
            .bind(id).fetch_one(&db).await.unwrap();
        assert_eq!(count,0);
    }).await;
}
