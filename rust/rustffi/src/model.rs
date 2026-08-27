//! Which checkpoint, where it is, and getting it here.

use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use anyhow::{anyhow, Result};
use rustcore::config::ModelConfig;
use rustcore::hub::{self, DownloadProgress};
use rustcore::models::{self, ModelSpec};

use crate::abi::{drop_handle, opt_str_arg, out_json, str_arg, Handle, JarvisProgress};
use crate::error::guard;

/// Resolve the same way `rustcli` does: an alias or a bare `org/name`, with an
/// optional explicit repository overriding whatever the alias points at.
pub(crate) fn spec(alias: &str, revision: Option<&str>, repo: Option<&str>) -> Result<ModelSpec> {
    models::from_config(&ModelConfig {
        alias: alias.to_string(),
        repo: repo.unwrap_or_default().to_string(),
        revision: revision.unwrap_or("main").to_string(),
    })
}

/// The aliases this build knows: `[{"alias":…, "repo":…}, …]`.
#[no_mangle]
pub extern "C" fn jarvis_models_json() -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let list: Vec<_> = models::known_aliases()
            .map(|(alias, repo)| serde_json::json!({ "alias": alias, "repo": repo }))
            .collect();
        out_json(&serde_json::Value::Array(list))
    })
}

/// Everything known about one model: what it resolves to, whether it is on
/// disk, and — when it is — what the checkpoint itself says about its shape.
///
/// # Safety
/// The arguments must be null or NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn jarvis_model_info_json(
    alias: *const c_char,
    revision: *const c_char,
    repo: *const c_char,
) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let spec = spec(
            str_arg(alias, "alias")?,
            opt_str_arg(revision, "revision")?,
            opt_str_arg(repo, "repo")?,
        )?;
        let mut json = serde_json::json!({
            "alias": spec.alias,
            "repo": spec.repo,
            "revision": spec.revision,
            "architecture": format!("{:?}", spec.architecture),
            "approx_gib": spec.approx_gib,
            "local": false,
        });

        if let Ok(files) = hub::local(&spec) {
            json["local"] = true.into();
            json["snapshot"] = files.root.display().to_string().into();
            json["shards"] = files.weights.len().into();
            json["weight_bytes"] = files.weight_bytes().into();
            json["chat_template"] = files.chat_template.is_some().into();

            // Read from the checkpoint rather than from the alias table: a bare
            // `org/name` has no entry there, and the file is the truth anyway.
            if let Ok(config) = rustmlx::ModelConfig::load(&files.config) {
                let text = &config.text;
                let full = (0..text.num_hidden_layers)
                    .filter(|&i| text.layer_kind(i) == rustmlx::LayerKind::Full)
                    .count();
                json["model"] = serde_json::json!({
                    "architectures": config.architectures,
                    "parameters": config.text_parameters(),
                    "layers": text.num_hidden_layers,
                    "full_attention": full,
                    "delta_net": text.num_hidden_layers - full,
                    "hidden_size": text.hidden_size,
                    "attention_heads": text.num_attention_heads,
                    "kv_heads": text.num_key_value_heads,
                    "head_dim": text.head_dim(),
                    "context": text.max_position_embeddings,
                    "vocabulary": text.vocab_size,
                    "quantization": config.quantization.as_ref().map(|q| serde_json::json!({
                        "bits": q.bits,
                        "group_size": q.group_size,
                    })),
                });
            }
        }
        out_json(&json)
    })
}

/// 1 when the checkpoint is already in the Hugging Face cache, 0 when it is
/// not, -1 when the model could not even be resolved.
///
/// # Safety
/// As [`jarvis_model_info_json`].
#[no_mangle]
pub unsafe extern "C" fn jarvis_model_is_local(
    alias: *const c_char,
    revision: *const c_char,
    repo: *const c_char,
) -> i32 {
    guard(-1, || {
        let spec = spec(
            str_arg(alias, "alias")?,
            opt_str_arg(revision, "revision")?,
            opt_str_arg(repo, "repo")?,
        )?;
        Ok(hub::local(&spec).is_ok() as i32)
    })
}

