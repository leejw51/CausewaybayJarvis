//! The clip beside every video: three seconds of it as Ogg Theora, which is
//! the one format LÖVE plays.
//!
//! A phone's video is H.264 or HEVC in an MP4 or a MOV, and LÖVE 11 decodes
//! none of that: `love.graphics.newVideo` reads Ogg Theora and nothing else.
//! So when a video is filed the original is kept as it came — a browser
//! plays it fine — and a short clip is encoded beside it on the same shelf:
//!
//! ```text
//! agents/<GUID>/videos/holiday.mov              the original, untouched
//! agents/<GUID>/videos/holiday.clip.ogv         the first three seconds, Theora, ≤640px
//! agents/<GUID>/videos/holiday.poster.png       one frame, for a thumbnail
//! ```
//!
//! The row's `meta` says where both are, or why there is neither. Filing
//! never fails for want of an encoder: a machine with no ffmpeg still files
//! the video, and the meta carries the sentence that fixes it.
//!
//! # Which encoder
//!
//! Homebrew's `ffmpeg` no longer links libtheora, so the clip is made by
//! whichever of these is on the machine, tried in this order:
//!
//! 1. `ffmpeg` carrying `libtheora` — one command.
//! 2. `ffmpeg` decoding into a `yuv4mpeg` pipe, `ffmpeg2theora` encoding it
//!    — the modern decoder for a phone's HEVC, the old encoder for Theora.
//!    `brew install ffmpeg2theora` is the usual way to get here.
//! 3. `ffmpeg2theora` alone, on what its own libav can decode.
//!
//! Every clip is silent: LÖVE plays a video's sound through a separate
//! `Source`, and a three-second preview does not need one.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;

use serde_json::{json, Value};

use crate::space::Space;

/// How much of the video the clip holds.
pub const CLIP_SECONDS: f64 = 3.0;
/// The clip fits in a box this big; a smaller source is not scaled up.
/// Theora decodes on the CPU, in the LÖVE window's own thread, so the clip
/// is kept small enough to draw at sixty frames a second on a laptop.
pub const CLIP_BOX: u32 = 640;
/// Theora quality, 0–10. Six is where the artefacts stop being the first
/// thing you see and the file stops being the size of the original.
pub const CLIP_QUALITY: u32 = 6;
/// Where in the video the poster frame is taken: a little way in, because
/// the first frame of a phone video is often black or a thumb.
pub const POSTER_AT: f64 = 0.5;

pub const CLIP_SUFFIX: &str = ".clip.ogv";
pub const POSTER_SUFFIX: &str = ".poster.png";

/// The clip and the poster as they were made, or why they were not.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Clip {
    /// Relative to the space, like every path the database holds.
    pub clip: String,
    pub poster: Option<String>,
    pub seconds: f64,
    pub width: Option<u32>,
    pub height: Option<u32>,
    /// The length of the original, when ffprobe could say.
    pub duration: Option<f64>,
    pub encoder: &'static str,
    pub bytes: u64,
}

/// The encoders this machine has, found once per process.
#[derive(Debug, Clone, Default)]
pub struct Tools {
    pub ffmpeg: Option<PathBuf>,
    pub ffprobe: Option<PathBuf>,
    pub ffmpeg2theora: Option<PathBuf>,
    /// Does `ffmpeg` carry the `libtheora` encoder?
    pub theora_in_ffmpeg: bool,
}

/// Which route to Theora a machine offers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Encoder {
    /// `ffmpeg -c:v libtheora`.
    Ffmpeg,
    /// `ffmpeg … -f yuv4mpegpipe - | ffmpeg2theora … -`.
    Pipe,
    /// `ffmpeg2theora` on its own.
    Ffmpeg2theora,
}

impl Encoder {
    pub fn as_str(self) -> &'static str {
        match self {
            Encoder::Ffmpeg => "ffmpeg+libtheora",
            Encoder::Pipe => "ffmpeg|ffmpeg2theora",
            Encoder::Ffmpeg2theora => "ffmpeg2theora",
        }
    }
}

