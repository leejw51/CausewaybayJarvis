//! A robot: a GUID, a face, a persona, and a corner of the disk.
//!
//! The GUID is the identity. Everything else about a robot — its name, the
//! sprite it wears, the words it answers in — can be edited; the GUID is made
//! once, names its folder (`agents/<GUID>/`), and is what every context row
//! points at. `slug` is the stable *handle* the UI and the router use, so that
//! "the coding one" survives a rename.

use serde::{Deserialize, Serialize};

use crate::db::now;
use crate::space::{new_guid, Space};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Agent {
    /// The GUID. Its folder is `agents/<id>`.
    pub id: String,
    /// Stable handle: `coding`, `food`, `jarvis`.
    pub slug: String,
    pub name: String,
    /// The domain it answers for. The router matches on this and `keywords`.
    pub kind: String,
    pub role: String,
    /// Which robot sprite it wears: `assets/agent_<sprite>.png`.
    pub sprite: String,
    pub color: String,
    /// The system prompt for this robot's turns.
    pub persona: String,
    /// Space-separated routing hints.
    pub keywords: String,
    /// Relative path of its space: `agents/<id>`.
    pub space: String,
    pub created_at: i64,
    pub updated_at: i64,
}

impl Agent {
    pub fn new(seed: &Seed) -> Self {
        let id = new_guid();
        let space = Space::agent_space(Some(&id));
        let t = now();
        Self {
            id,
            slug: seed.slug.to_string(),
            name: seed.name.to_string(),
            kind: seed.kind.to_string(),
            role: seed.role.to_string(),
            sprite: seed.sprite.to_string(),
            color: seed.color.to_string(),
            persona: seed.persona.to_string(),
            keywords: seed.keywords.to_string(),
            space,
            created_at: t,
            updated_at: t,
        }
    }

    /// The system prompt a turn opens with.
    pub fn system_prompt(&self) -> String {
        format!(
            "You are {}, the {} robot of the Causeway Bay swarm ({}). {}\n\
             Answer in at most six sentences unless asked for more. \
             You may call the tools you were given to read or write this robot's own \
             archive of notes, files and photos before you answer.",
            self.name, self.kind, self.role, self.persona
        )
    }
}

/// One entry of the shipped roster.
#[derive(Debug, Clone, Copy)]
pub struct Seed {
    pub slug: &'static str,
    pub name: &'static str,
    pub kind: &'static str,
    pub role: &'static str,
    pub sprite: &'static str,
    pub color: &'static str,
    pub persona: &'static str,
    pub keywords: &'static str,
}

