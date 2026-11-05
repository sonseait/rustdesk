//! The sole secret-storage boundary. Tests never use the host Keychain.
#[cfg(test)]
mod encoding_tests {
    use super::*;

    #[test]
    fn binary_secret_avoids_utf16_expansion_and_round_trips() {
        let raw = format!("{{\"fixture\":\"{}\"}}", "a".repeat(1800));
        assert!(raw.encode_utf16().count() * 2 > 2560);
        let encoded = encode_secret(&raw);
        assert!(encoded.len() <= 2560);
        assert_eq!(decode_secret(&encoded).unwrap(), Some(raw));
        assert_eq!(decode_secret(&encode_secret("máy tính 🖥")).unwrap(), Some("máy tính 🖥".into()));
    }

    #[test]
    fn legacy_entries_fall_back_and_invalid_encoding_fails_closed() {
        assert_eq!(decode_secret(&[b'{', 0, b'}', 0]).unwrap(), None);
        assert!(decode_secret(&[SECRET_PREFIX, &[255]].concat()).is_err());
        assert_eq!(storage_error(keyring::Error::TooLong("sensitive".into(), 2560)), "credential_store_too_large");
        assert_eq!(storage_error(keyring::Error::BadEncoding(vec![255])), "credential_store_encoding");
    }
}
#[cfg(not(test))]
use keyring::Entry;

#[cfg(any(test, target_os = "windows"))]
const SECRET_PREFIX: &[u8] = b"RDMC\x01";

#[cfg(any(test, target_os = "windows"))]
fn encode_secret(raw: &str) -> Vec<u8> {
    [SECRET_PREFIX, raw.as_bytes()].concat()
}

#[cfg(any(test, target_os = "windows"))]
fn decode_secret(raw: &[u8]) -> Result<Option<String>, String> {
    match raw.strip_prefix(SECRET_PREFIX) {
        Some(bytes) => String::from_utf8(bytes.to_vec()).map(Some)
            .map_err(|_| "credential_store_encoding".into()),
        None => Ok(None),
    }
}

fn storage_error(error: keyring::Error) -> String {
    match error {
        keyring::Error::TooLong(_, _) => "credential_store_too_large",
        keyring::Error::NoStorageAccess(_) => "credential_store_access_denied",
        keyring::Error::BadEncoding(_) => "credential_store_encoding",
        _ => "credential_store_unavailable",
    }.into()
}

#[cfg(not(test))]
fn entry() -> Result<Entry, String> {
    if !cfg!(any(target_os = "macos", target_os = "windows")) {
        return Err("credential_store_unsupported".into());
    }
    Entry::new("com.rustdesk.managed-platform", "device-credential")
        .map_err(storage_error)
}

#[cfg(not(test))]
pub(super) fn load() -> Result<Option<String>, String> {
    // Marked UTF-8 secrets avoid Windows password UTF-16 expansion. Older
    // entries retain their original password decoding and identity.
    #[cfg(target_os = "windows")]
    match entry()?.get_secret() {
        Ok(bytes) => if let Some(raw) = decode_secret(&bytes)? { return Ok(Some(raw)); },
        Err(keyring::Error::NoEntry) => return Ok(None),
        Err(error) => return Err(storage_error(error)),
    }
    match entry()?.get_password() {
        Ok(raw) => Ok(Some(raw)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(storage_error(error)),
    }
}
#[cfg(not(test))]
pub(super) fn save(raw: &str) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    { entry()?.set_secret(&encode_secret(raw)).map_err(storage_error) }
    #[cfg(not(target_os = "windows"))]
    { entry()?.set_password(raw).map_err(storage_error) }
}
#[cfg(not(test))]
pub(super) fn delete() -> Result<(), String> {
    match entry()?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(storage_error(error)),
    }
}

#[cfg(test)]
#[derive(Default)]
pub(super) struct Memory {
    pub raw: Option<String>,
    pub fail_write: bool,
}
#[cfg(test)]
thread_local! { pub(super) static MEMORY: std::cell::RefCell<Memory> = Default::default(); }
#[cfg(test)]
pub(super) fn load() -> Result<Option<String>, String> { MEMORY.with(|m| Ok(m.borrow().raw.clone())) }
#[cfg(test)]
pub(super) fn save(raw: &str) -> Result<(), String> {
    MEMORY.with(|m| {
        let mut memory = m.borrow_mut();
        if memory.fail_write { return Err("credential_store_unavailable".into()); }
        memory.raw = Some(raw.into());
        Ok(())
    })
}
#[cfg(test)]
pub(super) fn delete() -> Result<(), String> {
    MEMORY.with(|m| m.borrow_mut().raw = None); Ok(())
}
