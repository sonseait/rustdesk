use super::*;
use ed25519_dalek::Signer;
use std::{cell::RefCell, rc::Rc};
static SERIAL: Mutex<()> = Mutex::new(());
fn reset() -> std::sync::MutexGuard<'static, ()> {
    let serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    *state().lock().unwrap() = ManagedState::default();
    store::MEMORY.with(|m| *m.borrow_mut() = Default::default());
    TEST_OPTIONS.with(|o| o.borrow_mut().clear()); TEST_NOW.with(|n| n.set(None));
    #[cfg(feature = "managed-only")]
    set_local_option(CONTROL_PLANE_URL_KEY.into(), managed_bootstrap::CP_URL.into());
    #[cfg(not(feature = "managed-only"))]
    set_local_option(CONTROL_PLANE_URL_KEY.into(), "http://127.0.0.1:18080".into());
    transport::HANDLER.with(|h| *h.borrow_mut() = Some(Box::new(|_,_| panic!("unexpected HTTP"))));
    serial
}
fn identity() -> ManagedState {
    let key = SigningKey::from_bytes(&[3;32]);
    ManagedState { loaded:true, generation:1, device_id:uuid::Uuid::from_u128(42).to_string(),
        public_key_fingerprint:hex::encode(Sha256::digest(key.verifying_key().as_bytes())),
        signing_key:Some(key), config_validated:true, ..Default::default() }
}
fn signed<T: Serialize>(claims: T) -> serde_json::Value {
    let key = SigningKey::from_bytes(&[9;32]);
    let signature = hex::encode(key.sign(&serde_json::to_vec(&claims).unwrap()).to_bytes());
    serde_json::json!({"claims":claims,"signature":signature,"issuer_public_key":hex::encode(key.verifying_key().as_bytes())})
}
fn credential(state: &ManagedState) -> serde_json::Value {
    signed(DeviceCredentialClaims { version:1, device_id:state.device_id.parse().unwrap(),
        rustdesk_id:"123456789".into(), public_key_fingerprint:state.public_key_fingerprint.clone(),
        issued_at:utc_now(), expires_at:utc_now()+chrono::Duration::hours(24) })
}
fn policy(state: &ManagedState) -> serde_json::Value {
    signed(DevicePolicyClaims { version:1, device_id:state.device_id.parse().unwrap(), revision:1,
        expires_at:utc_now()+chrono::Duration::hours(4), capabilities:vec!["remote-control".into()] })
}

fn revoked_identity() -> ManagedState {
    TEST_NOW.with(|n| n.set(Some(Utc::now())));
    let mut initial = identity();
    initial.issuer_public_key = hex::encode(SigningKey::from_bytes(&[9;32]).verifying_key().as_bytes());
    *state().lock().unwrap() = initial;
    response_error(transport::Failure { status:401, code:"device_revoked".into() },1);
    restored_snapshot()
}

fn recovery(subject: &ManagedState, request: &serde_json::Value) -> serde_json::Value {
    signed(managed_claim::RecoveryClaims {
        version:1, purpose:"device-recovery".into(), device_id:subject.device_id.clone(),
        nonce:request["nonce"].as_str().unwrap().into(), timestamp:request["timestamp"].as_i64().unwrap(),
        issued_at:utc_now().timestamp(), expires_at:utc_now().timestamp()+60,
        credential:serde_json::from_value::<SignedDeviceCredential>(credential(subject)).unwrap(),
        policy:serde_json::from_value::<SignedDevicePolicy>(policy(subject)).unwrap(),
    })
}

#[test]
fn legacy_revocation_without_identity_requires_admin_reprovisioning() {
    let _serial = reset();
    set_local_option(REVOKED_KEY.into(), "Y".into());
    let snapshot = status();
    assert_eq!(snapshot.state, "revoked");
    assert_eq!(snapshot.last_error, "recovery_identity_missing");
    assert!(!snapshot.ready);
    assert_eq!(reconcile(&mut lifecycle::Schedule::default(), 0).unwrap_err(), "recovery_identity_missing");
    assert_eq!(enroll("synthetic-token".into(), "test".into()).unwrap_err(), "device_revoked");
    assert!(store::load().unwrap().is_none());
    assert_eq!(local_option(REVOKED_KEY), "Y");
}