/// Whether a Hugging Face token was found, for the "gated repositories will
/// fail" hint a front end shows before a download.
#[no_mangle]
pub extern "C" fn jarvis_has_hf_token() -> i32 {
    hub::token().is_some() as i32
}

/* --------------------------------------------------------------- pull ---- */

/// A download in flight.
///
/// It runs on its own thread and reports through a shared snapshot the caller
/// polls, rather than through a callback. The Hub client makes progress calls
/// from several threads at once, and a binding whose runtime is single-threaded
/// — a LuaJIT `ffi` callback, a Python one holding the GIL — cannot safely be
/// entered from any of them.
pub struct JarvisPull {
    magic: u64,
    progress: Arc<Mutex<DownloadProgress>>,
    worker: Option<JoinHandle<Result<PathBuf>>>,
}

impl Handle for JarvisPull {
    const MAGIC: u64 = 0x4a5f_7075_6c6c_5f31; // "J_pull_1"
    fn magic(&self) -> u64 {
        self.magic
    }
}

/// Start downloading, returning immediately.
///
/// # Safety
/// As [`jarvis_model_info_json`].
#[no_mangle]
pub unsafe extern "C" fn jarvis_pull_start(
    alias: *const c_char,
    revision: *const c_char,
    repo: *const c_char,
) -> *mut JarvisPull {
    guard(std::ptr::null_mut(), || {
        let spec = spec(
            str_arg(alias, "alias")?,
            opt_str_arg(revision, "revision")?,
            opt_str_arg(repo, "repo")?,
        )?;
        let progress = Arc::new(Mutex::new(DownloadProgress::default()));
        let sink = Arc::clone(&progress);
        let worker = std::thread::Builder::new()
            .name("jarvis-pull".into())
            .spawn(move || {
                let files = hub::fetch(&spec, move |p| {
                    // A poisoned lock here would only cost a progress update.
                    if let Ok(mut slot) = sink.lock() {
                        *slot = p;
                    }
                })?;
                Ok(files.root)
            })?;
        Ok(Box::into_raw(Box::new(JarvisPull {
            magic: JarvisPull::MAGIC,
            progress,
            worker: Some(worker),
        })))
    })
}

/// 1 while the download is still running, 0 once it has finished, -1 if it
/// failed — in which case the reason is in `jarvis_last_error`.
///
/// `out` may be null if only the status is wanted.
///
/// # Safety
/// `pull` must be a live handle from [`jarvis_pull_start`]; `out` must be null
/// or point at a writable `JarvisProgress`.
#[no_mangle]
pub unsafe extern "C" fn jarvis_pull_poll(pull: *mut JarvisPull, out: *mut JarvisProgress) -> i32 {
    guard(-1, || {
        let pull = JarvisPull::borrow(pull, "pull")?;
        if !out.is_null() {
            let snapshot = pull
                .progress
                .lock()
                .map_err(|_| anyhow!("the download reporter panicked"))?;
            out.write(JarvisProgress::from(&*snapshot));
        }

        let Some(worker) = &pull.worker else {
            return Ok(0); // already collected
        };
        if !worker.is_finished() {
            return Ok(1);
        }
        match pull.worker.take().expect("just checked").join() {
            Ok(Ok(_root)) => Ok(0),
            Ok(Err(e)) => Err(e),
            Err(_) => Err(anyhow!("the download thread panicked")),
        }
    })
}

/// Free the handle. A download still in flight is waited for first — there is
/// no way to cancel a Hub request part way through.
///
/// # Safety
/// `pull` must be null or a live handle from [`jarvis_pull_start`].
#[no_mangle]
pub unsafe extern "C" fn jarvis_pull_free(pull: *mut JarvisPull) {
    drop_handle(pull, &mut |p: &mut JarvisPull| {
        p.magic = 0;
        if let Some(worker) = p.worker.take() {
            let _ = worker.join();
        }
    });
}
