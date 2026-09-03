//! The **paper**: one robot's whole archive as one square picture.
//!
//! A 1024x1024 PNG — the head, the name, the folder, what is on every
//! shelf, the latest photos as thumbnails, and the last few things said —
//! drawn here pixel by pixel with the same 8x8 ROM font the client uses.
//! No font library and no image library beyond the PNG codec: the whole
//! renderer is a byte buffer, a glyph table and a few rectangles, which is
//! also what keeps it deterministic enough to test.
//!
//! The paper lands in `agents/<GUID>/paper/` and is *not* filed as an
//! item: it is drawn from the archive, so filing it would put a picture of
//! the gallery into the gallery, and the next paper would carry the last.

use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use serde::Serialize;

use crate::db::now;
use crate::mirror::iso;
use crate::space::{self, PAPER_SIZE};
use crate::store::Store;

/// An RGBA raster.
pub struct Canvas {
    pub w: u32,
    pub h: u32,
    pub px: Vec<u8>,
}

pub type Rgb = [u8; 3];

// The client's palette, `robots/src/theme.lua`.
pub const VOID: Rgb = [7, 11, 20];
pub const NAVY: Rgb = [12, 18, 36];
pub const PANEL: Rgb = [18, 26, 48];
pub const PANEL2: Rgb = [24, 34, 62];
pub const PAPER: Rgb = [240, 230, 208];
pub const ICE: Rgb = [216, 240, 255];
pub const DIM: Rgb = [90, 104, 128];
pub const CYAN: Rgb = [92, 232, 255];
pub const JADE: Rgb = [61, 220, 122];
pub const AMBER: Rgb = [255, 191, 0];
pub const MAGENTA: Rgb = [255, 46, 166];
pub const GOLD: Rgb = [230, 193, 90];

/// The colour a robot names, in the client's palette.
pub fn accent(name: &str) -> Rgb {
    match name.trim().to_ascii_lowercase().as_str() {
        "gold" => GOLD,
        "cyan" => CYAN,
        "teal" => [46, 230, 200],
        "jade" | "lime" | "green" => JADE,
        "magenta" => MAGENTA,
        "orange" => [255, 140, 46],
        "blue" | "sky" => [110, 175, 255],
        "yellow" | "amber" => AMBER,
        "red" | "crimson" => [232, 59, 59],
        "violet" => [168, 92, 255],
        "rose" => [255, 110, 150],
        "ice" => ICE,
        _ => CYAN,
    }
}

impl Canvas {
    pub fn new(w: u32, h: u32, bg: Rgb) -> Self {
        let mut px = Vec::with_capacity((w * h * 4) as usize);
        for _ in 0..(w * h) {
            px.extend_from_slice(&[bg[0], bg[1], bg[2], 255]);
        }
        Self { w, h, px }
    }

    pub fn put(&mut self, x: i64, y: i64, c: Rgb) {
        if x < 0 || y < 0 || x >= self.w as i64 || y >= self.h as i64 {
            return;
        }
        let i = ((y as u32 * self.w + x as u32) * 4) as usize;
        self.px[i] = c[0];
        self.px[i + 1] = c[1];
        self.px[i + 2] = c[2];
        self.px[i + 3] = 255;
    }

    pub fn get(&self, x: u32, y: u32) -> [u8; 4] {
        let i = ((y * self.w + x) * 4) as usize;
        [self.px[i], self.px[i + 1], self.px[i + 2], self.px[i + 3]]
    }

    /// Alpha-blend one pixel over what is there.
    pub fn blend(&mut self, x: i64, y: i64, c: Rgb, a: u8) {
        if x < 0 || y < 0 || x >= self.w as i64 || y >= self.h as i64 || a == 0 {
            return;
        }
        if a == 255 {
            return self.put(x, y, c);
        }
        let i = ((y as u32 * self.w + x as u32) * 4) as usize;
        let a = a as u32;
        for (k, &channel) in c.iter().enumerate() {
            let under = self.px[i + k] as u32;
            self.px[i + k] = ((channel as u32 * a + under * (255 - a)) / 255) as u8;
        }
    }

    pub fn fill(&mut self, x: i64, y: i64, w: i64, h: i64, c: Rgb) {
        for yy in y.max(0)..(y + h).min(self.h as i64) {
            for xx in x.max(0)..(x + w).min(self.w as i64) {
                self.put(xx, yy, c);
            }
        }
    }