#[test]
fn revoked_executor_only_polls_recovery_and_survives_restart() {
    let _serial = reset(); revoked_identity();
    transport::HANDLER.with(|h| *h.borrow_mut() = Some(Box::new(|url, body| {
        assert!(url.ends_with("/recovery")); assert_eq!(body["proof_version"],2);
        Err(transport::Failure{status:401,code:"device_revoked".into()})
    })));
    assert_eq!(reconcile(&mut lifecycle::Schedule::default(),0).unwrap_err(),"device_revoked");
    *state().lock().unwrap() = ManagedState::default();
    assert!(restored_snapshot().revoked); assert!(!status().ready);
    assert_eq!(renew_credential().unwrap_err(),"device_revoked");
    assert_eq!(sync_policy().unwrap_err(),"device_revoked");
    assert_eq!(heartbeat().unwrap_err(),"device_revoked");
}

#[test]
fn restored_recovery_persists_both_before_clearing_tombstone_and_resumes() {
    let _serial = reset(); let initial = revoked_identity(); let subject = initial.clone();
    transport::HANDLER.with(|h| *h.borrow_mut() = Some(Box::new(move |url,body| {
        assert!(state().try_lock().is_ok());
        if url.ends_with("/recovery") { Ok(recovery(&subject,body)) }
        else if url.ends_with("/heartbeat") { Ok(serde_json::Value::Null) }
        else if url.ends_with("/managed/config") { Ok(signed(DeploymentConfigClaims{version:1,revision:1,
            rendezvous_server:"test-hbbs:21116".into(),relay_server:"test-hbbr:21117".into(),
            server_public_key:"synthetic-server-key".into(),issued_at:utc_now()})) }
        else { panic!("unexpected request {url}") }
    })));
    let mut schedule = lifecycle::Schedule::default(); schedule.config_at = u64::MAX; schedule.policy_at = u64::MAX;
    reconcile(&mut schedule,0).unwrap();
    assert!(!restored_snapshot().revoked); assert!(local_option(REVOKED_KEY).is_empty());
    let durable: StoredCredential = serde_json::from_str(&store::load().unwrap().unwrap()).unwrap();
    assert!(!durable.revoked); assert!(durable.credential.is_some()); assert!(durable.policy.is_some());
    assert_eq!(durable.signing_key,hex::encode(initial.signing_key.unwrap().to_bytes()));
    *state().lock().unwrap() = ManagedState::default();
    assert!(!restored_snapshot().revoked); assert!(restored_snapshot().credential.is_some());
}

#[test]
fn recovery_failures_keep_durable_tombstone() {
    let _serial = reset();
    for failure in ["proof", "signature", "policy", "binding", "nonce", "timestamp", "stale", "purpose", "credential", "persistence", "generation"] {
        let initial = revoked_identity(); let subject = initial.clone(); let mode = failure.to_owned();
        transport::HANDLER.with(|h| *h.borrow_mut() = Some(Box::new(move |_,body| {
            if mode == "proof" { return Err(transport::Failure{status:401,code:"invalid_device_proof".into()}); }
            let mut response = recovery(&subject,body);
            match mode.as_str() {
                "signature" => response["signature"] = "00".repeat(64).into(),
                "policy" | "binding" | "nonce" | "timestamp" | "stale" | "purpose" | "credential" => {
                    let mut claims = response["claims"].clone();
                    match mode.as_str() {
                        "policy" => claims["policy"]["signature"] = "00".repeat(64).into(),
                        "binding" => claims["credential"]["claims"]["rustdesk_id"] = "wrong".into(),
                        "nonce" => claims["nonce"] = uuid::Uuid::new_v4().to_string().into(),
                        "timestamp" => claims["timestamp"] = (utc_now().timestamp()-1).into(),
                        "stale" => claims["expires_at"] = (utc_now().timestamp()-1).into(),
                        "purpose" => claims["purpose"] = "credential-renew".into(),
                        _ => claims["credential"]["signature"] = "00".repeat(64).into(),
                    }
                    response = signed(claims);
                }
                "persistence" => store::MEMORY.with(|m| m.borrow_mut().fail_write = true),
                "generation" => { let generation = restored_snapshot().generation;
                    response_error(transport::Failure{status:401,code:"device_revoked".into()},generation); },
                _ => unreachable!(),
            }
            Ok(response)
        })));
        assert!(reconcile(&mut lifecycle::Schedule::default(),0).is_err(),"{failure}");
        assert!(restored_snapshot().revoked,"{failure}"); assert_eq!(local_option(REVOKED_KEY),"Y");
        store::MEMORY.with(|m| m.borrow_mut().fail_write = false);
        *state().lock().unwrap() = ManagedState::default();
        assert!(restored_snapshot().revoked,"restart: {failure}");
        if failure == "generation" { assert_eq!(restored_snapshot().generation,initial.generation+1); }
    }
}

