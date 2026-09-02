//! The functions the model is allowed to call.
//!
//! Ollama answers a turn with `tool_calls` when it wants to act before it
//! speaks. Each one lands here, does something real to the robot's archive,
//! and answers with one short line the model can read back.
//!
//! Two rules hold throughout. Every call is **scoped to the robot whose turn
//! it is** — a tool cannot reach into another robot's space, because the agent
//! id is passed in rather than taken from the arguments. And every failure
//! answers with a line beginning `REJECTED:` or `FAILED:` rather than raising,
//! because a model that gets an error string can correct itself on the next
//! step, and one that gets an exception just loses the turn.

use anyhow::Result;
use serde_json::{json, Value};

use crate::context::{Kind, NewItem};
use crate::embed::Embedder;
use crate::search::{self, Mode, Scope};
use crate::store::Store;

/// The schema handed to `/api/chat`.
pub fn schema() -> Vec<Value> {
    vec![
        function(
            "search_context",
            "Search this robot's own archive of notes, markdown, files, photos and past \
             messages. Use it before answering anything that might already be written down.",
            json!({
                "type": "object",
                "properties": {
                    "query": { "type": "string", "description": "What to look for." },
                    "mode": {
                        "type": "string",
                        "enum": ["hybrid", "bm25", "semantic"],
                        "description": "hybrid is both engines fused, bm25 is exact keywords, semantic is meaning."
                    },
                    "limit": { "type": "integer", "description": "How many hits, 1 to 20." }
                },
                "required": ["query"]
            }),
        ),
        function(
            "write_note",
            "Write a markdown note into this robot's archive so it is remembered and \
             searchable later. Use it when the operator tells you something worth keeping.",
            json!({
                "type": "object",
                "properties": {
                    "title": { "type": "string", "description": "A short title." },
                    "body": { "type": "string", "description": "The note, in markdown." }
                },
                "required": ["title", "body"]
            }),
        ),
        function(
            "list_context",
            "List what is on this robot's shelves.",
            json!({
                "type": "object",
                "properties": {
                    "kind": {
                        "type": "string",
                        "enum": ["image", "markdown", "file", "note", "message"],
                        "description": "Which shelf. Omit for everything but the transcript."
                    },
                    "limit": { "type": "integer", "description": "How many, 1 to 50." }
                }
            }),
        ),
        function(
            "read_item",
            "Read one item of the archive in full, by the id a search or a listing gave.",
            json!({
                "type": "object",
                "properties": { "id": { "type": "integer", "description": "The item id." } },
                "required": ["id"]
            }),
        ),
        function(
            "list_robots",
            "List the robots of the swarm and what each one answers for.",
            json!({ "type": "object", "properties": {} }),
        ),
        function(
            "get_time",
            "The current clock time, local to the operator or UTC.",
            json!({
                "type": "object",
                "properties": {
                    "zone": { "type": "string", "enum": ["local", "utc", "both"] }
                }
            }),
        ),
    ]
}

fn function(name: &str, description: &str, parameters: Value) -> Value {
    json!({
        "type": "function",
        "function": { "name": name, "description": description, "parameters": parameters }
    })
}

/// Everything a tool is allowed to touch.
pub struct Ctx<'a> {
    pub store: &'a Store,
    pub embedder: &'a dyn Embedder,
    /// Whose turn it is. `None` is the global space.
    pub agent_id: Option<String>,
}

/// Run one call. Never fails: a rejection is a sentence, not an error.
pub fn run(ctx: &Ctx, name: &str, args: &Value) -> String {
    let result = match name {
        "search_context" => tool_search(ctx, args),
        "write_note" => tool_write_note(ctx, args),
        "list_context" => tool_list(ctx, args),
        "read_item" => tool_read(ctx, args),
        "list_robots" => tool_robots(ctx),
        "get_time" => Ok(tool_time(args)),
        _ => {
            let mut known: Vec<String> = schema()
                .iter()
                .filter_map(|s| s["function"]["name"].as_str().map(str::to_uppercase))
                .collect();
            known.sort();
            return format!(
                "REJECTED: NO TOOL {name:?}. AVAILABLE: {}.",
                known.join(", ")
            );
        }
    };
    match result {
        Ok(line) => line,
        Err(e) => format!("FAILED: {}", one_line(&e.to_string(), 140)),
    }
}

