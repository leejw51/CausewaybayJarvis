//! Streaming, over whatever brain this build and machine can offer.
//!
//! The point of a streaming brain is that the first piece arrives long
//! before the last one, and that the pieces joined back together are
//! exactly the answer the non-streaming call would have given. Both are
//! checked here against a fake brain, which is the only way to assert on
//! timing without a GPU; the real engines are exercised by
//! `make test-model`.

use std::sync::{Arc, Mutex};

use anyhow::Result;
use serde_json::Value;

use rustagent::harness::{Brain, Chunk, Sink};
use rustagent::ollama::{Message, Reply};

/// A brain that answers in five pieces, with a beat between them.
struct Slow {
    pieces: Vec<&'static str>,
}

impl Brain for Slow {
    fn chat(&self, _m: &[Message], _t: &[Value]) -> Result<Reply> {
        Ok(Reply {
            message: Message::assistant(self.pieces.concat()),
            done_reason: "stop".into(),
        })
    }
    fn label(&self) -> String {
        "slow".into()
    }
    fn streams(&self) -> bool {
        true
    }
    fn chat_stream(&self, _m: &[Message], _t: &[Value], sink: &mut Sink<'_>) -> Result<Reply> {
        let mut whole = String::new();
        for piece in &self.pieces {
            std::thread::sleep(std::time::Duration::from_millis(20));
            whole.push_str(piece);
            if !sink(Chunk::Token(piece)) {
                return Ok(Reply {
                    message: Message::assistant(whole),
                    done_reason: "interrupted".into(),
                });
            }
        }
        Ok(Reply {
            message: Message::assistant(whole),
            done_reason: "stop".into(),
        })
    }
}

/// A brain with nothing to stream: the default `chat_stream`.
struct Blunt;

impl Brain for Blunt {
    fn chat(&self, _m: &[Message], _t: &[Value]) -> Result<Reply> {
        Ok(Reply {
            message: Message::assistant("all at once"),
            done_reason: "stop".into(),
        })
    }
    fn label(&self) -> String {
        "blunt".into()
    }
}

fn collect(brain: &dyn Brain) -> (Vec<String>, Reply) {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let sink_seen = seen.clone();
    let mut sink = move |chunk: Chunk<'_>| {
        if let Chunk::Token(text) = chunk {
            sink_seen.lock().unwrap().push(text.to_string());
        }
        true
    };
    let reply = brain
        .chat_stream(&[Message::user("go")], &[], &mut sink)
        .expect("streaming");
    let out = seen.lock().unwrap().clone();
    (out, reply)
}

#[test]
fn a_streaming_brain_arrives_in_pieces_that_rejoin_into_the_whole_answer() {
    let brain = Slow {
        pieces: vec!["the ", "suit ", "is ", "coming ", "together"],
    };
    let (pieces, reply) = collect(&brain);
    assert_eq!(pieces.len(), 5, "{pieces:?}");
    assert_eq!(pieces.concat(), "the suit is coming together");
    assert_eq!(reply.message.content, pieces.concat());
    assert_eq!(reply.done_reason, "stop");
}

#[test]
fn the_first_piece_lands_long_before_the_last() {
    let brain = Slow {
        pieces: vec!["a", "b", "c", "d", "e"],
    };
    let started = std::time::Instant::now();
    let first: Arc<Mutex<Option<std::time::Duration>>> = Arc::new(Mutex::new(None));
    let mark = first.clone();
    let mut sink = move |_: Chunk<'_>| {
        let mut slot = mark.lock().unwrap();
        if slot.is_none() {
            *slot = Some(started.elapsed());
        }
        true
    };
    brain
        .chat_stream(&[Message::user("go")], &[], &mut sink)
        .unwrap();
    let whole = started.elapsed();
    let first = first.lock().unwrap().expect("a first piece");
    assert!(
        first < whole / 2,
        "the first piece waited for the answer: {first:?} of {whole:?}"
    );
}

#[test]
fn a_sink_that_says_stop_ends_the_generation_there() {
    let brain = Slow {
        pieces: vec!["one", "two", "three", "four", "five"],
    };
    let mut n = 0;
    let mut sink = |_: Chunk<'_>| {
        n += 1;
        n < 2
    };
    let reply = brain
        .chat_stream(&[Message::user("go")], &[], &mut sink)
        .unwrap();
    assert_eq!(n, 2, "the sink was called after it said stop");
    assert_eq!(reply.done_reason, "interrupted");
    assert_eq!(reply.message.content, "onetwo");
}

#[test]
fn a_brain_with_nothing_to_stream_still_answers_the_streaming_call() {
    let (pieces, reply) = collect(&Blunt);
    assert!(!Blunt.streams(), "and says so");
    assert_eq!(pieces, vec!["all at once".to_string()]);
    assert_eq!(reply.message.content, "all at once");
}

/// A tool call is not prose. It arrives as text, but the operator must
/// never watch a raw `<tool_call>` block type itself across the screen —
/// the harness runs it and shows the result instead.
#[test]
fn a_tool_call_block_is_held_back_from_the_stream() {
    use rustagent::ondevice::in_tool_call;
    assert!(!in_tool_call("here is an ordinary answer"));
    assert!(in_tool_call("thinking <tool_call>"));
    assert!(in_tool_call("<tool_call>{\"name\":\"search\"}"));
    assert!(!in_tool_call("<tool_call>{}</tool_call>"));
    assert!(!in_tool_call("<tool_call>{}</tool_call> and then prose"));
    // A tag halfway through being typed is not prose either.
    assert!(in_tool_call("answer <tool_c"));
    assert!(!in_tool_call("a < b"));
}
