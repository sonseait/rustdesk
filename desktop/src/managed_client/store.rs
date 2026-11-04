//! The sole secret-storage boundary. Tests never use the host Keychain.
#[cfg(not(test))]
use keyring::Entry;

#[cfg(not(test))]
fn entry() -> Result<Entry, String> {
    if !cfg!(any(target_os = "macos", target_os = "windows")) {
        return Err("credential_store_unsupported".into());
    }
    Entry::new("com.rustdesk.managed-platform", "device-credential")
        .map_err(|_| "credential_store_unavailable".into())
}

#[cfg(not(test))]
pub(super) fn load() -> Result<Option<String>, String> {
    match entry()?.get_password() {
        Ok(raw) => Ok(Some(raw)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(_) => Err("credential_store_unavailable".into()),
    }
}
#[cfg(not(test))]
pub(super) fn save(raw: &str) -> Result<(), String> {
    entry()?.set_password(raw).map_err(|_| "credential_store_unavailable".into())
}
#[cfg(not(test))]
pub(super) fn delete() -> Result<(), String> {
    match entry()?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(_) => Err("credential_store_unavailable".into()),
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
