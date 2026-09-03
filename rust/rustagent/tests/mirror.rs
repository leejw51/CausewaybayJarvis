//! A robot's folder stands on its own: its own database, the three plain
//! mirrors, the papers — and a search scoped to the robot reads *its* database,
//! not the global index. Every test here works on real files in a scratch space.

use serde_json::json;

use rustagent::context::{Kind, NewItem};
use rustagent::embed::HashEmbedder;
use rustagent::paper::{Canvas, VOID};
use rustagent::proto::Backend;
use rustagent::search::{self, Mode, Scope};
use rustagent::space::{Space, CSV_FILE, JSONL_FILE, MARKDOWN_FILE, OWN_DB_FILE, PAPER_SIZE};
use rustagent::store::Store;

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
    fn own_db(&self, space_dir: &str) -> rusqlite::Connection {
        rusqlite::Connection::open(
            self.space
                .resolve(&format!("{space_dir}/{OWN_DB_FILE}"))
                .unwrap(),
        )
        .unwrap()
    }
    fn read(&self, rel: &str) -> String {
        std::fs::read_to_string(self.space.resolve(rel).unwrap()).unwrap_or_default()
    }
    /// A real PNG outside the space: a square with a bright blob in the top
    /// band, the way a robot sprite has a head.
    fn png(&self, name: &str, w: u32, h: u32, blob: [u8; 3]) -> std::path::PathBuf {
        let mut c = Canvas::new(w, h, [0, 0, 0]);
        for i in 0..c.px.len() / 4 {
            c.px[i * 4 + 3] = 0;
        }
        for y in (h / 8)..(h / 2) {
            for x in (w / 4)..(3 * w / 4) {
                c.put(x as i64, y as i64, blob);
            }
        }
        let path = self.space.root().join("..").join(name);
        let path = std::fs::canonicalize(path.parent().unwrap())
            .unwrap()
            .join(name);
        std::fs::write(&path, c.encode_png().unwrap()).unwrap();
        path
    }
}

fn count(conn: &rusqlite::Connection, sql: &str) -> i64 {
    conn.query_row(sql, [], |r| r.get(0)).unwrap()
}

