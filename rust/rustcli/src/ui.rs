//! Terminal presentation: colours, spinners, byte counts.

use std::io::{IsTerminal, Write};
use std::time::{Duration, Instant};

/// ANSI escapes, empty when stdout is not a terminal.
#[derive(Debug, Clone, Copy)]
pub struct Style {
    enabled: bool,
}

impl Style {
    pub fn detect() -> Self {
        // Honour the de-facto standard opt-out.
        let forced_off = std::env::var_os("NO_COLOR").is_some();
        Self {
            enabled: !forced_off && std::io::stdout().is_terminal(),
        }
    }

    /// Styling disabled, whatever stdout is. Used by the tests.
    #[cfg(test)]
    pub fn plain() -> Self {
        Self { enabled: false }
    }

    fn wrap(&self, code: &str, text: &str) -> String {
        if self.enabled {
            format!("\x1b[{code}m{text}\x1b[0m")
        } else {
            text.to_string()
        }
    }

    pub fn dim(&self, text: &str) -> String {
        self.wrap("2", text)
    }
    pub fn bold(&self, text: &str) -> String {
        self.wrap("1", text)
    }
    pub fn cyan(&self, text: &str) -> String {
        self.wrap("36", text)
    }
    pub fn green(&self, text: &str) -> String {
        self.wrap("32", text)
    }
    pub fn yellow(&self, text: &str) -> String {
        self.wrap("33", text)
    }
    pub fn red(&self, text: &str) -> String {
        self.wrap("31", text)
    }

    /// Open a dim run without closing it — for streaming reasoning text.
    pub fn dim_on(&self) -> &'static str {
        if self.enabled {
            "\x1b[2m"
        } else {
            ""
        }
    }
    pub fn off(&self) -> &'static str {
        if self.enabled {
            "\x1b[0m"
        } else {
            ""
        }
    }
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }
}

/// A single-line status that redraws in place, throttled so a fast callback
/// does not spend all its time writing to the terminal.
pub struct StatusLine {
    style: Style,
    last: Instant,
    width: usize,
    interval: Duration,
}

impl StatusLine {
    pub fn new(style: Style) -> Self {
        Self {
            style,
            last: Instant::now() - Duration::from_secs(1),
            width: 0,
            interval: Duration::from_millis(80),
        }
    }

    /// Redraw unless the last update was very recent.
    pub fn set(&mut self, text: &str) {
        if self.last.elapsed() < self.interval {
            return;
        }
        self.force(text);
    }

    pub fn force(&mut self, text: &str) {
        if !self.style.is_enabled() {
            return;
        }
        let pad = self.width.saturating_sub(text.chars().count());
        print!("\r{}{}", text, " ".repeat(pad));
        let _ = std::io::stdout().flush();
        self.width = text.chars().count();
        self.last = Instant::now();
    }

    /// Erase the line.
    pub fn clear(&mut self) {
        if self.style.is_enabled() && self.width > 0 {
            print!("\r{}\r", " ".repeat(self.width));
            let _ = std::io::stdout().flush();
        }
        self.width = 0;
    }
}

pub fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit + 1 < UNITS.len() {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

pub fn human_count(n: u64) -> String {
    match n {
        n if n >= 1_000_000_000 => format!("{:.1}B", n as f64 / 1e9),
        n if n >= 1_000_000 => format!("{:.1}M", n as f64 / 1e6),
        n if n >= 1_000 => format!("{:.1}k", n as f64 / 1e3),
        n => n.to_string(),
    }
}

/// `[####----]` — 20 cells wide.
pub fn bar(fraction: f64) -> String {
    const WIDTH: usize = 20;
    let filled = ((fraction.clamp(0.0, 1.0)) * WIDTH as f64).round() as usize;
    format!("[{}{}]", "#".repeat(filled), "-".repeat(WIDTH - filled))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bytes_read_sensibly() {
        assert_eq!(human_bytes(0), "0 B");
        assert_eq!(human_bytes(1536), "1.5 KiB");
        assert_eq!(human_bytes(16 * 1024 * 1024 * 1024), "16.0 GiB");
    }

    #[test]
    fn counts_are_abbreviated() {
        assert_eq!(human_count(999), "999");
        assert_eq!(human_count(27_000_000_000), "27.0B");
    }

    #[test]
    fn the_bar_saturates_at_both_ends() {
        assert_eq!(bar(0.0), "[--------------------]");
        assert_eq!(bar(1.0), "[####################]");
        assert_eq!(bar(-5.0), bar(0.0));
        assert_eq!(bar(5.0), bar(1.0));
        assert_eq!(bar(0.5), "[##########----------]");
    }

    #[test]
    fn styling_is_a_no_op_without_a_terminal() {
        let s = Style::plain();
        assert_eq!(s.bold("hi"), "hi");
        assert_eq!(s.dim_on(), "");
    }
}
