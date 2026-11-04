use std::{future::Future, panic::AssertUnwindSafe, str::FromStr};
use futures_util::FutureExt;
use sqlx::{postgres::{PgConnectOptions, PgPoolOptions}, PgPool};

/// Explicitly opt-in. Never uses DATABASE_URL or reads configuration files.
/// Only loopback, disposable managed_test databases are accepted.
pub async fn isolated<F, Fut>(test: F)
where F: FnOnce(PgPool) -> Fut, Fut: Future<Output = ()> {
    let url = std::env::var("MANAGED_TEST_DATABASE_URL")
        .expect("set MANAGED_TEST_DATABASE_URL to a disposable loopback managed_test database");
    let options = PgConnectOptions::from_str(&url).expect("invalid test database URL");
    assert!(matches!(options.get_host(), "127.0.0.1" | "localhost" | "::1"), "test database must be loopback");
    assert!(options.get_database().is_some_and(|db| db == "managed_test" || db.starts_with("managed_test_")), "refusing non-test database");
    let admin = PgPoolOptions::new().max_connections(1).connect_with(options.clone()).await.expect("disposable PostgreSQL unavailable");
    let schema = format!("managed_test_{}", uuid::Uuid::new_v4().simple());
    sqlx::query(&format!("CREATE SCHEMA {schema}")).execute(&admin).await.unwrap();
    let pool = PgPoolOptions::new().max_connections(6)
        .connect_with(options.options([("search_path", schema.as_str())])).await.unwrap();
    let result = AssertUnwindSafe(async {
        control_plane_db::migrate(&pool).await.unwrap();
        test(pool.clone()).await;
    }).catch_unwind().await;
    pool.close().await;
    sqlx::query(&format!("DROP SCHEMA {schema} CASCADE")).execute(&admin).await.unwrap();
    admin.close().await;
    if let Err(panic) = result { std::panic::resume_unwind(panic); }
}
