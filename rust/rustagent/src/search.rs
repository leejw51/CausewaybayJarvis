//! Retrieval over one robot's context: BM25, vectors, and the two together.
//!
//! **BM25** is SQLite's own FTS5 ranking, over the `items_fts` index. It is
//! the classic search and it is very good at the thing it is good at: the
//! exact words, rare ones weighted heavily, long documents discounted.
//!
//! **Semantic** is brute-force cosine over [`crate::embed`] vectors. It finds
//! the row that means the same thing in other words.
//!
//! **Hybrid** is Reciprocal Rank Fusion: each engine votes with `1/(K+rank)`
//! and the votes are added. RRF rather than a weighted sum of the two scores,
//! because a BM25 score and a cosine are not on the same scale and never will
//! be — one is unbounded and corpus-relative, the other is in `[-1, 1]`. Ranks
//! are comparable; the numbers behind them are not. `K = 60` is the constant
//! from the original paper and it is not sensitive.

use anyhow::Result;
use rusqlite::params;
use serde::Serialize;

use crate::context::{Item, Kind};
use crate::db::fts_query;
use crate::embed::{cosine, Embedder};
use crate::store::{decode_vec, Store};

/// The RRF constant. Bigger flattens the two rankings towards each other.
pub const RRF_K: f32 = 60.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    /// Classic keyword search. No model needed, ever.
    Bm25,
    /// Vectors only.
    Semantic,
    /// Both, fused by rank.
    Hybrid,
}

impl Mode {
    pub fn parse(s: &str) -> Mode {
        match s.trim().to_ascii_lowercase().as_str() {
            "bm25" | "keyword" | "classic" | "fts" => Mode::Bm25,
            "semantic" | "vector" | "embedding" => Mode::Semantic,
            _ => Mode::Hybrid,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Bm25 => "bm25",
            Mode::Semantic => "semantic",
            Mode::Hybrid => "hybrid",
        }
    }
}

/// Which rows are in play. A chosen robot searches its own archive; with no
/// robot chosen the global space is the archive.
#[derive(Debug, Clone)]
pub enum Scope {
    Agent(String),
    Global,
    /// Every robot at once — what the router and `search --all` use.
    All,
}

impl Scope {
    pub fn of(agent_id: Option<&str>) -> Scope {
        match agent_id {
            Some(id) => Scope::Agent(id.to_string()),
            None => Scope::Global,
        }
    }