    pub fn frame(&mut self, x: i64, y: i64, w: i64, h: i64, t: i64, c: Rgb) {
        self.fill(x, y, w, t, c);
        self.fill(x, y + h - t, w, t, c);
        self.fill(x, y, t, h, c);
        self.fill(x + w - t, y, t, h, c);
    }

    /// One string in the ROM font at `scale` pixels per dot. Lowercase is
    /// folded to upper, and anything outside the table is a `?`.
    pub fn text(&mut self, x: i64, y: i64, scale: i64, c: Rgb, s: &str) -> i64 {
        let mut px = x;
        for ch in s.chars() {
            let rows = glyph(ch);
            for (row, bits) in rows.iter().enumerate() {
                for col in 0..8 {
                    if bits & (0x80 >> col) != 0 {
                        self.fill(
                            px + col as i64 * scale,
                            y + row as i64 * scale,
                            scale,
                            scale,
                            c,
                        );
                    }
                }
            }
            px += 8 * scale;
        }
        px
    }

    /// Paste a decoded picture, scaled with nearest neighbour to *cover*
    /// `w x h` at `x, y` (cropped, centred), honouring its alpha.
    pub fn paste(&mut self, img: &Canvas, x: i64, y: i64, w: i64, h: i64) {
        self.paste_crop(img, 0, 0, img.w as i64, img.h as i64, x, y, w, h);
    }

    /// The same, from a source rectangle.
    #[allow(clippy::too_many_arguments)]
    pub fn paste_crop(
        &mut self,
        img: &Canvas,
        sx: i64,
        sy: i64,
        sw: i64,
        sh: i64,
        x: i64,
        y: i64,
        w: i64,
        h: i64,
    ) {
        if sw <= 0 || sh <= 0 || w <= 0 || h <= 0 {
            return;
        }
        let scale = (w as f64 / sw as f64).max(h as f64 / sh as f64);
        let dw = (sw as f64 * scale).round() as i64;
        let dh = (sh as f64 * scale).round() as i64;
        let ox = (dw - w) / 2;
        let oy = (dh - h) / 2;
        for dy in 0..h {
            let syy = sy + ((dy + oy) as f64 / scale) as i64;
            for dx in 0..w {
                let sxx = sx + ((dx + ox) as f64 / scale) as i64;
                if sxx < 0 || syy < 0 || sxx >= img.w as i64 || syy >= img.h as i64 {
                    continue;
                }
                let p = img.get(sxx as u32, syy as u32);
                self.blend(x + dx, y + dy, [p[0], p[1], p[2]], p[3]);
            }
        }
    }

    /// The opaque bounding box, and the head band inside it — the same
    /// measurement the client's `Sprites.head` makes, so the paper frames
    /// the same face the screen does.
    pub fn head_crop(&self) -> (i64, i64, i64, i64) {
        let (mut minx, mut miny, mut maxx, mut maxy) = (self.w as i64, self.h as i64, -1, -1);
        for y in 0..self.h {
            for x in 0..self.w {
                if self.get(x, y)[3] > 30 {
                    minx = minx.min(x as i64);
                    maxx = maxx.max(x as i64);
                    miny = miny.min(y as i64);
                    maxy = maxy.max(y as i64);
                }
            }
        }
        if maxx < minx {
            return (0, 0, self.w as i64, (self.h / 2) as i64);
        }
        let bh = (maxy - miny + 1).max(8);
        let band_bottom = miny + (bh as f64 * 0.16) as i64;
        let (mut hminx, mut hmaxx) = (self.w as i64, -1);
        for y in miny..=band_bottom.min(self.h as i64 - 1) {
            for x in 0..self.w {
                if self.get(x, y as u32)[3] > 30 {
                    hminx = hminx.min(x as i64);
                    hmaxx = hmaxx.max(x as i64);
                }
            }
        }
        if hmaxx < hminx {
            hminx = minx;
            hmaxx = maxx;
        }
        let head_cx = (hminx + hmaxx) / 2;
        let side = ((hmaxx - hminx + 1).max(bh / 3) as f64 * 1.15) as i64;
        let side = side.clamp(8, self.w.min(self.h) as i64);
        let x = (head_cx - side / 2).clamp(0, self.w as i64 - side);
        let y = (miny - side / 10).clamp(0, self.h as i64 - side);
        (x, y, side, side)
    }

