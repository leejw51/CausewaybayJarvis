#!/usr/bin/env bash
# Paint the backgrounds the LÖVE client uses, with Grok.
#
#   tools/grokart.sh              paint whatever is missing
#   tools/grokart.sh --force      repaint everything
#   tools/grokart.sh klementinum  repaint one plate
#
# The plates are 1280x720 photographic renders; the client crushes them to a
# sixteen-colour MSX palette at load, so what matters here is composition and
# light, not detail. They are not committed — `make art` is how a checkout
# gets them, and the client draws procedural art when they are absent.

set -euo pipefail

KEY="${XAI_API_KEY:-${GROK_API_KEY:-}}"
MODEL="${GROK_IMAGE_MODEL:-grok-imagine-image}"
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/love/assets/bg"

# A house style, appended to every plate: this is a background for a 16-colour
# game, so it wants deep shadow, one warm light source and no small print.
STYLE="Dramatic painterly video game background art, deep chiaroscuro shadows, \
one warm light source, rich saturated colour, wide cinematic composition, \
empty of people, no text, no letters, no watermark, no signature, no UI."

plate() {
  local name="$1" prompt="$2"
  local file="$OUT/$name.jpg"
  if [ -f "$file" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "  have  $name"
    return
  fi
  echo "  paint $name …"
  local body
  body=$(jq -nc --arg m "$MODEL" --arg p "$prompt $STYLE" \
    '{model:$m, prompt:$p, n:1, response_format:"b64_json"}')
  local response
  response=$(curl -sS -X POST https://api.x.ai/v1/images/generations \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d "$body")
  if ! jq -e '.data[0].b64_json' >/dev/null 2>&1 <<<"$response"; then
    echo "  failed $name: $(jq -r '.error.message // .error // .' <<<"$response" | head -3)" >&2
    return 1
  fi
  jq -r '.data[0].b64_json' <<<"$response" | base64 -d > "$file.tmp"
  mv "$file.tmp" "$file"
  echo "  wrote $name  ($(du -h "$file" | cut -f1))"
}

if [ -z "$KEY" ]; then
  echo "set XAI_API_KEY (or GROK_API_KEY) — the plates are painted by Grok." >&2
  exit 1
fi
mkdir -p "$OUT"

FORCE=0
WANT=()
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
    *) WANT+=("$arg") ;;
  esac
done
export FORCE

want() {
  [ ${#WANT[@]} -eq 0 ] && return 0
  for w in "${WANT[@]}"; do [ "$w" = "$1" ] && return 0; done
  return 1
}

echo "painting with $MODEL into love/assets/bg"

want klementinum && plate klementinum \
"The Baroque Library Hall of the Klementinum in Prague at night. Two storeys of \
dark walnut bookshelves running away to a far door, a barrel-vaulted ceiling of \
allegorical frescoes, enormous brass astronomical globes on the floor, hundreds \
of candles burning."

want prague-castle && plate prague-castle \
"Prague Castle and the spires of Saint Vitus Cathedral on the hill at night, \
seen across the black Vltava river from the Charles Bridge, the castle lit \
gold, a storm sky behind it, mist on the water."

want astronomical-tower && plate astronomical-tower \
"The interior of the Klementinum astronomical tower in Prague, a cramped stone \
observatory room, brass sextants and pendulum clocks and star charts, a single \
tall window with moonlight falling across the meridian line on the floor."

want charles-bridge && plate charles-bridge \
"The Charles Bridge in Prague before dawn in heavy fog, blackened baroque \
saint statues in a receding row, gas lamps, wet cobbles, the Old Town bridge \
tower looming ahead."

want medieval-prague && plate medieval-prague \
"A crooked lane in the Old Town of Prague in the fourteenth century, at night. \
Steep-gabled Gothic burgher houses of stone and timber leaning over the \
cobbles, the two black spires of the Tyn church rising behind the rooftops, \
pitch torches guttering in iron brackets, one shuttered window lit from \
within, frost on the stones, a cold moon."

want golden-lane && plate golden-lane \
"Golden Lane at Prague Castle at night in the sixteenth century, the tiny \
alchemists' cottages built into the castle wall, an arched stone passage \
receding, one furnace glowing orange through an open doorway, iron lanterns \
on hooks, cold blue moonlight on the cobbles, smoke."

want forge && plate forge \
"A medieval armourer's forge at night in fourteenth-century Prague. An empty \
suit of plate armour on a wooden stand in the middle of the room, more pieces \
hanging around it on chains and glowing at the edges, an anvil, a great \
bellows, tongs and hammers, a furnace throwing orange light across a cold blue \
room, sparks in the air."

want awakening && plate awakening \
"A suit of iron plate armour hanging apart in mid-air in a dark Gothic hall, \
the pieces floating as though about to come together, trailing sparks, runes \
glowing white-hot along the edges of the steel, a shaft of cold moonlight from \
a high window and hot orange sparks rising through it."

want cartridge && plate cartridge \
"A single arcane cartridge of black obsidian and gold, the size of a book, \
floating above a carved stone pedestal in a dark vaulted crypt, glowing runes \
cut into its face, sparks rising, shafts of light from above."

echo "done."
