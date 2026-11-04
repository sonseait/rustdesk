//! Deadlines are monotonic; signed expirations are evaluated against UTC each tick.
pub const HEARTBEAT_INTERVAL_SECS: u64 = 60;
pub const CONFIG_REFRESH_INTERVAL_SECS: u64 = 300;
pub const CREDENTIAL_REFRESH_MARGIN_SECS: i64 = 3600;
pub const POLICY_REFRESH_MARGIN_SECS: i64 = 1800;
pub const RETRY_MAX_SECS: u64 = 300;

pub fn refresh_due(now: i64, issued: i64, expires: i64, margin: i64) -> bool {
    now >= expires - margin.min(((expires - issued).max(1) / 4).max(1))
}

#[derive(Default)]
pub struct Schedule {
    pub retry_at: u64,
    failures: u32,
    pub config_at: u64,
    pub heartbeat_at: u64,
    pub policy_at: u64,
}

impl Schedule {
    pub fn failed(&mut self, now: u64, jitter: u64) -> u64 {
        let delay = 2u64.saturating_pow(self.failures.min(9) + 1).min(RETRY_MAX_SECS);
        self.failures = self.failures.saturating_add(1);
        let delay = delay.saturating_add(jitter % (delay / 4 + 1)).min(RETRY_MAX_SECS);
        self.retry_at = now.saturating_add(delay);
        delay
    }
    pub fn succeeded(&mut self) { self.failures = 0; self.retry_at = 0; }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn short_lifetime_does_not_spin() {
        assert!(!refresh_due(100, 100, 120, 3600));
        assert!(!refresh_due(114, 100, 120, 3600));
        assert!(refresh_due(115, 100, 120, 3600));
    }
    #[test]
    fn retry_is_capped() {
        let mut schedule = Schedule::default();
        for _ in 0..100 { assert!(schedule.failed(0, 999) <= RETRY_MAX_SECS); }
        schedule.succeeded();
        assert_eq!(schedule.failed(0, 0), 2);
    }
}