#[test]
fn filing_writes_the_own_database_and_all_three_mirrors() {
    let f = fixture();
    let store = f.store();
    let food = store.agent_by_slug("food").unwrap().unwrap();

    let item = store
        .add(NewItem {
            agent_id: Some(food.id.clone()),
            kind: Some(Kind::Note),
            title: "pork belly".into(),
            body: "slow roast, score the skin, salt it the night before".into(),
            ..Default::default()
        })
        .unwrap();

    // The own database has the same row under the same id, and the robot.
    let own = f.own_db(&food.space);
    assert_eq!(count(&own, "SELECT COUNT(*) FROM agents"), 1);
    let title: String = own
        .query_row("SELECT title FROM items WHERE id = ?1", [item.id], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(title, "pork belly");
    // …with its FTS index in step: BM25 works inside the folder alone.
    assert_eq!(
        count(
            &own,
            "SELECT COUNT(*) FROM items_fts WHERE items_fts MATCH '\"pork\"*'"
        ),
        1
    );

    let jsonl = f.read(&format!("{}/{JSONL_FILE}", food.space));
    let line: serde_json::Value = serde_json::from_str(jsonl.lines().last().unwrap()).unwrap();
    assert_eq!(line["event"], "add");
    assert_eq!(line["id"], item.id);
    assert_eq!(line["title"], "pork belly");

    let csv = f.read(&format!("{}/{CSV_FILE}", food.space));
    assert!(csv.starts_with("id,agent_id,kind,role,title,body"));
    assert!(csv.contains("\"pork belly\""));

    let md = f.read(&format!("{}/{MARKDOWN_FILE}", food.space));
    assert!(md.starts_with(&format!("# {} — {}", food.name, food.role)));
    assert!(md.contains(&food.id), "the page names the GUID");
    assert!(md.contains("### #1 pork belly") || md.contains("pork belly"));
    assert!(md.contains("| notes | 1 |"));
}

#[test]
fn the_global_space_keeps_the_same_mirrors_beside_the_global_database() {
    let f = fixture();
    let store = f.store();
    store
        .add(NewItem {
            body: "a thought filed with nobody chosen".into(),
            ..Default::default()
        })
        .unwrap();
    assert!(f
        .read(&format!("global/{JSONL_FILE}"))
        .contains("nobody chosen"));
    assert!(f
        .read(&format!("global/{CSV_FILE}"))
        .contains("nobody chosen"));
    assert!(f
        .read(&format!("global/{MARKDOWN_FILE}"))
        .starts_with("# Global space"));
    // The global space has no `agent.db`: robots.db is its database.
    assert!(!f
        .space
        .resolve(&format!("global/{OWN_DB_FILE}"))
        .unwrap()
        .exists());
}

#[test]
fn a_scoped_search_reads_the_robots_own_database() {
    let f = fixture();
    let store = f.store();
    let embedder = HashEmbedder::default();
    let coding = store.agent_by_slug("coding").unwrap().unwrap();
    store
        .add(NewItem {
            agent_id: Some(coding.id.clone()),
            body: "the borrow checker".into(),
            ..Default::default()
        })
        .unwrap();

    // A row that exists only in the folder — as if the folder had been
    // carried over from another machine — is found by a search scoped to
    // that robot, and by nothing else.
    let own = f.own_db(&coding.space);
    own.execute(
        "INSERT INTO items (id, agent_id, kind, title, body, created_at, updated_at)
         VALUES (9001, ?1, 'note', 'smuggled', 'a lifetime elision rule', 1, 1)",
        [&coding.id],
    )
    .unwrap();
    drop(own);

    let scoped = search::search(
        &store,
        &embedder,
        "lifetime elision",
        &Scope::Agent(coding.id.clone()),
        Mode::Bm25,
        5,
    )
    .unwrap();
    assert_eq!(scoped.len(), 1);
    assert_eq!(scoped[0].item.id, 9001);

    let global = search::search(
        &store,
        &embedder,
        "lifetime elision",
        &Scope::All,
        Mode::Bm25,
        5,
    )
    .unwrap();
    assert!(global.is_empty(), "the global index never saw that row");

    // And the vectors are in the folder too: a semantic search scoped to the
    // robot finds what was filed through the store.
    search::reindex(&store, &embedder, Some(&coding.id)).unwrap();
    let own = f.own_db(&coding.space);
    assert!(count(&own, "SELECT COUNT(*) FROM embeddings") >= 1);
    let by_meaning = search::search(
        &store,
        &embedder,
        "borrow checker",
        &Scope::Agent(coding.id.clone()),
        Mode::Semantic,
        5,
    )
    .unwrap();
    assert_eq!(by_meaning[0].item.body, "the borrow checker");
}

#[test]
fn nobody_chosen_searches_every_robot_at_once() {
    let f = fixture();
    let backend = f.backend();
    let coding = backend.store.agent_by_slug("coding").unwrap().unwrap();
    let food = backend.store.agent_by_slug("food").unwrap().unwrap();
    for (who, body) in [
        (&coding.id, "a mutex guards the pan"),
        (&food.id, "sear the pork in the pan"),
    ] {
        backend.handle(&json!({ "op": "item.add", "agent": who, "body": body }));
    }
    backend.handle(&json!({ "op": "item.add", "body": "the pan is in the global drawer" }));

    let reply = backend.handle(&json!({ "op": "search", "query": "pan", "mode": "bm25" }));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["data"]["scope"], "all");
    let hits = reply["data"]["hits"].as_array().unwrap();
    let owners: std::collections::HashSet<String> = hits
        .iter()
        .map(|h| h["agent_name"].as_str().unwrap().to_string())
        .collect();
    assert!(owners.contains(&coding.name), "{owners:?}");
    assert!(owners.contains(&food.name), "{owners:?}");
    assert!(owners.contains("GLOBAL"), "{owners:?}");

    // Naming a robot narrows it to that robot's own database.
    let one = backend.handle(&json!({ "op": "search", "query": "pan", "agent": "food" }));
    let hits = one["data"]["hits"].as_array().unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0]["agent_name"], food.name);
    assert_eq!(one["data"]["scope"]["agent"], food.id);

    // And `global` by name is the leftovers alone.
    let leftovers = backend.handle(&json!({ "op": "search", "query": "pan", "agent": "global" }));
    assert_eq!(leftovers["data"]["scope"], "global");
    assert_eq!(leftovers["data"]["hits"].as_array().unwrap().len(), 1);
}

