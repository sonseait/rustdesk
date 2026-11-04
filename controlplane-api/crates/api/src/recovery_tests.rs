use super::*;
use ed25519_dalek::{Signer, SigningKey, Verifier};
use tower::ServiceExt;
use uuid::Uuid;

#[path = "../../db/tests/support/mod.rs"]
mod support;

fn proof(id: Uuid, purpose: &str) -> serde_json::Value {
    let key = SigningKey::from_bytes(&[3;32]);
    let timestamp = Utc::now().timestamp(); let nonce = Uuid::new_v4().to_string();
    let payload = managed_claim::device_proof(&id.to_string(),timestamp,&nonce,purpose,&serde_json::Value::Null);
    serde_json::json!({"proof_version":2,"timestamp":timestamp,"nonce":nonce,"metadata":null,
        "signature":hex::encode(key.sign(payload.as_bytes()).to_bytes())})
}

async fn request(router: Router, path: &str, body: serde_json::Value) -> (StatusCode,serde_json::Value) {
    let response = router.oneshot(axum::http::Request::builder().method("POST").uri(path)
        .header("content-type","application/json").body(axum::body::Body::from(body.to_string())).unwrap()).await.unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(),65536).await.unwrap();
    (status,serde_json::from_slice(&bytes).unwrap_or_default())
}

#[test]
fn recovery_proof_is_purpose_separated_without_legacy_fallback() {
    let id = Uuid::new_v4(); let key = hex::encode(SigningKey::from_bytes(&[3;32]).verifying_key().as_bytes());
    let request: Heartbeat = serde_json::from_value(proof(id,"device-recovery")).unwrap();
    assert!(validate_recovery_proof(id,&request,&key).is_ok());
    for purpose in ["heartbeat","credential-renew"] {
        let wrong = serde_json::from_value(proof(id,purpose)).unwrap();
        assert_eq!(validate_recovery_proof(id,&wrong,&key).unwrap_err().code,"invalid_device_proof");
    }
    let mut legacy = request;
    legacy.proof_version = 1;
    legacy.signature = hex::encode(SigningKey::from_bytes(&[3;32]).sign(format!("{id}:{}:{}",legacy.timestamp,legacy.nonce).as_bytes()).to_bytes());
    assert!(validate_recovery_proof(id,&legacy,&key).is_err());
}

#[tokio::test]
async fn recovery_route_rejects_legacy_and_stale_requests_before_db() {
    let id = Uuid::new_v4(); let path = format!("/v1/devices/{id}/recovery");
    for mode in ["legacy","stale","nonce"] {
        let mut body = proof(id,"device-recovery");
        match mode {
            "legacy" => body["proof_version"] = 1.into(),
            "stale" => body["timestamp"] = (Utc::now().timestamp()-301).into(),
            _ => body["nonce"] = "invalid".into(),
        }
        let (status,body) = request(managed_routes().with_state(tests::test_state()),&path,body).await;
        assert_eq!(status,StatusCode::UNAUTHORIZED);
        assert_eq!(body["code"],if mode == "stale" { "clock_skew" } else { "invalid_device_proof" });
    }
}

#[tokio::test]
async fn restore_route_requires_same_origin_and_admin() {
    let router = Router::new().route("/v1/devices/:id/restore",post(restore_managed_device)).with_state(tests::test_state());
    let path = format!("/v1/devices/{}/restore",Uuid::new_v4());
    let response = router.clone().oneshot(axum::http::Request::builder().method("POST").uri(&path)
        .header("host","portal.test").header("origin","https://attacker.test")
        .body(axum::body::Body::empty()).unwrap()).await.unwrap();
    assert_eq!(response.status(),StatusCode::FORBIDDEN);
    let response = router.oneshot(axum::http::Request::builder().method("POST").uri(&path)
        .header("host","portal.test").header("origin","https://portal.test")
        .body(axum::body::Body::empty()).unwrap()).await.unwrap();
    assert_eq!(response.status(),StatusCode::UNAUTHORIZED);
}