impl Tools {
    /// The encoder to use, or the sentence that says what to install.
    pub fn encoder(&self) -> Result<Encoder, String> {
        match (&self.ffmpeg, self.theora_in_ffmpeg, &self.ffmpeg2theora) {
            (Some(_), true, _) => Ok(Encoder::Ffmpeg),
            (Some(_), false, Some(_)) => Ok(Encoder::Pipe),
            (None, _, Some(_)) => Ok(Encoder::Ffmpeg2theora),
            (Some(_), false, None) => Err(
                "ffmpeg has no Theora encoder — brew install ffmpeg2theora (the LÖVE clip needs Ogg Theora)"
                    .into(),
            ),
            (None, _, None) => {
                Err("no video encoder — brew install ffmpeg ffmpeg2theora (the LÖVE clip needs Ogg Theora)".into())
            }
        }
    }
}

/// Look the tools up once. A daemon under supervisord may have a bare
/// `PATH`, so the Homebrew and local prefixes are searched as well.
pub fn tools() -> &'static Tools {
    static TOOLS: OnceLock<Tools> = OnceLock::new();
    TOOLS.get_or_init(|| {
        let ffmpeg = which("ffmpeg");
        let theora_in_ffmpeg = ffmpeg
            .as_ref()
            .map(|bin| {
                Command::new(bin)
                    .args(["-hide_banner", "-encoders"])
                    .output()
                    .map(|o| String::from_utf8_lossy(&o.stdout).contains(" libtheora "))
                    .unwrap_or(false)
            })
            .unwrap_or(false);
        Tools {
            ffmpeg,
            ffprobe: which("ffprobe"),
            ffmpeg2theora: which("ffmpeg2theora"),
            theora_in_ffmpeg,
        }
    })
}

/// `PATH`, then the places Homebrew and MacPorts put things.
pub fn which(name: &str) -> Option<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    for extra in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] {
        dirs.push(PathBuf::from(extra));
    }
    dirs.into_iter().map(|d| d.join(name)).find(|p| p.is_file())
}

/// What ffprobe knows about a file: the first video stream's size and the
/// container's length.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Probe {
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration: Option<f64>,
}

pub fn probe(ffprobe: &Path, source: &Path) -> Probe {
    let out = Command::new(ffprobe)
        .args([
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height:format=duration",
            "-of",
            "json",
        ])
        .arg(source)
        .output();
    let Ok(out) = out else {
        return Probe::default();
    };
    parse_probe(&String::from_utf8_lossy(&out.stdout))
}

/// The interesting part of ffprobe's JSON. Pure, for the tests.
pub fn parse_probe(text: &str) -> Probe {
    let v: Value = serde_json::from_str(text).unwrap_or(Value::Null);
    let stream = v["streams"].get(0).cloned().unwrap_or(Value::Null);
    Probe {
        width: stream["width"].as_u64().map(|n| n as u32),
        height: stream["height"].as_u64().map(|n| n as u32),
        duration: v["format"]["duration"]
            .as_str()
            .and_then(|s| s.parse().ok())
            .or_else(|| v["format"]["duration"].as_f64()),
    }
}

/// The clip's and the poster's paths beside a filed video. Pure.
pub fn names(rel: &str) -> (String, String) {
    let stem = match rel.rsplit_once('.') {
        Some((base, ext)) if !ext.contains('/') && !base.is_empty() => base,
        _ => rel,
    };
    (
        format!("{stem}{CLIP_SUFFIX}"),
        format!("{stem}{POSTER_SUFFIX}"),
    )
}

/// The ffmpeg filter that fits a frame in [`CLIP_BOX`] without enlarging
/// it, and keeps both sides even, which Theora needs.
fn scale_filter() -> String {
    format!(
        "scale='min({CLIP_BOX},iw)':'min({CLIP_BOX},ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"
    )
}