#[test]
fn deleting_and_clearing_reach_the_folder_too() {
    let f = fixture();
    let store = f.store();
    let food = store.agent_by_slug("food").unwrap().unwrap();
    let note = store
        .add(NewItem {
            agent_id: Some(food.id.clone()),
            title: "congee".into(),
            body: "rice, stock, ginger".into(),
            ..Default::default()
        })
        .unwrap();
    store
        .add_message(Some(&food.id), "user", "how long?")
        .unwrap();
    store
        .add_message(Some(&food.id), "assistant", "two hours")
        .unwrap();

    assert!(store.delete_item(note.id).unwrap());
    let own = f.own_db(&food.space);
    assert_eq!(
        count(&own, "SELECT COUNT(*) FROM items WHERE kind='note'"),
        0
    );
    assert_eq!(
        count(&own, "SELECT COUNT(*) FROM items WHERE kind='message'"),
        2
    );
    let jsonl = f.read(&format!("{}/{JSONL_FILE}", food.space));
    let last: serde_json::Value = serde_json::from_str(jsonl.lines().last().unwrap()).unwrap();
    assert_eq!(last["event"], "delete");
    assert_eq!(last["id"], note.id);
    // The log keeps the add; the page does not.
    assert!(jsonl.contains("congee"));
    assert!(!f
        .read(&format!("{}/{MARKDOWN_FILE}", food.space))
        .contains("congee"));

    assert_eq!(store.clear_messages(Some(&food.id)).unwrap(), 2);
    assert_eq!(count(&own, "SELECT COUNT(*) FROM items"), 0);
    assert!(f
        .read(&format!("{}/{JSONL_FILE}", food.space))
        .contains("clear_messages"));
}

#[test]
fn export_rebuilds_a_folder_that_was_emptied_and_boot_notices_by_itself() {
    let f = fixture();
    let food_space;
    {
        let store = f.store();
        let food = store.agent_by_slug("food").unwrap().unwrap();
        food_space = food.space.clone();
        for body in ["one", "two", "three"] {
            store
                .add(NewItem {
                    agent_id: Some(food.id.clone()),
                    body: body.into(),
                    ..Default::default()
                })
                .unwrap();
        }
        search::reindex(&store, &HashEmbedder::default(), Some(&food.id)).unwrap();
    }
    // Somebody deletes the mirrors and the own database.
    for name in [OWN_DB_FILE, JSONL_FILE, CSV_FILE, MARKDOWN_FILE] {
        let p = f.space.resolve(&format!("{food_space}/{name}")).unwrap();
        if p.exists() {
            std::fs::remove_file(&p).unwrap();
        }
    }
    // A fresh open — what `agentd` does at boot — puts them back.
    let store = f.store();
    let synced = store.sync().unwrap();
    assert!(synced.iter().any(|e| e.space == food_space), "{synced:?}");
    let own = f.own_db(&food_space);
    assert_eq!(count(&own, "SELECT COUNT(*) FROM items"), 3);
    assert_eq!(count(&own, "SELECT COUNT(*) FROM embeddings"), 3);
    assert_eq!(
        f.read(&format!("{food_space}/{JSONL_FILE}"))
            .lines()
            .count(),
        3
    );
    assert_eq!(
        f.read(&format!("{food_space}/{CSV_FILE}")).lines().count(),
        4
    );
    assert!(f
        .read(&format!("{food_space}/{MARKDOWN_FILE}"))
        .contains("| notes | 3 |"));

    // Explicitly, through the protocol, for everybody.
    let backend = Backend::offline(store);
    let reply = backend.handle(&json!({ "op": "export" }));
    assert_eq!(reply["ok"], true, "{reply}");
    let done = reply["data"]["exported"].as_array().unwrap();
    assert!(
        done.len() >= 9,
        "every robot and the global space: {}",
        done.len()
    );
    assert!(done.iter().any(|e| e["space"] == "global"));
    let food_report = done.iter().find(|e| e["space"] == food_space).unwrap();
    assert_eq!(food_report["items"], 3);
    assert_eq!(food_report["embeddings"], 3);
}