/// A compact label for the console: `SEARCH_CONTEXT "borrow checker"`.
pub fn label(name: &str, args: &Value) -> String {
    let mut out = name.to_uppercase();
    for key in ["query", "title", "kind", "id", "zone", "mode"] {
        if let Some(v) = args.get(key) {
            let v = v
                .as_str()
                .map(str::to_string)
                .unwrap_or_else(|| v.to_string());
            if !v.is_empty() {
                out.push(' ');
                out.push_str(&one_line(&v, 40).to_uppercase());
                break;
            }
        }
    }
    out
}

// ------------------------------------------------------------------ tools --

fn tool_search(ctx: &Ctx, args: &Value) -> Result<String> {
    let query = str_arg(args, "query");
    if query.trim().is_empty() {
        return Ok("REJECTED: SEARCH_CONTEXT NEEDS A QUERY.".into());
    }
    let mode = Mode::parse(&str_arg(args, "mode"));
    let limit = int_arg(args, "limit").unwrap_or(5).clamp(1, 20) as usize;
    let scope = Scope::of(ctx.agent_id.as_deref());

    let hits = search::search(ctx.store, ctx.embedder, &query, &scope, mode, limit)?;
    if hits.is_empty() {
        return Ok(format!("NOTHING FOUND FOR {query:?} IN THIS ARCHIVE."));
    }
    let mut out = format!("{} HITS ({}):", hits.len(), mode.as_str());
    for hit in &hits {
        out.push_str(&format!(
            "\n#{} [{}] {}",
            hit.item.id,
            hit.item.kind,
            hit.item.summary(220)
        ));
    }
    Ok(out)
}

fn tool_write_note(ctx: &Ctx, args: &Value) -> Result<String> {
    let title = str_arg(args, "title");
    let body = str_arg(args, "body");
    if body.trim().is_empty() {
        return Ok("REJECTED: WRITE_NOTE NEEDS A BODY.".into());
    }
    let item = ctx.store.add(NewItem {
        agent_id: ctx.agent_id.clone(),
        kind: Some(Kind::Markdown),
        title: if title.trim().is_empty() {
            "note".into()
        } else {
            title
        },
        body,
        meta: Some(json!({ "author": "tool" }).to_string()),
        ..Default::default()
    })?;
    // Index it immediately, so the note is findable within the same turn.
    if let Ok(vec) = ctx.embedder.embed_one(&item.indexed_text()) {
        let _ = ctx.store.put_embedding(item.id, ctx.embedder.model(), &vec);
    }
    Ok(format!(
        "DONE: WROTE #{} TO {}.",
        item.id,
        item.path.as_deref().unwrap_or("the archive")
    ))
}

fn tool_list(ctx: &Ctx, args: &Value) -> Result<String> {
    let kind = Kind::parse(&str_arg(args, "kind"));
    let limit = int_arg(args, "limit").unwrap_or(10).clamp(1, 50);
    let items = ctx.store.items(ctx.agent_id.as_deref(), kind, limit)?;
    if items.is_empty() {
        return Ok("THE SHELF IS EMPTY.".into());
    }
    let mut out = format!("{} ITEMS:", items.len());
    for item in &items {
        out.push_str(&format!(
            "\n#{} [{}] {}{}",
            item.id,
            item.kind,
            item.title,
            item.path
                .as_deref()
                .map(|p| format!("  ({p})"))
                .unwrap_or_default()
        ));
    }
    Ok(out)
}

