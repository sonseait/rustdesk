use async_trait::async_trait;
use hbb_common::{log, ResultType};
use sqlx::{
    sqlite::SqliteConnectOptions, ConnectOptions, Connection, Error as SqlxError, SqliteConnection,
};
use std::{ops::DerefMut, str::FromStr};
//use sqlx::postgres::PgPoolOptions;
//use sqlx::mysql::MySqlPoolOptions;

type Pool = deadpool::managed::Pool<DbPool>;

pub struct DbPool {
    url: String,
}

#[async_trait]
impl deadpool::managed::Manager for DbPool {
    type Type = SqliteConnection;
    type Error = SqlxError;
    async fn create(&self) -> Result<SqliteConnection, SqlxError> {
        let mut opt = SqliteConnectOptions::from_str(&self.url).unwrap();
        opt.log_statements(log::LevelFilter::Debug);
        SqliteConnection::connect_with(&opt).await
    }
    async fn recycle(
        &self,
        obj: &mut SqliteConnection,
    ) -> deadpool::managed::RecycleResult<SqlxError> {
        Ok(obj.ping().await?)
    }
}

#[derive(Clone)]
pub struct Database {
    pool: Pool,
}

#[derive(Default, sqlx::FromRow)]
pub struct Peer {
    pub guid: Vec<u8>,
    pub id: String,
    pub uuid: Vec<u8>,
    pub pk: Vec<u8>,
    pub user: Option<Vec<u8>>,
    pub info: String,
    pub status: Option<i64>,
}

impl Database {
    pub async fn new(url: &str) -> ResultType<Database> {
        if !std::path::Path::new(url).exists() {
            std::fs::File::create(url).ok();
        }
        let n: usize = crate::common::get_arg_or("MAX_DATABASE_CONNECTIONS", "1".to_owned())
            .parse()
            .unwrap_or(1);
        log::debug!("MAX_DATABASE_CONNECTIONS={}", n);
        let pool = Pool::new(
            DbPool {
                url: url.to_owned(),
            },
            n,
        );
        let _ = pool.get().await?; // test
        let db = Database { pool };
        db.create_tables().await?;
        Ok(db)
    }

    async fn create_tables(&self) -> ResultType<()> {
        sqlx::query(
            "
            create table if not exists peer (
                guid blob primary key not null,
                id varchar(100) not null,
                uuid blob not null,
                pk blob not null,
                created_at datetime not null default(current_timestamp),
                user blob,
                status tinyint,
                note varchar(300),
                info text not null
            ) without rowid;
            create unique index if not exists index_peer_id on peer (id);
            create index if not exists index_peer_user on peer (user);
            create index if not exists index_peer_created_at on peer (created_at);
            create index if not exists index_peer_status on peer (status);
        "
        )
        .execute(self.pool.get().await?.deref_mut())
        .await?;
        Ok(())
    }

    pub async fn get_peer(&self, id: &str) -> ResultType<Option<Peer>> {
        Ok(sqlx::query_as::<_, Peer>(
            "select guid, id, uuid, pk, user, status, info from peer where id = ?",
        )
        .bind(id)
        .fetch_optional(self.pool.get().await?.deref_mut())
        .await?)
    }

    pub async fn insert_peer(
        &self,
        id: &str,
        uuid: &[u8],
        pk: &[u8],
        info: &str,
    ) -> ResultType<Vec<u8>> {
        let guid = uuid::Uuid::new_v4().as_bytes().to_vec();
        sqlx::query("insert into peer(guid, id, uuid, pk, info) values(?, ?, ?, ?, ?)")
        .bind(&guid)
        .bind(id)
        .bind(uuid)
        .bind(pk)
        .bind(info)
        .execute(self.pool.get().await?.deref_mut())
        .await?;
        Ok(guid)
    }

    pub async fn update_pk(
        &self,
        guid: &Vec<u8>,
        id: &str,
        pk: &[u8],
        info: &str,
    ) -> ResultType<()> {
        sqlx::query("update peer set id=?, pk=?, info=? where guid=?")
        .bind(id)
        .bind(pk)
        .bind(info)
        .bind(guid)
        .execute(self.pool.get().await?.deref_mut())
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{Database, DbPool, Pool};
    use hbb_common::tokio;
    use std::ops::DerefMut;

    #[tokio::test]
    async fn peer_queries_round_trip_without_a_build_database() {
        let db = Database {
            pool: Pool::new(
                DbPool {
                    url: "sqlite::memory:".to_owned(),
                },
                1,
            ),
        };
        db.create_tables().await.unwrap();
        db.create_tables().await.unwrap();
        assert!(db.get_peer("missing").await.unwrap().is_none());

        let id = "peer'with?quotes";
        let uuid = vec![0, 255, 1];
        let pk = vec![2, 0, 255];
        let info = r#"{"name":"peer's device"}"#;
        let guid = db.insert_peer(id, &uuid, &pk, info).await.unwrap();
        let peer = db.get_peer(id).await.unwrap().unwrap();
        assert_eq!(peer.guid, guid);
        assert_eq!(peer.id, id);
        assert_eq!(peer.uuid, uuid);
        assert_eq!(peer.pk, pk);
        assert_eq!(peer.info, info);
        assert_eq!(peer.user, None);
        assert_eq!(peer.status, None);
        assert!(db.insert_peer(id, &uuid, &pk, info).await.is_err());

        let updated_pk = vec![0, 3, 255];
        db.update_pk(&guid, "updated-peer", &updated_pk, "updated info")
            .await
            .unwrap();
        assert!(db.get_peer(id).await.unwrap().is_none());
        let peer = db.get_peer("updated-peer").await.unwrap().unwrap();
        assert_eq!(peer.guid, guid);
        assert_eq!(peer.uuid, uuid);
        assert_eq!(peer.pk, updated_pk);
        assert_eq!(peer.info, "updated info");

        sqlx::query("update peer set user=?, status=? where guid=?")
            .bind(vec![4_u8, 0, 255])
            .bind(1_i64)
            .bind(&guid)
            .execute(db.pool.get().await.unwrap().deref_mut())
            .await
            .unwrap();
        let peer = db.get_peer("updated-peer").await.unwrap().unwrap();
        assert_eq!(peer.user, Some(vec![4, 0, 255]));
        assert_eq!(peer.status, Some(1));
    }

    #[test]
    fn test_insert() {
        insert();
    }

    #[tokio::main(flavor = "multi_thread")]
    async fn insert() {
        let db = super::Database::new("test.sqlite3").await.unwrap();
        let mut jobs = vec![];
        for i in 0..10000 {
            let cloned = db.clone();
            let id = i.to_string();
            let a = tokio::spawn(async move {
                let empty_vec = Vec::new();
                cloned
                    .insert_peer(&id, &empty_vec, &empty_vec, "")
                    .await
                    .unwrap();
            });
            jobs.push(a);
        }
        for i in 0..10000 {
            let cloned = db.clone();
            let id = i.to_string();
            let a = tokio::spawn(async move {
                cloned.get_peer(&id).await.unwrap();
            });
            jobs.push(a);
        }
        hbb_common::futures::future::join_all(jobs).await;
    }
}
