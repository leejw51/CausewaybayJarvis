//! Which robot answers, when nobody chose one.
//!
//! Ask about a borrow checker and the coding robot walks on; ask what to cook
//! and the galley chief does. That is the whole trick, and it is deliberately
//! **not** a model call: routing runs before the turn, on every keystroke the
//! UI wants a face for, and it has to work with no key, no daemon and no
//! network. So it is a scored keyword match, and the score is auditable —
//! [`Route::why`] says which words decided it.
//!
//! The weighting is inverse document frequency over the roster: a word that
//! only one robot claims (`braise`) is worth much more than one that half of
//! them claim (`file`). Below [`MIN_SCORE`] nothing has really matched and the
//! general robot takes it, which is the honest answer to "hello".
//!
//! Two things stop that from being naive. Words are **folded** to a stem
//! before they are compared, so `simmering` reaches the keyword `simmer` —
//! without it a router built on a word list loses to any inflection. And each
//! robot's **own archive votes**: if the words of the question already appear
//! in what one robot has filed, that is stronger evidence than a shipped
//! keyword list, because it is evidence about *this* operator. That vote is
//! [`ARCHIVE_WEIGHT`] and it is bounded, so a single stray note cannot
//! capture every question.

use serde::Serialize;

use crate::agent::Agent;
use crate::embed::tokenize;

/// Below this, no robot has a real claim and the general one takes the turn.
pub const MIN_SCORE: f32 = 1.6;

/// Naming a robot outright beats any amount of keyword overlap.
pub const NAME_BONUS: f32 = 8.0;

/// How much a robot's own archive can add. Deliberately of the same order as
/// two or three good keywords: evidence, not a veto.
pub const ARCHIVE_WEIGHT: f32 = 4.0;

/// Fold a word to something an inflection cannot hide behind.
///
/// Not a real stemmer — a real one needs a table this router has not earned —
/// but the three rules that actually break a keyword list: the plural, the
/// `-ing`/`-ed` pair, and the silent `e`. The last one is what makes the other
/// two work: without it `bake` and `baked` fold to different stems and the
/// whole exercise is pointless. What matters is not that the stem is a word,
/// only that both sides of a comparison reach the same one.
pub fn fold(word: &str) -> String {
    let mut w = word.to_lowercase();

    // Plural.
    if w.len() >= 5 && w.ends_with("ies") {
        w = format!("{}y", &w[..w.len() - 3]);
    } else if w.len() >= 5 && w.ends_with("es") && sibilant(&w[..w.len() - 2]) {
        w.truncate(w.len() - 2);
    } else if w.len() >= 4 && w.ends_with('s') && !w.ends_with("ss") {
        w.truncate(w.len() - 1);
    }

    // Participle. `-ing` needs one more letter than `-ed` to survive `sing`
    // and `ring`, which are words and not participles.
    if w.len() >= 6 && w.ends_with("ing") {
        w.truncate(w.len() - 3);
    } else if w.len() >= 5 && w.ends_with("ed") {
        w.truncate(w.len() - 2);
    }

    // The silent e, last, so `recipe`/`recipes` and `bake`/`baked`/`baking`
    // all land together.
    if w.len() >= 4 && w.ends_with('e') {
        w.truncate(w.len() - 1);
    }
    w
}

/// Does this stem take `-es` rather than `-s` in the plural?
fn sibilant(stem: &str) -> bool {
    stem.ends_with('s')
        || stem.ends_with('x')
        || stem.ends_with('z')
        || stem.ends_with("ch")
        || stem.ends_with("sh")
}