    pub fn encode_png(&self) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        {
            let mut enc = png::Encoder::new(&mut out, self.w, self.h);
            enc.set_color(png::ColorType::Rgba);
            enc.set_depth(png::BitDepth::Eight);
            let mut writer = enc.write_header()?;
            writer.write_image_data(&self.px)?;
        }
        Ok(out)
    }

    /// Decode a PNG from disk into RGBA. Anything that is not a PNG — or
    /// not a PNG this codec reads — is an error the caller turns into a
    /// placeholder.
    pub fn decode_png(path: &Path) -> Result<Canvas> {
        let file =
            std::fs::File::open(path).with_context(|| format!("opening {}", path.display()))?;
        let mut decoder = png::Decoder::new(std::io::BufReader::new(file));
        decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
        let mut reader = decoder.read_info()?;
        let mut buf = vec![0u8; reader.output_buffer_size()];
        let info = reader.next_frame(&mut buf)?;
        let bytes = &buf[..info.buffer_size()];
        let (w, h) = (info.width, info.height);
        let mut px = Vec::with_capacity((w * h * 4) as usize);
        match info.color_type {
            png::ColorType::Rgba => px.extend_from_slice(bytes),
            png::ColorType::Rgb => {
                for p in bytes.chunks_exact(3) {
                    px.extend_from_slice(&[p[0], p[1], p[2], 255]);
                }
            }
            png::ColorType::Grayscale => {
                for &g in bytes {
                    px.extend_from_slice(&[g, g, g, 255]);
                }
            }
            png::ColorType::GrayscaleAlpha => {
                for p in bytes.chunks_exact(2) {
                    px.extend_from_slice(&[p[0], p[0], p[0], p[1]]);
                }
            }
            other => return Err(anyhow!("unsupported png colour type {other:?}")),
        }
        Ok(Canvas { w, h, px })
    }

    /// How many pixels are not the background — the tests use it to check
    /// that a paper was actually drawn on.
    pub fn ink(&self, bg: Rgb) -> usize {
        self.px
            .chunks_exact(4)
            .filter(|p| p[0] != bg[0] || p[1] != bg[1] || p[2] != bg[2])
            .count()
    }
}

// ----------------------------------------------------------------- layout --

/// Where the paper went.
#[derive(Debug, Clone, Serialize)]
pub struct Saved {
    /// Relative to the space, or absolute when `out` was given.
    pub path: String,
    pub abs: String,
    pub width: u32,
    pub height: u32,
    pub bytes: u64,
    pub agent: Option<String>,
}

/// Draw the paper for one robot (or the global space) and write it.
pub fn save(
    store: &Store,
    agent_id: Option<&str>,
    sprite: Option<&Path>,
    out: Option<&Path>,
) -> Result<Saved> {
    let canvas = render(store, agent_id, sprite)?;
    let bytes = canvas.encode_png()?;
    let page = store.page(agent_id)?;
    let stamp = iso(now()).replace([' ', ':'], "-");
    let name = match &page.agent {
        Some(a) => format!("{}-{stamp}.png", space::slug_filename(&a.slug)),
        None => format!("global-{stamp}.png"),
    };
    let (path, abs) = match out {
        Some(p) => {
            if let Some(dir) = p.parent() {
                if !dir.as_os_str().is_empty() {
                    std::fs::create_dir_all(dir)?;
                }
            }
            (p.to_string_lossy().to_string(), p.to_path_buf())
        }
        None => {
            let dir = store.space.paper_dir(&page.space)?;
            let mut abs = dir.join(&name);
            let mut n = 1;
            while abs.exists() {
                abs = dir.join(format!("{}-{n}.png", name.trim_end_matches(".png")));
                n += 1;
            }
            let rel = store
                .space
                .relative(&dir)
                .map(|d| format!("{d}/{}", abs.file_name().unwrap().to_string_lossy()))
                .unwrap_or_else(|| abs.to_string_lossy().to_string());
            (rel, abs)
        }
    };
    std::fs::write(&abs, &bytes).with_context(|| format!("writing {}", abs.display()))?;
    Ok(Saved {
        path,
        abs: abs.to_string_lossy().to_string(),
        width: canvas.w,
        height: canvas.h,
        bytes: bytes.len() as u64,
        agent: page.agent.map(|a| a.id),
    })
}

