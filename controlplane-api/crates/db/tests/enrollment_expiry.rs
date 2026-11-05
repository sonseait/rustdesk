mod support;
use chrono::{Duration, Utc};
use control_plane_db::{claim_enrollment, claim_enrollment_v2, create_enrollment_token, list_enrollment_tokens, revoke_enrollment_token};
use control_plane_domain::EnrollmentClaim;
use uuid::Uuid;

#[tokio::test]
#[ignore = "requires explicit disposable MANAGED_TEST_DATABASE_URL; never production"]
async fn optional_expiry_roundtrips_and_both_claim_paths_enforce_limits() {
    support::isolated(|db| async move {
        let actor = control_plane_db::create_initial_admin(&db,"admin@example.test","Admin","synthetic").await.unwrap().unwrap().id;
        for expiry in [None, Some(Utc::now() + Duration::days(365)), Some(Utc::now() - Duration::minutes(1))] {
            let hash = Uuid::new_v4().to_string();
            let token = create_enrollment_token(&db, actor, &hash, "Test", 2, expiry).await.unwrap();
            assert_eq!(token.expires_at, expiry);
            assert_eq!(list_enrollment_tokens(&db).await.unwrap().iter().find(|t| t.id == token.id).unwrap().expires_at.is_none(), expiry.is_none());
            let claim = EnrollmentClaim { token: "synthetic".into(), display_name: "Test".into(), hostname: "test".into(), operating_system: "test".into(), client_version: "test".into(), public_key_fingerprint: Uuid::new_v4().to_string(), public_key: "synthetic".into(), rustdesk_id: Uuid::new_v4().to_string() };
            let legacy = claim_enrollment(&db, &hash, "Test", "test", "test", "test", &Uuid::new_v4().to_string(), "synthetic", &Uuid::new_v4().to_string()).await.unwrap();
            let managed = claim_enrollment_v2(&db, Uuid::new_v4(), "binding", &hash, &claim).await;
            if expiry.is_some_and(|expiry| expiry <= Utc::now()) {
                assert!(legacy.is_none());
                assert!(managed.is_err());
            } else {
                assert!(legacy.is_some());
                assert!(managed.is_ok());
                assert!(claim_enrollment_v2(&db, Uuid::new_v4(), "binding", &hash, &claim).await.is_err(), "usage limit still applies");
            }
            assert!(revoke_enrollment_token(&db, actor, token.id).await.unwrap());
            assert!(claim_enrollment_v2(&db, Uuid::new_v4(), "binding", &hash, &claim).await.is_err());
        }
    }).await;
}
