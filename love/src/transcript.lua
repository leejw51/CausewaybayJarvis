--- The conversation, off the screen and into a file or the clipboard.
---
--- Four shapes, because a saved conversation gets four different things done
--- to it: `jsonl` to hand back to a model, `markdown` to read, `csv` to open
--- in a spreadsheet, `txt` to paste anywhere at all.
---
--- Pure string work -- no `love.*` anywhere, and no clock. The scene does the
--- writing and passes the timestamp in, so what comes out of here can be
--- checked without a graphics context or a save directory, and two exports in
--- the same second are the caller's problem rather than a silent overwrite.

local M = {}

--- The order the export card lists them in: the machine-readable ones first,
--- because that is what an export is usually for.
M.FORMATS = { "jsonl", "markdown", "csv", "txt" }

M.LABEL = { jsonl = "JSONL", markdown = "MARKDOWN", csv = "CSV", txt = "TXT" }

M.EXTENSION = { jsonl = "jsonl", markdown = "md", csv = "csv", txt = "txt" }

-- `you` and `jarvis` are what this client calls them; `user` and `assistant`
-- are what a model expects to be handed back. `system` is already the standard
-- name, and `error` deliberately keeps its own: calling a fault a system
-- message puts the client's own bad news into the model's mouth on reload.
local JSONL_ROLE = { you = "user", jarvis = "assistant" }

-- ------------------------------------------------------------- escaping ---

local JSON_ESCAPE = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

--- A JSON string. Everything below a space that is not one of the five named
--- escapes goes out as `\u00XX`: a raw control byte inside a JSON string is
--- not JSON, and a transcript can hold one -- the model is free to emit it and
--- the clipboard is free to bring one in.
local function json_string(s)
  return '"' .. (tostring(s):gsub('[%z\1-\31\\"]', function(ch)
    return JSON_ESCAPE[ch] or string.format("\\u%04X", ch:byte())
  end)) .. '"'
end

--- A CSV field, RFC 4180: quoted whenever it holds a comma, a quote, a line
--- break or edge whitespace, and the quotes inside it doubled. A reply is
--- several paragraphs and a spreadsheet will take them in one cell, but only
--- if the quoting is right.
local function csv_field(s)
  s = tostring(s)
  if s:find('[",\r\n]') or s:find("^%s") or s:find("%s$") then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

-- -------------------------------------------------------------- writing ---

--- The line at the top of the human-readable formats: which model said this,
--- and when. `meta.model` and `meta.stamp` are both optional -- a demo run has
--- no model worth naming and neither one is worth a header of its own.
local function header(meta)
  local parts = {}
  if meta.model and meta.model ~= "" then parts[#parts + 1] = tostring(meta.model) end
  if meta.stamp and meta.stamp ~= "" then parts[#parts + 1] = tostring(meta.stamp) end
  return table.concat(parts, "  --  ")
end

local WRITERS = {}

function WRITERS.jsonl(log, _)
  local out = {}
  for _, entry in ipairs(log) do
    local role = JSONL_ROLE[entry.role] or entry.role or "system"
    out[#out + 1] = "{" .. table.concat({
      '"role":' .. json_string(role),
      '"content":' .. json_string(entry.body or ""),
    }, ",") .. "}\n"
  end
  return table.concat(out)
end

function WRITERS.markdown(log, meta)
  local out = { "# JARVIS transcript\n" }
  local head = header(meta)
  if head ~= "" then out[#out + 1] = "\n" .. head .. "\n" end
  for _, entry in ipairs(log) do
    -- The role is uppercased rather than looked up, so a role added to the
    -- chat scene appears here without a second table to keep in step.
    out[#out + 1] = "\n## " .. tostring(entry.role or "system"):upper() .. "\n\n"
    out[#out + 1] = (entry.body or "") .. "\n"
  end
  return table.concat(out)
end

function WRITERS.csv(log, _)
  local out = { "role,text\n" }
  for _, entry in ipairs(log) do
    out[#out + 1] = csv_field(entry.role or "system") .. ","
      .. csv_field(entry.body or "") .. "\r\n"
  end
  return table.concat(out)
end

function WRITERS.txt(log, meta)
  local out = {}
  local head = header(meta)
  if head ~= "" then out[#out + 1] = "JARVIS transcript  --  " .. head .. "\n\n" end
  for _, entry in ipairs(log) do
    -- The role on its own line in brackets rather than `YOU: ...`, because a
    -- reply is several paragraphs and a prefix only labels the first of them.
    out[#out + 1] = "[" .. tostring(entry.role or "system"):upper() .. "]\n"
    out[#out + 1] = (entry.body or "") .. "\n\n"
  end
  return table.concat(out)
end

--- Is this a format anything here knows how to write?
function M.has(format) return WRITERS[format] ~= nil end

--- The whole panel, as one string. An unknown format is written as `txt`
--- rather than refused: the caller is a button, and the four it can press are
--- the four in `FORMATS`.
function M.render(log, format, meta)
  return (WRITERS[format] or WRITERS.txt)(log or {}, meta or {})
end

--- What to call the file. The stamp is passed in for the same reason the
--- header's is: nothing in this file reads the clock.
function M.filename(format, stamp)
  return "transcript-" .. tostring(stamp) .. "." .. (M.EXTENSION[format] or "txt")
end

return M
