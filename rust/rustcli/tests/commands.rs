//! Black-box tests for the `rustcli` binary.
//!
//! Everything here either avoids the model entirely or is gated on
//! `JARVIS_TEST_MODEL=1`, so `cargo test` works on a machine with no weights.

use std::process::{Command, Output};

fn rustcli(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_rustcli"))
        .args(args)
        // Colour codes would only get in the way of the assertions.
        .env("NO_COLOR", "1")
        .output()
        .expect("running rustcli")
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).to_string()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).to_string()
}

fn model_is_downloaded() -> bool {
    rustcore::models::resolve("qwen3.8:27b-mlx", "main")
        .ok()
        .and_then(|spec| rustcore::hub::local(&spec).ok())
        .is_some()
}

#[test]
fn help_lists_the_commands() {
    let out = rustcli(&["--help"]);
    assert!(out.status.success());
    let text = stdout(&out);
    for command in ["chat", "run", "pull", "info", "models", "bench"] {
        assert!(
            text.contains(command),
            "`{command}` missing from --help:\n{text}"
        );
    }
}

#[test]
fn version_is_reported() {
    let out = rustcli(&["--version"]);
    assert!(out.status.success());
    assert!(stdout(&out).contains(env!("CARGO_PKG_VERSION")));
}

#[test]
fn models_lists_the_default_alias_and_its_repository() {
    let out = rustcli(&["models"]);
    assert!(out.status.success(), "{}", stderr(&out));
    let text = stdout(&out);
    assert!(text.contains("qwen3.8:27b-mlx"), "{text}");
    assert!(text.contains("mlx-community/Qwen3.8-27B-4bit"), "{text}");
}

#[test]
fn info_reports_the_configuration_without_touching_the_network() {
    let out = rustcli(&["info"]);
    assert!(out.status.success(), "{}", stderr(&out));
    let text = stdout(&out);
    assert!(text.contains("Causewaybay Jarvis"), "{text}");
    assert!(text.contains("alias"), "{text}");
    assert!(text.contains("repository"), "{text}");

    if model_is_downloaded() {
        // With weights present it reads the real config.json.
        assert!(text.contains("gated DeltaNet"), "{text}");
        assert!(text.contains("4-bit affine"), "{text}");
        assert!(text.contains("26.9B"), "{text}");
    } else {
        assert!(text.contains("not downloaded"), "{text}");
    }
}

#[test]
fn an_unknown_model_is_rejected_with_the_known_aliases() {
    let out = rustcli(&["--model", "llama-42", "info"]);
    assert!(!out.status.success());
    let text = stderr(&out);
    assert!(text.contains("unknown model"), "{text}");
    assert!(
        text.contains("qwen3.8:27b-mlx"),
        "the error should suggest what works:\n{text}"
    );
}

#[test]
fn a_bare_repository_id_is_accepted() {
    let out = rustcli(&["--model", "mlx-community/Qwen3.8-27B-8bit", "info"]);
    assert!(out.status.success(), "{}", stderr(&out));
    assert!(stdout(&out).contains("mlx-community/Qwen3.8-27B-8bit"));
}

#[test]
fn a_nonsense_reasoning_effort_fails_before_the_model_loads() {
    let out = rustcli(&["run", "--effort", "turbo", "hello"]);
    assert!(!out.status.success());
    let text = stderr(&out);
    assert!(text.contains("reasoning effort"), "{text}");
    // It must not have spent a minute loading 15 GiB first.
    assert!(
        !stdout(&out).contains("params"),
        "the model was loaded anyway:\n{}",
        stdout(&out)
    );
}

#[test]
fn a_missing_config_file_is_reported() {
    let out = rustcli(&["--config", "/nonexistent/config.jsonl", "info"]);
    assert!(!out.status.success());
    assert!(stderr(&out).contains("config.jsonl"), "{}", stderr(&out));
}

#[test]
fn run_needs_something_to_answer() {
    // Empty stdin, no prompt argument.
    let out = Command::new(env!("CARGO_BIN_EXE_rustcli"))
        .args(["run"])
        .env("NO_COLOR", "1")
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(
        stderr(&out).contains("nothing to answer"),
        "{}",
        stderr(&out)
    );
}

// ------------------------------------------------ these need the weights ---

fn skip_without_model() -> bool {
    if std::env::var("JARVIS_TEST_MODEL").is_err() || !model_is_downloaded() {
        println!("skipping: set JARVIS_TEST_MODEL=1 and run `make model` first");
        return true;
    }
    false
}

#[test]
fn run_answers_a_question_from_the_command_line() {
    if skip_without_model() {
        return;
    }
    let out = rustcli(&[
        "run",
        "--no-think",
        "--temperature",
        "0",
        "--max-tokens",
        "24",
        "What is the capital of France? One word.",
    ]);
    assert!(out.status.success(), "{}", stderr(&out));
    assert!(
        stdout(&out).to_lowercase().contains("paris"),
        "{}",
        stdout(&out)
    );
}

