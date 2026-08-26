//! Conversation state for the terminal UI.
//!
//! The transcript is kept twice on purpose: `messages` is what the chat template
//! sees, `blocks` is what the screen shows. They diverge because reasoning is
//! rendered as its own collapsible block while the template treats it as part of
//! the assistant turn.

use rustcore::engine::Stats;
use rustcore::{Message, Role};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    User,
    Reasoning,
    Answer,
    Notice,
}

#[derive(Debug, Clone)]
pub struct Block {
    pub kind: Kind,
    pub text: String,
}

pub struct App {
    pub blocks: Vec<Block>,
    pub messages: Vec<Message>,
    pub input: String,
    /// Byte offset of the caret inside `input`.
    pub cursor: usize,
    /// First visible wrapped line; `None` means pinned to the bottom.
    pub scroll: Option<u16>,
    pub busy: bool,
    pub status: String,
    pub show_thinking: bool,
    pub last_stats: Option<Stats>,
    pub should_quit: bool,
    pub interrupt: bool,
    history: Vec<String>,
    history_pos: Option<usize>,
}

impl App {
    pub fn new(system: Option<String>, show_thinking: bool) -> Self {
        let mut messages = Vec::new();
        if let Some(system) = system {
            messages.push(Message::system(system));
        }
        Self {
            blocks: Vec::new(),
            messages,
            input: String::new(),
            cursor: 0,
            scroll: None,
            busy: false,
            status: String::new(),
            show_thinking,
            last_stats: None,
            should_quit: false,
            interrupt: false,
            history: Vec::new(),
            history_pos: None,
        }
    }

    // ----- input editing -------------------------------------------------

    pub fn insert(&mut self, c: char) {
        self.input.insert(self.cursor, c);
        self.cursor += c.len_utf8();
    }

    pub fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let prev = self.input[..self.cursor]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
        self.input.replace_range(prev..self.cursor, "");
        self.cursor = prev;
    }

    pub fn delete(&mut self) {
        if self.cursor >= self.input.len() {
            return;
        }
        let next = self.input[self.cursor..]
            .char_indices()
            .nth(1)
            .map(|(i, _)| self.cursor + i)
            .unwrap_or(self.input.len());
        self.input.replace_range(self.cursor..next, "");
    }

    pub fn left(&mut self) {
        self.cursor = self.input[..self.cursor]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
    }

    pub fn right(&mut self) {
        self.cursor = self.input[self.cursor..]
            .char_indices()
            .nth(1)
            .map(|(i, _)| self.cursor + i)
            .unwrap_or(self.input.len());
    }

    pub fn home(&mut self) {
        self.cursor = 0;
    }

    pub fn end(&mut self) {
        self.cursor = self.input.len();
    }

    /// Take the current line, clearing the box and recording it in the history.
    pub fn take_input(&mut self) -> String {
        let text = std::mem::take(&mut self.input);
        self.cursor = 0;
        self.history_pos = None;
        let trimmed = text.trim().to_string();
        if !trimmed.is_empty() && self.history.last() != Some(&trimmed) {
            self.history.push(trimmed.clone());
        }
        trimmed
    }

    pub fn history_prev(&mut self) {
        if self.history.is_empty() {
            return;
        }
        let next = match self.history_pos {
            None => self.history.len() - 1,
            Some(0) => 0,
            Some(i) => i - 1,
        };
        self.history_pos = Some(next);
        self.input = self.history[next].clone();
        self.cursor = self.input.len();
    }

    pub fn history_next(&mut self) {
        match self.history_pos {
            Some(i) if i + 1 < self.history.len() => {
                self.history_pos = Some(i + 1);
                self.input = self.history[i + 1].clone();
            }
            Some(_) => {
                self.history_pos = None;
                self.input.clear();
            }
            None => {}
        }
        self.cursor = self.input.len();
    }

    // ----- transcript ----------------------------------------------------

    pub fn push_block(&mut self, kind: Kind, text: impl Into<String>) {
        self.blocks.push(Block {
            kind,
            text: text.into(),
        });
        self.scroll = None;
    }

    /// Append to the trailing block of this kind, starting one if needed.
    pub fn stream(&mut self, kind: Kind, text: &str) {
        match self.blocks.last_mut() {
            Some(block) if block.kind == kind => block.text.push_str(text),
            _ => self.blocks.push(Block {
                kind,
                text: text.to_string(),
            }),
        }
        self.scroll = None;
    }

    pub fn clear_conversation(&mut self) {
        self.blocks.clear();
        let system = self
            .messages
            .first()
            .filter(|m| m.role == Role::System)
            .cloned();
        self.messages.clear();
        self.messages.extend(system);
        self.last_stats = None;
        self.scroll = None;
    }

    /// Drop an empty trailing block, e.g. reasoning that produced nothing.
    pub fn trim_empty_tail(&mut self) {
        if self.blocks.last().is_some_and(|b| b.text.trim().is_empty()) {
            self.blocks.pop();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app() -> App {
        App::new(None, true)
    }

    #[test]
    fn editing_handles_multibyte_characters() {
        let mut a = app();
        for c in "héllo".chars() {
            a.insert(c);
        }
        assert_eq!(a.input, "héllo");
        a.backspace();
        assert_eq!(a.input, "héll");
        a.home();
        a.right();
        a.delete(); // removes 'é', two bytes
        assert_eq!(a.input, "hll");
        assert_eq!(a.cursor, 1);
    }

    #[test]
    fn streaming_appends_to_the_matching_block() {
        let mut a = app();
        a.stream(Kind::Answer, "hel");
        a.stream(Kind::Answer, "lo");
        assert_eq!(a.blocks.len(), 1);
        assert_eq!(a.blocks[0].text, "hello");

        a.stream(Kind::Reasoning, "hmm");
        assert_eq!(a.blocks.len(), 2);
    }

    #[test]
    fn history_walks_backwards_and_forwards() {
        let mut a = app();
        a.input = "one".into();
        a.take_input();
        a.input = "two".into();
        a.take_input();

        a.history_prev();
        assert_eq!(a.input, "two");
        a.history_prev();
        assert_eq!(a.input, "one");
        a.history_next();
        assert_eq!(a.input, "two");
        a.history_next();
        assert_eq!(a.input, "");
    }

    #[test]
    fn duplicate_entries_are_not_repeated_in_history() {
        let mut a = app();
        for _ in 0..3 {
            a.input = "same".into();
            a.take_input();
        }
        a.history_prev();
        assert_eq!(a.input, "same");
        a.history_prev();
        assert_eq!(a.input, "same", "there is only one entry to walk to");
    }

    #[test]
    fn reset_keeps_the_system_prompt() {
        let mut a = App::new(Some("be brief".into()), true);
        a.messages.push(Message::user("hi"));
        a.push_block(Kind::User, "hi");
        a.clear_conversation();
        assert_eq!(a.messages.len(), 1);
        assert_eq!(a.messages[0].role, Role::System);
        assert!(a.blocks.is_empty());
    }
}
