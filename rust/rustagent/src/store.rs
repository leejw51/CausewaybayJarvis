//! The one object everything else in the backend goes through: the database
//! and the folder, kept in step with each other.
//!
//! Filing something is one operation and not two. `add` copies the file onto
//! the right shelf of the right robot's space, writes the row, and lets the
//! FTS triggers index it — so a row can never point at a file that was never
//! copied, and a file can never sit on a shelf with nothing to find it by.

use anyhow::{anyhow, bail, Context, Result};
use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::agent::{Agent, Seed, ROSTER};
use crate::context::{Item, Kind, NewItem};
use crate::db::{self, now};
use crate::space::{self, Space};

pub struct Store {
    pub conn: Connection,
    pub space: Space,
}

/// What a robot's page is made of.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Page {
    pub agent: Option<Agent>,
    /// `agents/<GUID>`, or `global`.
    pub space: String,
    /// The absolute path, with `~` for the home directory. For the UI only.
    pub folder: String,
    pub gallery: Vec<Item>,
    pub markdowns: Vec<Item>,
    pub files: Vec<Item>,
    pub notes: Vec<Item>,
    pub messages: i64,
    pub bytes: i64,
}

impl Store {
    pub fn open(space: Space) -> Result<Self> {
        let conn = db::open(&space.db_path())?;
        Ok(Self { conn, space })
    }

    /// A store with the database in memory but a real folder — what the tests
    /// use, and what makes them fast.
    pub fn open_memory(space: Space) -> Result<Self> {
        let conn = db::open_in_memory()?;
        Ok(Self { conn, space })
    }

    /// Put the shipped roster in, once. Existing robots are left exactly as
    /// they are, including any editing the operator has done to them.
    pub fn seed_roster(&self) -> Result<usize> {
        let mut made = 0;
        for seed in ROSTER {
            if self.agent_by_slug(seed.slug)?.is_none() {
                self.create_agent(seed)?;
                made += 1;
            }
        }
        Ok(made)
    }

    // ------------------------------------------------------------- agents --

    pub fn create_agent(&self, seed: &Seed) -> Result<Agent> {
        let agent = Agent::new(seed);
        self.space.ensure_shelves(&agent.space)?;
        self.conn.execute(
            "INSERT INTO agents (id, slug, name, kind, role, sprite, color, persona,
                                 keywords, space, created_at, updated_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
            params![
                agent.id,
                agent.slug,
                agent.name,
                agent.kind,
                agent.role,
                agent.sprite,
                agent.color,
                agent.persona,
                agent.keywords,
                agent.space,
                agent.created_at,
                agent.updated_at
            ],
        )?;
        Ok(agent)
    }