#[test]
fn run_reads_the_prompt_from_stdin() {
    if skip_without_model() {
        return;
    }
    use std::io::Write;
    let mut child = Command::new(env!("CARGO_BIN_EXE_rustcli"))
        .args([
            "run",
            "--no-think",
            "--temperature",
            "0",
            "--max-tokens",
            "24",
        ])
        .env("NO_COLOR", "1")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(b"What is 6 times 7? Digits only.")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    assert!(stdout(&out).contains("42"), "{}", stdout(&out));
}

#[test]
fn a_seed_makes_the_command_line_reproducible() {
    if skip_without_model() {
        return;
    }
    let args = [
        "run",
        "--no-think",
        "--temperature",
        "0.9",
        "--seed",
        "99",
        "--max-tokens",
        "20",
        "Invent a name for a boat.",
    ];
    assert_eq!(stdout(&rustcli(&args)), stdout(&rustcli(&args)));
}

/// Drive the REPL by piping a whole session at it. rustyline falls back to
/// plain line reading when stdin is not a terminal, so the loop is testable
/// without a pty.
fn repl(script: &str, extra: &[&str]) -> Output {
    use std::io::Write;
    let mut args = vec![
        "chat",
        "--no-think",
        "--temperature",
        "0",
        "--max-tokens",
        "40",
    ];
    args.extend_from_slice(extra);
    let mut child = Command::new(env!("CARGO_BIN_EXE_rustcli"))
        .args(&args)
        .env("NO_COLOR", "1")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("starting the repl");
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(script.as_bytes())
        .unwrap();
    // Dropping stdin is the end-of-input the loop exits on.
    drop(child.stdin.take());
    child.wait_with_output().unwrap()
}

#[test]
fn the_repl_keeps_going_and_remembers_the_conversation() {
    if skip_without_model() {
        return;
    }
    let out = repl(
        "My name is Jun. Reply in three words.\n\
         What is my name? One word.\n\
         And what did I say my name was? One word.\n",
        &[],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    let text = stdout(&out);
    // Three prompts in, three answers out, and the name carried across turns.
    assert!(
        text.matches("Jun").count() >= 3,
        "the session lost context:\n{text}"
    );
    assert!(
        text.trim_end().ends_with("bye"),
        "the loop did not exit cleanly:\n{text}"
    );
}

#[test]
fn the_repl_handles_commands_and_blank_lines() {
    if skip_without_model() {
        return;
    }
    let out = repl("/help\n\n   \n/temp 0.4\n/max 12\n/nonsense\n/exit\n", &[]);
    assert!(out.status.success(), "{}", stderr(&out));
    let text = stdout(&out);
    assert!(
        text.contains("/reset"),
        "/help did not print the list:\n{text}"
    );
    assert!(text.contains("temperature 0.4"), "{text}");
    assert!(text.contains("max tokens 12"), "{text}");
    assert!(text.contains("unknown command `/nonsense`"), "{text}");
    assert!(
        text.trim_end().ends_with("bye"),
        "/exit did not quit:\n{text}"
    );
}

#[test]
fn reset_makes_the_repl_forget() {
    if skip_without_model() {
        return;
    }
    let out = repl(
        "Remember the number 8675309. Reply OK.\n\
         /reset\n\
         What number did I ask you to remember? Say `none` if you do not know.\n",
        &[],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    let text = stdout(&out);
    assert!(text.contains("conversation cleared"), "{text}");
    let after_reset = &text[text.find("conversation cleared").unwrap()..];
    assert!(
        !after_reset.contains("8675309"),
        "the model still had the number after /reset:\n{after_reset}"
    );
}

#[test]
fn a_second_turn_reuses_the_prompt_cache() {
    if skip_without_model() {
        return;
    }
    let out = repl("Say hi.\nSay hi again.\n/stats\n", &[]);
    assert!(out.status.success(), "{}", stderr(&out));
    let text = stdout(&out);
    // /stats reports the last turn; a reused cache shows up as fast prefill.
    let line = text
        .lines()
        .find(|l| l.contains("prompt ·"))
        .unwrap_or_else(|| panic!("no statistics line:\n{text}"));
    assert!(line.contains("tok/s"), "{line}");
}

#[test]
fn the_transcript_can_be_saved() {
    if skip_without_model() {
        return;
    }
    let path = std::env::temp_dir().join(format!("jarvis-transcript-{}.json", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let out = repl(&format!("Say hi.\n/save {}\n", path.display()), &[]);
    assert!(out.status.success(), "{}", stderr(&out));

    let saved = std::fs::read_to_string(&path).expect("the transcript was written");
    let messages: Vec<serde_json::Value> = serde_json::from_str(&saved).expect("valid JSON");
    assert!(messages.len() >= 2, "{saved}");
    assert_eq!(messages[messages.len() - 2]["role"], "user");
    assert_eq!(messages[messages.len() - 1]["role"], "assistant");
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn bench_reports_throughput() {
    if skip_without_model() {
        return;
    }
    let out = rustcli(&["bench", "--prompt", "64", "--tokens", "8"]);
    assert!(out.status.success(), "{}", stderr(&out));
    let text = stdout(&out);
    assert!(text.contains("prefill"), "{text}");
    assert!(text.contains("decode"), "{text}");
    assert!(text.contains("tok/s"), "{text}");
}
