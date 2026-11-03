use argon2::{
    password_hash::{Error as PasswordHashError, PasswordHasher, PasswordVerifier, SaltString},
    Argon2, PasswordHash,
};
use rand_core::{OsRng, RngCore};
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum PasswordError {
    #[error("could not hash password")]
    Hash(PasswordHashError),
    #[error("stored password hash is invalid")]
    InvalidStoredHash(PasswordHashError),
}

pub fn hash_password(password: &str) -> Result<String, PasswordError> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(PasswordError::Hash)
}

pub fn verify_password(password: &str, stored_hash: &str) -> Result<bool, PasswordError> {
    let hash = PasswordHash::new(stored_hash).map_err(PasswordError::InvalidStoredHash)?;
    Ok(Argon2::default()
        .verify_password(password.as_bytes(), &hash)
        .is_ok())
}

/// Generates an opaque session secret. Only its SHA-256 hash is persisted.
pub fn new_session_token() -> String {
    let mut bytes = [0_u8; 32];
    OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}

pub fn hash_session_token(token: &str) -> String {
    hex::encode(Sha256::digest(token.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::{hash_password, hash_session_token, new_session_token, verify_password};

    #[test]
    fn hashes_are_verifiable() {
        let hash = hash_password("correct horse battery staple").unwrap();
        assert!(verify_password("correct horse battery staple", &hash).unwrap());
        assert!(!verify_password("not the password", &hash).unwrap());
    }

    #[test]
    fn session_tokens_are_random_and_hashable() {
        let first = new_session_token();
        let second = new_session_token();
        assert_ne!(first, second);
        assert_eq!(hash_session_token(&first).len(), 64);
    }
}