    pub fn agents(&self) -> Result<Vec<Agent>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, slug, name, kind, role, sprite, color, persona, keywords, space,
                    created_at, updated_at
             FROM agents ORDER BY created_at, slug",
        )?;
        let rows = stmt
            .query_map([], row_to_agent)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    pub fn agent(&self, id: &str) -> Result<Option<Agent>> {
        let found = self
            .conn
            .query_row(
                "SELECT id, slug, name, kind, role, sprite, color, persona, keywords, space,
                        created_at, updated_at
                 FROM agents WHERE id = ?1",
                [id],
                row_to_agent,
            )
            .optional()?;
        Ok(found)
    }

    pub fn agent_by_slug(&self, slug: &str) -> Result<Option<Agent>> {
        let found = self
            .conn
            .query_row(
                "SELECT id, slug, name, kind, role, sprite, color, persona, keywords, space,
                        created_at, updated_at
                 FROM agents WHERE slug = ?1",
                [slug],
                row_to_agent,
            )
            .optional()?;
        Ok(found)
    }

    /// Accept either form the UI might hand us: a GUID or a slug. An empty
    /// string — or the word `global` — is "no robot chosen", which is not an
    /// error: it is the global space.
    pub fn resolve_agent(&self, who: Option<&str>) -> Result<Option<Agent>> {
        let who = match who.map(str::trim) {
            None | Some("") | Some("global") | Some("none") => return Ok(None),
            Some(w) => w,
        };
        if let Some(a) = self.agent(who)? {
            return Ok(Some(a));
        }
        match self.agent_by_slug(who)? {
            Some(a) => Ok(Some(a)),
            None => Err(anyhow!("no robot {who:?}")),
        }
    }

    pub fn update_agent(&self, agent: &Agent) -> Result<()> {
        self.conn.execute(
            "UPDATE agents SET slug=?2, name=?3, kind=?4, role=?5, sprite=?6, color=?7,
                               persona=?8, keywords=?9, updated_at=?10
             WHERE id=?1",
            params![
                agent.id,
                agent.slug,
                agent.name,
                agent.kind,
                agent.role,
                agent.sprite,
                agent.color,
                agent.persona,
                agent.keywords,
                now()
            ],
        )?;
        Ok(())
    }

    /// Forget a robot. The rows go with it (`ON DELETE CASCADE`); the folder
    /// is left on disk deliberately — deleting a picture the operator put
    /// there is not something a chat command should be able to do.
    pub fn delete_agent(&self, id: &str) -> Result<bool> {
        Ok(self
            .conn
            .execute("DELETE FROM agents WHERE id = ?1", [id])?
            > 0)
    }

    // -------------------------------------------------------------- items --

    /// File something. Returns the row as it was stored.
    pub fn add(&self, new: NewItem) -> Result<Item> {
        let agent = match new.agent_id.as_deref() {
            Some(id) => self
                .agent(id)?
                .map(Some)
                .ok_or_else(|| anyhow!("no robot {id}"))?,
            None => None,
        };
        let space_dir = match &agent {
            Some(a) => a.space.clone(),
            None => space::Space::agent_space(None),
        };

        let mut kind = new.kind;
        let mut path = None;
        let mut mime = String::new();
        let mut bytes = 0i64;
        let mut title = new.title.clone();
        let mut body = new.body.clone();

        if let Some(source) = new.source_path.as_deref() {
            let source = std::path::Path::new(source);
            let name = source
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| "file".into());
            mime = space::mime_for(&name).to_string();
            let guessed = if space::is_image(&mime) {
                Kind::Image
            } else if mime == "text/markdown" {
                Kind::Markdown
            } else {
                Kind::File
            };
            let k = kind.unwrap_or(guessed);
            kind = Some(k);
            let (rel, len) = self.space.intake(&space_dir, k.shelf(), source)?;
            bytes = len as i64;
            if title.is_empty() {
                title = name;
            }
            // A text file is its own body, so BM25 and the embedder can read
            // it. A picture has no text, so what it is findable by is whatever
            // caption came with it.
            if body.is_empty() && (mime.starts_with("text/") || mime == "application/json") {
                body = std::fs::read_to_string(self.space.resolve(&rel)?).unwrap_or_default();
            }
            path = Some(rel);
        } else if matches!(kind, Some(Kind::Markdown)) {
            let name = if title.is_empty() {
                format!("note-{}.md", now())
            } else {
                format!("{}.md", space::slug_filename(&title))
            };
            let rel = self.space.put_text(&space_dir, "notes", &name, &body)?;
            bytes = body.len() as i64;
            mime = "text/markdown".into();
            path = Some(rel);
        }

        let kind = kind.unwrap_or(Kind::Note);
        if title.is_empty() {
            title = first_line(&body, 60);
        }
        let t = now();
        let meta = new.meta.unwrap_or_else(|| "{}".into());

        self.conn.execute(
            "INSERT INTO items (agent_id, kind, role, title, body, path, mime, bytes, meta,
                                created_at, updated_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?10)",
            params![
                agent.as_ref().map(|a| a.id.clone()),
                kind.as_str(),
                new.role,
                title,
                body,
                path,
                mime,
                bytes,
                meta,
                t
            ],
        )?;
        let id = self.conn.last_insert_rowid();
        self.item(id)?
            .ok_or_else(|| anyhow!("row vanished after insert"))
    }

    pub fn item(&self, id: i64) -> Result<Option<Item>> {
        Ok(self
            .conn
            .query_row(&format!("{ITEM_COLUMNS} WHERE id = ?1"), [id], row_to_item)
            .optional()?)
    }

    /// Items in one space. `kind = None` is everything but the transcript.
    pub fn items(
        &self,
        agent_id: Option<&str>,
        kind: Option<Kind>,
        limit: i64,
    ) -> Result<Vec<Item>> {
        let limit = limit.clamp(1, 1000);
        let mut sql = String::from(ITEM_COLUMNS);
        sql.push_str(match agent_id {
            Some(_) => " WHERE agent_id = ?1",
            None => " WHERE agent_id IS NULL",
        });
        match kind {
            Some(_) => sql.push_str(" AND kind = ?2"),
            None => sql.push_str(" AND kind <> 'message'"),
        }
        sql.push_str(" ORDER BY id DESC LIMIT ?3");

        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt
            .query_map(
                params![agent_id, kind.map(|k| k.as_str()), limit],
                row_to_item,
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    pub fn delete_item(&self, id: i64) -> Result<bool> {
        Ok(self.conn.execute("DELETE FROM items WHERE id = ?1", [id])? > 0)
    }

    /// Everything the robot's page draws: the gallery, the markdown, the
    /// files, and how much room they take.
    pub fn page(&self, agent_id: Option<&str>) -> Result<Page> {
        let agent = match agent_id {
            Some(id) => self.agent(id)?,
            None => None,
        };
        let space_dir = agent
            .as_ref()
            .map(|a| a.space.clone())
            .unwrap_or_else(|| space::Space::agent_space(None));
        let folder = self.space.tilde(&self.space.resolve(&space_dir)?);

        // `agent_id IS NULL` takes no parameter, so the two branches cannot
        // share one binding list: SQLite counts a statement's parameters and
        // rejects a call that hands it one it has no slot for.
        let tally = |sql_agent: &str, sql_global: &str| -> Result<i64> {
            Ok(match agent_id {
                Some(id) => self.conn.query_row(sql_agent, params![id], |r| r.get(0))?,
                None => self.conn.query_row(sql_global, [], |r| r.get(0))?,
            })
        };
        let messages = tally(
            "SELECT COUNT(*) FROM items WHERE kind='message' AND agent_id=?1",
            "SELECT COUNT(*) FROM items WHERE kind='message' AND agent_id IS NULL",
        )?;
        let bytes = tally(
            "SELECT COALESCE(SUM(bytes),0) FROM items WHERE agent_id=?1",
            "SELECT COALESCE(SUM(bytes),0) FROM items WHERE agent_id IS NULL",
        )?;

        Ok(Page {
            agent,
            space: space_dir,
            folder,
            gallery: self.items(agent_id, Some(Kind::Image), 200)?,
            markdowns: self.items(agent_id, Some(Kind::Markdown), 200)?,
            files: self.items(agent_id, Some(Kind::File), 200)?,
            notes: self.items(agent_id, Some(Kind::Note), 200)?,
            messages,
            bytes,
        })
    }

    // ----------------------------------------------------------- messages --

    pub fn add_message(&self, agent_id: Option<&str>, role: &str, content: &str) -> Result<Item> {
        self.add(NewItem {
            agent_id: agent_id.map(str::to_string),
            kind: Some(Kind::Message),
            title: role.to_uppercase(),
            body: content.to_string(),
            role: role.to_string(),
            ..Default::default()
        })
    }

    /// The last `limit` turns, oldest first — the order a chat API wants.
    pub fn messages(&self, agent_id: Option<&str>, limit: i64) -> Result<Vec<Item>> {
        let limit = limit.clamp(1, 500);
        let sql = format!(
            "SELECT * FROM ({ITEM_COLUMNS} WHERE kind='message' AND {} ORDER BY id DESC LIMIT ?2)
             ORDER BY id ASC",
            match agent_id {
                Some(_) => "agent_id = ?1",
                None => "agent_id IS NULL",
            }
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt
            .query_map(params![agent_id, limit], row_to_item)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    pub fn clear_messages(&self, agent_id: Option<&str>) -> Result<usize> {
        Ok(match agent_id {
            Some(id) => self.conn.execute(
                "DELETE FROM items WHERE kind='message' AND agent_id=?1",
                params![id],
            )?,
            None => self.conn.execute(
                "DELETE FROM items WHERE kind='message' AND agent_id IS NULL",
                [],
            )?,
        })
    }

    // --------------------------------------------------------- embeddings --

    pub fn put_embedding(&self, item_id: i64, model: &str, vec: &[f32]) -> Result<()> {
        if vec.is_empty() {
            bail!("refusing to store an empty embedding");
        }
        let norm = vec.iter().map(|v| v * v).sum::<f32>().sqrt();
        let mut blob = Vec::with_capacity(vec.len() * 4);
        for v in vec {
            blob.extend_from_slice(&v.to_le_bytes());
        }
        self.conn.execute(
            "INSERT INTO embeddings (item_id, model, dim, norm, vec) VALUES (?1,?2,?3,?4,?5)
             ON CONFLICT(item_id, model) DO UPDATE SET dim=?3, norm=?4, vec=?5",
            params![item_id, model, vec.len() as i64, norm as f64, blob],
        )?;
        Ok(())
    }

    pub fn embedding(&self, item_id: i64, model: &str) -> Result<Option<Vec<f32>>> {
        let blob: Option<Vec<u8>> = self
            .conn
            .query_row(
                "SELECT vec FROM embeddings WHERE item_id=?1 AND model=?2",
                params![item_id, model],
                |r| r.get(0),
            )
            .optional()?;
        Ok(blob.map(|b| decode_vec(&b)))
    }

    /// Items in one space with no vector *from this model*.
    ///
    /// The model matters. A row embedded by `embeddinggemma` and one embedded
    /// by the offline fallback are points in two unrelated spaces, and a
    /// cosine between them is noise — so changing embedder means re-embedding,
    /// and the query that finds work to do has to know which one is asking.
    pub fn unembedded(&self, agent_id: Option<&str>, model: &str, limit: i64) -> Result<Vec<Item>> {
        let sql = format!(
            "{ITEM_COLUMNS} WHERE {}
             AND id NOT IN (SELECT item_id FROM embeddings WHERE model = ?2)
             ORDER BY id DESC LIMIT ?3",
            match agent_id {
                Some(_) => "agent_id = ?1",
                None => "agent_id IS NULL",
            }
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt
            .query_map(params![agent_id, model, limit.clamp(1, 2000)], row_to_item)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    // -------------------------------------------------------------- stats --

    pub fn stats(&self) -> Result<serde_json::Value> {
        let count = |sql: &str| -> Result<i64> { Ok(self.conn.query_row(sql, [], |r| r.get(0))?) };
        Ok(serde_json::json!({
            "root": self.space.tilde(self.space.root()),
            "db": self.space.tilde(&self.space.db_path()),
            "agents": count("SELECT COUNT(*) FROM agents")?,
            "items": count("SELECT COUNT(*) FROM items")?,
            "messages": count("SELECT COUNT(*) FROM items WHERE kind='message'")?,
            "images": count("SELECT COUNT(*) FROM items WHERE kind='image'")?,
            "markdowns": count("SELECT COUNT(*) FROM items WHERE kind='markdown'")?,
            "files": count("SELECT COUNT(*) FROM items WHERE kind='file'")?,
            "notes": count("SELECT COUNT(*) FROM items WHERE kind='note'")?,
            "embeddings": count("SELECT COUNT(DISTINCT item_id) FROM embeddings")?,
            "bytes": count("SELECT COALESCE(SUM(bytes),0) FROM items")?,
        }))
    }

    pub fn setting(&self, key: &str) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row("SELECT value FROM settings WHERE key=?1", [key], |r| {
                r.get(0)
            })
            .optional()?)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO settings (key,value) VALUES (?1,?2)
             ON CONFLICT(key) DO UPDATE SET value=?2",
            params![key, value],
        )?;
        Ok(())
    }
}

const ITEM_COLUMNS: &str = "SELECT id, agent_id, kind, role, title, body, path, mime, bytes,
                                   meta, created_at, updated_at FROM items";

pub fn decode_vec(blob: &[u8]) -> Vec<f32> {
    blob.chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

fn row_to_agent(row: &Row) -> rusqlite::Result<Agent> {
    Ok(Agent {
        id: row.get(0)?,
        slug: row.get(1)?,
        name: row.get(2)?,
        kind: row.get(3)?,
        role: row.get(4)?,
        sprite: row.get(5)?,
        color: row.get(6)?,
        persona: row.get(7)?,
        keywords: row.get(8)?,
        space: row.get(9)?,
        created_at: row.get(10)?,
        updated_at: row.get(11)?,
    })
}

fn row_to_item(row: &Row) -> rusqlite::Result<Item> {
    Ok(Item {
        id: row.get(0)?,
        agent_id: row.get(1)?,
        kind: row.get(2)?,
        role: row.get(3)?,
        title: row.get(4)?,
        body: row.get(5)?,
        path: row.get(6)?,
        mime: row.get(7)?,
        bytes: row.get(8)?,
        meta: row.get(9)?,
        created_at: row.get(10)?,
        updated_at: row.get(11)?,
    })
}

fn first_line(body: &str, width: usize) -> String {
    let line = body
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("")
        .trim();
    if line.chars().count() > width {
        line.chars().take(width).collect()
    } else if line.is_empty() {
        "untitled".to_string()
    } else {
        line.to_string()
    }
}

/// Open the default space and make sure the roster is in it. The one call a
/// front end needs.
pub fn boot() -> Result<Store> {
    let space = Space::discover().context("opening ~/.causewaybayjarvis")?;
    let store = Store::open(space)?;
    store.seed_roster()?;
    Ok(store)
}
