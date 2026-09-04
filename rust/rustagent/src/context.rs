//! One row of what a robot knows.
//!
//! Photos, files, markdown pages, hand-written notes and the conversation
//! itself are all the same shape, because they are all the same thing to a
//! turn: text that can be retrieved, sometimes with a file behind it. `kind`
//! says which, `path` is the file when there is one — always relative to the
//! space root — and `body` is what the two indexes read.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// A turn of conversation. `role` says whose.
    Message,
    /// Something the operator or a tool wrote down. No file.
    Note,
    /// A markdown page on the `notes` shelf.
    Markdown,
    /// Any other file on the `files` shelf.
    File,
    /// A picture on the `photos` shelf.
    Image,
    /// A video on the `videos` shelf. The original is kept as it came; a
    /// three-second Ogg Theora clip is made beside it for the LÖVE client,
    /// and `meta` says where — see [`crate::video`].
    Video,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Message => "message",
            Kind::Note => "note",
            Kind::Markdown => "markdown",
            Kind::File => "file",
            Kind::Image => "image",
            Kind::Video => "video",
        }
    }

    pub fn parse(s: &str) -> Option<Kind> {
        Some(match s.trim().to_ascii_lowercase().as_str() {
            "message" => Kind::Message,
            "note" => Kind::Note,
            "markdown" | "md" => Kind::Markdown,
            "file" => Kind::File,
            "image" | "photo" => Kind::Image,
            "video" | "movie" | "clip" => Kind::Video,
            _ => return None,
        })
    }

    /// Which shelf of the space a file of this kind lands on.
    pub fn shelf(self) -> &'static str {
        match self {
            Kind::Image => "photos",
            Kind::Video => "videos",
            Kind::Markdown | Kind::Note => "notes",
            _ => "files",
        }
    }

    /// Does this kind belong on the robot's page? A message does not — the
    /// page is the archive, and the transcript is drawn separately.
    pub fn on_page(self) -> bool {
        !matches!(self, Kind::Message)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Item {
    pub id: i64,
    /// `None` is the global space: what a turn with no robot chosen writes to.
    pub agent_id: Option<String>,
    pub kind: String,
    /// Messages only: `user`, `assistant`, `system` or `tool`.
    pub role: String,
    pub title: String,
    pub body: String,
    /// Relative to `~/.causewaybayjarvis`, or `None` for a pure-text row.
    pub path: Option<String>,
    pub mime: String,
    pub bytes: i64,
    pub meta: String,
    pub created_at: i64,
    pub updated_at: i64,
}

impl Item {
    /// The text both indexes see. Title first: a filename is often the most
    /// specific word anyone will search for.
    pub fn indexed_text(&self) -> String {
        if self.title.is_empty() {
            self.body.clone()
        } else {
            format!("{}\n{}", self.title, self.body)
        }
    }

    /// A one-line form for a tool result or a search hit.
    pub fn summary(&self, width: usize) -> String {
        let text = self.body.replace(['\n', '\r'], " ");
        let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
        let head = if self.title.is_empty() {
            String::new()
        } else {
            format!("{}: ", self.title)
        };
        let mut out = format!("{head}{text}");
        if out.chars().count() > width {
            out = out
                .chars()
                .take(width.saturating_sub(1))
                .collect::<String>()
                + "…";
        }
        out
    }
}

/// What the operator asked to be filed. `Store::add` turns this into an
/// [`Item`], a copy on the right shelf, and two index entries.
#[derive(Debug, Clone, Default)]
pub struct NewItem {
    pub agent_id: Option<String>,
    pub kind: Option<Kind>,
    pub title: String,
    pub body: String,
    /// A file to copy into the space. Absolute, or relative to the cwd.
    pub source_path: Option<String>,
    /// What to call that file on the shelf, when its own name is not it:
    /// an upload arrives in a temporary file, and this is the name the
    /// phone gave it. `None` keeps the source's name.
    pub name: Option<String>,
    pub role: String,
    pub meta: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_round_trip_and_pick_a_shelf() {
        for k in [
            Kind::Message,
            Kind::Note,
            Kind::Markdown,
            Kind::File,
            Kind::Image,
            Kind::Video,
        ] {
            assert_eq!(Kind::parse(k.as_str()), Some(k));
        }
        assert_eq!(Kind::parse("photo"), Some(Kind::Image));
        assert_eq!(Kind::parse("movie"), Some(Kind::Video));
        assert_eq!(Kind::parse("md"), Some(Kind::Markdown));
        assert_eq!(Kind::parse("nonsense"), None);
        assert_eq!(Kind::Image.shelf(), "photos");
        assert_eq!(Kind::Video.shelf(), "videos");
        assert!(Kind::Video.on_page());
        assert_eq!(Kind::Markdown.shelf(), "notes");
        assert_eq!(Kind::File.shelf(), "files");
        assert!(!Kind::Message.on_page());
        assert!(Kind::Image.on_page());
    }

    #[test]
    fn a_summary_fits_the_width_it_was_given() {
        let item = Item {
            id: 1,
            agent_id: None,
            kind: "note".into(),
            role: String::new(),
            title: "cat".into(),
            body: "a  long\nnote about\ncats".into(),
            path: None,
            mime: String::new(),
            bytes: 0,
            meta: "{}".into(),
            created_at: 0,
            updated_at: 0,
        };
        assert_eq!(item.summary(80), "cat: a long note about cats");
        assert_eq!(item.summary(10).chars().count(), 10);
    }
}