    /// The `WHERE` fragment, with `i` bound to `items`.
    fn sql(&self) -> &'static str {
        match self {
            Scope::Agent(_) => "i.agent_id = ?2",
            Scope::Global => "i.agent_id IS NULL",
            Scope::All => "1=1",
        }
    }

    fn param(&self) -> Option<&str> {
        match self {
            Scope::Agent(id) => Some(id.as_str()),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Hit {
    pub item: Item,
    /// The fused score in hybrid mode, or the engine's own otherwise.
    pub score: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bm25: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cosine: Option<f32>,
    /// `bm25`, `semantic`, or `both`.
    pub via: &'static str,
}

/// Classic keyword search. Returns best first.
pub fn bm25(store: &Store, query: &str, scope: &Scope, limit: usize) -> Result<Vec<(Item, f32)>> {
    bm25_over(store, query, scope, limit, false)
}

/// The same, optionally skipping the transcript.
///
/// Routing uses `filed_only`: a robot should be summoned by what it has been
/// *given*, not by what it has already been asked. Counting past turns makes a
/// wrong route self-reinforcing — the mistake writes two messages into that
/// robot, which is then the best match for the next identical question.
pub fn bm25_over(
    store: &Store,
    query: &str,
    scope: &Scope,
    limit: usize,
    filed_only: bool,
) -> Result<Vec<(Item, f32)>> {
    let match_query = fts_query(query);
    if match_query.is_empty() {
        return Ok(Vec::new());
    }
    // SQLite's bm25() is negative, and *more* negative is a better match.
    // Flipping the sign here means every score in this module reads the same
    // way round: bigger is better.
    let sql = format!(
        "SELECT i.id, i.agent_id, i.kind, i.role, i.title, i.body, i.path, i.mime, i.bytes,
                i.meta, i.created_at, i.updated_at, -bm25(items_fts, 4.0, 1.0) AS score
         FROM items_fts JOIN items i ON i.id = items_fts.rowid
         WHERE items_fts MATCH ?1 AND {}{}
         ORDER BY score DESC LIMIT ?3",
        scope.sql(),
        if filed_only {
            " AND i.kind <> 'message'"
        } else {
            ""
        }
    );
    let mut stmt = store.conn.prepare(&sql)?;
    let rows = stmt
        .query_map(params![match_query, scope.param(), limit as i64], |row| {
            Ok((
                Item {
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
                },
                row.get::<_, f64>(12)? as f32,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

/// Cosine over every vector in scope. Brute force: a personal archive is
/// thousands of rows, not millions, and an exact scan has no index to go stale.
pub fn semantic(
    store: &Store,
    embedder: &dyn Embedder,
    query: &str,
    scope: &Scope,
    limit: usize,
) -> Result<Vec<(Item, f32)>> {
    if query.trim().is_empty() {
        return Ok(Vec::new());
    }
    let q = embedder.embed_one(query)?;
    if q.is_empty() {
        return Ok(Vec::new());
    }

    // Only vectors this embedder wrote. Comparing across two models is
    // comparing two different spaces, which produces confident nonsense.
    let model = embedder.model().to_string();
    let sql = format!(
        "SELECT i.id, i.agent_id, i.kind, i.role, i.title, i.body, i.path, i.mime, i.bytes,
                i.meta, i.created_at, i.updated_at, e.vec
         FROM embeddings e JOIN items i ON i.id = e.item_id
         WHERE e.model = ?1 AND {}",
        scope.sql()
    );
    let agent = scope.param();
    let bound: Vec<&dyn rusqlite::ToSql> = match &agent {
        Some(id) => vec![&model, id],
        None => vec![&model],
    };
    let mut stmt = store.conn.prepare(&sql)?;
    let mut scored: Vec<(Item, f32)> = stmt
        .query_map(bound.as_slice(), |row| {
            let item = Item {
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
            };
            let blob: Vec<u8> = row.get(12)?;
            Ok((item, blob))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?
        .into_iter()
        .map(|(item, blob)| {
            let score = cosine(&q, &decode_vec(&blob));
            (item, score)
        })
        .collect();

    scored.sort_by(|a, b| b.1.total_cmp(&a.1));
    scored.truncate(limit);
    Ok(scored)
}

/// Both, fused by rank. This is what a turn retrieves with.
pub fn hybrid(
    store: &Store,
    embedder: &dyn Embedder,
    query: &str,
    scope: &Scope,
    limit: usize,
) -> Result<Vec<Hit>> {
    // Take a deeper slice from each engine than we return: a row that is
    // eighth on both lists should be able to beat one that is first on one and
    // absent from the other, and it cannot if it was never in the pool.
    let pool = (limit * 4).max(20);
    let keyword = bm25(store, query, scope, pool)?;
    let vector = semantic(store, embedder, query, scope, pool).unwrap_or_default();

    let mut fused: std::collections::HashMap<i64, Hit> = Default::default();
    for (rank, (item, score)) in keyword.into_iter().enumerate() {
        fused.insert(
            item.id,
            Hit {
                item,
                score: 1.0 / (RRF_K + rank as f32 + 1.0),
                bm25: Some(score),
                cosine: None,
                via: "bm25",
            },
        );
    }
    for (rank, (item, score)) in vector.into_iter().enumerate() {
        let vote = 1.0 / (RRF_K + rank as f32 + 1.0);
        match fused.get_mut(&item.id) {
            Some(hit) => {
                hit.score += vote;
                hit.cosine = Some(score);
                hit.via = "both";
            }
            None => {
                fused.insert(
                    item.id,
                    Hit {
                        item,
                        score: vote,
                        bm25: None,
                        cosine: Some(score),
                        via: "semantic",
                    },
                );
            }
        }
    }

    let mut out: Vec<Hit> = fused.into_values().collect();
    // Ties broken by recency, so a fresh note wins over an identical old one.
    out.sort_by(|a, b| {
        b.score
            .total_cmp(&a.score)
            .then(b.item.created_at.cmp(&a.item.created_at))
            .then(b.item.id.cmp(&a.item.id))
    });
    out.truncate(limit);
    Ok(out)
}

/// The front door. `mode` picks the engine; the shape of the answer is the
/// same either way, so the UI does not branch.
pub fn search(
    store: &Store,
    embedder: &dyn Embedder,
    query: &str,
    scope: &Scope,
    mode: Mode,
    limit: usize,
) -> Result<Vec<Hit>> {
    let limit = limit.clamp(1, 100);
    Ok(match mode {
        Mode::Hybrid => hybrid(store, embedder, query, scope, limit)?,
        Mode::Bm25 => bm25(store, query, scope, limit)?
            .into_iter()
            .map(|(item, score)| Hit {
                item,
                score,
                bm25: Some(score),
                cosine: None,
                via: "bm25",
            })
            .collect(),
        Mode::Semantic => semantic(store, embedder, query, scope, limit)?
            .into_iter()
            .map(|(item, score)| Hit {
                item,
                score,
                bm25: None,
                cosine: Some(score),
                via: "semantic",
            })
            .collect(),
    })
}

/// Give every row in scope a vector it is missing. Called after anything is
/// filed, and by `agentd reindex`.
pub fn reindex(store: &Store, embedder: &dyn Embedder, agent_id: Option<&str>) -> Result<usize> {
    let pending = store.unembedded(agent_id, embedder.model(), 2000)?;
    if pending.is_empty() {
        return Ok(0);
    }
    let mut done = 0;
    // In batches, because an embedding API charges per round trip and not per
    // input.
    for chunk in pending.chunks(32) {
        let texts: Vec<String> = chunk.iter().map(|i| i.indexed_text()).collect();
        let vectors = embedder.embed(&texts)?;
        for (item, vec) in chunk.iter().zip(vectors) {
            if vec.is_empty() {
                continue;
            }
            store.put_embedding(item.id, embedder.model(), &vec)?;
            done += 1;
        }
    }
    Ok(done)
}

/// How well each robot's *filed* archive matches a prompt, normalised so the
/// best-matching robot scores 1.0.
///
/// A BM25 score is meaningless on its own — it depends on the corpus, the
/// document lengths and the rarity of the words — so it is only ever used here
/// as a ranking, turned into a relative weight. [`crate::router`] adds it to
/// the keyword score; it is evidence about this operator, which a shipped word
/// list cannot be.
pub fn archive_evidence(store: &Store, prompt: &str) -> std::collections::HashMap<String, f32> {
    let mut out: std::collections::HashMap<String, f32> = Default::default();
    for (item, score) in bm25_over(store, prompt, &Scope::All, 60, true).unwrap_or_default() {
        if let Some(id) = item.agent_id {
            let slot = out.entry(id).or_insert(0.0);
            *slot = slot.max(score.max(0.0));
        }
    }
    if let Some(best) = out.values().copied().reduce(f32::max) {
        if best > 0.0 {
            for v in out.values_mut() {
                *v /= best;
            }
        }
    }
    out
}

/// Retrieved context, folded into the one system message a turn carries.
pub fn as_context_block(hits: &[Hit]) -> String {
    if hits.is_empty() {
        return String::new();
    }
    let mut out = String::from(
        "Context retrieved from this robot's archive. Use it when it is relevant, \
         and say so when it is not:\n",
    );
    for (i, hit) in hits.iter().enumerate() {
        let where_from = hit.item.path.as_deref().unwrap_or(hit.item.kind.as_str());
        out.push_str(&format!(
            "[{}] ({}) {}\n{}\n",
            i + 1,
            where_from,
            hit.item.title,
            hit.item.summary(600)
        ));
    }
    out
}

/// The kinds a page shows, in the order it shows them.
pub const PAGE_KINDS: [Kind; 4] = [Kind::Image, Kind::Markdown, Kind::File, Kind::Note];
