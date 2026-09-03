/*
 * libjarvis — the C ABI of Causewaybay Jarvis, an on-device agent running
 * Qwen3.8 on Apple MLX. This header is the canonical declaration; the
 * implementation lives in rust/rustffi.
 *
 *   Strings in   NUL-terminated UTF-8, borrowed for the call only.
 *   Strings out  owned by you — free them with jarvis_string_free().
 *                Structured results are JSON text.
 *   Failure      NULL, or a negative number; the reason is in
 *                jarvis_last_error(), thread-local and valid until the next
 *                call on that thread.
 *   Panics       never cross this boundary; they arrive as errors.
 *
 * A session drives one GPU queue and is not thread-safe: use it from the
 * thread that opened it. Downloads are the exception and run behind a polling
 * handle so that no callback is ever entered from a foreign thread.
 *
 *   Handles      opaque; never dereference one. A handle that has been freed
 *                is refused by every later call, for the life of the process.
 *   Reentrancy   an event callback must not call back in on the session it was
 *                fired for — the turn holds it. Such a call fails with an
 *                error, and so does closing that session from inside one.
 *
 * Link with -ljarvis, or dlopen()/ffi.load() libjarvis.dylib.
 */

#ifndef JARVIS_H
#define JARVIS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------- library ---- */

/* The layout and signatures below. Check this at load time. */
#define JARVIS_ABI_VERSION 2

uint32_t    jarvis_abi_version(void);
const char *jarvis_version(void);       /* static storage, do not free */
const char *jarvis_last_error(void);    /* NULL when the last call succeeded */
void        jarvis_string_free(char *text);

size_t jarvis_sizeof_params(void);      /* 64 */
size_t jarvis_sizeof_progress(void);    /* 168 */

/* Seconds from a fixed point, for throttling a progress display. */
double   jarvis_monotonic(void);
uint64_t jarvis_memory_active(void);    /* MLX's current allocation, bytes */
uint64_t jarvis_memory_peak(void);      /* high-water mark of the last turn */

/* ---------------------------------------------------------- parameters ---- */

typedef struct {
    uint64_t seed;                 /* honoured only when has_seed != 0        */
    uint32_t max_tokens;
    uint32_t top_k;
    uint32_t repetition_context;
    int32_t  has_seed;
    int32_t  enable_thinking;      /* let the model open a <think> block      */
    int32_t  preserve_thinking;    /* keep old <think> blocks — cache reuse   */
    float    temperature;          /* 0 is greedy                             */
    float    top_p;
    float    min_p;
    float    repetition_penalty;
    char     reasoning_effort[16]; /* "low" | "medium" | "xhigh"              */
} JarvisParams;

int jarvis_params_default(JarvisParams *out);

/* -------------------------------------------------------------- config ---- */

typedef struct JarvisConfig JarvisConfig;

/* path may be NULL, which discovers config.jsonl the way rustcli does. */
JarvisConfig *jarvis_config_open(const char *path);
void          jarvis_config_free(JarvisConfig *cfg);
char         *jarvis_config_source(JarvisConfig *cfg);         /* NULL if built in */
char         *jarvis_config_get_json(JarvisConfig *cfg, const char *key);
char         *jarvis_config_system_prompt(JarvisConfig *cfg);  /* NULL if unset */
char         *jarvis_config_model_json(JarvisConfig *cfg);
int           jarvis_config_params(JarvisConfig *cfg, JarvisParams *out);

/* -------------------------------------------------------------- models ---- */

/* Everywhere below: alias is an alias or a bare "org/name"; revision and repo
 * may be NULL, and repo overrides whatever the alias resolves to. */

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
    char     current[128];   /* the file that last made progress */
} JarvisProgress;

typedef struct JarvisPull JarvisPull;

JarvisPull *jarvis_pull_start(const char *alias, const char *revision, const char *repo);
/* 1 running, 0 finished, -1 failed. out may be NULL. A failure is sticky: every
 * later poll reports -1 with the same reason, never 0. */
int         jarvis_pull_poll(JarvisPull *pull, JarvisProgress *out);
void        jarvis_pull_free(JarvisPull *pull);

/* ------------------------------------------------------------- session ---- */

typedef struct JarvisSession JarvisSession;

