use std::{env, thread, time::Duration};

use anyhow::{Context, Result};
use control_plane_node_agent::{
    AgentConfig, DesiredConfigStore, LoopbackRuntimeController, MtlsControlPlaneTransport,
};
use url::Url;
use uuid::Uuid;

fn main() -> Result<()> {
    let config_json = env::var("NODE_AGENT_CONFIG")
        .context("NODE_AGENT_CONFIG must contain the node-agent JSON configuration")?;
    let config: AgentConfig =
        serde_json::from_str(&config_json).context("NODE_AGENT_CONFIG must be valid JSON")?;
    config.validate().map_err(anyhow::Error::msg)?;
    let node_id = Uuid::parse_str(&config.node_id).context("node_id must be a UUID")?;
    let runtime_url: Url = env::var("NODE_AGENT_RUNTIME_URL")
        .unwrap_or_else(|_| "http://127.0.0.1:21116/".to_owned())
        .parse()
        .context("NODE_AGENT_RUNTIME_URL must be a URL")?;
    let interval_seconds = env::var("NODE_AGENT_POLL_SECONDS")
        .unwrap_or_else(|_| "15".to_owned())
        .parse::<u64>()
        .context("NODE_AGENT_POLL_SECONDS must be an integer")?;
    if !(5..=300).contains(&interval_seconds) {
        anyhow::bail!("NODE_AGENT_POLL_SECONDS must be between 5 and 300");
    }

    let transport = MtlsControlPlaneTransport::new(config.control_plane_url, node_id, &config.mtls)
        .map_err(anyhow::Error::msg)?;
    let runtime = LoopbackRuntimeController::new(runtime_url).map_err(anyhow::Error::msg)?;
    let desired = transport
        .fetch_desired_config()
        .map_err(anyhow::Error::msg)?;
    // Start at revision zero so even the first desired state is applied through
    // the runtime, rather than treating it as already effective after a reboot.
    let initial = control_plane_node_agent::DesiredNodeConfig {
        revision: 0,
        anonymous_remote_policy: desired.anonymous_remote_policy.clone(),
        managed_mode: desired.managed_mode,
        credential_issuer_public_key: desired.credential_issuer_public_key.clone(),
    };
    let store = DesiredConfigStore::new(initial).map_err(anyhow::Error::msg)?;

    loop {
        let mut healthy = true;
        match transport.fetch_desired_config() {
            Ok(next) if next.revision > store.health().effective_config.revision => {
                if let Err(error) = store.apply_with_runtime(next, &runtime) {
                    eprintln!("node-agent rollout failed: {error}");
                    healthy = false;
                }
            }
            Ok(_) => {}
            Err(error) => {
                eprintln!("node-agent desired-config poll failed: {error}");
                healthy = false;
            }
        }
        let mut health = store.health();
        health.healthy = healthy;
        if let Err(error) = transport.report_health(&health) {
            eprintln!("node-agent health report failed: {error}");
        }
        thread::sleep(Duration::from_secs(interval_seconds));
    }
}
