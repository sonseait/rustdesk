//! Bounded HTTP. Protocol error bodies are reduced to allowlisted codes by the caller.
use serde_json::Value;
use std::time::Duration;
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug)]
pub(super) struct Failure { pub status: u16, pub code: String }

#[cfg(not(test))]
pub(super) fn post(url: &str, body: &Value) -> Result<Value, Failure> {
    let unavailable = |_| Failure { status: 0, code: "temporarily_unavailable".into() };
    let client = reqwest::blocking::Client::builder().connect_timeout(CONNECT_TIMEOUT)
        .timeout(REQUEST_TIMEOUT).redirect(reqwest::redirect::Policy::none())
        .build().map_err(unavailable)?;
    let response = client.post(url).json(body).send().map_err(unavailable)?;
    let status = response.status();
    if status == reqwest::StatusCode::NO_CONTENT { return Ok(Value::Null); }
    let body = response.json::<Value>().unwrap_or(Value::Null);
    if status.is_success() { Ok(body) } else {
        Err(Failure { status: status.as_u16(), code: body["code"].as_str().unwrap_or_default().into() })
    }
}

#[cfg(test)]
type Handler = Box<dyn FnMut(&str, &Value) -> Result<Value, Failure>>;
#[cfg(test)]
thread_local! { pub(super) static HANDLER: std::cell::RefCell<Option<Handler>> = Default::default(); }
#[cfg(test)]
pub(super) fn post(url: &str, body: &Value) -> Result<Value, Failure> {
    HANDLER.with(|handler| handler.borrow_mut().as_mut().expect("install isolated HTTP handler")(url,body))
}