#[test]
fn the_gallery_op_lists_every_photo_by_the_folder_that_holds_it() {
    let f = fixture();
    let backend = f.backend();
    let coding = backend.store.agent_by_slug("coding").unwrap().unwrap();
    let food = backend.store.agent_by_slug("food").unwrap().unwrap();
    let a = f.png("a.png", 16, 16, [255, 0, 0]);
    let b = f.png("b.png", 16, 16, [0, 255, 0]);
    let c = f.png("c.png", 16, 16, [0, 0, 255]);
    for (who, path) in [(&coding.id, &a), (&food.id, &b), (&food.id, &c)] {
        let r = backend.handle(&json!({ "op": "item.add", "agent": who, "path": path }));
        assert_eq!(r["ok"], true, "{r}");
    }

    let all = backend.handle(&json!({ "op": "gallery" }));
    assert_eq!(all["ok"], true, "{all}");
    assert_eq!(all["data"]["total"], 3);
    let groups = all["data"]["groups"].as_array().unwrap();
    let food_group = groups
        .iter()
        .find(|g| g["agent"]["slug"] == "food")
        .unwrap();
    assert_eq!(food_group["count"], 2);
    assert!(food_group["folder"].as_str().unwrap().ends_with("/photos"));
    for photo in food_group["photos"].as_array().unwrap() {
        assert!(std::path::Path::new(photo["abs"].as_str().unwrap()).is_file());
    }
    assert!(groups
        .iter()
        .any(|g| g["agent"].is_null() && g["space"] == "global"));

    let one = backend.handle(&json!({ "op": "gallery", "agent": "coding" }));
    assert_eq!(one["data"]["total"], 1);
    assert_eq!(one["data"]["groups"].as_array().unwrap().len(), 1);
}

#[test]
fn a_paper_is_one_square_png_in_the_robots_paper_folder() {
    let f = fixture();
    let backend = f.backend();
    let food = backend.store.agent_by_slug("food").unwrap().unwrap();
    let photo = f.png("dinner.png", 32, 32, [200, 40, 40]);
    backend
        .handle(&json!({ "op": "item.add", "agent": &food.id, "path": photo, "title": "dinner" }));
    backend.handle(
        &json!({ "op": "item.add", "agent": &food.id, "kind": "markdown",
        "title": "congee", "body": "# Congee\nrice, stock, ginger" }),
    );
    backend
        .store
        .add_message(Some(&food.id), "user", "what should I cook?")
        .unwrap();
    backend
        .store
        .add_message(Some(&food.id), "assistant", "congee, obviously")
        .unwrap();
    let sprite = f.png("sprite.png", 64, 64, [30, 220, 90]);

    let reply = backend.handle(&json!({ "op": "paper", "agent": "food", "sprite": sprite }));
    assert_eq!(reply["ok"], true, "{reply}");
    let saved = &reply["data"];
    assert_eq!(saved["width"], PAPER_SIZE);
    assert_eq!(saved["height"], PAPER_SIZE);
    let rel = saved["path"].as_str().unwrap();
    assert!(
        rel.starts_with(&format!("{}/paper/food-", food.space)),
        "{rel}"
    );
    let abs = std::path::Path::new(saved["abs"].as_str().unwrap());
    assert!(abs.is_file());

    let img = Canvas::decode_png(abs).unwrap();
    assert_eq!((img.w, img.h), (PAPER_SIZE, PAPER_SIZE));
    assert!(
        img.ink(VOID) > 40_000,
        "a paper with almost nothing drawn on it"
    );
    // The head sprite was pasted: the head box carries the sprite's colour.
    let mut green = 0;
    for y in 28..204u32 {
        for x in 28..204u32 {
            let p = img.get(x, y);
            if p[1] > 180 && p[0] < 80 {
                green += 1;
            }
        }
    }
    assert!(
        green > 1000,
        "the head was not drawn ({green} green pixels)"
    );

    // The paper is not an item — the gallery still has one photo — but the
    // page lists it on its paper shelf, newest first, with a real path.
    let page = backend.handle(&json!({ "op": "page", "agent": "food" }));
    assert_eq!(page["data"]["gallery"].as_array().unwrap().len(), 1);
    let papers = page["data"]["papers"].as_array().unwrap();
    assert_eq!(papers.len(), 1);
    assert_eq!(papers[0]["kind"], "paper");
    assert_eq!(papers[0]["abs"], saved["abs"]);

    // A second paper gets its own name, and the global space can have one
    // too, drawn without a sprite.
    let again = backend.handle(&json!({ "op": "paper", "agent": "food" }));
    assert_ne!(again["data"]["abs"], saved["abs"]);
    let global = backend.handle(&json!({ "op": "paper" }));
    assert_eq!(global["ok"], true, "{global}");
    assert!(global["data"]["path"]
        .as_str()
        .unwrap()
        .starts_with("global/paper/global-"));

    // `out` puts it wherever it is told.
    let out = f.space.root().join("..").join("elsewhere.png");
    let placed = backend.handle(&json!({ "op": "paper", "agent": "food", "out": out }));
    assert_eq!(placed["ok"], true, "{placed}");
    assert!(out.is_file());
}

