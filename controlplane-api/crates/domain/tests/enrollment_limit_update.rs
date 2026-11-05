use control_plane_domain::UpdateEnrollmentTokenExpiry;
use serde_json::json;

#[test]
fn update_accepts_valid_enrollment_limits_only() {
    for max in [1, 10000] {
        let request: UpdateEnrollmentTokenExpiry = serde_json::from_value(json!({"expires_at": null, "max_enrollments": max})).unwrap();
        assert!(request.validate().is_ok());
    }
    for max in [0, 10001] {
        let request: UpdateEnrollmentTokenExpiry = serde_json::from_value(json!({"expires_at": null, "max_enrollments": max})).unwrap();
        assert!(request.validate().is_err());
    }
}