fn tool_read(ctx: &Ctx, args: &Value) -> Result<String> {
    let Some(id) = int_arg(args, "id") else {
        return Ok("REJECTED: READ_ITEM NEEDS AN ID.".into());
    };
    let Some(item) = ctx.store.item(id)? else {
        return Ok(format!("REJECTED: NO ITEM #{id}."));
    };
    // A tool must not be a way out of the robot it belongs to.
    if item.agent_id != ctx.agent_id {
        return Ok(format!("REJECTED: ITEM #{id} BELONGS TO ANOTHER ROBOT."));
    }
    let body = if item.body.trim().is_empty() {
        match item.path.as_deref() {
            Some(path) => ctx.store.space.read_text(path).unwrap_or_default(),
            None => String::new(),
        }
    } else {
        item.body.clone()
    };
    if body.trim().is_empty() {
        return Ok(format!(
            "#{} [{}] {} — no text (it is a {}).",
            item.id, item.kind, item.title, item.mime
        ));
    }
    Ok(format!(
        "#{} [{}] {}\n{}",
        item.id,
        item.kind,
        item.title,
        body.chars().take(4000).collect::<String>()
    ))
}

fn tool_robots(ctx: &Ctx) -> Result<String> {
    let agents = ctx.store.agents()?;
    if agents.is_empty() {
        return Ok("NO ROBOTS ON THE ROSTER.".into());
    }
    let mut out = format!("{} ROBOTS:", agents.len());
    for a in &agents {
        let here = if Some(&a.id) == ctx.agent_id.as_ref() {
            "  <- you"
        } else {
            ""
        };
        out.push_str(&format!("\n{} ({}) — {}{}", a.name, a.kind, a.role, here));
    }
    Ok(out)
}

fn tool_time(args: &Value) -> String {
    let zone = str_arg(args, "zone").to_lowercase();
    let secs = crate::db::now();
    match zone.as_str() {
        "utc" | "gmt" | "zulu" => format!("UTC {}", stamp(secs)),
        "both" => format!("UNIX {secs}. UTC {}.", stamp(secs)),
        _ => format!("UNIX {secs}. UTC {}.", stamp(secs)),
    }
}

/// Seconds since the epoch as `YYYY-MM-DD HH:MM:SS`, computed rather than
/// pulled in with a date crate: the civil-from-days algorithm is ten lines and
/// this backend needs nothing else from a calendar.
pub fn stamp(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);

    // Howard Hinnant's civil_from_days, shifted to an era starting 0000-03-01.
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mth = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mth <= 2 { y + 1 } else { y };
    format!("{y:04}-{mth:02}-{d:02} {h:02}:{m:02}:{s:02}")
}

// ---------------------------------------------------------------- helpers --

fn str_arg(args: &Value, key: &str) -> String {
    match args.get(key) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

fn int_arg(args: &Value, key: &str) -> Option<i64> {
    match args.get(key)? {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

fn one_line(text: &str, width: usize) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() > width {
        flat.chars().take(width).collect()
    } else {
        flat
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_epoch_and_a_known_date_agree() {
        assert_eq!(stamp(0), "1970-01-01 00:00:00");
        assert_eq!(stamp(1_700_000_000), "2023-11-14 22:13:20");
        assert_eq!(stamp(951_782_400), "2000-02-29 00:00:00");
    }

    #[test]
    fn every_tool_in_the_schema_is_well_formed() {
        let tools = schema();
        assert!(tools.len() >= 6);
        for t in &tools {
            assert_eq!(t["type"], "function");
            assert!(t["function"]["name"].as_str().is_some());
            assert!(!t["function"]["description"].as_str().unwrap().is_empty());
            assert_eq!(t["function"]["parameters"]["type"], "object");
        }
    }

    #[test]
    fn arguments_are_read_whether_they_arrive_typed_or_as_strings() {
        let args = json!({ "id": "42", "limit": 7.0, "query": "x", "kind": null });
        assert_eq!(int_arg(&args, "id"), Some(42));
        assert_eq!(int_arg(&args, "limit"), Some(7));
        assert_eq!(int_arg(&args, "missing"), None);
        assert_eq!(str_arg(&args, "query"), "x");
        assert_eq!(str_arg(&args, "kind"), "");
    }

    #[test]
    fn a_label_is_short_and_says_what_ran() {
        assert_eq!(
            label("search_context", &json!({ "query": "borrow checker" })),
            "SEARCH_CONTEXT BORROW CHECKER"
        );
        assert_eq!(label("list_robots", &json!({})), "LIST_ROBOTS");
    }
}