/// The robots a fresh space is born with. Every `sprite` here has a matching
/// `assets/agent_<sprite>.png` and `assets/agent_<sprite>_fly.png` in the
/// LOVE client, which is what makes a robot a *face* and not a row.
pub const ROSTER: &[Seed] = &[
    Seed {
        slug: "jarvis",
        name: "JARVIS",
        kind: "general",
        role: "CORE BUTLER",
        sprite: "jarvis",
        color: "gold",
        persona: "You are the house butler: unflappable, dry, and brief. \
                  You take anything that does not belong to a specialist.",
        keywords: "hello hi help general anything status swarm butler jarvis chat talk",
    },
    Seed {
        slug: "coding",
        name: "BYTE",
        kind: "coding",
        role: "CODE WRANGLER",
        sprite: "byte",
        color: "cyan",
        persona: "You write and debug software. Prefer a small correct example \
                  over an essay, and say plainly when something will not work.",
        keywords: "code coding program programming bug debug compile compiler error \
                   stack trace function rust python lua javascript typescript c cpp java \
                   git commit merge rebase refactor test unit api sql regex build make \
                   cargo npm docker kubernetes shell script algorithm borrow checker \
                   segfault exception crash lint type null pointer async thread",
    },
    Seed {
        slug: "food",
        name: "EMBER",
        kind: "food",
        role: "GALLEY CHIEF",
        sprite: "ember",
        color: "orange",
        persona: "You cook. Give quantities, heat and timing, and assume a home \
                  kitchen unless told otherwise.",
        keywords: "food cook cooking recipe recipes eat eating meal meals dinner lunch \
                   breakfast supper kitchen bake baking roast fry grill boil simmer \
                   ingredient ingredients spice sauce dough pasta rice noodle soup stew \
                   restaurant menu taste flavour flavor hungry snack dessert cake bread \
                   vegetable meat fish chicken beef pork tofu wine coffee tea",
    },
    Seed {
        slug: "research",
        name: "JADE",
        kind: "research",
        role: "ARCHIVIST",
        sprite: "jade",
        color: "jade",
        persona: "You look things up, compare sources, and separate what is known \
                  from what is guessed. Cite what you searched.",
        keywords: "research find look lookup search paper study source sources cite \
                   citation reference history background compare comparison evidence \
                   fact facts explain define definition meaning archive library document \
                   summary summarise summarize analysis",
    },
    Seed {
        slug: "writing",
        name: "NEON",
        kind: "writing",
        role: "COMMS",
        sprite: "neon",
        color: "magenta",
        persona: "You draft and edit prose: mail, posts, copy, replies. \
                  Match the register you are given and cut what does not earn its place.",
        keywords: "write writing draft rewrite edit editing prose email mail letter \
                   message reply post blog article copy headline tone grammar spelling \
                   translate translation summary caption script speech pitch",
    },
    Seed {
        slug: "vision",
        name: "IRIS",
        kind: "vision",
        role: "OPTICS",
        sprite: "iris",
        color: "teal",
        persona: "You look at pictures: what is in them, what they say, what is wrong \
                  with them. You keep the photo shelf of this space in order.",
        keywords: "image images photo photos picture pictures screenshot screenshots \
                   camera gallery album png jpg jpeg draw drawing sketch diagram chart \
                   scan ocr visual look see colour color crop resize",
    },
    Seed {
        slug: "finance",
        name: "TALLY",
        kind: "finance",
        role: "COUNTING HOUSE",
        sprite: "tally",
        color: "lime",
        persona: "You handle money: budgets, prices, invoices, arithmetic that has to \
                  be right. Show the sum, not just the answer.",
        keywords: "money budget cost costs price prices spend spending invoice bill \
                   payment pay salary tax taxes bank account savings expense expenses \
                   currency exchange rate interest loan mortgage stock stocks crypto \
                   profit loss revenue accounting receipt",
    },
    Seed {
        slug: "health",
        name: "IVY",
        kind: "health",
        role: "MEDIC",
        sprite: "ivy",
        color: "green",
        persona: "You handle training, sleep and everyday wellbeing. You are not a \
                  doctor and you say so when the question needs one.",
        keywords: "health fitness exercise workout training run running gym weight \
                   sleep tired stress diet nutrition calories protein stretch injury \
                   pain sore doctor medicine symptom rest recovery walk yoga heart",
    },
    Seed {
        slug: "travel",
        name: "ORBIT",
        kind: "travel",
        role: "NAVIGATOR",
        sprite: "orbit",
        color: "blue",
        persona: "You plan journeys: routes, timings, what to book and in what order.",
        keywords: "travel trip journey flight flights airport hotel booking book train \
                   bus taxi route map direction directions city country visa passport \
                   itinerary luggage weather timezone holiday vacation tour station \
                   drive driving distance",
    },
    Seed {
        slug: "design",
        name: "LUMEN",
        kind: "design",
        role: "ATELIER",
        sprite: "lumen",
        color: "yellow",
        persona: "You handle layout, type, colour and the look of things. \
                  You give one opinion, not five options.",
        keywords: "design layout ui ux typography font colour color palette spacing \
                   grid logo brand icon interface mockup wireframe css style theme \
                   contrast alignment aesthetic look visual poster",
    },
    Seed {
        slug: "security",
        name: "SENTRY",
        kind: "security",
        role: "WARDEN",
        sprite: "sentry",
        color: "red",
        persona: "You look for what can go wrong: permissions, secrets, inputs nobody \
                  validated. You describe the risk before the fix.",
        keywords: "security secure vulnerability exploit attack attacker password \
                   passwords secret secrets key keys token auth authentication permission \
                   permissions encrypt encryption tls ssl certificate firewall audit \
                   injection xss csrf privacy leak breach backup ransomware malware",
    },
    Seed {
        slug: "data",
        name: "VECTOR",
        kind: "data",
        role: "COMPUTER",
        sprite: "vector",
        color: "violet",
        persona: "You do maths and data: statistics, transforms, and the shape of a \
                  dataset. Show the working.",
        keywords: "data maths math mathematics calculate calculation number numbers \
                   statistics statistic average mean median graph plot chart dataset csv \
                   table matrix vector probability equation solve algebra geometry \
                   percentage ratio regression model machine learning embedding",
    },
];

pub fn seed_for(slug: &str) -> Option<&'static Seed> {
    ROSTER.iter().find(|s| s.slug == slug)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_roster_slug_and_sprite_is_unique() {
        let mut slugs: Vec<&str> = ROSTER.iter().map(|s| s.slug).collect();
        let n = slugs.len();
        slugs.sort_unstable();
        slugs.dedup();
        assert_eq!(slugs.len(), n, "duplicate slug in the roster");

        let mut sprites: Vec<&str> = ROSTER.iter().map(|s| s.sprite).collect();
        sprites.sort_unstable();
        sprites.dedup();
        assert_eq!(sprites.len(), n, "two robots wearing the same face");
    }

    #[test]
    fn a_new_agent_gets_a_guid_and_a_matching_space() {
        let a = Agent::new(&ROSTER[1]);
        assert_eq!(a.slug, "coding");
        assert_eq!(a.space, format!("agents/{}", a.id));
        assert_ne!(a.id, Agent::new(&ROSTER[1]).id);
        assert!(a.system_prompt().contains("BYTE"));
    }
}