/// The picture itself, undrawn to disk.
pub fn render(store: &Store, agent_id: Option<&str>, sprite: Option<&Path>) -> Result<Canvas> {
    let page = store.page(agent_id)?;
    let messages = store.messages(agent_id, 8)?;
    let size = PAPER_SIZE as i64;
    let mut c = Canvas::new(PAPER_SIZE, PAPER_SIZE, VOID);
    let tone = page
        .agent
        .as_ref()
        .map(|a| accent(&a.color))
        .unwrap_or(GOLD);

    // A faint grid, so the void reads as a screen and not as nothing.
    for y in (0..size).step_by(32) {
        c.fill(0, y, size, 1, NAVY);
    }
    for x in (0..size).step_by(32) {
        c.fill(x, 0, 1, size, NAVY);
    }

    // ---- header: the head, the name, the folder --------------------------
    c.fill(0, 0, size, 232, PANEL);
    c.fill(0, 232, size, 4, tone);
    let head = 176;
    c.fill(28, 28, head, head, PANEL2);
    let mut drew_head = false;
    if let Some(path) = sprite {
        if let Ok(img) = Canvas::decode_png(path) {
            let (sx, sy, sw, sh) = img.head_crop();
            c.paste_crop(&img, sx, sy, sw, sh, 28, 28, head, head);
            drew_head = true;
        }
    }
    if !drew_head {
        // The swarm's own mark: two nested squares on a point.
        let cx = 28 + head / 2;
        let cy = 28 + head / 2;
        for r in [60, 40] {
            for i in 0..r {
                c.fill(cx - i, cy - r + i, 2, 2, tone);
                c.fill(cx + i, cy - r + i, 2, 2, tone);
                c.fill(cx - i, cy + r - i, 2, 2, tone);
                c.fill(cx + i, cy + r - i, 2, 2, tone);
            }
        }
    }
    c.frame(28, 28, head, head, 3, tone);

    let tx = 28 + head + 28;
    let (name, sub, guid) = match &page.agent {
        Some(a) => (
            a.name.to_uppercase(),
            format!("{}  //  {}", a.role, a.kind).to_uppercase(),
            a.id.clone(),
        ),
        None => (
            "GLOBAL SPACE".to_string(),
            "NO ROBOT CHOSEN".to_string(),
            "everything filed with nobody chosen".to_string(),
        ),
    };
    let room = (size - tx - 28) / 8;
    c.text(tx, 36, 6, tone, &clip(&name, room / 6));
    c.text(tx, 92, 3, PAPER, &clip(&sub, room / 3));
    c.text(tx, 124, 2, DIM, &clip(&guid.to_uppercase(), room / 2));
    c.text(
        tx,
        148,
        2,
        DIM,
        &clip(&fit_path(&page.folder, (room / 2) as usize), room / 2),
    );
    if let Some(a) = &page.agent {
        let persona = wrap(&a.persona, (room / 2) as usize);
        for (i, line) in persona.iter().take(2).enumerate() {
            c.text(tx, 176 + i as i64 * 20, 2, ICE, line);
        }
    }

    // ---- the counters ----------------------------------------------------
    let tiles: [(&str, String, Rgb); 6] = [
        ("PHOTOS", page.gallery.len().to_string(), CYAN),
        ("MARKDOWN", page.markdowns.len().to_string(), JADE),
        ("FILES", page.files.len().to_string(), AMBER),
        ("NOTES", page.notes.len().to_string(), MAGENTA),
        ("MESSAGES", page.messages.to_string(), GOLD),
        ("SIZE", human(page.bytes), ICE),
    ];
    let tile_w = (size - 28 * 2 - 12 * 5) / 6;
    for (i, (label, value, col)) in tiles.iter().enumerate() {
        let x = 28 + i as i64 * (tile_w + 12);
        c.fill(x, 252, tile_w, 84, PANEL);
        c.fill(x, 252, tile_w, 3, *col);
        c.text(x + 12, 264, 2, DIM, label);
        c.text(x + 12, 296, 3, *col, &clip(value, (tile_w - 24) / 24));
    }

    // ---- the gallery strip ------------------------------------------------
    let strip_y = 356;
    c.text(28, strip_y, 2, CYAN, "PHOTOS");
    let thumb = 148;
    let per_row = 6;
    let gap = (size - 28 * 2 - thumb * per_row) / (per_row - 1);
    for (i, item) in page.gallery.iter().take(per_row as usize).enumerate() {
        let x = 28 + i as i64 * (thumb + gap);
        let y = strip_y + 24;
        c.fill(x, y, thumb, thumb, PANEL2);
        let pasted = item
            .path
            .as_deref()
            .and_then(|rel| store.space.resolve(rel).ok())
            .and_then(|abs| Canvas::decode_png(&abs).ok())
            .map(|img| c.paste(&img, x, y, thumb, thumb))
            .is_some();
        if !pasted {
            let ext = item
                .path
                .as_deref()
                .and_then(|p| p.rsplit_once('.'))
                .map(|(_, e)| e.to_uppercase())
                .unwrap_or_else(|| "IMAGE".into());
            c.text(x + 12, y + thumb / 2 - 8, 2, DIM, &clip(&ext, 8));
        }
        c.frame(x, y, thumb, thumb, 2, CYAN);
        c.text(
            x,
            y + thumb + 6,
            1,
            DIM,
            &clip(&item.title.to_uppercase(), thumb / 8),
        );
    }
    if page.gallery.is_empty() {
        c.text(
            28,
            strip_y + 24 + 60,
            2,
            DIM,
            "NOTHING FILED ON THIS SHELF YET",
        );
    }

    // ---- two columns: the shelves, and the conversation ------------------
    let col_y = 560;
    let col_w = (size - 28 * 2 - 24) / 2;
    let left = 28;
    let right = 28 + col_w + 24;
    let chars = (col_w / 16) as usize;
    let rows_avail = ((size - 48 - col_y - 28) / 20) as usize;

    c.text(left, col_y, 2, JADE, "SHELVES");
    let mut y = col_y + 24;
    let mut lines: Vec<(Rgb, String)> = Vec::new();
    for (label, col, items) in [
        ("MD", JADE, &page.markdowns),
        ("FILE", AMBER, &page.files),
        ("NOTE", MAGENTA, &page.notes),
    ] {
        for it in items.iter().take(6) {
            let head = format!("{label} #{} ", it.id);
            let text = format!("{head}{}", it.title.to_uppercase());
            lines.push((col, clip(&text, chars as i64)));
            if !it.body.trim().is_empty() && it.kind != "markdown" {
                let body = it.body.split_whitespace().collect::<Vec<_>>().join(" ");
                lines.push((
                    DIM,
                    format!("  {}", clip(&body.to_uppercase(), chars as i64 - 2)),
                ));
            }
        }
    }
    if lines.is_empty() {
        lines.push((DIM, "NOTHING ON THE SHELVES YET".into()));
    }
    for (col, line) in lines.iter().take(rows_avail) {
        c.text(left, y, 2, *col, line);
        y += 20;
    }

    c.text(right, col_y, 2, GOLD, "LAST SAID");
    let mut y = col_y + 24;
    let mut said: Vec<(Rgb, String)> = Vec::new();
    let bot: String = page
        .agent
        .as_ref()
        .map(|a| a.name.to_uppercase().chars().take(6).collect())
        .unwrap_or_else(|| "SWARM".into());
    for m in &messages {
        let who = if m.role == "user" {
            "YOU"
        } else {
            bot.as_str()
        };
        let col = if m.role == "user" { PAPER } else { tone };
        let body = m.body.split_whitespace().collect::<Vec<_>>().join(" ");
        for (i, line) in wrap(&body, chars - 4).into_iter().take(3).enumerate() {
            let head = if i == 0 {
                format!("{who}>")
            } else {
                "   ".into()
            };
            said.push((col, format!("{head} {}", line.to_uppercase())));
        }
    }
    if said.is_empty() {
        said.push((DIM, "NOTHING SAID YET".into()));
    }
    let start = said.len().saturating_sub(rows_avail);
    for (col, line) in &said[start..] {
        c.text(right, y, 2, *col, &clip(line, chars as i64));
        y += 20;
    }

    // ---- footer ----------------------------------------------------------
    c.fill(0, size - 40, size, 40, PANEL);
    c.fill(0, size - 40, size, 2, tone);
    let total = page.gallery.len() + page.markdowns.len() + page.files.len() + page.notes.len();
    let left_foot = format!("CAUSEWAYBAY JARVIS  //  {}", iso(now()));
    let right_foot = format!("{total} ITEMS  {} MSG", page.messages);
    c.text(28, size - 28, 2, DIM, &left_foot);
    let rx = size - 28 - right_foot.chars().count() as i64 * 16;
    c.text(rx, size - 28, 2, DIM, &right_foot);
    Ok(c)
}

