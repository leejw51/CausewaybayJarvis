//! The backend end to end: a real folder, a real SQLite file, a scripted model.
//!
//! Nothing here reaches the network. The model is a [`ScriptBrain`] that
//! replays a fixed list of replies — including one that asks for a tool — so
//! the whole turn (route, retrieve, call, tool, call again, remember) is
//! exercised without a key, and the assertions are about what the pipeline
//! did rather than about what a model happened to say.

use std::sync::Mutex;

use serde_json::{json, Value};

use rustagent::context::{Kind, NewItem};
use rustagent::embed::HashEmbedder;
use rustagent::harness::{Brain, Harness};
use rustagent::ollama::{Message, Reply, ToolCall, ToolCallFunction};
use rustagent::proto::Backend;
use rustagent::search::{self, Mode, Scope};
use rustagent::space::Space;
use rustagent::store::Store;

// ------------------------------------------------------------- scaffolding --

struct Fixture {
    _dir: tempfile::TempDir,
    space: Space,
}

fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let space = Space::at(dir.path()).unwrap();
    Fixture { _dir: dir, space }
}

impl Fixture {
    fn store(&self) -> Store {
        let store = Store::open(self.space.clone()).unwrap();
        store.seed_roster().unwrap();
        store
    }
    fn backend(&self) -> Backend {
        Backend::offline(self.store())
    }
    /// A file outside the space, the way the operator's picker would hand one over.
    fn loose_file(&self, name: &str, body: &[u8]) -> std::path::PathBuf {
        let path = self.space.root().join("..").join(name);
        let path = std::fs::canonicalize(path.parent().unwrap())
            .unwrap()
            .join(name);
        std::fs::write(&path, body).unwrap();
        path
    }
}

/// A model that says what it was told to say, in order.
struct ScriptBrain {
    replies: Mutex<std::collections::VecDeque<Reply>>,
    seen: Mutex<Vec<Vec<Message>>>,
}

impl ScriptBrain {
    fn new(replies: Vec<Reply>) -> Self {
        Self {
            replies: Mutex::new(replies.into()),
            seen: Mutex::new(Vec::new()),
        }
    }
    fn says(text: &str) -> Reply {
        Reply {
            message: Message::assistant(text),
            done_reason: "stop".into(),
        }
    }
    fn calls(name: &str, args: Value) -> Reply {
        let mut m = Message::assistant("");
        m.tool_calls = Some(vec![ToolCall {
            function: ToolCallFunction {
                name: name.into(),
                arguments: args,
            },
        }]);
        Reply {
            message: m,
            done_reason: "tool".into(),
        }
    }
    /// The messages the model was shown on call `n`.
    fn call(&self, n: usize) -> Vec<Message> {
        self.seen.lock().unwrap()[n].clone()
    }
    fn calls_made(&self) -> usize {
        self.seen.lock().unwrap().len()
    }
}

impl Brain for ScriptBrain {
    fn chat(&self, messages: &[Message], _tools: &[Value]) -> anyhow::Result<Reply> {
        self.seen.lock().unwrap().push(messages.to_vec());
        self.replies
            .lock()
            .unwrap()
            .pop_front()
            .ok_or_else(|| anyhow::anyhow!("the script ran out"))
    }
    fn label(&self) -> String {
        "script".into()
    }
}

// -------------------------------------------------------------- the space --

#[test]
fn a_fresh_space_seeds_the_roster_once_and_gives_each_robot_a_folder() {
    let f = fixture();
    let store = f.store();

    let agents = store.agents().unwrap();
    assert_eq!(agents.len(), rustagent::ROSTER.len());

    for agent in &agents {
        assert_eq!(agent.space, format!("agents/{}", agent.id));
        for shelf in ["photos", "files", "notes"] {
            let dir = f
                .space
                .resolve(&format!("{}/{shelf}", agent.space))
                .unwrap();
            assert!(dir.is_dir(), "{} was not made", dir.display());
        }
    }

    // Seeding again is a no-op: the operator's edits survive a restart.
    assert_eq!(store.seed_roster().unwrap(), 0);
    assert_eq!(store.agents().unwrap().len(), agents.len());
}