/* Kinds passed to a JarvisEventFn. */
#define JARVIS_EVENT_PREFILL        0  /* a = tokens read, b = tokens total */
#define JARVIS_EVENT_REASONING      1  /* a chunk of the <think> block      */
#define JARVIS_EVENT_TOKEN          2  /* a chunk of the visible answer     */
#define JARVIS_EVENT_REASONING_DONE 3  /* </think> closed                   */
#define JARVIS_EVENT_TOOL           4  /* what a turn ran; backend only     */

/* text is NUL-terminated, len bytes long, and valid for this call only.
 * Return 0 to keep generating, non-zero to stop.
 * Do not call back into this library on the session being generated for; the
 * counters and the interrupt flag it might want are reachable without it. */
typedef int (*JarvisEventFn)(int kind, const char *text, size_t len,
                             uint64_t a, uint64_t b, void *user);

/* Loads weights already on disk; pull first if jarvis_model_is_local() is 0. */
JarvisSession *jarvis_open(const char *alias, const char *revision, const char *repo);
/* Refused, leaving the session open, if called from inside its own callback. */
void           jarvis_close(JarvisSession *session);

char *jarvis_info_json(JarvisSession *session);
int   jarvis_set_system(JarvisSession *session, const char *text); /* NULL removes it */
int   jarvis_reset(JarvisSession *session);                        /* keeps the system prompt */

char *jarvis_messages_json(JarvisSession *session);
int   jarvis_messages_load(JarvisSession *session, const char *json);
char *jarvis_last_json(JarvisSession *session);                    /* NULL before the first turn */
char *jarvis_render(JarvisSession *session, const char *text, const JarvisParams *params);

int jarvis_send(JarvisSession *session, const char *text, const JarvisParams *params,
                JarvisEventFn callback, void *user);
/* A raw, already-templated prompt. Does not touch the transcript, but does
 * share — and therefore invalidate — the conversation's cache. */
int jarvis_generate(JarvisSession *session, const char *prompt, const JarvisParams *params,
                    JarvisEventFn callback, void *user);

uint64_t jarvis_cached_tokens(JarvisSession *session);
uint64_t jarvis_cache_bytes(JarvisSession *session);
int64_t  jarvis_count_tokens(JarvisSession *session, const char *text);
/* Cut text down to at most max_tokens, on a token boundary. */
char    *jarvis_truncate(JarvisSession *session, const char *text, size_t max_tokens);

/* -------------------------------------------------------------- agent ---- */

/*
 * The robot backend — the archive, the roster, both searches, a turn with its
 * tools — in this process rather than behind a socket to agentd. The reply is
 * the same protocol envelope the daemon would send, from the same dispatch.
 *
 * One space per process: opening again closes what was open first, and calls
 * are serialised, so a second thread's call waits rather than races.
 *
 *   jarvis_agent_open("/Users/me/.causewaybayjarvis", NULL);
 *   char *reply = jarvis_agent_call("{\"op\":\"agents.list\"}", NULL, NULL);
 *   puts(reply);
 *   jarvis_string_free(reply);
 *
 * root           the space to open; NULL means $JARVIS_HOME or the default.
 * overrides_json a JSON object of settings for this backend alone — the
 *                in-process equivalent of variables on agentd's command line.
 */
int   jarvis_agent_open(const char *root, const char *overrides_json);
int   jarvis_agent_is_open(void);
char *jarvis_agent_root(void);          /* NULL when nothing is open */
void  jarvis_agent_close(void);

/* One request, one reply. A backend refusal is a reply with "ok": false; NULL
 * means the request never got there — nothing open, or text that is not JSON.
 * The callback fires only for "chat" and "brain.chat", on this thread, and
 * returning non-zero stops the turn. */
char *jarvis_agent_call(const char *request_json, JarvisEventFn callback, void *user);

/* ---------------------------------------------------------- interrupts ---- */

/* Take over Ctrl-C. The handler only sets a flag — poll it from inside your
 * event callback and return non-zero to stop the turn. A signal handler cannot
 * safely re-enter most language runtimes; reading a flag between tokens can. */
int  jarvis_interrupt_install(void);
int  jarvis_interrupt_raised(void);
void jarvis_interrupt_clear(void);

#ifdef __cplusplus
}
#endif

#endif /* JARVIS_H */
