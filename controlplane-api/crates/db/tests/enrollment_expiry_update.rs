mod support;
use chrono::{Duration, Utc};
use control_plane_db::{create_enrollment_token, update_enrollment_token_expiry, list_enrollment_tokens, revoke_enrollment_token};
use uuid::Uuid;

#[tokio::test]
#[ignore = "requires explicit disposable MANAGED_TEST_DATABASE_URL; never production"]
async fn edits_expiry_without_changing_token_or_restoring_revoked_tokens() {
    support::isolated(|db| async move {
        let actor = control_plane_db::create_initial_admin(&db,"admin@example.test","Admin","synthetic").await.unwrap().unwrap().id;
        let token = create_enrollment_token(&db, actor, "synthetic-expiry-update", "Test", 3, Some(Utc::now() - Duration::days(1))).await.unwrap();
        let future = Utc::now() + Duration::days(365);
        assert!(update_enrollment_token_expiry(&db, actor, token.id, Some(future)).await.unwrap());
        assert!(list_enrollment_tokens(&db).await.unwrap()[0].expires_at.unwrap() > Utc::now());
        assert!(update_enrollment_token_expiry(&db, actor, token.id, None).await.unwrap());
        let row = &list_enrollment_tokens(&db).await.unwrap()[0];
        assert_eq!(row.expires_at, None);
        assert_eq!(row.max_enrollments, 3);
        assert_eq!(row.enrollment_count, 0);
        let hash: String = sqlx::query_scalar("SELECT token_hash FROM enrollment_tokens WHERE id=$1").bind(token.id).fetch_one(&db).await.unwrap();
        assert_eq!(hash, "synthetic-expiry-update");
        let audits: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_events WHERE action='enrollment_token_expiry_updated'").fetch_one(&db).await.unwrap();
        assert_eq!(audits, 2);
        assert!(!update_enrollment_token_expiry(&db, actor, Uuid::new_v4(), None).await.unwrap());
        revoke_enrollment_token(&db, actor, token.id).await.unwrap();
        assert!(!update_enrollment_token_expiry(&db, actor, token.id, Some(future)).await.unwrap());
    }).await;
}
