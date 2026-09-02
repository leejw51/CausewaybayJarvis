//! The database. One file, `robots.db`, in the space.
//!
//! Two ideas hold the schema together.
//!
//! **A robot is its context.** There is no separate notion of "the agent" and
//! "the agent's stuff": a robot is a GUID, a persona, and everything filed
//! under it. So one table — `items` — holds photos, files, markdown pages,
//! notes *and* the conversation, and `agent_id` is what says whose they are.
//! `NULL` there is the global space, which is where a turn lands when no robot
//! has been chosen.
//!
//! **Both searches read the same rows.** `items_fts` is an FTS5 index over
//! `items`, kept in step by triggers, and BM25 comes straight out of it.
//! `embeddings` hangs off the same rowid. Neither index owns a copy of the
//! text, so they cannot drift apart from it or from each other.

use anyhow::{Context, Result};
use rusqlite::Connection;

/// Bumped whenever the statements below change shape. `user_version` in the
/// file says which of them a database has had run against it.
pub const SCHEMA_VERSION: i64 = 1;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS agents (
  id          TEXT PRIMARY KEY,
  slug        TEXT NOT NULL UNIQUE,
  name        TEXT NOT NULL,
  kind        TEXT NOT NULL,
  role        TEXT NOT NULL,
  sprite      TEXT NOT NULL,
  color       TEXT NOT NULL DEFAULT '',
  persona     TEXT NOT NULL DEFAULT '',
  keywords    TEXT NOT NULL DEFAULT '',
  space       TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS agents_kind ON agents(kind);

-- Everything a robot knows. `agent_id IS NULL` is the global space.
CREATE TABLE IF NOT EXISTS items (
  id          INTEGER PRIMARY KEY,
  agent_id    TEXT REFERENCES agents(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL,          -- message | note | markdown | file | image
  role        TEXT NOT NULL DEFAULT '', -- messages only: user|assistant|system|tool
  title       TEXT NOT NULL DEFAULT '',
  body        TEXT NOT NULL DEFAULT '',
  path        TEXT,                   -- relative to the space root, or NULL
  mime        TEXT NOT NULL DEFAULT '',
  bytes       INTEGER NOT NULL DEFAULT 0,
  meta        TEXT NOT NULL DEFAULT '{}',
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS items_agent    ON items(agent_id, id);
CREATE INDEX IF NOT EXISTS items_kind     ON items(agent_id, kind, id);
CREATE UNIQUE INDEX IF NOT EXISTS items_path ON items(path) WHERE path IS NOT NULL;

-- BM25. `content=` makes it an external-content index: the text lives in
-- `items` and only the inverted index lives here.
CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
  title, body,
  content='items', content_rowid='id',
  tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS items_fts_insert AFTER INSERT ON items BEGIN
  INSERT INTO items_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;
CREATE TRIGGER IF NOT EXISTS items_fts_delete AFTER DELETE ON items BEGIN
  INSERT INTO items_fts(items_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
END;
CREATE TRIGGER IF NOT EXISTS items_fts_update AFTER UPDATE ON items BEGIN
  INSERT INTO items_fts(items_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
  INSERT INTO items_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;

-- One vector per item *per model*, little-endian f32. Brute-force cosine is
-- fast enough for a personal archive and costs nothing to keep correct.
--
-- The model is part of the key because two embedders are two unrelated
-- geometries: an archive that has been through both keeps both sets rather
-- than comparing across them, and swapping back costs nothing.
CREATE TABLE IF NOT EXISTS embeddings (
  item_id  INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  model    TEXT NOT NULL,
  dim      INTEGER NOT NULL,
  norm     REAL NOT NULL,
  vec      BLOB NOT NULL,
  PRIMARY KEY (item_id, model)
);

CREATE TABLE IF NOT EXISTS settings (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
);
"#;

/// Open (creating if needed) the database at `path` and bring it up to date.
pub fn open(path: &std::path::Path) -> Result<Connection> {
    let conn = Connection::open(path).with_context(|| format!("opening {}", path.display()))?;
    prepare(&conn)?;
    Ok(conn)
}

/// A database that never touches the disk. The tests run against this.
pub fn open_in_memory() -> Result<Connection> {
    let conn = Connection::open_in_memory()?;
    prepare(&conn)?;
    Ok(conn)
}

fn prepare(conn: &Connection) -> Result<()> {
    // WAL so the LOVE client can read while a turn is being written; foreign
    // keys so deleting a robot takes its context with it.
    conn.pragma_update(None, "journal_mode", "WAL").ok();
    conn.pragma_update(None, "foreign_keys", "ON")?;
    conn.pragma_update(None, "synchronous", "NORMAL").ok();
    conn.execute_batch(SCHEMA)?;

    let version: i64 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if version < SCHEMA_VERSION {
        conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
    }
    Ok(())
}

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// FTS5 treats a lot of punctuation as syntax. Everything a person types goes
/// through here first, so `what's a "borrow checker"?` is a query and not a
/// parse error.
pub fn fts_query(text: &str) -> String {
    let mut terms: Vec<String> = Vec::new();
    for raw in text.split(|c: char| !c.is_alphanumeric() && c != '_') {
        if raw.is_empty() {
            continue;
        }
        // Quoting each term makes it a literal; the trailing * keeps prefix
        // matching, which is what a half-typed search box wants.
        terms.push(format!("\"{}\"*", raw.to_lowercase()));
    }
    terms.join(" OR ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_schema_applies_and_is_idempotent() {
        let conn = open_in_memory().unwrap();
        prepare(&conn).unwrap();
        let version: i64 = conn
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);
    }

    #[test]
    fn punctuation_never_reaches_the_fts_parser() {
        assert_eq!(fts_query("borrow checker"), "\"borrow\"* OR \"checker\"*");
        assert_eq!(
            fts_query("what's \"this\"?"),
            "\"what\"* OR \"s\"* OR \"this\"*"
        );
        assert_eq!(fts_query("   "), "");

        let conn = open_in_memory().unwrap();
        // The raw string would be a syntax error; the cleaned one is not.
        let q = fts_query("a AND ( OR \"");
        let mut stmt = conn
            .prepare("SELECT rowid FROM items_fts WHERE items_fts MATCH ?1")
            .unwrap();
        assert!(stmt.query_map([&q], |_| Ok(())).is_ok());
    }
}
