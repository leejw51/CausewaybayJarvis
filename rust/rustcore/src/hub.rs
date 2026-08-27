//! Pulling MLX checkpoints off the Hugging Face Hub.
//!
//! Files land in the standard `~/.cache/huggingface/hub` layout, so a repo
//! already fetched with `hf download` (or by any other tool) is reused instead
//! of downloaded twice.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::{anyhow, Context, Result};
use hf_hub::progress::{DownloadEvent, FileStatus, Progress, ProgressEvent, ProgressHandler};
use hf_hub::{HFClient, HFClientSync};

use crate::models::ModelSpec;

/// Everything the loader needs, resolved to concrete paths.
#[derive(Debug, Clone)]
pub struct ModelFiles {
    /// The snapshot directory the rest of the paths live under.
    pub root: PathBuf,
    pub config: PathBuf,
    pub tokenizer: PathBuf,
    pub tokenizer_config: Option<PathBuf>,
    pub chat_template: Option<PathBuf>,
    pub generation_config: Option<PathBuf>,
    /// Safetensors shards, in index order.
    pub weights: Vec<PathBuf>,
}

impl ModelFiles {
    /// Total size of the weight shards on disk.
    pub fn weight_bytes(&self) -> u64 {
        self.weights
            .iter()
            .filter_map(|p| std::fs::metadata(p).ok())
            .map(|m| m.len())
            .sum()
    }
}

/// A snapshot of an in-flight download, for the caller's progress bar.
#[derive(Debug, Clone, Default)]
pub struct DownloadProgress {
    pub files_total: usize,
    pub files_done: usize,
    pub bytes_total: u64,
    pub bytes_done: u64,
    /// The file that most recently made progress.
    pub current: Option<String>,
    pub finished: bool,
}

/// Glob patterns for the files an MLX text model actually needs — this skips
/// the `.gguf` / `original/` extras some repos carry alongside.
const WANTED: &[&str] = &["*.json", "*.jinja", "*.safetensors", "*.txt", "*.model"];

/// Read the token the same way the Python client does: `HF_TOKEN` first, then
/// the token file written by `hf auth login`.
pub fn token() -> Option<String> {
    if let Ok(t) = std::env::var("HF_TOKEN") {
        if !t.trim().is_empty() {
            return Some(t.trim().to_string());
        }
    }
    if let Ok(path) = std::env::var("HF_TOKEN_PATH") {
        if let Ok(t) = std::fs::read_to_string(path) {
            if !t.trim().is_empty() {
                return Some(t.trim().to_string());
            }
        }
    }
    let home = std::env::var("HF_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| default_cache_home());
    let t = std::fs::read_to_string(home.join("token")).ok()?;
    let t = t.trim();
    (!t.is_empty()).then(|| t.to_string())
}

fn default_cache_home() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".cache").join("huggingface")
}

/// Download (or reuse) the checkpoint and return the resolved file set.
///
/// `on_progress` is called from the download threads; keep it cheap.
pub fn fetch(
    spec: &ModelSpec,
    on_progress: impl Fn(DownloadProgress) + Send + Sync + 'static,
) -> Result<ModelFiles> {
    snapshot(spec, false, Some(Progress::new(Reporter::new(on_progress))))
}

/// Resolve an already-downloaded checkpoint without touching the network.
pub fn local(spec: &ModelSpec) -> Result<ModelFiles> {
    snapshot(spec, true, None)
}

fn snapshot(spec: &ModelSpec, local_only: bool, progress: Option<Progress>) -> Result<ModelFiles> {
    let (owner, name) = spec
        .repo
        .split_once('/')
        .ok_or_else(|| anyhow!("`{}` is not an org/name repository id", spec.repo))?;

    let mut builder =
        HFClient::builder().user_agent(concat!("causewaybay-jarvis/", env!("CARGO_PKG_VERSION")));
    if let Some(tok) = token() {
        builder = builder.token(tok);
    }
    let client = HFClientSync::from_inner(
        builder
            .build()
            .context("configuring the Hugging Face client")?,
    )
    .context("starting the Hugging Face client")?;

    let root = client
        .model(owner, name)
        .snapshot_download()
        .revision(spec.revision.clone())
        .allow_patterns(WANTED.iter().map(|s| s.to_string()).collect::<Vec<_>>())
        .local_files_only(local_only)
        .maybe_progress(progress)
        .send()
        .with_context(|| {
            if local_only {
                format!(
                    "`{}` is not in the local cache — run `rustcli pull` first",
                    spec.repo
                )
            } else {
                format!("downloading {}", spec.repo)
            }
        })?;

    resolve_files(&root)
}

