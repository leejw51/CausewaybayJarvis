//! Compare this Rust port against the reference `mlx_lm` implementation.
//!
//! `tools/reference_logits.py` writes `tools/reference.json`; this replays the
//! same prompt through `rustmlx` and checks the top-10 logits and a greedy
//! continuation match.
//!
//!     cargo run --release -p rustmlx --example logits_check

use anyhow::{anyhow, Context, Result};
use mlx_rs::{ops, transforms, Array, Dtype};
use rustmlx::model::{tokens_to_array, Model};
use rustmlx::{memory, Weights};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct TopEntry {
    id: u32,
    logit: f32,
}

#[derive(Debug, Deserialize)]
struct Reference {
    repo: String,
    prompt_ids: Vec<u32>,
    top10: Vec<TopEntry>,
    greedy_ids: Vec<u32>,
    greedy_text: String,
}

fn main() -> Result<()> {
    let path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "tools/reference.json".into());
    let reference: Reference = serde_json::from_str(
        &std::fs::read_to_string(&path).with_context(|| format!("reading {path}"))?,
    )?;
    println!(
        "reference: {} ({} prompt tokens)",
        reference.repo,
        reference.prompt_ids.len()
    );

    let spec = rustcore::models::resolve(&reference.repo, "main")?;
    let files = rustcore::hub::local(&spec)?;

    let started = std::time::Instant::now();
    let mut weights = Weights::load(&files.weights)?;
    let config = rustmlx::ModelConfig::load(&files.config)?;
    let model = Model::from_weights(config, &mut weights)?;
    println!(
        "loaded {} layers, {} of weights in {:.1}s",
        model.num_layers(),
        memory::human(model.weight_bytes()),
        started.elapsed().as_secs_f64()
    );
    let unclaimed: Vec<_> = weights.remaining().take(5).collect();
    if !unclaimed.is_empty() {
        println!(
            "note: {} tensors went unused, e.g. {unclaimed:?}",
            weights.len()
        );
    }

    let mut cache = model.make_cache();
    let started = std::time::Instant::now();
    let logits = model.prefill(&reference.prompt_ids, &mut cache, |_| {})?;
    let prefill = started.elapsed().as_secs_f64();
    println!(
        "prefill: {} tokens in {prefill:.2}s ({:.0} tok/s)",
        reference.prompt_ids.len(),
        reference.prompt_ids.len() as f64 / prefill
    );

    let row = to_host(&logits)?;
    let mut order: Vec<u32> = (0..row.len() as u32).collect();
    order.sort_unstable_by(|&a, &b| row[b as usize].total_cmp(&row[a as usize]));

    println!(
        "\n{:<8} {:>12} {:>12} {:>10}",
        "token", "reference", "rust", "delta"
    );
    let mut worst: f32 = 0.0;
    let mut rank_mismatch = 0;
    for (i, entry) in reference.top10.iter().enumerate() {
        let ours = row[entry.id as usize];
        let delta = (ours - entry.logit).abs();
        worst = worst.max(delta);
        if order[i] != entry.id {
            rank_mismatch += 1;
        }
        println!(
            "{:<8} {:>12.4} {:>12.4} {:>10.4}",
            entry.id, entry.logit, ours, delta
        );
    }
    println!("\nlargest logit difference: {worst:.4}");
    println!("top-10 ordering mismatches: {rank_mismatch}");

    // Greedy continuation, one token at a time.
    let started = std::time::Instant::now();
    let mut produced = Vec::with_capacity(reference.greedy_ids.len());
    let mut token = rustmlx::sample::argmax(&row);
    for _ in 0..reference.greedy_ids.len() {
        produced.push(token);
        let out = model.forward(&tokens_to_array(&[token]), &mut cache, true)?;
        transforms::eval([&out])?;
        token = rustmlx::sample::argmax(&to_host(&out)?);
    }
    let decode = started.elapsed().as_secs_f64();
    println!(
        "\ndecode: {} tokens in {decode:.2}s ({:.1} tok/s)",
        produced.len(),
        produced.len() as f64 / decode
    );

    let tokenizer = rustcore::Tokenizer::load(&files.tokenizer, &files.root)?;
    let text = tokenizer.decode(&produced)?;
    println!("\nreference: {:?}", reference.greedy_text);
    println!("rust     : {text:?}");

    let agree = produced
        .iter()
        .zip(&reference.greedy_ids)
        .take_while(|(a, b)| a == b)
        .count();
    println!(
        "\ngreedy tokens matching: {agree}/{}",
        reference.greedy_ids.len()
    );
    println!("peak memory: {}", memory::human(memory::peak()));

    if agree != reference.greedy_ids.len() {
        return Err(anyhow!(
            "diverged at token {agree}: rust {:?} vs reference {:?}",
            produced.get(agree),
            reference.greedy_ids.get(agree)
        ));
    }
    println!("\nOK — the Rust port matches mlx_lm.");
    Ok(())
}

fn to_host(logits: &Array) -> Result<Vec<f32>> {
    let row = logits.reshape(&[-1])?.as_dtype(Dtype::Float32)?;
    transforms::eval([&row])?;
    Ok(row.as_slice::<f32>().to_vec())
}

#[allow(dead_code)]
fn unused(_: &Array) -> Result<Array> {
    Ok(ops::zeros::<f32>(&[1])?)
}
