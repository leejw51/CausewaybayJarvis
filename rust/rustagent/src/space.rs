//! `~/.causewaybayjarvis` — the one folder this project keeps things in.
//!
//! ```text
//! ~/.causewaybayjarvis/
//!   robots.db                     every agent, every context item, both indexes
//!   agents/<GUID>/photos/         what the robot has been shown
//!   agents/<GUID>/files/          what it has been given
//!   agents/<GUID>/notes/          what it wrote down
//!   global/…                      the same three, for when no robot is chosen
//!   tmp/                          request bodies on their way to ollama
//! ```
//!
//! Every path the database holds is **relative to the root** — `agents/<GUID>/
//! photos/0001-cat.png`, never `/Users/…`. A home directory that moves, a
//! backup restored somewhere else, or a database copied between machines all
//! keep working, and nothing in the database leaks a username.

use std::path::{Component, Path, PathBuf};

use anyhow::{bail, Context, Result};

/// Overridable so the tests (and a second robot city on the same machine) can
/// have a space of their own.
pub const HOME_ENV: &str = "JARVIS_HOME";
pub const DEFAULT_DIR: &str = ".causewaybayjarvis";
pub const DB_FILE: &str = "robots.db";

/// The three shelves every agent — and the global space — gets.
pub const SHELVES: [&str; 3] = ["photos", "files", "notes"];

/// Where an item lives when no robot is chosen.
pub const GLOBAL: &str = "global";

#[derive(Debug, Clone)]
pub struct Space {
    root: PathBuf,
}

impl Space {
    /// `$JARVIS_HOME`, else `~/.causewaybayjarvis`. The directory is created.
    pub fn discover() -> Result<Self> {
        let root = match std::env::var(HOME_ENV) {
            Ok(dir) if !dir.trim().is_empty() => PathBuf::from(dir),
            _ => home()?.join(DEFAULT_DIR),
        };
        Self::at(root)
    }

    pub fn at(root: impl Into<PathBuf>) -> Result<Self> {
        let root = root.into();
        std::fs::create_dir_all(&root).with_context(|| format!("creating {}", root.display()))?;
        // Canonicalize once, so `contains` below compares like with like even
        // when the caller handed us `~/../home/x` or a symlinked /tmp.
        let root = root.canonicalize().unwrap_or(root);
        let space = Self { root };
        space.ensure_shelves(GLOBAL)?;
        Ok(space)
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn db_path(&self) -> PathBuf {
        self.root.join(DB_FILE)
    }

    pub fn tmp_dir(&self) -> Result<PathBuf> {
        let dir = self.root.join("tmp");
        std::fs::create_dir_all(&dir)?;
        Ok(dir)
    }

    /// The relative home of one agent: `agents/<GUID>`, or `global`.
    pub fn agent_space(agent_id: Option<&str>) -> String {
        match agent_id {
            Some(id) => format!("agents/{id}"),
            None => GLOBAL.to_string(),
        }
    }

    /// Make `<space>/photos`, `<space>/files` and `<space>/notes`.
    pub fn ensure_shelves(&self, space: &str) -> Result<()> {
        for shelf in SHELVES {
            std::fs::create_dir_all(self.resolve(&format!("{space}/{shelf}"))?)?;
        }
        Ok(())
    }

    /// Turn a stored relative path into a real one, refusing anything that
    /// would climb out of the root.
    ///
    /// This is the only door between a string in the database and the file
    /// system, so `..`, an absolute path and a Windows prefix are all rejected
    /// here rather than trusted anywhere else.
    pub fn resolve(&self, relative: &str) -> Result<PathBuf> {
        let rel = Path::new(relative.trim_start_matches('/'));
        for part in rel.components() {
            match part {
                Component::Normal(_) => {}
                Component::CurDir => {}
                _ => bail!("path escapes the space: {relative}"),
            }
        }
        Ok(self.root.join(rel))
    }

    /// The inverse: an absolute path under the root, written the way the
    /// database stores it. `None` when it is somewhere else entirely.
    pub fn relative(&self, path: &Path) -> Option<String> {
        let path = path.canonicalize().ok()?;
        let rel = path.strip_prefix(&self.root).ok()?;
        Some(rel.to_string_lossy().replace('\\', "/"))
    }

    /// Copy a file the operator picked into an agent's shelf, and answer with
    /// the relative path to record.
    ///
    /// The name is made safe and made unique: two photos called `IMG_0001.png`
    /// from two different cameras both survive.
    pub fn intake(&self, space: &str, shelf: &str, source: &Path) -> Result<(String, u64)> {
        if !source.is_file() {
            bail!("no such file: {}", source.display());
        }
        self.ensure_shelves(space)?;
        let stem = source
            .file_name()
            .map(|n| slug_filename(&n.to_string_lossy()))
            .unwrap_or_else(|| "file".to_string());

        let dir = format!("{space}/{shelf}");
        let mut candidate = format!("{dir}/{stem}");
        let mut n = 1;
        while self.resolve(&candidate)?.exists() {
            let (base, ext) = split_ext(&stem);
            candidate = match ext {
                Some(ext) => format!("{dir}/{base}-{n}.{ext}"),
                None => format!("{dir}/{base}-{n}"),
            };
            n += 1;
        }
        let dest = self.resolve(&candidate)?;
        std::fs::copy(source, &dest)
            .with_context(|| format!("copying {} to {}", source.display(), dest.display()))?;
        let bytes = std::fs::metadata(&dest).map(|m| m.len()).unwrap_or(0);
        Ok((candidate, bytes))
    }

    /// Write text (a note, a markdown page) into a shelf.
    pub fn put_text(&self, space: &str, shelf: &str, name: &str, body: &str) -> Result<String> {
        self.ensure_shelves(space)?;
        let stem = slug_filename(name);
        let dir = format!("{space}/{shelf}");
        let mut candidate = format!("{dir}/{stem}");
        let mut n = 1;
        while self.resolve(&candidate)?.exists() {
            let (base, ext) = split_ext(&stem);
            candidate = match ext {
                Some(ext) => format!("{dir}/{base}-{n}.{ext}"),
                None => format!("{dir}/{base}-{n}"),
            };
            n += 1;
        }
        std::fs::write(self.resolve(&candidate)?, body)?;
        Ok(candidate)
    }

    pub fn read_text(&self, relative: &str) -> Result<String> {
        let path = self.resolve(relative)?;
        std::fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))
    }

    /// `~/.causewaybayjarvis/…` written with the tilde, for the UI.
    pub fn tilde(&self, path: &Path) -> String {
        let shown = path.to_string_lossy().to_string();
        match home() {
            Ok(home) => {
                let home = home.to_string_lossy().to_string();
                if home.len() > 1 && shown.starts_with(&home) {
                    return format!("~{}", &shown[home.len()..]);
                }
                shown
            }
            Err(_) => shown,
        }
    }
}