/// Turn a snapshot directory into a [`ModelFiles`].
pub fn resolve_files(root: &Path) -> Result<ModelFiles> {
    let need = |name: &str| -> Result<PathBuf> {
        let p = root.join(name);
        p.is_file()
            .then_some(p)
            .ok_or_else(|| anyhow!("{name} missing from {}", root.display()))
    };
    let want = |name: &str| -> Option<PathBuf> {
        let p = root.join(name);
        p.is_file().then_some(p)
    };

    Ok(ModelFiles {
        config: need("config.json")?,
        tokenizer: need("tokenizer.json")?,
        tokenizer_config: want("tokenizer_config.json"),
        chat_template: want("chat_template.jinja"),
        generation_config: want("generation_config.json"),
        weights: weight_shards(root)?,
        root: root.to_path_buf(),
    })
}

/// Join a name from a downloaded index onto the snapshot directory, refusing
/// anything that would escape it.
///
/// The index is checkpoint-supplied data, and `Path::join` happily takes an
/// absolute path as a replacement for the base rather than a child of it. A
/// shard name is a plain file name — often in a subdirectory, never above one.
fn snapshot_relative(root: &Path, name: &str) -> Result<PathBuf> {
    use std::path::Component;

    let candidate = Path::new(name);
    let escapes = candidate
        .components()
        .any(|c| !matches!(c, Component::Normal(_)));
    if name.is_empty() || escapes {
        return Err(anyhow!(
            "`{name}` is not a plain path inside the checkpoint directory"
        ));
    }
    Ok(root.join(candidate))
}

/// Shard list, preferring the order in `model.safetensors.index.json` and
/// falling back to a sorted directory listing for single-file checkpoints.
fn weight_shards(root: &Path) -> Result<Vec<PathBuf>> {
    let index = root.join("model.safetensors.index.json");
    if index.is_file() {
        let text = std::fs::read_to_string(&index)?;
        let json: serde_json::Value = serde_json::from_str(&text)?;
        let map = json
            .get("weight_map")
            .and_then(|m| m.as_object())
            .ok_or_else(|| anyhow!("{} has no weight_map", index.display()))?;
        let mut names: Vec<&str> = map.values().filter_map(|v| v.as_str()).collect();
        names.sort_unstable();
        names.dedup();
        let mut out = Vec::with_capacity(names.len());
        for n in names {
            let p = snapshot_relative(root, n)?;
            if !p.is_file() {
                return Err(anyhow!("shard {n} listed in the index but not on disk"));
            }
            out.push(p);
        }
        return Ok(out);
    }

    let mut out: Vec<PathBuf> = std::fs::read_dir(root)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "safetensors"))
        .collect();
    out.sort();
    if out.is_empty() {
        return Err(anyhow!("no .safetensors weights in {}", root.display()));
    }
    Ok(out)
}

/// Bridges hf-hub's per-file deltas to a single running total.
struct Reporter<F> {
    sink: F,
    state: Mutex<State>,
}

/// What has been heard so far about a download in flight.
///
/// Kept as a state machine of its own, separate from the event plumbing, so
/// that the awkward parts are testable without constructing hub events: the
/// Hub reports a `Start` per batch rather than once for the whole pull, and it
/// repeats a completed file in every later `Progress`, so neither the totals
/// nor the completed count can simply be assigned or incremented.
#[derive(Default)]
struct State {
    /// The largest totals any `Start` has claimed. They only ever grow: a
    /// later `Start` describing one small file must not shrink the job.
    start_files: usize,
    start_bytes: u64,
    /// Bytes fetched, and bytes expected, per file.
    per_file: HashMap<String, u64>,
    per_file_total: HashMap<String, u64>,
    /// Which files have finished — a set, because a file that completed stays
    /// `Complete` in every subsequent event and counting those said ten of
    /// one.
    done: std::collections::HashSet<String>,
}

impl State {
    fn start(&mut self, files: usize, bytes: u64) {
        self.start_files = self.start_files.max(files);
        self.start_bytes = self.start_bytes.max(bytes);
    }

    fn file(&mut self, name: &str, done_bytes: u64, total_bytes: u64, complete: bool) {
        // `bytes_completed` is cumulative per file, so overwrite rather than add.
        self.per_file.insert(name.to_string(), done_bytes);
        if total_bytes > 0 {
            self.per_file_total.insert(name.to_string(), total_bytes);
        }
        if complete {
            self.done.insert(name.to_string());
            if total_bytes > 0 {
                self.per_file.insert(name.to_string(), total_bytes);
            }
        }
    }

    fn snapshot(&self, current: Option<String>, finished: bool) -> DownloadProgress {
        let bytes_done: u64 = self.per_file.values().sum();
        // The per-file totals are the authority once they arrive; the `Start`
        // figure is a lower bound, and neither may be less than what has
        // already been fetched or the bar reads over a hundred per cent.
        let bytes_total = self
            .start_bytes
            .max(self.per_file_total.values().sum())
            .max(bytes_done);
        let files_done = self.done.len();
        let files_total = self
            .start_files
            .max(self.per_file_total.len())
            .max(files_done);
        DownloadProgress {
            files_total,
            files_done,
            bytes_total,
            bytes_done,
            current,
            finished,
        }
    }
}

