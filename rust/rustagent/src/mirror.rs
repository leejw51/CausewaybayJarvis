//! The three plain-text mirrors kept beside every space's own database.
//!
//! SQLite is where things are *searched* — the FTS index and the vectors
//! live there and nowhere else. But a folder that only a database can read
//! is not a folder anybody can pick up, so every row is also written where
//! `cat`, a spreadsheet and a person can read it:
//!
//! ```text
//! agents/<GUID>/
//!   agent.db       the own database: the same schema as robots.db, this robot only
//!   items.jsonl    one JSON object per event, appended — add, delete, clear
//!   items.csv      one row per item added, appended, with a header
//!   agent.md       the whole archive as a page, rewritten after every change
//! global/…         the same three, for what was filed with nobody chosen
//! ```
//!
//! The JSONL and the CSV are appended, never rewritten, so they are a log:
//! a deleted item stays in them with a `deleted` line after it. The markdown
//! is the opposite — regenerated from the database each time — so it is
//! always the current state, and the two together are the history and the
//! present. None of the three is ever read back by the backend: `export`
//! rebuilds all of them from the database, which is the one source.

use std::io::Write;

use anyhow::{Context, Result};
use serde_json::json;

use crate::agent::Agent;
use crate::context::Item;
use crate::space::{Space, CSV_FILE, JSONL_FILE, MARKDOWN_FILE};

/// The CSV header. One column per `items` column, in the table's order.
pub const CSV_HEADER: &str =
    "id,agent_id,kind,role,title,body,path,mime,bytes,meta,created_at,updated_at";

/// Append one event to `<space>/items.jsonl`.
pub fn append_jsonl(space: &Space, space_dir: &str, event: &serde_json::Value) -> Result<()> {
    let path = space.resolve(&format!("{space_dir}/{JSONL_FILE}"))?;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .with_context(|| format!("opening {}", path.display()))?;
    writeln!(file, "{event}")?;
    Ok(())
}

/// The JSONL line for an item that was just filed.
pub fn added(item: &Item) -> serde_json::Value {
    let mut v = serde_json::to_value(item).unwrap_or_else(|_| json!({}));
    v["event"] = json!("add");
    v
}

/// Append one item row to `<space>/items.csv`, writing the header first
/// when the file is new.
pub fn append_csv(space: &Space, space_dir: &str, item: &Item) -> Result<()> {
    let path = space.resolve(&format!("{space_dir}/{CSV_FILE}"))?;
    let fresh = !path.exists()
        || std::fs::metadata(&path)
            .map(|m| m.len() == 0)
            .unwrap_or(true);
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .with_context(|| format!("opening {}", path.display()))?;
    if fresh {
        writeln!(file, "{CSV_HEADER}")?;
    }
    writeln!(file, "{}", csv_row(item))?;
    Ok(())
}

/// One item as a CSV row, RFC 4180 quoting: every field quoted, quotes
/// doubled, newlines kept inside the quotes.
pub fn csv_row(item: &Item) -> String {
    let q = |s: &str| format!("\"{}\"", s.replace('"', "\"\""));
    [
        item.id.to_string(),
        q(item.agent_id.as_deref().unwrap_or("")),
        q(&item.kind),
        q(&item.role),
        q(&item.title),
        q(&item.body),
        q(item.path.as_deref().unwrap_or("")),
        q(&item.mime),
        item.bytes.to_string(),
        q(&item.meta),
        item.created_at.to_string(),
        item.updated_at.to_string(),
    ]
    .join(",")
}

/// Everything the markdown page is made of. The caller reads the database;
/// this only writes.
pub struct Snapshot<'a> {
    pub agent: Option<&'a Agent>,
    pub space_dir: &'a str,
    pub gallery: &'a [Item],
    pub videos: &'a [Item],
    pub markdowns: &'a [Item],
    pub files: &'a [Item],
    pub notes: &'a [Item],
    /// Oldest first.
    pub messages: &'a [Item],
    pub message_count: i64,
    pub bytes: i64,
}

