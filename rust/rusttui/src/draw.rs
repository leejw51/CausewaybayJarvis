//! Laying the conversation out on screen.

use ratatui::layout::{Constraint, Layout, Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{
    Block, BorderType, Borders, Paragraph, Scrollbar, ScrollbarOrientation, ScrollbarState,
};
use ratatui::Frame;
use rustcore::engine::EngineInfo;
use unicode_width::UnicodeWidthStr;

use crate::app::{App, Kind};

const USER: Color = Color::Cyan;
const REASONING: Color = Color::DarkGray;
const NOTICE: Color = Color::Yellow;

pub fn draw(frame: &mut Frame, app: &mut App, info: &EngineInfo) {
    let [header, body, input, footer] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(3),
        Constraint::Length(3),
        Constraint::Length(1),
    ])
    .areas(frame.area());

    draw_header(frame, header, info, app);
    draw_body(frame, body, app);
    draw_input(frame, input, app);
    draw_footer(frame, footer, app);
}

fn draw_header(frame: &mut Frame, area: Rect, info: &EngineInfo, app: &App) {
    let left = Span::styled(
        format!(" {} ", info.model),
        Style::default()
            .fg(Color::Black)
            .bg(USER)
            .add_modifier(Modifier::BOLD),
    );
    let middle = Span::styled(
        format!(
            "  {}  ·  {}  ",
            human_count(info.parameters),
            info.quantization
        ),
        Style::default().fg(REASONING),
    );
    let right = Span::styled(
        match &app.last_stats {
            Some(s) => format!("{:.1} tok/s  ·  {} ctx ", s.decode_tps(), s.prompt_tokens),
            None => String::new(),
        },
        Style::default().fg(REASONING),
    );

    let used: usize = left.width() + middle.width() + right.width();
    let pad = (area.width as usize).saturating_sub(used);
    frame.render_widget(
        Line::from(vec![left, middle, Span::raw(" ".repeat(pad)), right]),
        area,
    );
}

fn draw_body(frame: &mut Frame, area: Rect, app: &mut App) {
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let lines = wrap_transcript(app, inner.width as usize);
    let height = inner.height as usize;
    let total = lines.len();

    // `None` means follow the tail; an explicit offset means the user scrolled.
    let offset = match app.scroll {
        None => total.saturating_sub(height),
        Some(v) => (v as usize).min(total.saturating_sub(height)),
    };

    frame.render_widget(Paragraph::new(lines).scroll((offset as u16, 0)), inner);

    if total > height {
        let mut state = ScrollbarState::new(total.saturating_sub(height)).position(offset);
        frame.render_stateful_widget(
            Scrollbar::new(ScrollbarOrientation::VerticalRight),
            area,
            &mut state,
        );
    }
}

/// Wrap every block to the available width. Doing it here rather than leaving it
/// to `Paragraph`'s own wrapping means the scroll offset is in real screen lines.
fn wrap_transcript(app: &App, width: usize) -> Vec<Line<'static>> {
    let width = width.max(8);
    let mut out: Vec<Line<'static>> = Vec::new();

    for block in &app.blocks {
        if block.kind == Kind::Reasoning && !app.show_thinking {
            continue;
        }
        let (prefix, style) = match block.kind {
            Kind::User => ("› ", Style::default().fg(USER).add_modifier(Modifier::BOLD)),
            Kind::Reasoning => (
                "│ ",
                Style::default()
                    .fg(REASONING)
                    .add_modifier(Modifier::ITALIC),
            ),
            Kind::Answer => ("", Style::default()),
            Kind::Notice => ("! ", Style::default().fg(NOTICE)),
        };

        if !out.is_empty() {
            out.push(Line::raw(""));
        }
        if block.kind == Kind::Reasoning {
            out.push(Line::styled(
                "thinking".to_string(),
                Style::default().fg(REASONING),
            ));
        }

        let body_width = width.saturating_sub(prefix.width()).max(4);
        for source in block.text.split('\n') {
            if source.is_empty() {
                out.push(Line::raw(""));
                continue;
            }
            for piece in textwrap::wrap(source, body_width) {
                out.push(Line::styled(format!("{prefix}{piece}"), style));
            }
        }
    }
    out
}

fn draw_input(frame: &mut Frame, area: Rect, app: &App) {
    let title = if app.busy { " working " } else { " message " };
    let border = if app.busy { REASONING } else { USER };
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(border))
        .title(title);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    // Keep the caret on screen on a long line by scrolling the view horizontally.
    let caret = app.input[..app.cursor].width();
    let visible = inner.width.saturating_sub(1) as usize;
    let shift = caret.saturating_sub(visible);

    frame.render_widget(
        Paragraph::new(app.input.clone()).scroll((0, shift as u16)),
        inner,
    );
    if !app.busy {
        frame.set_cursor_position(Position::new(inner.x + (caret - shift) as u16, inner.y));
    }
}