fn clip(s: &str, chars: i64) -> String {
    let chars = chars.max(1) as usize;
    let n = s.chars().count();
    if n <= chars {
        s.to_string()
    } else {
        s.chars().take(chars.saturating_sub(1)).collect::<String>() + "~"
    }
}

fn fit_path(path: &str, chars: usize) -> String {
    let n = path.chars().count();
    if n <= chars || chars < 5 {
        return path.to_string();
    }
    let keep: String = path.chars().skip(n - (chars - 3)).collect();
    format!("...{keep}")
}

pub fn wrap(text: &str, width: usize) -> Vec<String> {
    let width = width.max(4);
    let mut out = Vec::new();
    let mut line = String::new();
    for word in text.split_whitespace() {
        let mut word = word.to_string();
        while word.chars().count() > width {
            if !line.is_empty() {
                out.push(std::mem::take(&mut line));
            }
            let head: String = word.chars().take(width).collect();
            word = word.chars().skip(width).collect();
            out.push(head);
        }
        if line.is_empty() {
            line = word;
        } else if line.chars().count() + 1 + word.chars().count() <= width {
            line.push(' ');
            line.push_str(&word);
        } else {
            out.push(std::mem::replace(&mut line, word));
        }
    }
    if !line.is_empty() {
        out.push(line);
    }
    out
}