pub fn home() -> Result<PathBuf> {
    std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .map(PathBuf::from)
        .context("no HOME in the environment")
}

/// A new robot's identity. One GUID, made once, and never reused.
pub fn new_guid() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// Keep a filename to `[a-z0-9._-]`, so nothing a camera or a download named
/// can turn into a shell surprise or a second path component.
pub fn slug_filename(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for ch in name.chars() {
        let ch = ch.to_ascii_lowercase();
        if ch.is_ascii_alphanumeric() || ch == '.' || ch == '-' || ch == '_' {
            out.push(ch);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let out = out.trim_matches(['-', '.']).to_string();
    if out.is_empty() {
        "file".to_string()
    } else {
        out.chars().take(96).collect()
    }
}

fn split_ext(name: &str) -> (&str, Option<&str>) {
    match name.rsplit_once('.') {
        Some((base, ext)) if !base.is_empty() && !ext.is_empty() => (base, Some(ext)),
        _ => (name, None),
    }
}

/// Guess a mime type from the extension. Enough to tell a photo from a file.
pub fn mime_for(name: &str) -> &'static str {
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase());
    match ext.as_deref() {
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("bmp") => "image/bmp",
        Some("md" | "markdown") => "text/markdown",
        Some("txt") => "text/plain",
        Some("json") => "application/json",
        Some("csv") => "text/csv",
        Some("pdf") => "application/pdf",
        _ => "application/octet-stream",
    }
}

pub fn is_image(mime: &str) -> bool {
    mime.starts_with("image/")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stored_path_cannot_climb_out_of_the_space() {
        let dir = tempfile::tempdir().unwrap();
        let space = Space::at(dir.path()).unwrap();
        assert!(space.resolve("agents/abc/photos/x.png").is_ok());
        assert!(space.resolve("../../etc/passwd").is_err());
        assert!(space.resolve("agents/../../etc/passwd").is_err());
        assert!(space
            .resolve("/etc/passwd")
            .is_ok_and(|p| p.starts_with(space.root())));
    }

    #[test]
    fn filenames_are_slugged_and_kept_unique() {
        assert_eq!(slug_filename("IMG 0001.PNG"), "img-0001.png");
        assert_eq!(slug_filename("../../etc/passwd"), "etc-passwd");
        assert_eq!(slug_filename("   "), "file");

        let dir = tempfile::tempdir().unwrap();
        let space = Space::at(dir.path()).unwrap();
        let src = dir.path().join("cat.png");
        std::fs::write(&src, b"pixels").unwrap();
        let (first, bytes) = space.intake("global", "photos", &src).unwrap();
        let (second, _) = space.intake("global", "photos", &src).unwrap();
        assert_eq!(first, "global/photos/cat.png");
        assert_eq!(second, "global/photos/cat-1.png");
        assert_eq!(bytes, 6);
    }

    #[test]
    fn an_agent_space_is_its_guid() {
        let id = new_guid();
        assert_eq!(Space::agent_space(Some(&id)), format!("agents/{id}"));
        assert_eq!(Space::agent_space(None), "global");
        assert_eq!(id.len(), 36);
    }
}