#[test]
fn an_item_op_takes_its_row_as_item_because_id_is_the_frame_over_a_socket() {
    let f = fixture();
    let backend = f.backend();
    let added = backend.handle(&json!({ "op": "item.add", "body": "to be read and gone" }));
    let row = added["data"]["id"].as_i64().unwrap();
    // A stamped frame: `id` is the client's number, `item` the row.
    let read = backend.handle(&json!({ "id": 99, "op": "item.read", "item": row }));
    assert_eq!(read["ok"], true, "{read}");
    assert_eq!(read["data"]["body"], "to be read and gone");
    let gone = backend.handle(&json!({ "id": 100, "op": "item.delete", "item": row }));
    assert_eq!(gone["data"]["deleted"], true, "{gone}");
    // The old spelling still works where nothing stamps the request.
    let missing = backend.handle(&json!({ "op": "item.read", "id": row }));
    assert_eq!(missing["ok"], false);
    assert!(missing["error"].as_str().unwrap().contains("no item"));
}

#[test]
fn every_new_op_is_advertised_and_answers() {
    let f = fixture();
    let backend = f.backend();
    for op in ["gallery", "paper", "export"] {
        assert!(rustagent::proto::OPS.contains(&op), "{op} is not in OPS");
        let reply = backend.handle(&json!({ "op": op }));
        assert_eq!(reply["ok"], true, "{op}: {reply}");
    }
}

#[test]
fn a_failed_export_leaves_the_own_database_usable() {
    let f = fixture();
    let store = f.store();
    let food = store.agent_by_slug("food").unwrap().unwrap();
    store
        .add(NewItem {
            agent_id: Some(food.id.clone()),
            kind: Some(Kind::Note),
            title: "one".into(),
            body: "the first note".into(),
            source_path: None,
            role: String::new(),
            meta: None,
        })
        .unwrap();
    // The export's first statement inside its transaction is a bulk delete;
    // a trigger makes that one statement fail, after the transaction has
    // begun. RAISE(ABORT) backs out the statement and leaves the
    // transaction open — which is exactly what a cached connection must
    // not be left holding.
    store
        .with_conn(Some(&food.id), |c| {
            c.execute_batch(
                "CREATE TRIGGER boom BEFORE DELETE ON items
                 BEGIN SELECT RAISE(ABORT, 'boom'); END;",
            )?;
            Ok(())
        })
        .unwrap();
    let failed = store.export(Some(&food.id));
    assert!(
        failed
            .as_ref()
            .err()
            .map(|e| e.to_string().contains("boom"))
            .unwrap_or(false),
        "export should have failed on the trigger: {failed:?}"
    );
    store
        .with_conn(Some(&food.id), |c| {
            c.execute_batch("DROP TRIGGER boom")?;
            Ok(())
        })
        .unwrap();

    // The failure must not leave the connection inside a transaction: the
    // next row filed with this robot has to reach the file, where a fresh
    // reader can count it, and the next export has to go through.
    store
        .add(NewItem {
            agent_id: Some(food.id.clone()),
            kind: Some(Kind::Note),
            title: "two".into(),
            body: "the second note".into(),
            source_path: None,
            role: String::new(),
            meta: None,
        })
        .unwrap();
    let fresh = f.own_db(&food.space);
    assert_eq!(count(&fresh, "SELECT COUNT(*) FROM items"), 2);
    let report = store.export(Some(&food.id)).unwrap();
    assert_eq!(report.items, 2);
    assert_eq!(count(&fresh, "SELECT COUNT(*) FROM items"), 2);
}

#[test]
fn deleting_a_robot_lets_go_of_its_own_database() {
    let f = fixture();
    let store = f.store();
    let food = store.agent_by_slug("food").unwrap().unwrap();
    store
        .add(NewItem {
            agent_id: Some(food.id.clone()),
            kind: Some(Kind::Note),
            title: "note".into(),
            body: "before the robot goes".into(),
            source_path: None,
            role: String::new(),
            meta: None,
        })
        .unwrap();
    let open = store.own_open();
    assert!(open >= 1);

    assert!(store.delete_agent(&food.id).unwrap());
    assert_eq!(store.own_open(), open - 1, "the handle was kept");
    let err = store
        .with_conn(Some(&food.id), |_| Ok(()))
        .unwrap_err()
        .to_string();
    assert!(err.contains("no robot"), "{err}");
    // And the folder can go, nothing of ours still on it.
    std::fs::remove_dir_all(f.space.resolve(&food.space).unwrap()).unwrap();
    assert!(!f.space.resolve(&food.space).unwrap().exists());
    // Deleting twice is a plain `false`, not an error.
    assert!(!store.delete_agent(&food.id).unwrap());
}
