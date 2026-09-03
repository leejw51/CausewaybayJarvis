--- The raw C declarations, and finding the library they belong to.
--
-- This mirrors `rust/rustffi/include/jarvis.h` by hand, because LuaJIT's `ffi`
-- parses C but not the preprocessor. Nothing keeps the two in step
-- automatically, so the library reports its own ABI version and struct sizes
-- and this module refuses to load when they disagree — a mismatch is caught
-- here rather than as a corrupt struct three calls later.

local ffi = require("ffi")

ffi.cdef [[
/* ---- library ---- */
uint32_t    jarvis_abi_version(void);
const char *jarvis_version(void);
const char *jarvis_last_error(void);
void        jarvis_string_free(char *text);
size_t      jarvis_sizeof_params(void);
size_t      jarvis_sizeof_progress(void);
double      jarvis_monotonic(void);
uint64_t    jarvis_memory_active(void);
uint64_t    jarvis_memory_peak(void);

/* ---- parameters ---- */
typedef struct {
    uint64_t seed;
    uint32_t max_tokens;
    uint32_t top_k;
    uint32_t repetition_context;
    int32_t  has_seed;
    int32_t  enable_thinking;
    int32_t  preserve_thinking;
    float    temperature;
    float    top_p;
    float    min_p;
    float    repetition_penalty;
    char     reasoning_effort[16];
} JarvisParams;

int jarvis_params_default(JarvisParams *out);

/* ---- config ---- */
typedef struct JarvisConfig JarvisConfig;

JarvisConfig *jarvis_config_open(const char *path);
void          jarvis_config_free(JarvisConfig *cfg);
char         *jarvis_config_source(JarvisConfig *cfg);
char         *jarvis_config_get_json(JarvisConfig *cfg, const char *key);
char         *jarvis_config_system_prompt(JarvisConfig *cfg);
char         *jarvis_config_model_json(JarvisConfig *cfg);
int           jarvis_config_params(JarvisConfig *cfg, JarvisParams *out);

/* ---- models ---- */
char *jarvis_models_json(void);
char *jarvis_model_info_json(const char *alias, const char *revision, const char *repo);
int   jarvis_model_is_local(const char *alias, const char *revision, const char *repo);
int   jarvis_has_hf_token(void);

typedef struct {
    uint64_t files_total;
    uint64_t files_done;
    uint64_t bytes_total;
    uint64_t bytes_done;
    int32_t  finished;
    int32_t  _reserved;
    char     current[128];
} JarvisProgress;

typedef struct JarvisPull JarvisPull;

JarvisPull *jarvis_pull_start(const char *alias, const char *revision, const char *repo);
int         jarvis_pull_poll(JarvisPull *pull, JarvisProgress *out);
void        jarvis_pull_free(JarvisPull *pull);

/* ---- session ---- */
typedef struct JarvisSession JarvisSession;

typedef int (*JarvisEventFn)(int kind, const char *text, size_t len,
                             uint64_t a, uint64_t b, void *user);

JarvisSession *jarvis_open(const char *alias, const char *revision, const char *repo);
void           jarvis_close(JarvisSession *session);

char *jarvis_info_json(JarvisSession *session);
int   jarvis_set_system(JarvisSession *session, const char *text);
int   jarvis_reset(JarvisSession *session);
char *jarvis_messages_json(JarvisSession *session);
int   jarvis_messages_load(JarvisSession *session, const char *json);
char *jarvis_last_json(JarvisSession *session);
char *jarvis_render(JarvisSession *session, const char *text, const JarvisParams *params);

int jarvis_send(JarvisSession *session, const char *text, const JarvisParams *params,
                JarvisEventFn callback, void *user);
int jarvis_generate(JarvisSession *session, const char *prompt, const JarvisParams *params,
                    JarvisEventFn callback, void *user);

uint64_t jarvis_cached_tokens(JarvisSession *session);
uint64_t jarvis_cache_bytes(JarvisSession *session);
int64_t  jarvis_count_tokens(JarvisSession *session, const char *text);
char    *jarvis_truncate(JarvisSession *session, const char *text, size_t max_tokens);

/* ---- interrupts ---- */
int  jarvis_interrupt_install(void);
int  jarvis_interrupt_raised(void);
void jarvis_interrupt_clear(void);

/* ---- from libc, for the terminal and for polling a download ---- */
int isatty(int fd);
int usleep(unsigned int microseconds);
]]

local ABI_VERSION = 2

local M = {}

--- The directory this file sits in.
local function here()
  local source = debug.getinfo(1, "S").source:sub(2)
  return source:match("^(.*)[/\\][^/\\]*$") or "."
end

local function library_name()
  if ffi.os == "Windows" then
    return "jarvis.dll"
  elseif ffi.os == "OSX" then
    return "libjarvis.dylib"
  end
  return "libjarvis.so"
end

--- Where to look, in order: an explicit override, then the workspace build
--- output beside this checkout, then whatever the system linker can find.
function M.candidates()
  local name = library_name()
  local root = here() .. "/../../rust/target"
  local list = {}
  local override = os.getenv("JARVIS_LIB")
  if override then list[#list + 1] = override end
  list[#list + 1] = root .. "/release/" .. name
  list[#list + 1] = root .. "/debug/" .. name
  list[#list + 1] = "jarvis"
  return list
end

local function load_library()
  local tried = {}
  for _, path in ipairs(M.candidates()) do
    local ok, lib = pcall(ffi.load, path)
    if ok then return lib, path end
    tried[#tried + 1] = "  " .. path .. "\n    " .. tostring(lib):gsub("\n", " ")
  end
  error("libjarvis not found. Build it with `make ffi`, or set JARVIS_LIB.\ntried:\n"
    .. table.concat(tried, "\n"), 0)
end

local C, path = load_library()

local abi = C.jarvis_abi_version()
if abi ~= ABI_VERSION then
  error(string.format(
    "%s speaks ABI %d, these bindings speak %d — rebuild one of them (`make ffi`)",
    path, tonumber(abi), ABI_VERSION), 0)
end

-- The declarations above are a copy of the header, so check the copy: a field
-- added, reordered or differently padded shows up as a size mismatch.
local mismatch = {
  { "JarvisParams", ffi.sizeof("JarvisParams"), tonumber(C.jarvis_sizeof_params()) },
  { "JarvisProgress", ffi.sizeof("JarvisProgress"), tonumber(C.jarvis_sizeof_progress()) },
}
for _, row in ipairs(mismatch) do
  if row[2] ~= row[3] then
    error(string.format("%s is %d bytes here and %d bytes in %s — the cdef has drifted",
      row[1], row[2], row[3], path), 0)
  end
end

M.C = C
M.path = path
M.abi_version = ABI_VERSION

--- Sleep, in seconds. Used while polling a download.
function M.sleep(seconds)
  C.usleep(math.floor(seconds * 1e6))
end

return M
