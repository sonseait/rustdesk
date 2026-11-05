use chrono::{Duration, Utc};
use control_plane_domain::{NewEnrollmentToken, UpdateEnrollmentTokenExpiry};
use serde_json::json;

#[test]
fn update_requires_explicit_expiry_and_rejects_past_dates() {
    assert!(serde_json::from_value::<UpdateEnrollmentTokenExpiry>(json!({})).is_err());
    assert!(serde_json::from_value::<UpdateEnrollmentTokenExpiry>(json!({"expires_at": null, "label": "changed"})).is_err());
    for expires_at in [json!(null), json!((Utc::now() + Duration::days(1)).to_rfc3339())] {
        assert!(serde_json::from_value::<UpdateEnrollmentTokenExpiry>(json!({"expires_at": expires_at})).unwrap().validate().is_ok());
    }
    assert!(serde_json::from_value::<UpdateEnrollmentTokenExpiry>(json!({"expires_at": (Utc::now() - Duration::minutes(1)).to_rfc3339()})).unwrap().validate().is_err());
}

#[test]
fn enrollment_accepts_year_exact_and_no_expiry() {
    for expiry in [json!({"expires_in_hours": 8760}), json!({"expires_at": (Utc::now() + Duration::minutes(10)).to_rfc3339()}), json!({"expires_at": null})] {
        let mut value = json!({"label": "Test", "max_enrollments": 1});
        value.as_object_mut().unwrap().extend(expiry.as_object().unwrap().clone());
        let request: NewEnrollmentToken = serde_json::from_value(value).unwrap();
        assert!(request.validate().is_ok());
    }
}

#[test]
fn enrollment_rejects_past_and_conflicting_expiry() {
    for expiry in [json!({"expires_at": (Utc::now() - Duration::minutes(1)).to_rfc3339()}), json!({"expires_in_hours": 24, "expires_at": (Utc::now() + Duration::days(1)).to_rfc3339()}), json!({"expires_in_hours": 0})] {
        let mut value = json!({"label": "Test", "max_enrollments": 1});
        value.as_object_mut().unwrap().extend(expiry.as_object().unwrap().clone());
        let request: NewEnrollmentToken = serde_json::from_value(value).unwrap();
        assert!(request.validate().is_err());
    }
}