fn draw_footer(frame: &mut Frame, area: Rect, app: &App) {
    let text = if app.busy {
        format!(" {}  ·  esc to stop", app.status)
    } else if app.status.is_empty() {
        " enter send  ·  ctrl-r reset  ·  ctrl-t thinking  ·  pgup/pgdn scroll  ·  ctrl-c quit"
            .to_string()
    } else {
        format!(" {}", app.status)
    };
    frame.render_widget(Line::styled(text, Style::default().fg(REASONING)), area);
}

pub fn human_count(n: u64) -> String {
    match n {
        n if n >= 1_000_000_000 => format!("{:.1}B", n as f64 / 1e9),
        n if n >= 1_000_000 => format!("{:.1}M", n as f64 / 1e6),
        n if n >= 1_000 => format!("{:.1}k", n as f64 / 1e3),
        n => n.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::App;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    fn info() -> EngineInfo {
        EngineInfo {
            model: "qwen3.8:27b-mlx".into(),
            architecture: "Qwen3_5ForConditionalGeneration".into(),
            quantization: "4-bit affine (group 64)".into(),
            parameters: 26_900_000_000,
            context_length: 262_144,
            weight_bytes: 15 * 1024 * 1024 * 1024,
        }
    }

    /// Render a frame and flatten it to text, so the assertions read like the
    /// screen does.
    fn render(app: &mut App, width: u16, height: u16) -> String {
        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        terminal.draw(|frame| draw(frame, app, &info())).unwrap();
        let buffer = terminal.backend().buffer().clone();
        (0..buffer.area.height)
            .map(|y| {
                (0..buffer.area.width)
                    .map(|x| buffer[(x, y)].symbol())
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn a_full_frame_shows_the_model_the_transcript_and_the_input() {
        let mut app = App::new(None, true);
        app.push_block(Kind::User, "what is 2+2?");
        app.push_block(Kind::Answer, "Four.");
        app.input = "next question".into();
        app.cursor = app.input.len();

        let screen = render(&mut app, 60, 14);
        assert!(screen.contains("qwen3.8:27b-mlx"), "{screen}");
        assert!(screen.contains("26.9B"), "{screen}");
        assert!(screen.contains("what is 2+2?"), "{screen}");
        assert!(screen.contains("Four."), "{screen}");
        assert!(screen.contains("next question"), "{screen}");
        assert!(
            screen.contains("message"),
            "the input box is labelled: {screen}"
        );
        assert!(
            screen.contains("enter send"),
            "the footer shows the keys: {screen}"
        );
    }

    #[test]
    fn the_footer_offers_a_way_out_while_generating() {
        let mut app = App::new(None, true);
        app.busy = true;
        app.status = "answering".into();
        let screen = render(&mut app, 60, 10);
        assert!(screen.contains("answering"), "{screen}");
        assert!(screen.contains("esc to stop"), "{screen}");
        assert!(screen.contains("working"), "{screen}");
    }

    #[test]
    fn a_narrow_window_still_renders() {
        let mut app = App::new(None, true);
        app.push_block(
            Kind::Answer,
            "a rather long answer that has to wrap several times over",
        );
        let screen = render(&mut app, 24, 12);
        assert!(screen.lines().all(|l| l.chars().count() <= 24), "{screen}");
        assert!(screen.contains("wrap"), "{screen}");
    }

    #[test]
    fn long_lines_are_wrapped_to_the_width() {
        let mut app = App::new(None, true);
        app.push_block(Kind::Answer, "aaaa bbbb cccc dddd eeee");
        let lines = wrap_transcript(&app, 10);
        assert!(lines.len() > 1);
        assert!(lines.iter().all(|l| l.width() <= 10), "{lines:?}");
    }

    #[test]
    fn reasoning_disappears_when_it_is_hidden() {
        let mut app = App::new(None, false);
        app.push_block(Kind::Reasoning, "secret");
        app.push_block(Kind::Answer, "visible");
        let text: String = wrap_transcript(&app, 40)
            .iter()
            .map(|l| l.to_string())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(!text.contains("secret"));
        assert!(text.contains("visible"));
    }

    #[test]
    fn blank_lines_in_the_source_survive() {
        let mut app = App::new(None, true);
        app.push_block(Kind::Answer, "one\n\ntwo");
        let lines = wrap_transcript(&app, 40);
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[1].width(), 0);
    }

    #[test]
    fn counts_are_abbreviated() {
        assert_eq!(human_count(27_000_000_000), "27.0B");
        assert_eq!(human_count(42), "42");
    }
}
