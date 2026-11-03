use std::path::PathBuf;

use axum::Router;
use tower_http::services::ServeDir;

pub fn router(api: Router, ui_dir: Option<PathBuf>) -> Router {
    // Keep direct API paths for managed clients while the portal uses /api.
    let app = Router::new().nest("/api", api.clone()).merge(api);
    match ui_dir {
        Some(dir) => app.fallback_service(ServeDir::new(dir)),
        None => app,
    }
}

#[cfg(test)]
mod tests {
    use axum::{
        body::{to_bytes, Body},
        http::{Request, StatusCode},
        routing::get,
    };
    use tower::ServiceExt;

    use super::*;

    #[tokio::test]
    async fn portal_and_both_api_paths_share_one_router() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("index.html"), "<html>portal</html>").unwrap();
        std::fs::write(dir.path().join("app.js"), "console.log('portal')").unwrap();
        let api = Router::new()
            .route("/healthz", get(|| async { "healthy" }))
            .route("/v1/auth/me", get(|| async { StatusCode::UNAUTHORIZED }));
        let app = router(api, Some(dir.path().to_owned()))
            .layer(axum::middleware::from_fn(crate::add_security_headers));

        for path in ["/healthz", "/api/healthz"] {
            let response = app
                .clone()
                .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK, "{path}");
            assert_eq!(
                to_bytes(response.into_body(), 1024).await.unwrap(),
                "healthy"
            );
        }
        for path in ["/v1/auth/me", "/api/v1/auth/me"] {
            let response = app
                .clone()
                .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED, "{path}");
        }
        for (path, content_type) in [("/", "text/html"), ("/app.js", "text/javascript")] {
            let response = app
                .clone()
                .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK, "{path}");
            assert!(response.headers()["content-type"]
                .to_str()
                .unwrap()
                .starts_with(content_type));
            assert_eq!(response.headers()["x-content-type-options"], "nosniff");
        }
        // Missing assets and API routes must stay 404 rather than returning HTML.
        for path in [
            "/missing.js",
            "/api/v1/missing",
            "/v1/missing",
            "/%2e%2e/Cargo.toml",
        ] {
            let response = app
                .clone()
                .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::NOT_FOUND, "{path}");
        }
    }

    #[tokio::test]
    async fn native_api_can_run_without_portal_assets() {
        let app = router(
            Router::new().route("/healthz", get(|| async { "healthy" })),
            None,
        );
        for (path, status) in [
            ("/", StatusCode::NOT_FOUND),
            ("/api/healthz", StatusCode::OK),
        ] {
            let response = app
                .clone()
                .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), status, "{path}");
        }
    }
}