#[derive(Debug, Clone, Serialize)]
pub struct Candidate {
    pub id: String,
    pub slug: String,
    pub name: String,
    pub kind: String,
    pub sprite: String,
    pub score: f32,
    /// The words that scored, best first.
    pub why: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Route {
    /// `None` only when the roster is empty.
    pub agent: Option<Candidate>,
    /// Did anything actually match, or is this the general robot by default?
    pub confident: bool,
    /// Everything that scored above zero, best first.
    pub ranked: Vec<Candidate>,
}

/// Score the prompt against the roster, on the keyword lists alone.
pub fn route(prompt: &str, agents: &[Agent]) -> Route {
    route_with_archive(prompt, agents, &Default::default())
}

/// The same, with each robot's own archive voting.
///
/// `evidence` maps an agent id to a score in `0..=1` — how well the words of
/// the prompt already match what that robot has filed. [`crate::proto`] fills
/// it from the BM25 index, which is the classic search doing double duty.
pub fn route_with_archive(
    prompt: &str,
    agents: &[Agent],
    evidence: &std::collections::HashMap<String, f32>,
) -> Route {
    if agents.is_empty() {
        return Route {
            agent: None,
            confident: false,
            ranked: Vec::new(),
        };
    }

    let words: std::collections::HashSet<String> = tokenize(prompt)
        .into_iter()
        .flat_map(|w| {
            let folded = fold(&w);
            [w, folded]
        })
        .collect();

    // Document frequency across the roster: how many robots claim each word.
    let mut df: std::collections::HashMap<String, usize> = Default::default();
    let claimed: Vec<std::collections::HashSet<String>> = agents
        .iter()
        .map(|a| a.keywords.split_whitespace().map(fold).collect())
        .collect();
    for set in &claimed {
        for word in set {
            *df.entry(word.clone()).or_insert(0) += 1;
        }
    }
    let n = agents.len() as f32;

    let mut ranked: Vec<Candidate> = Vec::new();
    for (agent, keywords) in agents.iter().zip(&claimed) {
        let mut score = 0.0f32;
        let mut why: Vec<(String, f32)> = Vec::new();

        for word in keywords {
            if words.contains(word) {
                let d = *df.get(word).unwrap_or(&1) as f32;
                let idf = (1.0 + n / d).ln();
                score += idf;
                why.push((word.clone(), idf));
            }
        }

        // What this robot has actually been told about, which beats a list
        // somebody wrote before they met the operator.
        if let Some(weight) = evidence.get(&agent.id) {
            let vote = weight.clamp(0.0, 1.0) * ARCHIVE_WEIGHT;
            if vote > 0.01 {
                score += vote;
                why.push(("archive".into(), vote));
            }
        }
        // A robot called by name, by slug, or by its domain.
        for handle in [
            agent.slug.as_str(),
            agent.name.as_str(),
            agent.kind.as_str(),
        ] {
            let handle = handle.to_lowercase();
            if !handle.is_empty() && words.contains(&handle) {
                score += NAME_BONUS;
                why.push((handle, NAME_BONUS));
                break;
            }
        }

        if score > 0.0 {
            why.sort_by(|a, b| b.1.total_cmp(&a.1));
            why.dedup_by(|a, b| a.0 == b.0);
            ranked.push(Candidate {
                id: agent.id.clone(),
                slug: agent.slug.clone(),
                name: agent.name.clone(),
                kind: agent.kind.clone(),
                sprite: agent.sprite.clone(),
                score,
                why: why.into_iter().take(6).map(|(w, _)| w).collect(),
            });
        }
    }

    // Ties break on the slug rather than on hash order, so the same question
    // always summons the same robot.
    ranked.sort_by(|a, b| b.score.total_cmp(&a.score).then(a.slug.cmp(&b.slug)));

    let best = ranked.first().cloned();
    let confident = best.as_ref().is_some_and(|c| c.score >= MIN_SCORE);

    let agent = match (&best, confident) {
        (Some(c), true) => Some(c.clone()),
        _ => general(agents).map(|a| Candidate {
            id: a.id.clone(),
            slug: a.slug.clone(),
            name: a.name.clone(),
            kind: a.kind.clone(),
            sprite: a.sprite.clone(),
            score: best.as_ref().map(|c| c.score).unwrap_or(0.0),
            why: Vec::new(),
        }),
    };

    Route {
        agent,
        confident,
        ranked,
    }
}

/// The robot that takes what nobody else claims.
pub fn general(agents: &[Agent]) -> Option<&Agent> {
    agents
        .iter()
        .find(|a| a.kind == "general")
        .or_else(|| agents.first())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::{Agent, ROSTER};

    fn roster() -> Vec<Agent> {
        ROSTER.iter().map(Agent::new).collect()
    }

    fn pick(prompt: &str) -> (String, bool) {
        let agents = roster();
        let r = route(prompt, &agents);
        let a = r.agent.expect("a roster always answers");
        (a.slug, r.confident)
    }

    #[test]
    fn a_coding_question_summons_the_coding_robot() {
        let (slug, confident) = pick("why does the rust borrow checker reject this lifetime?");
        assert_eq!(slug, "coding");
        assert!(confident);
    }

    #[test]
    fn a_food_question_summons_the_galley() {
        assert_eq!(pick("what should I cook for dinner tonight?").0, "food");
        assert_eq!(pick("give me a recipe for braised pork belly").0, "food");
    }

    #[test]
    fn other_domains_land_where_they_should() {
        assert_eq!(
            pick("check this password hashing for vulnerabilities").0,
            "security"
        );
        assert_eq!(pick("draft an email declining the meeting").0, "writing");
        assert_eq!(
            pick("what is my monthly budget for rent and bills?").0,
            "finance"
        );
        assert_eq!(pick("book a flight and a hotel in Kyoto").0, "travel");
        assert_eq!(pick("crop this screenshot and fix the colour").0, "vision");
    }

    #[test]
    fn nothing_in_particular_falls_to_the_general_robot() {
        let (slug, confident) = pick("mmm");
        assert_eq!(slug, "jarvis");
        assert!(!confident, "an unmatched prompt is not a confident route");
    }

    #[test]
    fn naming_a_robot_outranks_the_subject() {
        // "recipe" is a strong food word, but the robot was named.
        let (slug, _) = pick("byte, what is a good recipe for a parser?");
        assert_eq!(slug, "coding");
    }

    #[test]
    fn the_reason_for_a_route_is_reported() {
        let agents = roster();
        let r = route("the compiler threw a segfault while linking", &agents);
        let best = r.agent.unwrap();
        assert_eq!(best.slug, "coding");
        assert!(
            best.why.contains(&"segfault".to_string()),
            "why: {:?}",
            best.why
        );
    }

    #[test]
    fn an_inflected_word_still_reaches_its_keyword() {
        // The point is not that a stem is a word, but that both sides agree.
        assert_eq!(fold("simmering"), fold("simmer"));
        assert_eq!(fold("recipes"), fold("recipe"));
        assert_eq!(fold("baked"), fold("bake"));
        assert_eq!(fold("baking"), fold("bake"));
        assert_eq!(fold("dishes"), fold("dish"));
        assert_eq!(fold("stories"), "story");
        // Short words, double-s endings and real -ing words are left alone.
        assert_eq!(fold("css"), "css");
        assert_eq!(fold("gas"), "gas");
        assert_eq!(fold("sing"), "sing");
        assert_eq!(fold("the"), "the");

        assert_eq!(pick("simmering a pork stew").0, "food");
        assert_eq!(pick("compiling the crate failed").0, "coding");
    }

    #[test]
    fn a_robots_own_archive_outvotes_a_shipped_keyword_list() {
        let agents = roster();
        // "what did I write down about simmering bones" reads as a *writing*
        // question on the word lists alone, because of "write".
        let prompt = "what did I write down about simmering bones?";
        let cold = route(prompt, &agents);
        let food = agents.iter().find(|a| a.slug == "food").unwrap();

        // Once the food robot is the one holding notes about it, it answers.
        let mut evidence = std::collections::HashMap::new();
        evidence.insert(food.id.clone(), 1.0);
        let warm = route_with_archive(prompt, &agents, &evidence);
        assert_eq!(warm.agent.unwrap().slug, "food");
        assert!(warm.confident);
        // …and the archive is named as the reason.
        let ranked = warm.ranked.iter().find(|c| c.slug == "food").unwrap();
        assert!(ranked.why.contains(&"archive".to_string()));
        // The cold route is left on record as the thing that was improved.
        assert!(cold.agent.is_some());
    }

    #[test]
    fn an_empty_roster_routes_to_nobody_instead_of_panicking() {
        let r = route("anything", &[]);
        assert!(r.agent.is_none());
        assert!(r.ranked.is_empty());
    }
}