/// Render the page — pure, so it is testable without a disk.
pub fn markdown(s: &Snapshot<'_>) -> String {
    let mut out = String::new();
    match s.agent {
        Some(a) => {
            out.push_str(&format!("# {} — {}\n\n", a.name, a.role));
            out.push_str(&format!("- **id**: `{}`\n", a.id));
            out.push_str(&format!("- **slug**: `{}`\n", a.slug));
            out.push_str(&format!("- **kind**: {}\n", a.kind));
            out.push_str(&format!("- **sprite**: {}\n", a.sprite));
            out.push_str(&format!("- **folder**: `{}`\n", s.space_dir));
            out.push_str(&format!("- **created**: {}\n\n", iso(a.created_at)));
            if !a.persona.trim().is_empty() {
                out.push_str("## Persona\n\n");
                out.push_str(a.persona.trim());
                out.push_str("\n\n");
            }
            if !a.keywords.trim().is_empty() {
                out.push_str(&format!("**Keywords:** {}\n\n", a.keywords.trim()));
            }
        }
        None => {
            out.push_str("# Global space\n\n");
            out.push_str("What was filed with no robot chosen.\n\n");
            out.push_str(&format!("- **folder**: `{}`\n\n", s.space_dir));
        }
    }

    out.push_str("## Archive\n\n");
    out.push_str("| shelf | items |\n| --- | ---: |\n");
    out.push_str(&format!("| photos | {} |\n", s.gallery.len()));
    out.push_str(&format!("| videos | {} |\n", s.videos.len()));
    out.push_str(&format!("| markdown | {} |\n", s.markdowns.len()));
    out.push_str(&format!("| files | {} |\n", s.files.len()));
    out.push_str(&format!("| notes | {} |\n", s.notes.len()));
    out.push_str(&format!("| messages | {} |\n", s.message_count));
    out.push_str(&format!("| bytes | {} |\n\n", s.bytes));

    for (title, items) in [
        ("Photos", s.gallery),
        ("Videos", s.videos),
        ("Markdown", s.markdowns),
        ("Files", s.files),
    ] {
        if items.is_empty() {
            continue;
        }
        out.push_str(&format!("## {title}\n\n"));
        for it in items {
            let path = it.path.as_deref().unwrap_or("");
            out.push_str(&format!(
                "- #{} **{}** — `{}` ({} bytes, {})\n",
                it.id,
                escape(&it.title),
                path,
                it.bytes,
                iso(it.created_at)
            ));
            if !it.body.trim().is_empty() && it.kind != "markdown" {
                out.push_str(&format!("  {}\n", escape(first_line(&it.body, 200))));
            }
            // The LÖVE clip beside a video, so a person reading the folder
            // knows the `.clip.ogv` is not a second video.
            if it.kind == "video" {
                let meta: serde_json::Value =
                    serde_json::from_str(&it.meta).unwrap_or(serde_json::Value::Null);
                match meta["clip"].as_str() {
                    Some(clip) => out.push_str(&format!("  LÖVE clip: `{clip}`\n")),
                    None => {
                        if let Some(why) = meta["why"].as_str() {
                            out.push_str(&format!("  no LÖVE clip: {}\n", escape(why)));
                        }
                    }
                }
            }
        }
        out.push('\n');
    }

    if !s.notes.is_empty() {
        out.push_str("## Notes\n\n");
        for it in s.notes {
            out.push_str(&format!("### #{} {}\n\n", it.id, escape(&it.title)));
            out.push_str(it.body.trim());
            out.push_str("\n\n");
        }
    }

    if !s.messages.is_empty() {
        out.push_str(&format!(
            "## Conversation (last {} of {})\n\n",
            s.messages.len(),
            s.message_count
        ));
        for m in s.messages {
            let who = if m.role.is_empty() {
                "user"
            } else {
                m.role.as_str()
            };
            out.push_str(&format!(
                "- **{}** ({}): {}\n",
                who,
                iso(m.created_at),
                escape(&m.body.replace('\n', " "))
            ));
        }
        out.push('\n');
    }
    out
}