#[test]
fn a_picture_lands_in_the_robots_own_photo_shelf_and_is_stored_relative() {
    let f = fixture();
    let store = f.store();
    let coding = store.agent_by_slug("coding").unwrap().unwrap();
    let source = f.loose_file("Screen Shot 2026.PNG", b"\x89PNG fake");

    let item = store
        .add(NewItem {
            agent_id: Some(coding.id.clone()),
            title: String::new(),
            body: "the stack trace from the crash".into(),
            source_path: Some(source.to_string_lossy().to_string()),
            ..Default::default()
        })
        .unwrap();

    assert_eq!(item.kind, "image");
    assert_eq!(item.mime, "image/png");
    let path = item.path.clone().unwrap();
    assert_eq!(
        path,
        format!("agents/{}/photos/screen-shot-2026.png", coding.id)
    );
    // Relative, and nothing about this machine in it.
    assert!(!path.starts_with('/'));
    assert!(!path.contains(&std::env::var("HOME").unwrap_or_default()));
    assert!(f.space.resolve(&path).unwrap().is_file());
    assert_eq!(item.bytes, 9);

    // The original is untouched: filing copies, it does not move.
    assert!(source.is_file());
}

#[test]
fn a_markdown_note_is_written_to_disk_as_well_as_to_the_row() {
    let f = fixture();
    let store = f.store();
    let food = store.agent_by_slug("food").unwrap().unwrap();

    let item = store
        .add(NewItem {
            agent_id: Some(food.id.clone()),
            kind: Some(Kind::Markdown),
            title: "Braised pork belly".into(),
            body: "# Braised pork belly\n\nThree hours at 140C.".into(),
            ..Default::default()
        })
        .unwrap();

    let path = item.path.clone().unwrap();
    assert_eq!(
        path,
        format!("agents/{}/notes/braised-pork-belly.md", food.id)
    );
    let on_disk = f.space.read_text(&path).unwrap();
    assert!(on_disk.contains("140C"));
}

#[test]
fn with_no_robot_chosen_everything_lands_in_the_global_space() {
    let f = fixture();
    let store = f.store();

    let item = store
        .add(NewItem {
            body: "a thought with no owner".into(),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(item.agent_id, None);

    let page = store.page(None).unwrap();
    assert_eq!(page.space, "global");
    assert!(page.agent.is_none());
    assert_eq!(page.notes.len(), 1);
}

// ------------------------------------------------------------- retrieval ---

/// Fill one robot with three notes that pull the two engines apart.
fn seeded_archive() -> (Fixture, Store, String) {
    let f = fixture();
    let store = f.store();
    let embedder = HashEmbedder::default();
    let coding = store.agent_by_slug("coding").unwrap().unwrap();

    for (title, body) in [
        (
            "lifetimes",
            "The borrow checker rejects a reference that outlives its owner.",
        ),
        (
            "threads",
            "Send and Sync decide what may cross a thread boundary.",
        ),
        (
            "pastry",
            "Laminated dough needs cold butter and a light hand.",
        ),
    ] {
        store
            .add(NewItem {
                agent_id: Some(coding.id.clone()),
                kind: Some(Kind::Note),
                title: title.into(),
                body: body.into(),
                ..Default::default()
            })
            .unwrap();
    }
    search::reindex(&store, &embedder, Some(&coding.id)).unwrap();
    (f, store, coding.id)
}

#[test]
fn bm25_finds_the_exact_words_and_nothing_else() {
    let (_f, store, coding) = seeded_archive();
    let scope = Scope::Agent(coding.clone());

    let hits = search::bm25(&store, "borrow checker", &scope, 5).unwrap();
    assert_eq!(hits[0].0.title, "lifetimes");
    assert!(hits[0].1 > 0.0, "scores read bigger-is-better");

    // A word nobody used finds nothing at all. That is the point of BM25.
    assert!(search::bm25(&store, "zzzznothing", &scope, 5)
        .unwrap()
        .is_empty());
}

#[test]
fn semantic_search_ranks_by_meaning_and_needs_no_exact_word() {
    let (_f, store, coding) = seeded_archive();
    let embedder = HashEmbedder::default();
    let scope = Scope::Agent(coding.clone());

    let hits = search::semantic(&store, &embedder, "cold butter dough", &scope, 3).unwrap();
    assert_eq!(hits[0].0.title, "pastry");
    // Every row in scope is scored, ranked rather than filtered.
    assert_eq!(hits.len(), 3);
    assert!(hits[0].1 >= hits[1].1 && hits[1].1 >= hits[2].1);
}

#[test]
fn hybrid_puts_the_row_both_engines_liked_on_top() {
    let (_f, store, coding) = seeded_archive();
    let embedder = HashEmbedder::default();
    let scope = Scope::Agent(coding.clone());

    let hits = search::hybrid(
        &store,
        &embedder,
        "borrow checker reference owner",
        &scope,
        3,
    )
    .unwrap();
    assert_eq!(hits[0].item.title, "lifetimes");
    assert_eq!(hits[0].via, "both", "the winner was found by both engines");
    assert!(hits[0].bm25.is_some() && hits[0].cosine.is_some());
    // Fusing two votes must beat holding one.
    assert!(hits[0].score > hits[1].score);
}

#[test]
fn one_robot_can_never_see_another_robots_archive() {
    let (_f, store, coding) = seeded_archive();
    let embedder = HashEmbedder::default();
    let food = store.agent_by_slug("food").unwrap().unwrap();

    for scope in [Scope::Agent(food.id.clone()), Scope::Global] {
        for mode in [Mode::Bm25, Mode::Semantic, Mode::Hybrid] {
            let hits =
                search::search(&store, &embedder, "borrow checker", &scope, mode, 10).unwrap();
            assert!(hits.is_empty(), "{mode:?} leaked out of its space");
        }
    }

    // …but the operator can ask across the whole swarm on purpose.
    let all = search::search(
        &store,
        &embedder,
        "borrow checker",
        &Scope::All,
        Mode::Bm25,
        10,
    )
    .unwrap();
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].item.agent_id.as_deref(), Some(coding.as_str()));
}