impl<F: Fn(DownloadProgress) + Send + Sync> Reporter<F> {
    fn new(sink: F) -> Self {
        Self {
            sink,
            state: Mutex::new(State::default()),
        }
    }
}

impl<F: Fn(DownloadProgress) + Send + Sync> ProgressHandler for Reporter<F> {
    fn on_progress(&self, event: &ProgressEvent) {
        let ProgressEvent::Download(event) = event else {
            return;
        };
        let mut st = self.state.lock().unwrap();
        let mut current = None;
        let mut finished = false;

        match event {
            DownloadEvent::Start {
                total_files,
                total_bytes,
            } => st.start(*total_files, *total_bytes),
            DownloadEvent::Progress { files } => {
                for f in files {
                    st.file(
                        &f.filename,
                        f.bytes_completed,
                        f.total_bytes,
                        f.status == FileStatus::Complete,
                    );
                    current = Some(f.filename.clone());
                }
            }
            DownloadEvent::AggregateProgress { .. } => {}
            DownloadEvent::Complete => finished = true,
        }

        let snapshot = st.snapshot(current, finished);
        drop(st);
        (self.sink)(snapshot);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Hub repeats a completed file in every later event and announces a
    /// `Start` per batch rather than once for the pull. Both of those used to
    /// reach the progress bar as-is, which read `473.6 MiB / 385 B` and
    /// `10 of 1` on a real download.
    #[test]
    fn progress_never_exceeds_its_own_totals() {
        let mut st = State::default();

        // A first batch that knows about one small file.
        st.start(1, 385);
        st.file("config.json", 385, 385, true);

        // Then the shards arrive, in a second batch, and every event repeats
        // the file that already finished.
        st.start(1, 8_000_000_000);
        for step in 1..=10 {
            st.file("config.json", 385, 385, true);
            st.file("model-00001.safetensors", step * 100_000_000, 8_000_000_000, false);
            let snap = st.snapshot(None, false);
            assert!(
                snap.bytes_done <= snap.bytes_total,
                "{} bytes of {}",
                snap.bytes_done,
                snap.bytes_total
            );
            assert!(
                snap.files_done <= snap.files_total,
                "{} files of {}",
                snap.files_done,
                snap.files_total
            );
        }

        // One file finished, once, however many times it was mentioned.
        let snap = st.snapshot(None, false);
        assert_eq!(snap.files_done, 1);
        assert_eq!(snap.files_total, 2);
        assert_eq!(snap.bytes_total, 8_000_000_385);
        assert_eq!(snap.bytes_done, 1_000_000_385);
    }

    /// A total that only ever arrives per-file still adds up.
    #[test]
    fn totals_can_come_entirely_from_the_files() {
        let mut st = State::default();
        st.file("a.safetensors", 50, 100, false);
        st.file("b.safetensors", 100, 100, true);
        let snap = st.snapshot(None, false);
        assert_eq!(snap.bytes_total, 200);
        assert_eq!(snap.bytes_done, 150);
        assert_eq!(snap.files_total, 2);
        assert_eq!(snap.files_done, 1);
    }

    #[test]
    fn shards_come_back_in_index_order() {
        let dir = std::env::temp_dir().join(format!("jarvis-hub-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        for n in [
            "model-00002-of-00002.safetensors",
            "model-00001-of-00002.safetensors",
        ] {
            std::fs::write(dir.join(n), b"x").unwrap();
        }
        std::fs::write(
            dir.join("model.safetensors.index.json"),
            r#"{"weight_map":{"b":"model-00002-of-00002.safetensors","a":"model-00001-of-00002.safetensors"}}"#,
        )
        .unwrap();

        let shards = weight_shards(&dir).unwrap();
        let names: Vec<_> = shards
            .iter()
            .map(|p| p.file_name().unwrap().to_str().unwrap())
            .collect();
        assert_eq!(
            names,
            [
                "model-00001-of-00002.safetensors",
                "model-00002-of-00002.safetensors"
            ]
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn an_index_cannot_point_a_shard_outside_the_snapshot() {
        let root = Path::new("/tmp/snapshot");
        for escape in ["/etc/hosts", "../elsewhere.safetensors", "a/../../b", ""] {
            assert!(
                snapshot_relative(root, escape).is_err(),
                "`{escape}` should have been rejected"
            );
        }
        assert_eq!(
            snapshot_relative(root, "model-00001-of-00002.safetensors").unwrap(),
            root.join("model-00001-of-00002.safetensors")
        );
        // A subdirectory is legitimate; only leaving the snapshot is not.
        assert_eq!(
            snapshot_relative(root, "shards/model.safetensors").unwrap(),
            root.join("shards/model.safetensors")
        );
    }
}