/// Write the page to `<space>/agent.md`.
pub fn write_markdown(space: &Space, s: &Snapshot<'_>) -> Result<()> {
    let path = space.resolve(&format!("{}/{MARKDOWN_FILE}", s.space_dir))?;
    std::fs::write(&path, markdown(s)).with_context(|| format!("writing {}", path.display()))
}

/// Start the JSONL and CSV over from nothing — what `export` does before it
/// replays the database into them.
pub fn truncate_logs(space: &Space, space_dir: &str) -> Result<()> {
    for name in [JSONL_FILE, CSV_FILE] {
        let path = space.resolve(&format!("{space_dir}/{name}"))?;
        if path.exists() {
            std::fs::write(&path, "")?;
        }
    }
    Ok(())
}

fn escape(s: &str) -> String {
    s.replace('|', "\\|").replace('\r', "")
}

fn first_line(body: &str, width: usize) -> &str {
    let line = body.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
    match line.char_indices().nth(width) {
        Some((i, _)) => &line[..i],
        None => line,
    }
}

/// Seconds since the epoch as `YYYY-MM-DD HH:MM:SS` UTC, without a date
/// crate: the civil-from-days arithmetic from Howard Hinnant's paper.
pub fn iso(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mo <= 2 { y + 1 } else { y };
    format!("{y:04}-{mo:02}-{d:02} {h:02}:{m:02}:{s:02}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: i64, kind: &str, title: &str, body: &str) -> Item {
        Item {
            id,
            agent_id: Some("g".into()),
            kind: kind.into(),
            role: String::new(),
            title: title.into(),
            body: body.into(),
            path: None,
            mime: String::new(),
            bytes: 3,
            meta: "{}".into(),
            created_at: 0,
            updated_at: 0,
        }
    }

    #[test]
    fn dates_are_civil_utc() {
        assert_eq!(iso(0), "1970-01-01 00:00:00");
        assert_eq!(iso(951_782_400), "2000-02-29 00:00:00");
        assert_eq!(iso(1_756_857_600), "2025-09-03 00:00:00");
    }

    #[test]
    fn csv_rows_quote_everything_that_needs_it() {
        let row = csv_row(&item(7, "note", "say \"hi\"", "two\nlines"));
        assert!(row.starts_with("7,\"g\",\"note\",\"\",\"say \"\"hi\"\"\",\"two\nlines\""));
        assert!(row.matches(',').count() >= 11);
    }

    #[test]
    fn the_markdown_page_lists_every_shelf_and_the_conversation() {
        let notes = [item(1, "note", "pork belly", "slow roast")];
        let msgs = [item(2, "message", "USER", "what's for dinner")];
        let mut clip = item(3, "video", "holiday.mov", "video, 12.0 s");
        clip.path = Some("global/videos/holiday.mov".into());
        clip.meta = r#"{"clip":"global/videos/holiday.clip.ogv"}"#.into();
        let mut bare = item(4, "video", "raw.mp4", "video");
        bare.meta = r#"{"clip":null,"why":"no encoder"}"#.into();
        let videos = [clip, bare];
        let snap = Snapshot {
            agent: None,
            space_dir: "global",
            gallery: &[],
            videos: &videos,
            markdowns: &[],
            files: &[],
            notes: &notes,
            messages: &msgs,
            message_count: 1,
            bytes: 6,
        };
        let page = markdown(&snap);
        assert!(page.starts_with("# Global space"));
        assert!(page.contains("| notes | 1 |"));
        assert!(page.contains("| videos | 2 |"));
        assert!(page.contains("## Videos"));
        assert!(page.contains("LÖVE clip: `global/videos/holiday.clip.ogv`"));
        assert!(page.contains("no LÖVE clip: no encoder"));
        assert!(page.contains("### #1 pork belly"));
        assert!(page.contains("what's for dinner"));
    }
}
