//! The web client: the pages the server hands a browser.
//!
//! One HTML page, one stylesheet, one script, two font files and a
//! manifest, compiled into the binary so that `agentd` on its own is the
//! whole thing — nothing to install beside it, nothing to find at runtime,
//! and a phone on the same Wi-Fi gets the same page as the Mac. The page
//! talks to the server it came from: `/v1/<op>` for the ops, `/file/…` for
//! the shelves, `/upload` for what the phone's camera just took.
//!
//! `JARVIS_WEB_DIR` points the server at the files on disk instead, so a
//! change to the page is a reload rather than a rebuild. It is a
//! development switch, not a deployment one: with it unset nothing on disk
//! is ever read.

use std::borrow::Cow;
use std::path::Path;

/// One file the browser may ask for, by the path it asks with.
pub struct Asset {
    pub path: &'static str,
    pub mime: &'static str,
    pub body: &'static [u8],
}

pub const ASSETS: &[Asset] = &[
    Asset {
        path: "/",
        mime: "text/html; charset=utf-8",
        body: include_bytes!("../web/index.html"),
    },
    Asset {
        path: "/app.css",
        mime: "text/css; charset=utf-8",
        body: include_bytes!("../web/app.css"),
    },
    Asset {
        path: "/app.js",
        mime: "text/javascript; charset=utf-8",
        body: include_bytes!("../web/app.js"),
    },
    Asset {
        path: "/favicon.svg",
        mime: "image/svg+xml",
        body: include_bytes!("../web/favicon.svg"),
    },
    Asset {
        path: "/icon.svg",
        mime: "image/svg+xml",
        body: include_bytes!("../web/icon.svg"),
    },
    Asset {
        path: "/manifest.webmanifest",
        mime: "application/manifest+json",
        body: include_bytes!("../web/manifest.webmanifest"),
    },
    Asset {
        path: "/fonts/chakra-petch-600-latin.woff2",
        mime: "font/woff2",
        body: include_bytes!("../web/fonts/chakra-petch-600-latin.woff2"),
    },
    Asset {
        path: "/fonts/chakra-petch-700-latin.woff2",
        mime: "font/woff2",
        body: include_bytes!("../web/fonts/chakra-petch-700-latin.woff2"),
    },
    Asset {
        path: "/fonts/OFL-chakra-petch.txt",
        mime: "text/plain; charset=utf-8",
        body: include_bytes!("../web/fonts/OFL-chakra-petch.txt"),
    },
];

/// The environment variable that serves the client from a folder instead.
pub const DIR_ENV: &str = "JARVIS_WEB_DIR";

/// The asset at `path`, if there is one: its mime type and its bytes. The
/// bytes come off the disk when [`DIR_ENV`] names a folder holding the
/// file, and out of the binary otherwise.
pub fn asset(path: &str) -> Option<(&'static str, Cow<'static, [u8]>)> {
    let asset = ASSETS.iter().find(|a| a.path == path)?;
    if let Ok(dir) = std::env::var(DIR_ENV) {
        let name = if path == "/" {
            "index.html"
        } else {
            &path[1..]
        };
        let file = Path::new(&dir).join(name);
        if let Ok(bytes) = std::fs::read(&file) {
            return Some((asset.mime, Cow::Owned(bytes)));
        }
    }
    Some((asset.mime, Cow::Borrowed(asset.body)))
}

/// A short tag for the build, so a browser can revalidate the page cheaply
/// and still see a new one after a rebuild.
pub fn etag(path: &str) -> String {
    let len = ASSETS
        .iter()
        .find(|a| a.path == path)
        .map(|a| a.body.len())
        .unwrap_or(0);
    format!("\"{}-{len}\"", env!("CARGO_PKG_VERSION"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_page_and_everything_it_links_are_in_the_binary() {
        let (mime, page) = asset("/").expect("the page");
        assert!(mime.starts_with("text/html"));
        let html = String::from_utf8_lossy(&page);
        for linked in [
            "/app.css",
            "/app.js",
            "/manifest.webmanifest",
            "/favicon.svg",
        ] {
            assert!(html.contains(linked), "the page does not link {linked}");
            assert!(asset(linked).is_some(), "{linked} is not embedded");
        }
        assert!(asset("/nowhere").is_none());
        assert!(etag("/").contains(env!("CARGO_PKG_VERSION")));
    }
}
