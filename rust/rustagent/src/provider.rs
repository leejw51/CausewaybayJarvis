//! Which brain answers: this machine's, or somebody else's.
//!
//! The operator's choice is one of three words, persisted in the `settings`
//! table so it survives a restart and can be flipped from the UI at any time:
//!
//! * `ondevice` — the MLX engine, the same Qwen3.8-27B `rustcli` runs.
//! * `cloud` — ollama.com (or whatever `OLLAMA_HOST` points at).
//! * `auto` — on-device when this build carries the engine and the weights
//!   are on disk, cloud when it does not. This is the default, and it is the
//!   sentence "use the local model, unless this Mac cannot" as a setting.
//!
//! The choice and the outcome are different things. [`Effective`] is what a
//! turn will actually use *right now*, with the reason when that is not what
//! was asked for — a UI that shows only the wish and not the outcome is how
//! "on-device" quietly becomes a cloud call.

use serde::{Deserialize, Serialize};

/// What the operator asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Auto,
    OnDevice,
    Cloud,
}

impl Provider {
    pub const KEY: &'static str = "provider";

    pub fn parse(s: &str) -> Option<Provider> {
        match s.trim().to_ascii_lowercase().as_str() {
            "auto" | "" => Some(Provider::Auto),
            "ondevice" | "on-device" | "local" | "device" | "mlx" => Some(Provider::OnDevice),
            "cloud" | "ollama" | "remote" => Some(Provider::Cloud),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Provider::Auto => "auto",
            Provider::OnDevice => "ondevice",
            Provider::Cloud => "cloud",
        }
    }

    /// The order the UI cycles through on a single key.
    pub fn next(self) -> Provider {
        match self {
            Provider::Auto => Provider::OnDevice,
            Provider::OnDevice => Provider::Cloud,
            Provider::Cloud => Provider::Auto,
        }
    }
}

/// What a turn will actually run against, right now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effective {
    OnDevice,
    Cloud,
    /// Nothing can answer; the string says why.
    Offline(String),
}

impl Effective {
    pub fn as_str(&self) -> &'static str {
        match self {
            Effective::OnDevice => "ondevice",
            Effective::Cloud => "cloud",
            Effective::Offline(_) => "offline",
        }
    }
}

/// Decide what actually runs. Pure, so the table of outcomes is testable
/// without a GPU, a key, or a database.
///
/// `ondevice` is `Ok(())` when this build has the engine *and* the weights
/// are on disk; `cloud` is `Ok(())` when the ollama config can be dialled.
pub fn effective(
    choice: Provider,
    ondevice: &Result<(), String>,
    cloud: &Result<(), String>,
) -> Effective {
    let on = |why: &Result<(), String>| why.clone().err().unwrap_or_default();
    match choice {
        Provider::OnDevice => match ondevice {
            Ok(()) => Effective::OnDevice,
            Err(_) => Effective::Offline(format!("on-device unavailable: {}", on(ondevice))),
        },
        Provider::Cloud => match cloud {
            Ok(()) => Effective::Cloud,
            Err(_) => Effective::Offline(format!("cloud unavailable: {}", on(cloud))),
        },
        Provider::Auto => match (ondevice, cloud) {
            (Ok(()), _) => Effective::OnDevice,
            (Err(_), Ok(())) => Effective::Cloud,
            (Err(_), Err(_)) => {
                Effective::Offline(format!("on-device: {}; cloud: {}", on(ondevice), on(cloud)))
            }
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok() -> Result<(), String> {
        Ok(())
    }
    fn no(why: &str) -> Result<(), String> {
        Err(why.to_string())
    }

    #[test]
    fn the_words_parse_and_the_ring_cycles() {
        assert_eq!(Provider::parse("ondevice"), Some(Provider::OnDevice));
        assert_eq!(Provider::parse("ON-DEVICE"), Some(Provider::OnDevice));
        assert_eq!(Provider::parse("local"), Some(Provider::OnDevice));
        assert_eq!(Provider::parse("cloud"), Some(Provider::Cloud));
        assert_eq!(Provider::parse(""), Some(Provider::Auto));
        assert_eq!(Provider::parse("nonsense"), None);

        let mut p = Provider::Auto;
        let mut seen = Vec::new();
        for _ in 0..3 {
            p = p.next();
            seen.push(p.as_str());
        }
        assert_eq!(seen, ["ondevice", "cloud", "auto"]);
    }

    #[test]
    fn auto_prefers_this_machine_and_falls_back_to_the_cloud() {
        assert_eq!(effective(Provider::Auto, &ok(), &ok()), Effective::OnDevice);
        assert_eq!(
            effective(Provider::Auto, &no("no weights"), &ok()),
            Effective::Cloud
        );
        match effective(Provider::Auto, &no("no engine"), &no("no key")) {
            Effective::Offline(why) => {
                assert!(why.contains("no engine") && why.contains("no key"))
            }
            other => panic!("expected offline, got {other:?}"),
        }
    }

    #[test]
    fn an_explicit_choice_is_honoured_or_refused_never_substituted() {
        // Asking for on-device with only the cloud available must NOT quietly
        // dial out: that is the one substitution this module exists to forbid.
        match effective(Provider::OnDevice, &no("not compiled"), &ok()) {
            Effective::Offline(why) => assert!(why.contains("not compiled")),
            other => panic!("on-device fell through to {other:?}"),
        }
        // And the mirror image: cloud chosen, only the local engine present.
        match effective(Provider::Cloud, &ok(), &no("no key")) {
            Effective::Offline(why) => assert!(why.contains("no key")),
            other => panic!("cloud fell through to {other:?}"),
        }
        assert_eq!(
            effective(Provider::Cloud, &no("x"), &ok()),
            Effective::Cloud
        );
    }
}