#[test]
fn reindex_is_idempotent_and_only_touches_what_is_missing() {
    let (_f, store, coding) = seeded_archive();
    let embedder = HashEmbedder::default();
    assert_eq!(
        search::reindex(&store, &embedder, Some(&coding)).unwrap(),
        0
    );

    store
        .add(NewItem {
            agent_id: Some(coding.clone()),
            body: "one more".into(),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(
        search::reindex(&store, &embedder, Some(&coding)).unwrap(),
        1
    );
    assert_eq!(
        search::reindex(&store, &embedder, Some(&coding)).unwrap(),
        0
    );
}

// ---------------------------------------------------------------- a turn ---

#[test]
fn a_turn_routes_retrieves_calls_a_tool_and_remembers_both_sides() {
    let (_f, store, coding) = seeded_archive();
    let embedder = HashEmbedder::default();

    let brain = ScriptBrain::new(vec![
        ScriptBrain::calls("search_context", json!({ "query": "borrow checker" })),
        ScriptBrain::says("The reference outlives its owner."),
    ]);
    let turn = Harness::new(&store, &embedder, &brain)
        .turn(None, "why does the borrow checker reject this reference?")
        .unwrap();

    // Routed, because no robot was locked on.
    assert!(turn.routed && turn.confident);
    assert_eq!(turn.agent.as_ref().unwrap().slug, "coding");
    assert_eq!(turn.agent.as_ref().unwrap().id, coding);

    // The tool ran, and its result went back to the model.
    assert_eq!(turn.tools, vec!["SEARCH_CONTEXT BORROW CHECKER"]);
    assert_eq!(brain.calls_made(), 2);
    let second = brain.call(1);
    assert!(second
        .iter()
        .any(|m| m.role == "tool" && m.content.contains("lifetimes")));

    // Retrieval put the archive in front of the model on the first call.
    assert!(turn.retrieved.iter().any(|r| r.title == "lifetimes"));
    let first = brain.call(0);
    assert!(
        first[0].content.contains("BYTE"),
        "the persona leads the turn"
    );
    assert!(first
        .iter()
        .any(|m| m.content.contains("Context retrieved")));

    // Both halves of the turn are in the archive, in order.
    let history = store.messages(Some(&coding), 10).unwrap();
    assert_eq!(history.len(), 2);
    assert_eq!(history[0].role, "user");
    assert_eq!(history[1].role, "assistant");
    assert_eq!(history[1].body, turn.reply);
    assert_eq!(history[0].id, turn.user_item);
    assert_eq!(history[1].id, turn.reply_item);
}

#[test]
fn the_next_turn_can_retrieve_what_the_last_one_said() {
    let f = fixture();
    let store = f.store();
    let embedder = HashEmbedder::default();

    let first = ScriptBrain::new(vec![ScriptBrain::says(
        "Your sourdough starter is called Reginald.",
    )]);
    Harness::new(&store, &embedder, &first)
        .turn(Some("food"), "what did I name the sourdough starter?")
        .unwrap();

    let second = ScriptBrain::new(vec![ScriptBrain::says("Reginald.")]);
    let turn = Harness::new(&store, &embedder, &second)
        .turn(Some("food"), "remind me about the sourdough starter")
        .unwrap();

    assert!(
        turn.retrieved.iter().any(|r| r.title == "ASSISTANT"),
        "the last answer should be retrievable: {:?}",
        turn.retrieved
    );
    // And the transcript itself is replayed to the model.
    assert!(second
        .call(0)
        .iter()
        .any(|m| m.content.contains("Reginald")));
}

#[test]
fn a_tool_note_is_findable_before_the_turn_is_over() {
    let f = fixture();
    let store = f.store();
    let embedder = HashEmbedder::default();

    let brain = ScriptBrain::new(vec![
        ScriptBrain::calls(
            "write_note",
            json!({ "title": "Reginald", "body": "The sourdough starter is called Reginald." }),
        ),
        ScriptBrain::calls("search_context", json!({ "query": "Reginald" })),
        ScriptBrain::says("Written down."),
    ]);
    let turn = Harness::new(&store, &embedder, &brain)
        .turn(Some("food"), "remember that the starter is called Reginald")
        .unwrap();

    assert_eq!(turn.tools.len(), 2);
    let third = brain.call(2);
    let found = third
        .iter()
        .filter(|m| m.role == "tool")
        .any(|m| m.content.contains("Reginald"));
    assert!(found, "the note written this turn was not searchable in it");

    let food = store.agent_by_slug("food").unwrap().unwrap();
    let notes = store
        .items(Some(&food.id), Some(Kind::Markdown), 10)
        .unwrap();
    assert_eq!(notes.len(), 1);
    assert!(f
        .space
        .resolve(notes[0].path.as_ref().unwrap())
        .unwrap()
        .is_file());
}

#[test]
fn a_tool_cannot_read_across_into_another_robot() {
    let (_f, store, coding) = seeded_archive();
    let embedder = HashEmbedder::default();
    let mine = store
        .items(Some(&coding), None, 20)
        .unwrap()
        .into_iter()
        .find(|i| i.title == "lifetimes")
        .unwrap()
        .id;
    let food = store.agent_by_slug("food").unwrap().unwrap();

    let ctx = rustagent::tools::Ctx {
        store: &store,
        embedder: &embedder,
        agent_id: Some(food.id.clone()),
    };
    let line = rustagent::tools::run(&ctx, "read_item", &json!({ "id": mine }));
    assert!(line.starts_with("REJECTED:"), "{line}");

    // The same call from the owner is fine.
    let ctx = rustagent::tools::Ctx {
        store: &store,
        embedder: &embedder,
        agent_id: Some(coding.clone()),
    };
    assert!(
        rustagent::tools::run(&ctx, "read_item", &json!({ "id": mine })).contains("borrow checker")
    );
}

#[test]
fn search_all_reaches_every_robot_and_names_the_owner() {
    let (_f, store, coding) = seeded_archive();
    let embedder = HashEmbedder::default();
    let food = store.agent_by_slug("food").unwrap().unwrap();
    store
        .add(NewItem {
            agent_id: Some(food.id.clone()),
            kind: Some(Kind::Note),
            title: "congee".into(),
            body: "congee for the borrow checker crowd: rice, stock, ginger".into(),
            source_path: None,
            role: String::new(),
            meta: None,
        })
        .unwrap();

    // It is the coding robot's turn. Its own search stays at home; the
    // unified one finds the galley's note and says whose it is.
    let ctx = rustagent::tools::Ctx {
        store: &store,
        embedder: &embedder,
        agent_id: Some(coding.clone()),
    };
    let own = rustagent::tools::run(
        &ctx,
        "search_context",
        &json!({ "query": "congee", "mode": "bm25" }),
    );
    assert!(own.starts_with("NOTHING FOUND"), "{own}");
    let all = rustagent::tools::run(
        &ctx,
        "search_all",
        &json!({ "query": "borrow checker", "mode": "bm25" }),
    );
    assert!(all.starts_with("2 HITS ACROSS ALL ROBOTS"), "{all}");
    assert!(all.contains("(EMBER)"), "{all}");
    assert!(all.contains("(BYTE, THIS ROBOT)"), "{all}");
    assert!(all.contains("congee"), "{all}");

    // Read-only: the unified search cannot be used to reach a row.
    let theirs = all
        .lines()
        .find(|l| l.contains("(EMBER)"))
        .and_then(|l| l.trim_start_matches('#').split(' ').next())
        .and_then(|n| n.parse::<i64>().ok())
        .unwrap();
    let line = rustagent::tools::run(&ctx, "read_item", &json!({ "id": theirs }));
    assert!(line.starts_with("REJECTED:"), "{line}");

    // With no query it is refused, not run.
    let none = rustagent::tools::run(&ctx, "search_all", &json!({}));
    assert!(none.starts_with("REJECTED: SEARCH_ALL"), "{none}");
    assert_eq!(
        rustagent::tools::label("search_all", &json!({ "query": "pork" })),
        "SEARCH_ALL PORK"
    );
}

#[test]
fn an_unknown_tool_is_answered_rather_than_raised() {
    let f = fixture();
    let store = f.store();
    let embedder = HashEmbedder::default();
    let ctx = rustagent::tools::Ctx {
        store: &store,
        embedder: &embedder,
        agent_id: None,
    };
    let line = rustagent::tools::run(&ctx, "launch_the_missiles", &json!({}));
    assert!(line.starts_with("REJECTED: NO TOOL"), "{line}");
    assert!(line.contains("SEARCH_CONTEXT"));
}

#[test]
fn a_model_that_only_ever_calls_tools_is_cut_off_rather_than_spinning() {
    let f = fixture();
    let store = f.store();
    let embedder = HashEmbedder::default();
    let brain = ScriptBrain::new(
        (0..20)
            .map(|_| ScriptBrain::calls("get_time", json!({})))
            .collect(),
    );
    let turn = Harness::new(&store, &embedder, &brain)
        .turn(Some("jarvis"), "what time is it?")
        .unwrap();

    assert_eq!(brain.calls_made(), rustagent::harness::MAX_STEPS + 1);
    assert!(!turn.reply.is_empty());
}

#[test]
fn a_robot_is_summoned_by_what_it_holds_not_by_what_it_was_asked() {
    let f = fixture();
    let backend = f.backend();

    // A name no keyword list has ever heard of: nothing claims it, so the
    // general robot takes it and says it is not confident.
    let prompt = "what did I say about Reginald?";
    let cold = ok(&backend.handle(&json!({ "op": "route", "text": prompt }))).clone();
    assert_eq!(cold["agent"]["slug"], json!("jarvis"));
    assert_eq!(cold["confident"], json!(false));

    // File a note about Reginald with the galley, and the galley answers.
    ok(&backend.handle(&json!({
        "op": "item.add", "agent": "food", "kind": "markdown", "title": "Reginald",
        "body": "Reginald is the sourdough starter. Feed him on Sundays."
    })));
    let warm = ok(&backend.handle(&json!({ "op": "route", "text": prompt }))).clone();
    assert_eq!(warm["agent"]["slug"], json!("food"));
    assert_eq!(warm["confident"], json!(true));
    assert!(warm["agent"]["why"]
        .as_array()
        .unwrap()
        .iter()
        .any(|w| w == "archive"));

    // A wrong route must not be able to entrench itself: three turns of
    // transcript on another robot are not evidence about anything.
    for _ in 0..3 {
        ok(&backend.handle(&json!({ "op": "chat", "agent": "writing", "text": prompt })));
    }
    let after = ok(&backend.handle(&json!({ "op": "route", "text": prompt }))).clone();
    assert_eq!(
        after["agent"]["slug"],
        json!("food"),
        "the transcript voted"
    );

    // And the chat path routes the same way the route op said it would.
    let turn = ok(&backend.handle(&json!({ "op": "chat", "text": prompt }))).clone();
    assert_eq!(turn["agent"]["slug"], json!("food"));
}

// -------------------------------------------------------------- protocol ---

fn ok(reply: &Value) -> &Value {
    assert_eq!(reply["ok"], json!(true), "{reply}");
    &reply["data"]
}

#[test]
fn the_protocol_answers_every_op_it_advertises() {
    let f = fixture();
    let backend = f.backend();
    for op in rustagent::OPS {
        let reply =
            backend.handle(&json!({ "op": op, "text": "hello", "query": "hello", "id": 1 }));
        assert!(reply.get("ok").is_some(), "{op} answered nothing");
        assert_eq!(reply["op"], json!(op));
    }
    // And refuses one it does not.
    let bad = backend.handle(&json!({ "op": "drop.everything" }));
    assert_eq!(bad["ok"], json!(false));
    assert!(bad["error"].as_str().unwrap().contains("unknown op"));
}

#[test]
fn health_says_where_the_prompts_would_go() {
    let f = fixture();
    let backend = f.backend();
    let data = ok(&backend.handle(&json!({ "op": "health" }))).clone();
    assert_eq!(data["online"], json!(false));
    assert_eq!(data["embed_model"], json!("hash-256"));
    assert!(data["root"]
        .as_str()
        .unwrap()
        .contains(f.space.root().file_name().unwrap().to_str().unwrap()));
}

#[test]
fn a_chat_with_no_agent_picks_one_and_says_which() {
    let f = fixture();
    let backend = f.backend();

    let data = ok(&backend.handle(&json!({
        "op": "chat", "text": "what should I cook for dinner?"
    })))
    .clone();
    assert_eq!(data["agent"]["slug"], json!("food"));
    assert_eq!(data["routed"], json!(true));
    assert_eq!(data["confident"], json!(true));
    // Offline is honest about being offline rather than inventing an answer.
    assert!(data["reply"].as_str().unwrap().starts_with("OFFLINE"));
    assert_eq!(data["model"], json!("OFFLINE"));
}

#[test]
fn a_chat_with_an_agent_stays_on_that_agent() {
    let f = fixture();
    let backend = f.backend();
    let data = ok(&backend.handle(&json!({
        "op": "chat", "agent": "security", "text": "what should I cook for dinner?"
    })))
    .clone();
    assert_eq!(data["agent"]["slug"], json!("security"));
    assert_eq!(data["routed"], json!(false));
}

#[test]
fn the_page_op_gives_the_client_gallery_markdown_and_files_with_real_paths() {
    let f = fixture();
    let backend = f.backend();
    let photo = f.loose_file("cat.png", b"pixels");
    let doc = f.loose_file("notes.md", b"# heading\nbody text");
    let blob = f.loose_file("data.bin", &[0u8, 1, 2, 3]);

    for path in [&photo, &doc, &blob] {
        let reply = backend.handle(&json!({
            "op": "item.add", "agent": "vision", "path": path.to_string_lossy()
        }));
        ok(&reply);
    }

    let page = ok(&backend.handle(&json!({ "op": "page", "agent": "vision" }))).clone();
    assert_eq!(page["agent"]["slug"], json!("vision"));
    assert_eq!(page["gallery"].as_array().unwrap().len(), 1);
    assert_eq!(page["markdowns"].as_array().unwrap().len(), 1);
    assert_eq!(page["files"].as_array().unwrap().len(), 1);

    // The gallery carries an absolute path, because LOVE has to open the file.
    let abs = page["gallery"][0]["abs"].as_str().unwrap();
    assert!(std::path::Path::new(abs).is_file());
    assert!(page["gallery"][0]["path"]
        .as_str()
        .unwrap()
        .starts_with("agents/"));
    assert!(page["folder"].as_str().unwrap().contains("agents/"));

    // A text file's contents were read in, so it is searchable by its words.
    let hits = ok(&backend.handle(&json!({
        "op": "search", "agent": "vision", "query": "heading", "mode": "bm25"
    })))
    .clone();
    assert_eq!(hits["hits"].as_array().unwrap().len(), 1);
}

#[test]
fn the_route_op_explains_itself() {
    let f = fixture();
    let backend = f.backend();
    let data = ok(&backend.handle(&json!({
        "op": "route", "text": "the compiler threw a segfault"
    })))
    .clone();
    assert_eq!(data["agent"]["slug"], json!("coding"));
    assert!(!data["ranked"].as_array().unwrap().is_empty());
    assert!(data["agent"]["why"]
        .as_array()
        .unwrap()
        .iter()
        .any(|w| w == "segfault"));
}

#[test]
fn search_defaults_to_hybrid_and_honours_the_mode_it_is_given() {
    let f = fixture();
    let backend = f.backend();
    ok(&backend.handle(&json!({
        "op": "item.add", "agent": "food", "kind": "note",
        "title": "stock", "body": "simmer the bones for six hours"
    })));

    for (mode, expect) in [("", "hybrid"), ("bm25", "bm25"), ("semantic", "semantic")] {
        let data = ok(&backend.handle(&json!({
            "op": "search", "agent": "food", "query": "simmer bones", "mode": mode
        })))
        .clone();
        assert_eq!(data["mode"], json!(expect));
        assert_eq!(data["hits"].as_array().unwrap().len(), 1, "mode {mode}");
    }
}

#[test]
fn a_robot_can_be_created_and_deleted_and_takes_its_context_with_it() {
    let f = fixture();
    let backend = f.backend();
    let made = ok(&backend.handle(&json!({
        "op": "agents.create", "slug": "garden", "name": "ivy2", "kind": "garden",
        "sprite": "ivy", "keywords": "plant soil water prune"
    })))
    .clone();
    let id = made["id"].as_str().unwrap().to_string();
    assert_eq!(made["name"], json!("IVY2"));
    assert_eq!(made["space"], json!(format!("agents/{id}")));

    ok(&backend.handle(&json!({
        "op": "item.add", "agent": "garden", "kind": "note", "body": "prune the fig"
    })));

    // A second robot with the same slug is refused rather than shadowing it.
    let clash = backend.handle(&json!({ "op": "agents.create", "slug": "garden" }));
    assert_eq!(clash["ok"], json!(false));

    ok(&backend.handle(&json!({ "op": "agents.delete", "agent": "garden" })));
    let stats = ok(&backend.handle(&json!({ "op": "stats" }))).clone();
    assert_eq!(stats["agents"], json!(rustagent::ROSTER.len()));
    let gone = backend.handle(&json!({ "op": "page", "agent": "garden" }));
    assert_eq!(gone["ok"], json!(false));
}

#[test]
fn the_transcript_can_be_read_and_cleared_per_robot() {
    let f = fixture();
    let backend = f.backend();
    for text in ["one", "two"] {
        ok(&backend.handle(&json!({ "op": "chat", "agent": "jarvis", "text": text })));
    }
    ok(&backend.handle(&json!({ "op": "chat", "agent": "food", "text": "three" })));

    let jarvis = ok(&backend.handle(&json!({ "op": "messages", "agent": "jarvis" }))).clone();
    assert_eq!(jarvis.as_array().unwrap().len(), 4, "two turns, both sides");

    let cleared =
        ok(&backend.handle(&json!({ "op": "messages.clear", "agent": "jarvis" }))).clone();
    assert_eq!(cleared["cleared"], json!(4));
    let food = ok(&backend.handle(&json!({ "op": "messages", "agent": "food" }))).clone();
    assert_eq!(
        food.as_array().unwrap().len(),
        2,
        "the other robot is untouched"
    );
}

#[test]
fn a_reopened_space_still_knows_everything() {
    let f = fixture();
    {
        let backend = f.backend();
        ok(&backend.handle(&json!({
            "op": "item.add", "agent": "coding", "kind": "note",
            "title": "sqlite", "body": "WAL keeps readers going while one writes"
        })));
    }
    // A second process, the same folder.
    let backend = f.backend();
    let hits = ok(&backend.handle(&json!({
        "op": "search", "agent": "coding", "query": "WAL readers", "mode": "hybrid"
    })))
    .clone();
    assert_eq!(hits["hits"][0]["item"]["title"], json!("sqlite"));
}