#[test]
fn recovery_response_replay_after_failed_write_and_restart_is_rejected() {
    let _serial = reset(); let initial = revoked_identity();
    let cached = Rc::new(RefCell::new(None)); let capture = cached.clone();
    transport::HANDLER.with(|h| *h.borrow_mut() = Some(Box::new(move |url,body| {
        assert!(url.ends_with("/recovery"));
        let response = recovery(&initial,body); *capture.borrow_mut() = Some(response.clone());
        store::MEMORY.with(|m| m.borrow_mut().fail_write = true);
        Ok(response)
    })));
    assert_eq!(reconcile(&mut lifecycle::Schedule::default(),0).unwrap_err(),"credential_store_unavailable");
    store::MEMORY.with(|m| m.borrow_mut().fail_write = false);
    *state().lock().unwrap() = ManagedState::default();
    let response = cached.borrow().clone().unwrap();
    transport::HANDLER.with(|h| *h.borrow_mut() = Some(Box::new(move |_,body| {
        assert_ne!(body["nonce"],response["claims"]["nonce"]); Ok(response.clone())
    })));
    assert_eq!(reconcile(&mut lifecycle::Schedule::default(),1).unwrap_err(),"invalid_recovery_response");
    assert!(restored_snapshot().revoked); assert!(!status().ready);
}
#[test]
fn pending_is_durable_before_claim_and_response_loss_recovers_same_identity() {
    let _serial = reset(); let seen = Rc::new(RefCell::new(Vec::new())); let capture = seen.clone();
    transport::HANDLER.with(|h| *h.borrow_mut() = Some(Box::new(move |url, body| {
        assert!(url.ends_with("/v1/enrollment/claim-v2"));
        assert!(state().try_lock().is_ok(), "HTTP must not hold the status mutex");
        let durable: StoredCredential = serde_json::from_str(&store::load().unwrap().unwrap()).unwrap();
        let claim: managed_claim::EnrollmentV2 = serde_json::from_value(body.clone()).unwrap();
        assert_eq!(durable.pending_claim.as_ref().unwrap().request_id, claim.request_id);
        assert!(durable.pending_claim.as_ref().unwrap().token.is_empty());
        let key: [u8;32] = hex::decode(&durable.signing_key).unwrap().try_into().unwrap();
        assert_eq!(hex::encode(SigningKey::from_bytes(&key).verifying_key().as_bytes()), claim.public_key);
        claim.verify(utc_now().timestamp()).unwrap();
        capture.borrow_mut().push((claim.request_id, claim.public_key));
        if capture.borrow().len() == 1 { Err(transport::Failure {status:0, code:"temporarily_unavailable".into()}) }
        else { Ok(serde_json::json!({"id":uuid::Uuid::from_u128(42)})) }
    })));
    let token = "synthetic-only-token-not-for-deployment".to_owned();
    assert_eq!(enroll(token.clone(), "Test device".into()).unwrap_err(), "temporarily_unavailable");
    *state().lock().unwrap() = ManagedState::default();
    enroll(token, "Changed UI name must not alter pending request".into()).unwrap();
    assert_eq!(seen.borrow().len(), 2); assert_eq!(seen.borrow()[0], seen.borrow()[1]);
    assert_eq!(restored_snapshot().device_id, uuid::Uuid::from_u128(42).to_string());
}
#[test]
fn failed_initial_write_sends_no_claim() {
    let _serial = reset(); store::MEMORY.with(|m| m.borrow_mut().fail_write = true);
    assert_eq!(enroll("synthetic-only-token-not-for-deployment".into(), "Test".into()).unwrap_err(), "credential_store_unavailable");
    assert!(restored_snapshot().signing_key.is_none());
}
#[test]
fn failed_write_does_not_publish_ready() {
    let _serial = reset(); let initial = identity(); let response = credential(&initial);
    *state().lock().unwrap() = initial; store::MEMORY.with(|m| m.borrow_mut().fail_write = true);
    transport::HANDLER.with(|h| *h.borrow_mut() = Some(Box::new(move |_,_| Ok(response.clone()))));
    assert_eq!(renew_credential().unwrap_err(), "credential_store_unavailable");
    assert!(restored_snapshot().credential.is_none()); assert!(!status().ready);
}
#[test]
fn stale_generation_result_is_discarded() {
    let _serial = reset(); let initial = identity(); let response = credential(&initial);
    *state().lock().unwrap() = initial;
    transport::HANDLER.with(|h| *h.borrow_mut() = Some(Box::new(move |_,_| {
        state().lock().unwrap().generation += 1; Ok(response.clone())
    })));
    assert_eq!(renew_credential().unwrap_err(), "stale_generation"); assert!(restored_snapshot().credential.is_none());
}
#[test]
fn unknown_401_preserves_key_and_revoked_survives_restart() {
    let _serial = reset(); let initial = identity();
    persist_credential(&initial, &local_option(CONTROL_PLANE_URL_KEY)).unwrap(); *state().lock().unwrap() = initial;
    assert_eq!(response_error(transport::Failure {status:401, code:String::new()},1), "authorization_rejected");
    assert!(restored_snapshot().signing_key.is_some()); assert!(!restored_snapshot().revoked);
    assert_eq!(response_error(transport::Failure {status:401, code:"device_revoked".into()},1), "device_revoked");
    set_local_option(REVOKED_KEY.into(), String::new()); *state().lock().unwrap() = ManagedState::default();
    assert!(restored_snapshot().revoked);
    assert_eq!(enroll("synthetic-only-token-not-for-deployment".into(), "Test".into()).unwrap_err(), "device_revoked");
}
#[test]
fn automatic_reconciliation_runs_beyond_both_expirations_without_ui() {
    let _serial = reset(); let now = Utc::now(); TEST_NOW.with(|n| n.set(Some(now)));
    let initial = identity(); *state().lock().unwrap() = initial.clone();
    let calls = Rc::new(RefCell::new(Vec::new())); let capture = calls.clone();
    transport::HANDLER.with(|h| *h.borrow_mut() = Some(Box::new(move |url,_| {
        assert!(state().try_lock().is_ok()); capture.borrow_mut().push(url.to_owned());
        if url.ends_with("/credential/renew") { Ok(credential(&initial)) }
        else if url.ends_with("/device-policy") { Ok(policy(&initial)) }
        else if url.ends_with("/heartbeat") { Ok(serde_json::Value::Null) }
        else { panic!("unexpected URL {url}") }
    })));
    let mut schedule = lifecycle::Schedule::default(); schedule.config_at = u64::MAX;
    reconcile(&mut schedule,0).unwrap(); assert!(status().ready);
    TEST_NOW.with(|n| n.set(Some(now+chrono::Duration::hours(5))));
    assert!(!policy_allows(&restored_snapshot(),"remote-control"));
    reconcile(&mut schedule,5*3600).unwrap(); assert!(status().ready);
    TEST_NOW.with(|n| n.set(Some(now+chrono::Duration::hours(25)))); assert!(!status().ready);
    reconcile(&mut schedule,25*3600).unwrap(); assert!(status().ready);
    assert_eq!(calls.borrow().iter().filter(|u| u.ends_with("/credential/renew")).count(),2);
}