/// The `ffmpeg` command line that makes the clip in one go. Pure.
pub fn ffmpeg_args(source: &Path, dest: &Path) -> Vec<String> {
    let mut args: Vec<String> = ["-y", "-hide_banner", "-loglevel", "error", "-i"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    args.push(source.to_string_lossy().into_owned());
    args.extend(
        [
            "-t",
            &CLIP_SECONDS.to_string(),
            "-an",
            "-sn",
            "-vf",
            &scale_filter(),
            "-c:v",
            "libtheora",
            "-q:v",
            &CLIP_QUALITY.to_string(),
        ]
        .iter()
        .map(|s| s.to_string()),
    );
    args.push(dest.to_string_lossy().into_owned());
    args
}

/// The decoding half of the pipe: ffmpeg writing raw frames to stdout.
pub fn pipe_decode_args(source: &Path) -> Vec<String> {
    let mut args: Vec<String> = ["-hide_banner", "-loglevel", "error", "-i"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    args.push(source.to_string_lossy().into_owned());
    args.extend(
        [
            "-t",
            &CLIP_SECONDS.to_string(),
            "-an",
            "-sn",
            "-vf",
            &scale_filter(),
            "-pix_fmt",
            "yuv420p",
            "-f",
            "yuv4mpegpipe",
            "-",
        ]
        .iter()
        .map(|s| s.to_string()),
    );
    args
}

/// The encoding half: ffmpeg2theora reading the pipe. No skeleton track,
/// because a stream with no known length gets one by default and LÖVE's
/// demuxer wants a plain Theora file.
pub fn pipe_encode_args(dest: &Path) -> Vec<String> {
    vec![
        "--noaudio".into(),
        "--no-skeleton".into(),
        "-v".into(),
        CLIP_QUALITY.to_string(),
        "-o".into(),
        dest.to_string_lossy().into_owned(),
        "-".into(),
    ]
}

/// `ffmpeg2theora` on its own, decoding as well as encoding.
pub fn ffmpeg2theora_args(source: &Path, dest: &Path) -> Vec<String> {
    vec![
        "--noaudio".into(),
        "--no-skeleton".into(),
        "-e".into(),
        CLIP_SECONDS.to_string(),
        "--max_size".into(),
        format!("{CLIP_BOX}x{CLIP_BOX}"),
        "-v".into(),
        CLIP_QUALITY.to_string(),
        "-o".into(),
        dest.to_string_lossy().into_owned(),
        source.to_string_lossy().into_owned(),
    ]
}

fn run(bin: &Path, args: &[String]) -> Result<(), String> {
    let out = Command::new(bin)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("running {}: {e}", bin.display()))?;
    if out.status.success() {
        return Ok(());
    }
    let err = String::from_utf8_lossy(&out.stderr);
    let line = err
        .lines()
        .rev()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("");
    Err(format!(
        "{} failed ({}): {}",
        bin.file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default(),
        out.status,
        line.trim()
    ))
}

fn encode(tools: &Tools, encoder: Encoder, source: &Path, dest: &Path) -> Result<(), String> {
    match encoder {
        Encoder::Ffmpeg => run(
            tools.ffmpeg.as_ref().expect("encoder() checked"),
            &ffmpeg_args(source, dest),
        ),
        Encoder::Ffmpeg2theora => run(
            tools.ffmpeg2theora.as_ref().expect("encoder() checked"),
            &ffmpeg2theora_args(source, dest),
        ),
        Encoder::Pipe => {
            let ffmpeg = tools.ffmpeg.as_ref().expect("encoder() checked");
            let f2t = tools.ffmpeg2theora.as_ref().expect("encoder() checked");
            let mut decoder = Command::new(ffmpeg)
                .args(pipe_decode_args(source))
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .map_err(|e| format!("running ffmpeg: {e}"))?;
            let frames: Stdio = decoder.stdout.take().expect("piped").into();
            let encoded = Command::new(f2t)
                .args(pipe_encode_args(dest))
                .stdin(frames)
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .output()
                .map_err(|e| format!("running ffmpeg2theora: {e}"))?;
            let decoded = decoder
                .wait_with_output()
                .map_err(|e| format!("waiting for ffmpeg: {e}"))?;
            if !decoded.status.success() {
                let err = String::from_utf8_lossy(&decoded.stderr);
                return Err(format!(
                    "ffmpeg failed ({}): {}",
                    decoded.status,
                    err.lines().last().unwrap_or("").trim()
                ));
            }
            if !encoded.status.success() {
                let err = String::from_utf8_lossy(&encoded.stderr);
                return Err(format!(
                    "ffmpeg2theora failed ({}): {}",
                    encoded.status,
                    err.lines().last().unwrap_or("").trim()
                ));
            }
            Ok(())
        }
    }
}

/// One frame as a PNG, for the thumbnail. Needs ffmpeg; a machine with only
/// ffmpeg2theora goes without.
fn poster(tools: &Tools, source: &Path, dest: &Path) -> Result<(), String> {
    let ffmpeg = tools
        .ffmpeg
        .as_ref()
        .ok_or_else(|| "no ffmpeg for the poster frame".to_string())?;
    let at = |seconds: f64| -> Vec<String> {
        let mut args: Vec<String> = ["-y", "-hide_banner", "-loglevel", "error", "-ss"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        args.push(seconds.to_string());
        args.push("-i".into());
        args.push(source.to_string_lossy().into_owned());
        args.extend(
            ["-frames:v", "1", "-an", "-vf", &scale_filter()]
                .iter()
                .map(|s| s.to_string()),
        );
        args.push(dest.to_string_lossy().into_owned());
        args
    };
    // A video shorter than the offset has no frame there; the first frame
    // is the fallback.
    match run(ffmpeg, &at(POSTER_AT)) {
        Ok(()) if dest.is_file() => Ok(()),
        _ => {
            run(ffmpeg, &at(0.0))?;
            if dest.is_file() {
                Ok(())
            } else {
                Err("ffmpeg wrote no poster frame".into())
            }
        }
    }
}

/// Make the clip and the poster beside a video already on its shelf.
/// `rel` is the video's path relative to the space. The error is a
/// sentence for the row's `meta`, never a reason not to file the video.
pub fn make(space: &Space, rel: &str) -> Result<Clip, String> {
    let tools = tools();
    let encoder = tools.encoder()?;
    let source = space.resolve(rel).map_err(|e| e.to_string())?;
    let (clip_rel, poster_rel) = names(rel);
    let clip_path = space.resolve(&clip_rel).map_err(|e| e.to_string())?;
    let poster_path = space.resolve(&poster_rel).map_err(|e| e.to_string())?;

    let started = std::time::Instant::now();
    encode(tools, encoder, &source, &clip_path)?;
    let bytes = std::fs::metadata(&clip_path).map(|m| m.len()).unwrap_or(0);
    if bytes == 0 {
        let _ = std::fs::remove_file(&clip_path);
        return Err(format!("{} wrote an empty clip", encoder.as_str()));
    }
    let poster_made = poster(tools, &source, &poster_path).is_ok();

    let info = tools
        .ffprobe
        .as_ref()
        .map(|p| probe(p, &clip_path))
        .unwrap_or_default();
    let duration = tools
        .ffprobe
        .as_ref()
        .and_then(|p| probe(p, &source).duration);
    eprintln!(
        "video: {clip_rel} ({bytes} bytes) in {:.1}s via {}",
        started.elapsed().as_secs_f64(),
        encoder.as_str()
    );
    Ok(Clip {
        clip: clip_rel,
        poster: poster_made.then_some(poster_rel),
        seconds: info.duration.unwrap_or(CLIP_SECONDS).min(CLIP_SECONDS),
        width: info.width,
        height: info.height,
        duration,
        encoder: encoder.as_str(),
        bytes,
    })
}

/// What the row's `meta` carries about the clip: the paths when it was
/// made, the reason when it was not.
pub fn meta(made: &Result<Clip, String>) -> Value {
    match made {
        Ok(clip) => serde_json::to_value(clip).unwrap_or_else(|_| json!({})),
        Err(why) => json!({ "clip": Value::Null, "why": why }),
    }
}

/// The words a video row is findable by, since the pixels are not: what it
/// is, how long, how big. The name is the title and is indexed already.
pub fn caption(made: &Result<Clip, String>) -> String {
    match made {
        Ok(clip) => {
            let mut out = String::from("video");
            if let Some(d) = clip.duration {
                out.push_str(&format!(", {d:.1} s"));
            }
            if let (Some(w), Some(h)) = (clip.width, clip.height) {
                out.push_str(&format!(", clip {w}×{h}"));
            }
            out.push_str(&format!(", {:.0}-second LÖVE clip", clip.seconds));
            out
        }
        Err(_) => "video".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_clip_and_poster_sit_beside_the_video() {
        let (clip, poster) = names("agents/g/videos/holiday.mov");
        assert_eq!(clip, "agents/g/videos/holiday.clip.ogv");
        assert_eq!(poster, "agents/g/videos/holiday.poster.png");
        // No extension: the suffixes are simply appended.
        assert_eq!(names("global/videos/raw").0, "global/videos/raw.clip.ogv");
        // A dot in a folder name is not an extension.
        assert_eq!(names("a.b/videos/raw").0, "a.b/videos/raw.clip.ogv");
    }

    #[test]
    fn the_encoder_is_picked_from_what_is_installed() {
        let none = Tools::default();
        assert!(none.encoder().unwrap_err().contains("brew install"));
        let both = Tools {
            ffmpeg: Some("/x/ffmpeg".into()),
            ffmpeg2theora: Some("/x/ffmpeg2theora".into()),
            ..Default::default()
        };
        assert_eq!(both.encoder(), Ok(Encoder::Pipe));
        let theora = Tools {
            theora_in_ffmpeg: true,
            ..both.clone()
        };
        assert_eq!(theora.encoder(), Ok(Encoder::Ffmpeg));
        let alone = Tools {
            ffmpeg: None,
            ..both.clone()
        };
        assert_eq!(alone.encoder(), Ok(Encoder::Ffmpeg2theora));
        let bare = Tools {
            ffmpeg2theora: None,
            ..both
        };
        assert!(bare.encoder().unwrap_err().contains("ffmpeg2theora"));
    }

    #[test]
    fn the_command_lines_cut_three_seconds_and_drop_the_sound() {
        let src = Path::new("/in/a.mov");
        let dst = Path::new("/out/a.clip.ogv");
        let one = ffmpeg_args(src, dst);
        assert!(one.windows(2).any(|w| w == ["-t", "3"]), "{one:?}");
        assert!(one.contains(&"-an".to_string()));
        assert!(one.windows(2).any(|w| w == ["-c:v", "libtheora"]));
        assert_eq!(one.last().unwrap(), "/out/a.clip.ogv");

        let dec = pipe_decode_args(src);
        assert!(dec.windows(2).any(|w| w == ["-f", "yuv4mpegpipe"]));
        assert_eq!(dec.last().unwrap(), "-");
        let enc = pipe_encode_args(dst);
        assert!(enc.contains(&"--no-skeleton".to_string()));
        assert_eq!(enc.last().unwrap(), "-");

        let alone = ffmpeg2theora_args(src, dst);
        assert!(alone.windows(2).any(|w| w == ["-e", "3"]));
        assert!(alone.windows(2).any(|w| w == ["--max_size", "640x640"]));
        assert_eq!(alone.last().unwrap(), "/in/a.mov");
    }

    #[test]
    fn ffprobe_json_is_read_for_size_and_length() {
        let p = parse_probe(
            r#"{"streams":[{"width":320,"height":240}],"format":{"duration":"5.000000"}}"#,
        );
        assert_eq!(
            p,
            Probe {
                width: Some(320),
                height: Some(240),
                duration: Some(5.0)
            }
        );
        assert_eq!(parse_probe("not json"), Probe::default());
    }

    #[test]
    fn meta_carries_the_clip_or_the_reason() {
        let why: Result<Clip, String> = Err("no encoder".into());
        let m = meta(&why);
        assert!(m["clip"].is_null());
        assert_eq!(m["why"], json!("no encoder"));
        assert_eq!(caption(&why), "video");

        let made: Result<Clip, String> = Ok(Clip {
            clip: "global/videos/a.clip.ogv".into(),
            poster: Some("global/videos/a.poster.png".into()),
            seconds: 3.0,
            width: Some(640),
            height: Some(360),
            duration: Some(12.25),
            encoder: "ffmpeg|ffmpeg2theora",
            bytes: 100,
        });
        let m = meta(&made);
        assert_eq!(m["clip"], json!("global/videos/a.clip.ogv"));
        assert_eq!(m["seconds"], json!(3.0));
        assert!(caption(&made).contains("12.2 s") || caption(&made).contains("12.3 s"));
        assert!(caption(&made).contains("640×360"));
    }
}