pub fn human(bytes: i64) -> String {
    if bytes >= 1 << 20 {
        format!("{:.1}MB", bytes as f64 / (1u64 << 20) as f64)
    } else if bytes >= 1 << 10 {
        format!("{}KB", bytes / 1024)
    } else {
        format!("{bytes}B")
    }
}

/// Where an exported paper's `path` points, made absolute for a client.
pub fn abs_of(store: &Store, saved: &Saved) -> PathBuf {
    store
        .space
        .resolve(&saved.path)
        .unwrap_or_else(|_| PathBuf::from(&saved.abs))
}

// ------------------------------------------------------------------- font --

/// The client's 8x8 ROM (`robots/src/font.lua`), ASCII 32..=126 with the
/// lower case folded onto the upper.
fn glyph(ch: char) -> &'static [u8; 8] {
    let ch = ch.to_ascii_uppercase();
    let code = ch as u32;
    let idx = match code {
        32..=96 => (code - 32) as usize,
        123..=126 => (code - 32 - 26) as usize,
        _ => return &GLYPHS[('?' as u32 - 32) as usize],
    };
    &GLYPHS[idx]
}

const GLYPHS: [[u8; 8]; 69] = [
    [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], // space
    [0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00], // !
    [0x66, 0x66, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00], // "
    [0x24, 0x7E, 0x24, 0x24, 0x7E, 0x24, 0x24, 0x00], // #
    [0x18, 0x3E, 0x58, 0x3C, 0x1A, 0x7C, 0x18, 0x00], // $
    [0x62, 0x64, 0x08, 0x10, 0x20, 0x4C, 0x8C, 0x00], // %
    [0x30, 0x48, 0x50, 0x20, 0x54, 0x48, 0x34, 0x00], // &
    [0x18, 0x18, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00], // '
    [0x08, 0x10, 0x20, 0x20, 0x20, 0x10, 0x08, 0x00], // (
    [0x20, 0x10, 0x08, 0x08, 0x08, 0x10, 0x20, 0x00], // )
    [0x00, 0x24, 0x18, 0x7E, 0x18, 0x24, 0x00, 0x00], // *
    [0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00], // +
    [0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30], // ,
    [0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00], // -
    [0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00], // .
    [0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x00], // /
    [0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00], // 0
    [0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00], // 1
    [0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30, 0x7E, 0x00], // 2
    [0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00], // 3
    [0x0C, 0x1C, 0x2C, 0x4C, 0x7E, 0x0C, 0x0C, 0x00], // 4
    [0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00], // 5
    [0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00], // 6
    [0x7E, 0x06, 0x0C, 0x18, 0x18, 0x18, 0x18, 0x00], // 7
    [0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00], // 8
    [0x3C, 0x66, 0x66, 0x3E, 0x06, 0x0C, 0x38, 0x00], // 9
    [0x00, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00, 0x00], // :
    [0x00, 0x18, 0x18, 0x00, 0x18, 0x18, 0x30, 0x00], // ;
    [0x08, 0x10, 0x20, 0x40, 0x20, 0x10, 0x08, 0x00], // <
    [0x00, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00, 0x00], // =
    [0x20, 0x10, 0x08, 0x04, 0x08, 0x10, 0x20, 0x00], // >
    [0x3C, 0x66, 0x06, 0x0C, 0x18, 0x00, 0x18, 0x00], // ?
    [0x3C, 0x4A, 0x56, 0x5E, 0x40, 0x3C, 0x00, 0x00], // @
    [0x18, 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x00], // A
    [0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00], // B
    [0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00], // C
    [0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00], // D
    [0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00], // E
    [0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00], // F
    [0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3C, 0x00], // G
    [0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00], // H
    [0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00], // I
    [0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38, 0x00], // J
    [0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00], // K
    [0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00], // L
    [0x63, 0x77, 0x7F, 0x6B, 0x63, 0x63, 0x63, 0x00], // M
    [0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00], // N
    [0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00], // O
    [0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00], // P
    [0x3C, 0x66, 0x66, 0x66, 0x6A, 0x64, 0x3A, 0x00], // Q
    [0x7C, 0x66, 0x66, 0x7C, 0x78, 0x6C, 0x66, 0x00], // R
    [0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00], // S
    [0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00], // T
    [0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00], // U
    [0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00], // V
    [0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00], // W
    [0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00], // X
    [0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00], // Y
    [0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00], // Z
    [0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00], // [
    [0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x00], // backslash
    [0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00], // ]
    [0x18, 0x3C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00], // ^
    [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7E, 0x00], // _
    [0x30, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], // `
    [0x0C, 0x18, 0x18, 0x70, 0x18, 0x18, 0x0C, 0x00], // {
    [0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00], // |
    [0x30, 0x18, 0x18, 0x0E, 0x18, 0x18, 0x30, 0x00], // }
    [0x00, 0x32, 0x4C, 0x00, 0x00, 0x00, 0x00, 0x00], // ~
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_printable_ascii_has_a_glyph_and_case_folds() {
        for code in 32u8..=126 {
            let _ = glyph(code as char);
        }
        assert_eq!(glyph('a'), glyph('A'));
        assert_eq!(glyph('~')[1], 0x32);
        assert_eq!(glyph('{')[0], 0x0C);
        assert_eq!(glyph('é'), glyph('?'));
    }

    #[test]
    fn text_puts_ink_where_the_glyph_says() {
        let mut c = Canvas::new(16, 8, VOID);
        c.text(0, 0, 1, ICE, "I");
        // Row 0 of 'I' is 0x7E: bits 1..=6 lit.
        assert_eq!(c.get(0, 0)[0], VOID[0]);
        assert_eq!(c.get(1, 0)[0], ICE[0]);
        assert_eq!(c.get(6, 0)[0], ICE[0]);
        assert_eq!(c.get(7, 0)[0], VOID[0]);
        assert!(c.ink(VOID) > 10);
    }

    #[test]
    fn png_round_trips_through_the_codec() {
        let mut c = Canvas::new(5, 3, [1, 2, 3]);
        c.put(4, 2, [9, 8, 7]);
        let bytes = c.encode_png().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.png");
        std::fs::write(&path, &bytes).unwrap();
        let back = Canvas::decode_png(&path).unwrap();
        assert_eq!((back.w, back.h), (5, 3));
        assert_eq!(back.get(4, 2), [9, 8, 7, 255]);
        assert_eq!(back.get(0, 0), [1, 2, 3, 255]);
    }

    #[test]
    fn wrapping_keeps_words_whole_and_breaks_long_ones() {
        assert_eq!(wrap("a bb ccc", 5), vec!["a bb", "ccc"]);
        assert_eq!(wrap("abcdefghij", 4), vec!["abcd", "efgh", "ij"]);
        assert_eq!(human(1500), "1KB");
        assert_eq!(human(3 << 20), "3.0MB");
    }
}