#[test]
fn parallel_targets_get_distinct_tickets() {
    let _serial = reset(); let mut initial = identity();
    initial.credential = Some(serde_json::from_value(credential(&initial)).unwrap());
    initial.policy = Some(serde_json::from_value(policy(&initial)).unwrap());
    initial.issuer_public_key = hex::encode(SigningKey::from_bytes(&[9;32]).verifying_key().as_bytes());
    *state().lock().unwrap() = initial.clone();
    let handles: Vec<_> = [("111111111",1u128),("222222222",2u128)].into_iter().map(|(target,id)| {
        let source = initial.device_id.clone();
        std::thread::spawn(move || {
            set_local_option(CONTROL_PLANE_URL_KEY.into(), "http://127.0.0.1:18080".into());
            transport::HANDLER.with(|h| *h.borrow_mut() = Some(Box::new(move |_,body| {
                assert_eq!(body["target_rustdesk_id"], target);
                Ok(signed(SessionTicketClaims {version:1,ticket_id:uuid::Uuid::new_v4(),source_device_id:source.parse().unwrap(),
                    target_device_id:uuid::Uuid::from_u128(id), expires_at:utc_now()+chrono::Duration::minutes(5),permissions:vec!["remote-control".into()]}))
            })));
            request_session_ticket_for_rustdesk_id(target.into()).unwrap();
        })
    }).collect();
    for handle in handles { handle.join().unwrap(); }
    let a = session_ticket_for("111111111").unwrap(); let b = session_ticket_for("222222222").unwrap();
    let a: SessionTicketClaims = serde_json::from_slice(&a.claims).unwrap();
    let b: SessionTicketClaims = serde_json::from_slice(&b.claims).unwrap();
    assert_ne!(a.target_device_id,b.target_device_id); assert_ne!(a.ticket_id,b.ticket_id);
}