#[tokio::test]
#[ignore = "requires explicit disposable MANAGED_TEST_DATABASE_URL; never production"]
async fn recovery_route_requires_restore_valid_proof_and_fresh_nonce() {
    support::isolated(|db| async move {
        let key = SigningKey::from_bytes(&[3;32]);
        let id = Uuid::new_v4();
        let fingerprint = { use sha2::Digest; hex::encode(sha2::Sha256::digest(key.verifying_key().as_bytes())) };
        sqlx::query("INSERT INTO devices (id,display_name,hostname,operating_system,client_version,public_key_fingerprint,public_key,rustdesk_id,revoked_at) VALUES ($1,'Test','test','test','test',$2,$3,'123456789',NOW())")
            .bind(id).bind(&fingerprint).bind(hex::encode(key.verifying_key().as_bytes())).execute(&db).await.unwrap();
        let actor = control_plane_db::create_initial_admin(&db,"admin@example.test","Admin","synthetic").await.unwrap().unwrap().id;
        let mut state = tests::test_state(); state.database = db.clone();
        let router = managed_routes().with_state(state);
        let path = format!("/v1/devices/{id}/recovery");
        let body = proof(id,"device-recovery");
        let (status,error) = request(router.clone(),&path,body.clone()).await;
        assert_eq!(status,StatusCode::UNAUTHORIZED); assert_eq!(error["code"],"device_revoked");
        control_plane_db::restore_device(&db,actor,id).await.unwrap();
        for purpose in ["heartbeat","credential-renew"] {
            let (status,error) = request(router.clone(),&path,proof(id,purpose)).await;
            assert_eq!(status,StatusCode::UNAUTHORIZED); assert_eq!(error["code"],"invalid_device_proof");
        }
        let mut tampered = proof(id,"device-recovery"); tampered["signature"] = "00".repeat(64).into();
        assert_eq!(request(router.clone(),&path,tampered).await.0,StatusCode::UNAUTHORIZED);
        let consumed: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM device_heartbeat_nonces WHERE device_id=$1")
            .bind(id).fetch_one(&db).await.unwrap();
        assert_eq!(consumed,0,"revoked/invalid proofs must not consume any nonce");
        let (status,response) = request(router.clone(),&path,body.clone()).await;
        assert_eq!(status,StatusCode::OK);
        let signed: managed_claim::SignedRecovery<SignedDeviceCredential,SignedDevicePolicy> = serde_json::from_value(response).unwrap();
        assert_eq!(signed.claims.purpose,"device-recovery"); assert_eq!(signed.claims.nonce,body["nonce"]);
        assert_eq!(signed.claims.timestamp,body["timestamp"].as_i64().unwrap());
        assert_eq!(signed.claims.device_id,id.to_string());
        assert_eq!(signed.claims.credential.claims.device_id,id); assert_eq!(signed.claims.policy.claims.device_id,id);
        assert_eq!(signed.claims.credential.claims.public_key_fingerprint,fingerprint);
        let issuer = SigningKey::from_bytes(&[9;32]).verifying_key();
        for (payload,signature) in [
            (serde_json::to_vec(&signed.claims).unwrap(),signed.signature),
            (serde_json::to_vec(&signed.claims.credential.claims).unwrap(),signed.claims.credential.signature),
            (serde_json::to_vec(&signed.claims.policy.claims).unwrap(),signed.claims.policy.signature),
        ] {
            issuer.verify(&payload,&ed25519_dalek::Signature::from_slice(&hex::decode(signature).unwrap()).unwrap()).unwrap();
        }
        assert_eq!(request(router.clone(),&path,body).await.0,StatusCode::CONFLICT);
        control_plane_db::revoke_device(&db,actor,id).await.unwrap();
        let (status,error) = request(router,&path,proof(id,"device-recovery")).await;
        assert_eq!(status,StatusCode::UNAUTHORIZED); assert_eq!(error["code"],"device_revoked");
    }).await;
}
