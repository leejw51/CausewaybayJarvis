"""Dump reference logits and a greedy continuation from mlx_lm.

The Rust port in `rust/rustmlx` has to agree with this. Run it once and check the
result into `tools/reference.json`; `cargo run --example logits_check` compares.

    python tools/reference_logits.py [model-repo] [out.json]
"""

import json
import sys

import mlx.core as mx
from mlx_lm import load
from mlx_lm.models.cache import make_prompt_cache

REPO = sys.argv[1] if len(sys.argv) > 1 else "mlx-community/Qwen3.8-27B-4bit"
OUT = sys.argv[2] if len(sys.argv) > 2 else "tools/reference.json"

# Thinking is switched off so the continuation is short and deterministic.
PROMPT = (
    "<|im_start|>user\nWhat is the capital of France?<|im_end|>\n"
    "<|im_start|>assistant\n<think>\n\n</think>\n\n"
)
STEPS = 24

model, tokenizer = load(REPO)
ids = tokenizer.encode(PROMPT, add_special_tokens=False)
print(f"prompt tokens: {len(ids)}", file=sys.stderr)

cache = make_prompt_cache(model)
logits = model(mx.array([ids]), cache=cache)
last = logits[0, -1].astype(mx.float32)
order = mx.argsort(-last)[:10].tolist()

record = {
    "repo": REPO,
    "prompt": PROMPT,
    "prompt_ids": [int(i) for i in ids],
    "top10": [{"id": int(i), "logit": float(last[i])} for i in order],
    "logsumexp": float(mx.logsumexp(last)),
}

# Greedy continuation, feeding one token at a time exactly like the Rust engine.
greedy = []
token = int(mx.argmax(last))
for _ in range(STEPS):
    greedy.append(token)
    out = model(mx.array([[token]]), cache=cache)
    token = int(mx.argmax(out[0, -1]))

record["greedy_ids"] = greedy
record["greedy_text"] = tokenizer.decode(greedy)

with open(OUT, "w") as f:
    json.dump(record, f, indent=2)
print(json.dumps({k: v for k, v in record.items() if k != "prompt_ids"}, indent=2))