#[test]
fn snapshot_contains_no_secret_fields() {
    let snapshot = serde_json::to_value(status_of(&identity(),false)).unwrap();
    for field in ["signing_key","credential","policy","token","signature","session_tickets","pending_claim"] {
        assert!(snapshot.get(field).is_none(), "secret-bearing field {field}");
    }
}

#[test]
fn second_owner_cannot_start_worker() {
    let owner = std::sync::atomic::AtomicBool::new(false);
    assert!(claim_worker(&owner)); assert!(!claim_worker(&owner));
}

#[cfg(feature = "managed-only")]
#[test]
fn gui_attach_does_not_enroll_and_owner_unavailable_is_not_ready() {
    let _serial = reset();
    let snapshot: serde_json::Value = serde_json::from_str(&snapshot_json()).unwrap();
    assert_eq!(snapshot["ready"],false); assert_eq!(snapshot["last_error"],"owner_unavailable");
    assert!(!state().lock().unwrap().loaded);
}

#[cfg(feature = "managed-only")]
#[test]
fn offline_startup_automatically_claims_renews_and_syncs_then_detects_revoke_despite_config_failure() {
    let _serial = reset();
    let offline = Rc::new(std::cell::Cell::new(true)); let fail_config = Rc::new(std::cell::Cell::new(false));
    let network = offline.clone(); let config = fail_config.clone();
    let request_ids = Rc::new(RefCell::new(Vec::new())); let seen = request_ids.clone();
    transport::HANDLER.with(|h| *h.borrow_mut() = Some(Box::new(move |url, body| {
        assert!(state().try_lock().is_ok());
        if url.ends_with("/enrollment/claim-v2") {
            seen.borrow_mut().push(body["request_id"].clone());
            if network.get() { return Err(transport::Failure{status:0,code:"temporarily_unavailable".into()}); }
            return Ok(serde_json::json!({"id":uuid::Uuid::from_u128(42)}));
        }
        let mut subject = identity();
        // A fresh install generated a real isolated key, rather than identity()'s fixture key.
        subject.public_key_fingerprint = state().lock().unwrap().public_key_fingerprint.clone();
        if url.ends_with("/credential/renew") { Ok(credential(&subject)) }
        else if url.ends_with("/device-policy") { Ok(policy(&subject)) }
        else if url.ends_with("/managed/config") {
            if config.get() { return Err(transport::Failure{status:503,code:"temporarily_unavailable".into()}); }
            Ok(signed(DeploymentConfigClaims{version:1,revision:1,rendezvous_server:"test-hbbs:21116".into(),
                relay_server:"test-hbbr:21117".into(),server_public_key:"synthetic-server-key".into(),issued_at:utc_now()}))
        } else if url.ends_with("/heartbeat") {
            if config.get() { Err(transport::Failure{status:401,code:"device_revoked".into()}) }
            else { Ok(serde_json::Value::Null) }
        } else { panic!("unexpected URL {url}") }
    })));
    let mut schedule = lifecycle::Schedule::default();
    assert_eq!(reconcile(&mut schedule,0).unwrap_err(),"temporarily_unavailable");
    assert!(!status().ready);
    offline.set(false);
    reconcile(&mut schedule,2).unwrap(); assert!(status().ready);
    assert_eq!(request_ids.borrow().len(),2); assert_eq!(request_ids.borrow()[0],request_ids.borrow()[1]);
    assert_eq!(local_option("mediator-restarts"),"1");
    // Unchanged signed config refresh does not restart the mediator.
    reconcile(&mut schedule,302).unwrap(); assert_eq!(local_option("mediator-restarts"),"1");
    fail_config.set(true);
    assert_eq!(reconcile(&mut schedule,602).unwrap_err(),"device_revoked");
    assert_eq!(status().state,"revoked"); assert!(!status().ready);
    assert_eq!(request_ids.borrow().len(),2);
}

#[test]
fn failed_tombstone_write_is_retried_without_claiming() {
    let _serial = reset(); let initial = identity();
    persist_credential(&initial,&local_option(CONTROL_PLANE_URL_KEY)).unwrap(); *state().lock().unwrap() = initial;
    store::MEMORY.with(|m| m.borrow_mut().fail_write = true);
    response_error(transport::Failure{status:401,code:"device_revoked".into()},1);
    assert!(restored_snapshot().revoked);
    store::MEMORY.with(|m| m.borrow_mut().fail_write = false);
    transport::HANDLER.with(|h| *h.borrow_mut() = Some(Box::new(|url,_| {
        assert!(url.ends_with("/recovery"));
        Err(transport::Failure{status:401,code:"device_revoked".into()})
    })));
    assert_eq!(reconcile(&mut lifecycle::Schedule::default(),1).unwrap_err(),"device_revoked");
    set_local_option(REVOKED_KEY.into(),String::new()); *state().lock().unwrap() = ManagedState::default();
    assert!(restored_snapshot().revoked);
}

#[test]
fn legacy_record_restores_without_reenrollment() {
    let _serial = reset(); let legacy = identity();
    let raw = serde_json::json!({"device_id":legacy.device_id,"control_plane_url":local_option(CONTROL_PLANE_URL_KEY),
        "public_key_fingerprint":legacy.public_key_fingerprint,
        "signing_key":hex::encode(legacy.signing_key.as_ref().unwrap().to_bytes())});
    store::save(&raw.to_string()).unwrap();
    let restored = restored_snapshot();
    assert_eq!(restored.device_id,legacy.device_id); assert_eq!(restored.generation,0);
    assert!(restored.signing_key.is_some());
    bootstrap_managed_only().unwrap(); // The installed identity must not claim again.
}

#[cfg(not(feature = "managed-only"))]
#[test]
fn configure_rejects_loopback_prefix_spoof_and_embedded_credentials() {
    let _serial = reset();
    assert!(configure("http://localhost.attacker.test".into()).is_err());
    assert!(configure("http://127.0.0.1.attacker.test".into()).is_err());
    assert!(configure("https://synthetic-user:synthetic-password@example.test".into()).is_err());
    assert!(configure("http://127.0.0.1:18080/api".into()).is_ok());
}
