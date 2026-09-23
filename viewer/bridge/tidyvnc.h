/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_C_API_H
#define TIDYVNC_C_API_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define TIDYVNC_ABI_VERSION 1u
/* Internal versioned ABI. All calls are thread-safe and nonblocking with respect
 * to protocol work; create may allocate/start threads. No caller thread joins.
 * IDs are opaque, process-local, typed by the implementation, and never reused.
 * Each returned handle owns one reference; retain/release on any thread. Keep a
 * reference throughout each call and while using borrowed spans. A final session
 * release initiates close; a final runtime release initiates shutdown. Draining
 * is explicit and can be polled without waiting. Invalid IDs are rejected.
 *
 * Caller pointers must address accessible memory for their declared lengths;
 * the ABI validates null/length/overflow, not arbitrary address accessibility.
 * Initialize every struct to zero, then set size=sizeof(struct), version=1.
 * Larger structs are accepted: known input reserved fields must be zero; unknown tail
 * bytes are ignored and never written. Unsupported versions/mandatory flags fail.
 * Outputs remain unchanged on failure/NO_CHANGE/PENDING, except optional errors.
 * Output handles must be released before overwriting their storage on a new call.
 */
typedef uint64_t tidyvnc_handle;
typedef uint32_t tidyvnc_status;
enum {
  TIDYVNC_OK = 0, TIDYVNC_NO_CHANGE = 1, TIDYVNC_PENDING = 2,
  TIDYVNC_INVALID_ARGUMENT = 10, TIDYVNC_ABI_MISMATCH = 11,
  TIDYVNC_UNSUPPORTED = 12, TIDYVNC_INVALID_HANDLE = 13,
  TIDYVNC_WRONG_HANDLE_TYPE = 14, TIDYVNC_RESOURCE_LIMIT = 15,
  TIDYVNC_OUT_OF_MEMORY = 16, TIDYVNC_STALE = 17,
  TIDYVNC_NOT_CONNECTED = 18, TIDYVNC_CLOSING = 19, TIDYVNC_BUSY = 20,
  TIDYVNC_QUEUE_FULL = 21, TIDYVNC_CANCELLED = 22,
  TIDYVNC_NOT_PENDING = 23, TIDYVNC_FAILED = 24, TIDYVNC_INTERNAL = 25,
  TIDYVNC_VIEW_ONLY = 26, TIDYVNC_UNFOCUSED = 27,
  TIDYVNC_DISABLED = 28, TIDYVNC_ECHO = 29
};
enum { TIDYVNC_DOMAIN_BRIDGE = 1, TIDYVNC_DOMAIN_ENDPOINT = 2,
       TIDYVNC_DOMAIN_OPERATION = 3, TIDYVNC_DOMAIN_INPUT = 4,
       TIDYVNC_DOMAIN_AUTHENTICATION = 5, TIDYVNC_DOMAIN_ENCODING = 6, TIDYVNC_DOMAIN_SECURITY = 7,
       TIDYVNC_DOMAIN_DOCUMENT = 8, TIDYVNC_DOMAIN_INVOCATION = 9, TIDYVNC_DOMAIN_LOGGING = 10 };
enum { TIDYVNC_ENDPOINT_TOO_LONG = 1, TIDYVNC_ENDPOINT_INVALID_HOST = 2,
       TIDYVNC_ENDPOINT_UNMATCHED_BRACKET = 3, TIDYVNC_ENDPOINT_INVALID_PORT = 4,
       TIDYVNC_ENDPOINT_INVALID_PATH = 5, TIDYVNC_ENDPOINT_INVALID_ROUTE = 6,
       TIDYVNC_ENDPOINT_UNSUPPORTED_TRANSPORT = 7 };
enum { TIDYVNC_FEATURE_RUNTIME = 1, TIDYVNC_FEATURE_TCP_UNIX_CONNECT = 2,
       TIDYVNC_FEATURE_EVENT_POLL = 4, TIDYVNC_FEATURE_IMAGES = 8,
       TIDYVNC_FEATURE_INPUT = 16, TIDYVNC_FEATURE_PROMPTS = 32,
       TIDYVNC_FEATURE_CALLBACKS = 64, TIDYVNC_FEATURE_GEOMETRY = 128,
       TIDYVNC_FEATURE_CLIPBOARD = 256, TIDYVNC_FEATURE_ENCODING = 512,
       TIDYVNC_FEATURE_ENDPOINT_VALIDATION = 1024, TIDYVNC_FEATURE_SCALING = 2048, TIDYVNC_FEATURE_TILE_RENDERER = 4096, TIDYVNC_FEATURE_DAMAGE_GEOMETRY = 8192,
       TIDYVNC_FEATURE_CURSOR_RENDERER = 16384, TIDYVNC_FEATURE_INPUT_POLICY = 32768, TIDYVNC_FEATURE_SHORTCUTS = 65536, TIDYVNC_FEATURE_INPUT_RELEASE = 131072,
       TIDYVNC_FEATURE_CONNECTION_INFO = 262144, TIDYVNC_FEATURE_ENDPOINT_IDENTITY = 524288, TIDYVNC_FEATURE_PROMPT_SECURITY = 1048576, TIDYVNC_FEATURE_CERTIFICATE_POLICY = 2097152, TIDYVNC_FEATURE_CERTIFICATE_KEY = 4194304, TIDYVNC_FEATURE_HOST_KEY_ENCODING = 8388608, TIDYVNC_FEATURE_REQUIRED_TLS_FILES = 16777216, TIDYVNC_FEATURE_SECURITY_SELECTION = 33554432, TIDYVNC_FEATURE_TLS_PRIORITY_VALIDATION = 67108864, TIDYVNC_FEATURE_SECURITY_RECONFIGURATION = 134217728, TIDYVNC_FEATURE_SHARED_SESSION = 268435456, TIDYVNC_FEATURE_DESKTOP_LAYOUT = 536870912, TIDYVNC_FEATURE_DISPLAY_LAYOUT = 1073741824 };
/* Feature bits above INT_MAX use uint64 constants for strict C consumers. */
#define TIDYVNC_FEATURE_CANVAS_GEOMETRY 2147483648ULL
#define TIDYVNC_FEATURE_CONNECTION_DOCUMENT 4294967296ULL
#define TIDYVNC_FEATURE_DOCUMENT_OPTIONS 8589934592ULL
#define TIDYVNC_FEATURE_INVOCATION_SYNTAX 17179869184ULL
#define TIDYVNC_FEATURE_INVOCATION_VALUES 34359738368ULL
#define TIDYVNC_FEATURE_INPUT_TIMING 68719476736ULL
#define TIDYVNC_FEATURE_MESSAGE_LIMITS 137438953472ULL
#define TIDYVNC_FEATURE_WINDOW_GEOMETRY 274877906944ULL
#define TIDYVNC_FEATURE_PROCESS_LOGGING 549755813888ULL
#define TIDYVNC_FEATURE_FILE_LOGGING 1099511627776ULL
#define TIDYVNC_FEATURE_PASSWORD_FILE_REPLY 2199023255552ULL
#define TIDYVNC_FEATURE_CREDENTIAL_BYTES 4398046511104ULL
#define TIDYVNC_FEATURE_LISTENER 8796093022208ULL
#define TIDYVNC_FEATURE_ROUTED_CONNECT 17592186044416ULL
#define TIDYVNC_FEATURE_VIEWPORT_DIAGNOSTICS 35184372088832ULL
#define TIDYVNC_FEATURE_PARAMETER_GRAMMARS 70368744177664ULL
typedef struct { const uint8_t* data; uint64_t length; } tidyvnc_bytes;
enum { TIDYVNC_LOGGING_TOO_LARGE = 1, TIDYVNC_LOGGING_NULL_BYTE = 2,
       TIDYVNC_LOGGING_INVALID_RULE = 3, TIDYVNC_LOGGING_LEVEL_OVERFLOW = 4,
       TIDYVNC_LOGGING_UNKNOWN_WRITER = 5, TIDYVNC_LOGGING_UNKNOWN_TARGET = 6,
       TIDYVNC_LOGGING_INVALID_CATALOG = 7, TIDYVNC_LOGGING_FROZEN = 8,
       TIDYVNC_LOGGING_INVALID_FILE_PATH = 9 };
/* Process startup logging, currently available on macOS/Linux. UTF-8 policy is
 * bounded to 65536 bytes. Validation does not open streams or change routing.
 * Configure commits once, before the first runtime creation; later calls return
 * BUSY, even after runtimes drain. Existing runtime creation without configure
 * preserves host logging. The caller must finish static writer registration
 * before these calls; no per-session/global registry mutation is supported.
 * Targets: stderr, stdout, file, and empty (disabled). Stdio destinations own
 * close-on-exec duplicates; original streams stay open. File logging lazily opens
 * /tmp/vncviewer.log on first output, rotates one .bak, and uses a private .lock
 * sidecar to serialize cooperating processes. Unsafe/unavailable files fall back
 * to redacted stderr with a fixed warning. File logging is nonfatal to sessions. Output is redacted before printf expansion. All writers are detached
 * after runtime service shutdown, before sinks close at process exit.
 * Error detail: low 8 bits = reason; remaining bits = one-based list entry. */
enum { TIDYVNC_INVOCATION_LAUNCH = 0, TIDYVNC_INVOCATION_HELP = 1, TIDYVNC_INVOCATION_VERSION = 2 };
enum { TIDYVNC_INVOCATION_TOO_MANY_ARGUMENTS = 1, TIDYVNC_INVOCATION_TOO_LARGE = 2,
       TIDYVNC_INVOCATION_NULL_BYTE = 3, TIDYVNC_INVOCATION_UNKNOWN_OPTION = 4,
       TIDYVNC_INVOCATION_MISSING_VALUE = 5, TIDYVNC_INVOCATION_UNAVAILABLE = 6,
       TIDYVNC_INVOCATION_EXTRA_OPERAND = 7, TIDYVNC_INVOCATION_INVALID_VALUE = 9 };
enum { TIDYVNC_INVOCATION_CONNECTION = 0, TIDYVNC_INVOCATION_ENCODING = 1,
       TIDYVNC_INVOCATION_INPUT = 2, TIDYVNC_INVOCATION_DISPLAY = 3,
       TIDYVNC_INVOCATION_SECURITY = 4, TIDYVNC_INVOCATION_CREDENTIAL_FILE = 5,
       TIDYVNC_INVOCATION_LOGGING = 6, TIDYVNC_INVOCATION_NETWORK = 7,
       TIDYVNC_INVOCATION_LISTEN = 8, TIDYVNC_INVOCATION_TUNNEL = 9,
       TIDYVNC_INVOCATION_PLATFORM = 10 };
typedef struct {
  uint32_t size, version, action, count, operand_argument, reserved;
  tidyvnc_bytes operand;
} tidyvnc_invocation_info;
typedef struct {
  uint32_t size, version, category, argument, value_argument, reserved;
  char name[64];
  tidyvnc_bytes value;
} tidyvnc_invocation_assignment;
typedef struct {
  uint32_t size, version, category, boolean, available, reserved;
  char name[64], alias[64];
} tidyvnc_invocation_option;
/* Document errors: detail low 8 bits = reason; remaining bits = one-based
 * source line, or zero when no source line applies. No input-bearing messages. */
enum { TIDYVNC_DOCUMENT_EMPTY = 1, TIDYVNC_DOCUMENT_INVALID_HEADER = 2,
       TIDYVNC_DOCUMENT_NULL_BYTE = 3, TIDYVNC_DOCUMENT_LINE_TOO_LONG = 4,
       TIDYVNC_DOCUMENT_INVALID_ASSIGNMENT = 5, TIDYVNC_DOCUMENT_INVALID_ESCAPE = 6,
       TIDYVNC_DOCUMENT_TOO_LARGE = 7, TIDYVNC_DOCUMENT_TOO_MANY_ENTRIES = 8,
       TIDYVNC_DOCUMENT_INVALID_EXPORT_NAME = 9,
       TIDYVNC_DOCUMENT_INVALID_VALUE = 12, TIDYVNC_DOCUMENT_UNAVAILABLE = 13 };
typedef struct { uint32_t size, version, count, legacy_header; } tidyvnc_document_info;
typedef struct {
  uint32_t size, version, line, reserved;
  char name[255], value[256]; /* Copied NUL-terminated bytes, not necessarily UTF-8. */
} tidyvnc_document_entry;
typedef struct { tidyvnc_bytes name, value; } tidyvnc_document_assignment;
typedef struct {
  uint32_t size, version, shared, editable;
  uint64_t revision, generation;
} tidyvnc_sharing;
typedef struct {
  uint32_t size, version, editable, reserved;
  uint64_t revision, generation;
  uint32_t tls_priority_length, ca_file_length, crl_file_length, reserved2;
  char types[1025]; /* NUL terminated. Following arrays use lengths (max 4096). */
  char tls_priority[4096], ca_file[4096], crl_file[4096];
} tidyvnc_security_configuration;
typedef struct {
  uint32_t size, version;
  tidyvnc_bytes types, tls_priority, ca_file, crl_file;
} tidyvnc_security_update;
typedef struct { uint8_t* data; uint64_t length; } tidyvnc_mutable_bytes;
enum { TIDYVNC_ENDPOINT_TCP = 1, TIDYVNC_ENDPOINT_UNIX = 2 };
typedef struct {
  uint32_t size, version, transport, port;
  tidyvnc_bytes host, scope, path, route;
} tidyvnc_endpoint_info;
enum { TIDYVNC_SECURITY_UNKNOWN_TYPE = 1, TIDYVNC_SECURITY_UNAVAILABLE = 2,
       TIDYVNC_SECURITY_TOO_LONG = 3, TIDYVNC_SECURITY_INVALID_SYNTAX = 4, TIDYVNC_SECURITY_INVALID_TLS_PRIORITY = 5 };
enum { TIDYVNC_SECURITY_UNENCRYPTED = 0, TIDYVNC_SECURITY_ANONYMOUS_TLS = 1,
       TIDYVNC_SECURITY_X509_TLS = 2, TIDYVNC_SECURITY_RSA_AES = 3,
       TIDYVNC_SECURITY_RSA_AUTHENTICATION = 4, TIDYVNC_SECURITY_LEGACY_AUTHENTICATION = 5 };
enum { TIDYVNC_SECURITY_NO_CREDENTIALS = 0, TIDYVNC_SECURITY_PASSWORD = 1,
       TIDYVNC_SECURITY_USERNAME_PASSWORD = 2, TIDYVNC_SECURITY_SERVER_SELECTED = 3 };
typedef struct {
  uint32_t size, version, type, available, protection, credentials, aes_bits, reserved;
  char name[32]; /* Canonical RFB SecurityTypes token. */
} tidyvnc_security_choice;
typedef struct {
  uint32_t size, version, count, reserved;
  uint32_t types[32];
  char canonical[1025]; /* Empty selection denies all; not inherited defaults. */
} tidyvnc_security_selection;
enum { TIDYVNC_ENCODING_AUTO_SELECT = 0, TIDYVNC_ENCODING_FULL_COLOR = 1,
       TIDYVNC_ENCODING_LOW_COLOR_LEVEL = 2, TIDYVNC_ENCODING_PREFERRED = 3,
       TIDYVNC_ENCODING_CUSTOM_COMPRESSION = 4, TIDYVNC_ENCODING_COMPRESSION = 5,
       TIDYVNC_ENCODING_NO_JPEG = 6, TIDYVNC_ENCODING_QUALITY = 7 };
enum { TIDYVNC_OPTION_BOOLEAN = 0, TIDYVNC_OPTION_INTEGER = 1, TIDYVNC_OPTION_ENUMERATION = 2 };
enum { TIDYVNC_SOURCE_COMPILED = 0, TIDYVNC_SOURCE_APP_DEFAULTS = 1,
       TIDYVNC_SOURCE_PROFILE = 2, TIDYVNC_SOURCE_SESSION = 3, TIDYVNC_SOURCE_COMMAND_LINE = 4,
       TIDYVNC_SOURCE_DOCUMENT = 5 };
/* Encoding errors: detail low 16 bits are the reason below; high 16 bits are
 * option ID + 1, or zero if no individual option is identified. No input text. */
enum { TIDYVNC_ENCODING_UNKNOWN_OPTION = 1, TIDYVNC_ENCODING_INVALID_VALUE = 2,
       TIDYVNC_ENCODING_UNAVAILABLE = 3, TIDYVNC_ENCODING_TOO_LONG = 4 };
typedef struct { tidyvnc_bytes name, value; } tidyvnc_encoding_assignment;
typedef struct {
  uint32_t size, version, id, type;
  int32_t minimum, maximum;
  uint32_t persistent, live;
  char name[32], alias[32], default_value[32]; /* Copied, NUL-terminated UTF-8. */
} tidyvnc_encoding_schema;
typedef struct {
  uint32_t size, version, available;
  int32_t wire_encoding;
  char name[32];
} tidyvnc_encoding_choice;
typedef struct {
  uint32_t size, version, id, source;
  char value[32]; /* Canonical value from the shared core validator. */
} tidyvnc_encoding_value;
typedef struct {
  uint32_t size, version, code, domain;
  uint32_t detail; int32_t native_error;
  char message[160]; /* Fixed diagnostic text; never copies endpoints or secrets. */
} tidyvnc_error;
typedef struct {
  uint32_t size, version;
  uint64_t features;
  uint32_t handle_capacity, runtime_capacity, security_count, reserved;
  uint32_t security_types[32]; /* RFB wire security IDs compiled into this build. */
} tidyvnc_abi_info;
typedef struct {
  uint32_t size, version, session_capacity, reserved;
  uint64_t required_features;
} tidyvnc_runtime_options;
enum { TIDYVNC_LISTENER_STARTING = 0, TIDYVNC_LISTENER_LISTENING = 1,
       TIDYVNC_LISTENER_STOPPING = 2, TIDYVNC_LISTENER_CLOSED = 3, TIDYVNC_LISTENER_FAILED = 4 };
enum { TIDYVNC_LISTENER_STATE = 0, TIDYVNC_LISTENER_INCOMING = 1,
       TIDYVNC_LISTENER_ACCEPTED = 2, TIDYVNC_LISTENER_REJECTED = 3, TIDYVNC_LISTENER_EXPIRED = 4 };
enum { TIDYVNC_LISTENER_ERROR_NONE = 0, TIDYVNC_LISTENER_ERROR_CANCELLED = 1,
       TIDYVNC_LISTENER_ERROR_BIND = 2, TIDYVNC_LISTENER_ERROR_ACCEPT = 3,
       TIDYVNC_LISTENER_ERROR_INVALID_ADDRESS = 4, TIDYVNC_LISTENER_ERROR_UNSUPPORTED = 5,
       TIDYVNC_LISTENER_ERROR_EVENT_OVERFLOW = 6, TIDYVNC_LISTENER_ERROR_INTERNAL = 7 };
typedef struct {
  uint32_t size, version, port, ipv4, ipv6, backlog, pending_capacity,
           event_capacity, pending_timeout_ms, reserved;
  tidyvnc_bytes address; /* Empty wildcard, or numeric IPv4/IPv6; copied. */
} tidyvnc_listener_options;
typedef struct {
  char host[64]; /* Copied numeric host, including any numeric IPv6 scope. */
  uint32_t port, reserved;
} tidyvnc_listener_address;
typedef struct {
  uint32_t size, version, state, error;
  int32_t native_error;
  uint32_t pending, address_count, reserved;
  tidyvnc_listener_address addresses[2];
} tidyvnc_listener_snapshot;
typedef struct {
  uint32_t size, version, kind, reserved;
  uint64_t sequence, incoming_id; /* Zero incoming_id for state events. */
  tidyvnc_listener_address peer;
  tidyvnc_listener_snapshot snapshot;
} tidyvnc_listener_event;
typedef struct {
  uint32_t size, version;
  uint32_t security_count, security_types[32]; /* Explicit allow-list; empty denies all. */
  uint32_t prompt_timeout_ms, event_capacity, command_capacity, reserved;
  uint64_t framebuffer_bytes, publication_bytes;
  tidyvnc_bytes tls_priority, ca_file, crl_file; /* UTF-8; copied before return. Explicit CA/CRL files must load during X509 TLS setup. */
} tidyvnc_session_options;
typedef struct {
  uint32_t size, version, pointer_interval_ms, reserved;
} tidyvnc_input_timing;
typedef struct {
  uint32_t size, version, max_cut_text, reserved;
} tidyvnc_message_limits;
/* Flags identify supplied size/position; absent fields are zero. */
enum { TIDYVNC_WINDOW_GEOMETRY_SIZE = 1, TIDYVNC_WINDOW_GEOMETRY_POSITION = 2 };
typedef struct {
  uint32_t size, version, flags, reserved;
  int32_t width, height, x, y;
} tidyvnc_window_geometry;
typedef struct {
  uint32_t size, version, ipv4, ipv6;
  uint32_t resolve_timeout_ms, connect_timeout_ms, address_timeout_ms, reserved;
  tidyvnc_bytes endpoint; /* Shared viewer address syntax, max 4096 bytes. */
} tidyvnc_connect_options;
typedef struct {
  uint32_t size, version;
  uint64_t operation, generation;
} tidyvnc_operation;
enum { TIDYVNC_STATE_IDLE = 0, TIDYVNC_STATE_RESOLVING = 1,
       TIDYVNC_STATE_CONNECTING = 2, TIDYVNC_STATE_NEGOTIATING = 3,
       TIDYVNC_STATE_AUTHENTICATING = 4, TIDYVNC_STATE_CONNECTED = 5,
       TIDYVNC_STATE_DISCONNECTING = 6, TIDYVNC_STATE_CLOSED = 7,
       TIDYVNC_STATE_FAILED = 8 };
enum { TIDYVNC_END_NONE = 0, TIDYVNC_END_CANCELLED = 1, TIDYVNC_END_PEER_CLOSED = 2,
       TIDYVNC_END_PROMPT_TIMEOUT = 3, TIDYVNC_END_AUTH_REJECTED = 4,
       TIDYVNC_END_TRANSPORT = 5, TIDYVNC_END_PROTOCOL = 6,
       TIDYVNC_END_RESOURCE = 7, TIDYVNC_END_INTERNAL = 8,
       TIDYVNC_END_EVENT_OVERFLOW = 9, TIDYVNC_END_RESOLUTION = 10,
       TIDYVNC_END_CONNECTION = 11, TIDYVNC_END_RESOLUTION_TIMEOUT = 12,
       TIDYVNC_END_CONNECTION_TIMEOUT = 13, TIDYVNC_END_UNSUPPORTED_ENDPOINT = 14,
       TIDYVNC_END_INVALID_ENDPOINT = 15 };
typedef struct {
  uint32_t size, version, state, end_reason;
  int32_t native_error; uint32_t width, height, supports_resize, resize_pending, reserved;
  uint64_t generation, frames, bells;
} tidyvnc_snapshot;
/* Remote pixels and RFB identities, never local monitor indices/OS objects. */
typedef struct { uint32_t id, x, y, width, height, flags; } tidyvnc_remote_screen;
typedef struct {
  uint32_t size, version, width, height, screen_count, reserved;
  const tidyvnc_remote_screen* screens; /* Borrowed for the call; 1..255. */
} tidyvnc_desktop_layout_request;
typedef struct {
  uint32_t size, version, screen_count, reserved;
  tidyvnc_snapshot snapshot; /* Geometry/capability from the same publication. */
  tidyvnc_remote_screen screens[255]; /* Owned copy; unused entries zeroed. */
} tidyvnc_desktop_layout;
/* Local monitor geometry. IDs are caller-owned mapping tokens, not RFB IDs.
 * Logical coordinates are integral points, top-left origin, positive Y down.
 * Bounds and backing dimensions are checked before any coordinate arithmetic. */
typedef struct {
  uint32_t id;
  int32_t x, y;
  uint32_t width, height, backing_width, backing_height;
} tidyvnc_display_monitor;
typedef struct {
  uint32_t size, version, monitor_count, device_pixels;
  const tidyvnc_display_monitor* monitors; /* Borrowed for the call; 1..64. */
} tidyvnc_display_layout_request;
typedef struct {
  uint32_t size, version, width, height, screen_count, normalized;
  tidyvnc_remote_screen screens[64]; /* IDs echo mapping tokens; flags are zero. */
} tidyvnc_display_layout;
typedef struct {
  uint32_t size, version, protocol_major, protocol_minor;
  uint32_t security_type, credentials_secure, name_truncated, reserved;
  int32_t requested_encoding, last_encoding; /* -1 means no data encoding yet. */
  uint64_t bits_per_second;
  tidyvnc_snapshot snapshot; /* Counters/state from the same publication as metadata. */
  /* All text is copied and NUL terminated. Name is at most 1024 server-provided
   * bytes; UTF-8 may be incomplete if name_truncated is set. Other text is ASCII. */
  /* credentials_secure is the existing authentication policy result, not a
   * claim that all desktop traffic is encrypted or that identity was verified. */
  char desktop_name[1025], pixel_format[128], security_name[64];
  char requested_encoding_name[32], last_encoding_name[32];
} tidyvnc_connection_info;
enum { TIDYVNC_EVENT_SNAPSHOT = 0, TIDYVNC_EVENT_STATE = 1,
       TIDYVNC_EVENT_DESKTOP = 2, TIDYVNC_EVENT_BELL = 3,
       TIDYVNC_EVENT_STATISTICS = 4, TIDYVNC_EVENT_COMPLETION = 5,
       TIDYVNC_EVENT_OVERFLOW = 6 };
enum { TIDYVNC_OPERATION_SUCCEEDED = 0, TIDYVNC_OPERATION_CANCELLED = 1,
       TIDYVNC_OPERATION_FAILED = 2 };
enum { TIDYVNC_OPERATION_FAILURE_NONE = 0, TIDYVNC_OPERATION_TIMED_OUT = 1,
       TIDYVNC_OPERATION_SERVER_REJECTED = 2 };
typedef struct {
  uint32_t size, version, kind, result, failure, native_result;
  uint64_t sequence, operation, origin;
  tidyvnc_snapshot snapshot;
} tidyvnc_event;
typedef struct {
  uint32_t size, version, frame_changed, cursor_changed;
  uint64_t generation;
  tidyvnc_handle frame, cursor; /* Each nonzero handle owns a reference. */
  uint32_t damage_x, damage_y, damage_width, damage_height;
} tidyvnc_view_update;
enum { TIDYVNC_PIXEL_BGRA8 = 1, TIDYVNC_PIXEL_RGBA8 = 2 };
enum { TIDYVNC_ALPHA_OPAQUE = 1, TIDYVNC_ALPHA_STRAIGHT = 2, TIDYVNC_ALPHA_PREMULTIPLIED = 3 };
enum { TIDYVNC_ORIGIN_TOP_LEFT = 1 };
typedef struct {
  uint32_t size, version, width, height, format, alpha, origin, reserved;
  uint64_t stride, generation, size_generation, sequence;
  uint32_t hotspot_x, hotspot_y;
  tidyvnc_bytes pixels; /* Borrowed from the image handle, immutable. */
} tidyvnc_image_info;
enum { TIDYVNC_PROMPT_CREDENTIALS = 1, TIDYVNC_PROMPT_CERTIFICATE = 2, TIDYVNC_PROMPT_HOST_KEY = 3 };
typedef struct {
  uint32_t size, version, kind, secure, username_required, certificate_status;
  uint64_t id, generation;
  tidyvnc_bytes server_name, identity, fingerprint; /* Borrowed from prompt handle. */
} tidyvnc_prompt_info;


/* Optional certificate-key support is advertised only with TLS support.
 * Immutable handles own exact DER SPKI bytes. No filesystem IO. All outputs stay
 * unchanged on failure; the key span is borrowed until the handle is released. */
typedef struct { uint32_t size, version; tidyvnc_bytes spki; } tidyvnc_certificate_key_info;
typedef struct { uint32_t size, version, length, reserved; uint8_t bytes[64]; } tidyvnc_key_digest;
/* Validate RSA-AES public-key encoding (declared 1024..8192 bits), returning
 * actual modulus bits (the retained server rounds its header). No crypto or
 * filesystem IO. On failure bits is unchanged. This does not establish trust. */
tidyvnc_status tidyvnc_host_key_validate(tidyvnc_bytes key, uint32_t* bits, tidyvnc_error* error);
tidyvnc_status tidyvnc_certificate_key_create(tidyvnc_bytes, tidyvnc_handle*, tidyvnc_error*);
tidyvnc_status tidyvnc_certificate_key_get(tidyvnc_handle, tidyvnc_certificate_key_info*, tidyvnc_error*);
/* Algorithm numbers are the existing gnutls known_hosts c0 commitment IDs. */
tidyvnc_status tidyvnc_certificate_key_digest(tidyvnc_handle, uint32_t, tidyvnc_key_digest*, tidyvnc_error*);

/* Portable presentation reasons. These are not the TLS status bit values. */
enum {
  TIDYVNC_CERT_INVALID = 1, TIDYVNC_CERT_REVOKED = 2, TIDYVNC_CERT_UNKNOWN_ISSUER = 4,
  TIDYVNC_CERT_SIGNER_NOT_CA = 8, TIDYVNC_CERT_WEAK_ALGORITHM = 16,
  TIDYVNC_CERT_NOT_YET_VALID = 32, TIDYVNC_CERT_EXPIRED = 64, TIDYVNC_CERT_BAD_SIGNATURE = 128,
  TIDYVNC_CERT_OLD_REVOCATION_DATA = 256, TIDYVNC_CERT_WRONG_OWNER = 512,
  TIDYVNC_CERT_FUTURE_REVOCATION_DATA = 1024, TIDYVNC_CERT_SIGNER_CONSTRAINTS = 2048,
  TIDYVNC_CERT_MISMATCH = 4096, TIDYVNC_CERT_WRONG_PURPOSE = 8192,
  TIDYVNC_CERT_MISSING_OCSP = 16384, TIDYVNC_CERT_INVALID_OCSP = 32768,
  TIDYVNC_CERT_CRITICAL_EXTENSION = 65536, TIDYVNC_CERT_UNKNOWN_PROBLEM = 131072,
  TIDYVNC_CERT_MISSING_PROBLEM = 262144
};
typedef struct {
  uint32_t size, version, reasons, fatal_status, may_override, reserved;
} tidyvnc_certificate_policy;
/* Classifies the certificate_status value of a prompt. No IO/global state;
 * output is unchanged on failure. Zero/unknown statuses never allow an exception.
 * Trust reply enforces this policy independently of the frontend's presentation. */
tidyvnc_status tidyvnc_certificate_policy_get(uint32_t, tidyvnc_certificate_policy*, tidyvnc_error*);

/* Readiness only: no borrowed payload pointers escape a callback. Notifications
 * coalesce; on each wake drain event/view/prompt/clipboard mailboxes and check session
 * drain. One subscription per session, at most 512 in the process. All ready
 * callbacks run serially on one bridge dispatcher, outside bridge/core locks;
 * return promptly. Never throw. Reentrant ABI calls, including unsubscribe and
 * release of already-owned handles, are allowed. The subscription ID is borrowed.
 * An initial callback may run before subscribe returns; use its ID, not the
 * caller's output storage. Retain that ID if it must outlive this callback.
 *
 * retain_context runs once on the subscribing thread before publication;
 * release_context runs once after the last callback on the dispatcher (or on
 * the caller if subscription fails). Both must return promptly and never throw.
 * The context pointer may be null; all three function pointers are required.
 */
typedef struct {
  uint32_t size, version;
  void* context;
  void (*retain_context)(void*);
  void (*release_context)(void*);
  void (*ready)(void*, tidyvnc_handle subscription, uint64_t generation);
  uint64_t reserved;
} tidyvnc_callbacks;

/* Copied shared-parser result. x/y are hundredths of a percent, or exact
 * dimensions for EXACT. canonical is NUL-terminated; 100% canonicalizes to
 * UNSCALED. Fit modes ignore the explicit-size units selection. */
enum { TIDYVNC_SCALING_UNSCALED = 0, TIDYVNC_SCALING_AUTO = 1,
       TIDYVNC_SCALING_FIXED_RATIO = 2, TIDYVNC_SCALING_FIT_WIDTH = 3,
       TIDYVNC_SCALING_FIT_HEIGHT = 4, TIDYVNC_SCALING_EXACT = 5,
       TIDYVNC_SCALING_PERCENT = 6, TIDYVNC_SCALING_INDEPENDENT = 7 };
typedef struct {
  uint32_t size, version, mode, x, y, fits;
  char canonical[64];
} tidyvnc_scaling;

/* Desktop filter IDs map to the shared CPU algorithms. */
enum { TIDYVNC_FILTER_NEAREST = 0, TIDYVNC_FILTER_BILINEAR = 1, TIDYVNC_FILTER_AREA = 2 };
typedef struct {
  uint32_t size, version, width, height, quality, reserved;
  uint32_t x, y, tile_width, tile_height;
  uint64_t previous_sequence;
  uint32_t damage_x, damage_y, damage_width, damage_height;
} tidyvnc_tile_options;
typedef struct {
  uint32_t size, version, cache_hit, reserved;
  uint64_t cache_bytes;
} tidyvnc_tile_result;

typedef struct {
  uint32_t size, version, quality, reserved;
  double scale_x, scale_y;
} tidyvnc_cursor_options;
typedef struct {
  uint32_t size, version, width, height, hotspot_x, hotspot_y;
  uint32_t blank, reserved; /* blank means every source alpha is zero. */
  uint64_t source_bytes;
} tidyvnc_cursor_geometry;
typedef struct {
  uint32_t size, version, x, y, width, height, reserved[2];
} tidyvnc_cursor_tile;

/* Immutable transform request, using the shared scaling parser/geometry.
 * Coordinates are host logical units, origin/top-left; units=0 logical, 1 device
 * pixels for explicit scaling sizes. Fit modes always fit the logical viewport.
 * Scaling text uses the existing eight-mode syntax, max 64 UTF-8 bytes. */
typedef struct {
  uint32_t size, version, remote_width, remote_height, units, reserved;
  double viewport_width, viewport_height, backing_scale, pan_x, pan_y;
  tidyvnc_bytes scaling;
} tidyvnc_geometry_options;
typedef struct {
  uint32_t size, version, backing_width, backing_height;
  double x, y, width, height;
  int32_t remote_x, remote_y;
} tidyvnc_geometry;

/* One enclosed region of a shared fullscreen canvas, in the geometry option's
 * selected logical/device units. Dimensions are 1..65535. Viewport dimensions
 * still describe this local view; fitting uses the entire canvas. */
typedef struct {
  uint32_t size, version, width, height, x, y, region_width, region_height;
} tidyvnc_canvas_viewport;

/* Remote source damage and filter halo, mapped by the shared transform. */
typedef struct {
  uint32_t size, version, x, y, width, height, quality, reserved;
} tidyvnc_damage;
typedef struct {
  uint32_t size, version;
  double x, y, width, height;
} tidyvnc_rectangle;

/* Clipboard tokens are advisory, not locks: the host must serialize focus and
 * native writes, rechecking this token immediately before a pasteboard write.
 * Any generation/focus/view-only/policy transition invalidates old tokens. */
typedef struct {
  uint32_t size, version;
  tidyvnc_handle session; /* Identity only: no owning reference. */
  uint64_t generation, focus_revision, policy_revision;
} tidyvnc_clipboard_route;
enum { TIDYVNC_CLIPBOARD_OFFERED = 1, TIDYVNC_CLIPBOARD_TEXT = 2,
       TIDYVNC_CLIPBOARD_UNAVAILABLE = 3, TIDYVNC_CLIPBOARD_INVALIDATED = 4,
       TIDYVNC_CLIPBOARD_REJECTED = 5 };
typedef struct {
  uint32_t size, version, kind, result; /* result is a tidyvnc_status. */
  uint64_t sequence;
  tidyvnc_clipboard_route route;
  tidyvnc_handle text; /* Nonzero owns an immutable text lease, release normally. */
} tidyvnc_clipboard_update;
typedef struct {
  uint32_t size, version, from_remote, reserved;
  tidyvnc_clipboard_route route;
  tidyvnc_bytes text; /* Borrowed UTF-8/LF text while its lease is retained. */
} tidyvnc_clipboard_info;

/* Clipboard directions default enabled, independently enforced in the core.
 * Text is bounded to 256 KiB, with a 1 MiB shared retained-text budget per session.
 * Offers copy and validate UTF-8 before returning. Empty text is valid; embedded
 * NUL is not. A remote-origin lease suppresses echoes, even across sessions.
 * Completion means protocol announcement/send, not a remote OS pasteboard write.
 * Clear withdraws a local offer; it never erases the host's native pasteboard. */
tidyvnc_status tidyvnc_session_clipboard_policy(tidyvnc_handle, uint64_t generation, uint32_t send, uint32_t receive, tidyvnc_error*);
tidyvnc_status tidyvnc_session_clipboard_offer(tidyvnc_handle, uint64_t generation, tidyvnc_bytes text, tidyvnc_handle origin, uint64_t change_id, tidyvnc_operation*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_clipboard_clear(tidyvnc_handle, uint64_t generation, tidyvnc_operation*, tidyvnc_error*);
/* A readiness subscription also signals clipboard changes. One consumer. */
tidyvnc_status tidyvnc_session_take_clipboard(tidyvnc_handle, tidyvnc_clipboard_update*, tidyvnc_error*);
tidyvnc_status tidyvnc_clipboard_get(tidyvnc_handle text, tidyvnc_clipboard_info*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_clipboard_check(tidyvnc_handle, const tidyvnc_clipboard_route*, uint32_t sending, tidyvnc_error*);

/* Optional errors must also have initialized headers. Never throws across C. */
tidyvnc_status tidyvnc_get_abi(tidyvnc_abi_info*, tidyvnc_error*);
/* Stateless, thread-safe; outputs unchanged on failure or NO_CHANGE. Catalog
 * includes known uncompiled choices as available=0. No globals, IO or handles.
 * defaults=1 requires empty text; defaults=0 parses <=1024 UTF-8/ASCII token bytes.
 * The allow-list never changes the server's security negotiation preference. */
tidyvnc_status tidyvnc_security_choice_at(uint32_t index, tidyvnc_security_choice*, tidyvnc_error*);
/* At most 4096 UTF-8 bytes; empty means library defaults. Nonempty requires
 * GnuTLS. Validates X509 or anonymous TLS syntax/usable suites, not peer
 * compatibility. May read GnuTLS configuration; use off the UI thread. */
tidyvnc_status tidyvnc_tls_priority_validate(tidyvnc_bytes, tidyvnc_error*);
/* Owned snapshot. set_security commits synchronously only between drained
 * attempts, with generation/revision CAS. No completion event; no parsing/file IO
 * except bounded method-list parsing. Preflight TLS priorities separately.
 * Input types is an exact list; empty denies all. Failure preserves outputs. */
/* RFB ClientInit shared flag, default false. Atomic disconnected-only update;
 * synchronous revision change, no completion event. Outputs preserved on failure. */
tidyvnc_status tidyvnc_session_sharing(tidyvnc_handle, tidyvnc_sharing*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_set_shared(tidyvnc_handle, uint64_t generation, uint64_t revision,
  uint32_t shared, uint64_t* new_revision, tidyvnc_error*);
tidyvnc_status tidyvnc_session_security(tidyvnc_handle, tidyvnc_security_configuration*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_set_security(tidyvnc_handle, uint64_t generation, uint64_t revision,
  const tidyvnc_security_update*, uint64_t* new_revision, tidyvnc_error*);
tidyvnc_status tidyvnc_security_resolve(tidyvnc_bytes text, uint32_t defaults, tidyvnc_security_selection*, tidyvnc_error*);

/* Renderer handles serialize calls with an internal mutex. Run render/clear off
 * the UI thread: area filtering can inspect every source pixel. Create admits a
 * 0..32 MiB CPU tile-cache budget. No framebuffer lease is retained after render.
 * Clear drops cached pixels; final release destroys the cache. Release/clear do
 * not cancel an in-progress call. Callers must own their handle throughout calls.
 * Render takes a retained frame image (not cursor), validates all arguments, and
 * writes tightly packed opaque BGRA into the caller's borrowed output span.
 * Dimensions <=65535, tile <=256x256, output length <=256 KiB and >=tile bytes.
 * Damage is relative to previous_sequence from this image's publication stream;
 * all tiles for one frame must carry identical history/damage metadata. Missing
 * history, changed source/generation/size/transform/filter clears the cache.
 * Result/output are untouched on validation failure. Cache allocation failure
 * drops the cache and still returns the rendered tile successfully. */
tidyvnc_status tidyvnc_renderer_create(uint64_t cache_bytes, tidyvnc_handle*, tidyvnc_error*);
tidyvnc_status tidyvnc_renderer_clear(tidyvnc_handle, tidyvnc_error*);
tidyvnc_status tidyvnc_renderer_render(tidyvnc_handle, tidyvnc_handle image, const tidyvnc_tile_options*,
                                      tidyvnc_mutable_bytes output, tidyvnc_tile_result*, tidyvnc_error*);
/* Immutable cursor sampler using shared premultiplied-alpha filtering. Create
 * copies at most 4 MiB of packed straight RGBA from a retained cursor image;
 * framebuffer images are unsupported. It retains no image/session lease.
 * Finite scales must be >0 and <=65535; resulting dimensions <=INT_MAX/4.
 * Geometry/hotspot use shared rounded backing-pixel coordinates. No full enlarged
 * raster is allocated. Render writes packed straight RGBA for a nonempty tile
 * <=256x256, within geometry, into a span <=256 KiB and >=tile bytes.
 * Create/render run synchronously off the UI thread; area work within a tile is
 * not interruptible. Calls on one immutable sampler may run concurrently with
 * separate output spans. Keep an owned handle throughout each call. Release
 * frees the original-sized premultiplied source. Outputs are untouched on failure. */
tidyvnc_status tidyvnc_cursor_renderer_create(tidyvnc_handle image, const tidyvnc_cursor_options*,
                                             tidyvnc_handle*, tidyvnc_cursor_geometry*, tidyvnc_error*);
tidyvnc_status tidyvnc_cursor_renderer_render(tidyvnc_handle, const tidyvnc_cursor_tile*, tidyvnc_mutable_bytes, tidyvnc_error*);

/* Stateless, thread-safe, synchronous; borrowed input <=64 UTF-8 bytes.
 * No runtime/handles or IO. Output is untouched on failure. Parsing does not
 * prove that a particular framebuffer/viewport fits the geometry limits. */
tidyvnc_status tidyvnc_scaling_parse(tidyvnc_bytes, tidyvnc_scaling*, tidyvnc_error*);
/* Synchronous, stateless damage mapping. Source bounds/quality and struct
 * headers are validated; empty damage maps to an empty rectangle. No input/output
 * memory is retained, and output is untouched on failure. */
tidyvnc_status tidyvnc_desktop_damage(const tidyvnc_geometry_options*, const tidyvnc_damage*, tidyvnc_rectangle*, tidyvnc_error*);
/* Synchronous value calculation, no session or handle lifetime. Point mapping
 * uses the same rounded placement as rendering, clamped to remote bounds. */
tidyvnc_status tidyvnc_desktop_geometry(const tidyvnc_geometry_options*, double point_x, double point_y, tidyvnc_geometry*, tidyvnc_error*);
/* Canvas variants reuse DesktopTransform::placeOnCanvas for pixels, inverse
 * pointer mapping and damage. Pure value calls; outputs unchanged on failure. */
tidyvnc_status tidyvnc_desktop_canvas_geometry(const tidyvnc_geometry_options*, const tidyvnc_canvas_viewport*,
  double pointer_x, double pointer_y, tidyvnc_geometry*, tidyvnc_error*);
tidyvnc_status tidyvnc_desktop_canvas_damage(const tidyvnc_geometry_options*, const tidyvnc_canvas_viewport*,
  const tidyvnc_damage*, tidyvnc_rectangle*, tidyvnc_error*);
tidyvnc_status tidyvnc_retain(tidyvnc_handle, tidyvnc_error*);
tidyvnc_status tidyvnc_release(tidyvnc_handle, tidyvnc_error*);
/* Initializers populate validated construction defaults, without global config. */
tidyvnc_status tidyvnc_runtime_options_init(tidyvnc_runtime_options*, tidyvnc_error*);
tidyvnc_status tidyvnc_logging_validate(tidyvnc_bytes policy, tidyvnc_error*);
/* Numeric local viewport metadata at debug level 100, writer NativeDesktop.
 * All dimensions are 1..INT_MAX, rounded down by the host independently for
 * logical units and backing pixels. No strings, endpoint, input or screen ID is
 * accepted. Uses the existing process logging route; never changes its policy.
 * A disabled route is a successful no-op. Callable after runtime creation. */
tidyvnc_status tidyvnc_logging_viewport(uint32_t logical_width, uint32_t logical_height,
  uint32_t backing_width, uint32_t backing_height, tidyvnc_error*);
tidyvnc_status tidyvnc_logging_configure(tidyvnc_bytes policy, tidyvnc_error*);
/* FILE_LOGGING: same startup gate, with a copied absolute UTF-8 file path for
 * embedding hosts. The path is validated even when file is unused; configuration
 * performs no file IO. Parent must be owned by this user or root and not writable
 * by other users, except a root-owned sticky directory. Leaves must be regular,
 * owned, single-link files; .lock must already be private or newly created.
 * Extended macOS parent ACLs are refused before creation; file ACLs are cleared.
 * No path is returned in errors. No connection/session file-path setting exists. */
tidyvnc_status tidyvnc_logging_configure_with_file(tidyvnc_bytes policy, tidyvnc_bytes file_path, tidyvnc_error*);
tidyvnc_status tidyvnc_session_options_init(tidyvnc_session_options*, tidyvnc_error*);
tidyvnc_status tidyvnc_connect_options_init(tidyvnc_connect_options*, tidyvnc_error*);
tidyvnc_status tidyvnc_runtime_create(const tidyvnc_runtime_options*, tidyvnc_handle*, tidyvnc_error*);
tidyvnc_status tidyvnc_runtime_shutdown(tidyvnc_handle, tidyvnc_error*);
tidyvnc_status tidyvnc_runtime_poll_drained(tidyvnc_handle, tidyvnc_error*);
/* LISTENER (macOS/Linux): separate lifecycle; four listeners per runtime, created
 * lazily. Defaults: port 5500, both families, backlog 16, pending 8, events 32,
 * pending timeout 30000 ms. Port zero requests a shared ephemeral port. Bounds:
 * backlog/pending 1..64, events 4..4096, timeout 1..60000. DNS/scoped bind/Unix
 * addresses are unsupported. Binding/accept run on workers, never the caller.
 * One ordered event consumer; starts with Starting, NO_CHANGE when empty.
 * Snapshots/events are copied values with no borrowed memory. Stop/final release
 * closes unclaimed peers; accepted sessions survive listener stop. Runtime drain
 * includes listeners and sessions. No protocol bytes are read before acceptance. */
tidyvnc_status tidyvnc_listener_options_init(tidyvnc_listener_options*, tidyvnc_error*);
tidyvnc_status tidyvnc_listener_create(tidyvnc_handle runtime, const tidyvnc_listener_options*, tidyvnc_handle*, tidyvnc_error*);
tidyvnc_status tidyvnc_listener_get_snapshot(tidyvnc_handle, tidyvnc_listener_snapshot*, tidyvnc_error*);
tidyvnc_status tidyvnc_listener_take_event(tidyvnc_handle, tidyvnc_listener_event*, tidyvnc_error*);
tidyvnc_status tidyvnc_listener_reject(tidyvnc_handle, uint64_t incoming_id, tidyvnc_error*);
/* Hand off once to an existing, configured reusable session. Preflight invalid
 * handles/output leave the peer pending. Once claimed, a session admission or
 * allocation failure closes the peer; it is never requeued. Accepted events mark
 * the ownership transfer, not successful RFB authentication. The operation uses
 * normal session events/prompts/cancellation. Numeric peer host is TLS identity
 * (IPv6 scope excluded). Incoming source port is not a stable saved-server key. */
tidyvnc_status tidyvnc_listener_accept(tidyvnc_handle listener, uint64_t incoming_id,
  tidyvnc_handle session, tidyvnc_operation*, tidyvnc_error*);
tidyvnc_status tidyvnc_listener_stop(tidyvnc_handle, tidyvnc_error*);
tidyvnc_status tidyvnc_listener_poll_drained(tidyvnc_handle, tidyvnc_error*);
/* Same retained/coalesced dispatcher and unsubscribe/drain contract as session
 * subscriptions. Readiness starts immediately; drain events through take_event.
 * Listener handles do not restart: callback generation is always 1. Final release
 * cancels subscriptions; stop alone preserves terminal event delivery. */
tidyvnc_status tidyvnc_listener_subscribe(tidyvnc_handle, const tidyvnc_callbacks*, tidyvnc_handle*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_create(tidyvnc_handle runtime, const tidyvnc_session_options*, tidyvnc_handle*, tidyvnc_error*);
/* Query the latest published connected observation. Generation must match;
 * NOT_CONNECTED before/after connection, STALE after attempt replacement. No
 * allocation/borrowed text or new handle. Statistics use existing throttling. */
tidyvnc_status tidyvnc_session_information(tidyvnc_handle session, uint64_t generation,
                                          tidyvnc_connection_info*, tidyvnc_error*);
/* Schema/choices are enumerated from zero; NO_CHANGE marks the end. No borrowed
 * text. Encoding handles own immutable validated snapshots, independent of a
 * session. base=0 starts with compiled defaults; otherwise patches a copy.
 * Patches: <=256 assignments, <=128 UTF-8 bytes per name/value; copied before
 * return, case-insensitive names/aliases, last duplicate wins. source is explicit.
 * Creating a session with an encoding snapshot applies it before negotiation.
 * Live apply copies it into the existing reserved async command queue; completion
 * means local application, not server acknowledgement. Cancellation only wins
 * before execution. Session encoding queries return a new retained snapshot. */
/* Stateless, synchronous syntax validation using the same parser as Connect.
 * No DNS, filesystem access, network IO, runtime, handles or callbacks. The UTF-8
 * span is borrowed for this call only, at most 4096 bytes, without embedded NUL.
 * allow_unix_sockets is exactly 0 or 1. Empty text has the core's localhost:0
 * meaning; UI clients may separately require explicit entry. Syntax failures use
 * DOMAIN_ENDPOINT/detail reasons; malformed spans/text use DOMAIN_BRIDGE.
 * Validation does not establish reachability, authorization or server identity. */
tidyvnc_status tidyvnc_endpoint_validate(tidyvnc_bytes endpoint, uint32_t allow_unix_sockets, tidyvnc_error*);
/* Immutable destination identity from the same parser; no DNS/filesystem IO.
 * Input spans are bounded UTF-8 without NUL, each at most 4096 bytes. Route is an
 * opaque, non-secret identity supplied by the host, never a tunnel command.
 * Normalizes DNS ASCII case and numeric IP spelling only. Aliases, trailing dots,
 * IPv6 scopes, Unix paths and routes remain distinct. TCP has empty path; Unix
 * has empty host/scope and port zero. Create returns one owned reference; get
 * borrows immutable spans valid while the caller retains that handle. Copy or
 * consume spans before release. This does not verify the server, authorize
 * credential reuse or identify a tunnel target from its local forwarding port. */
tidyvnc_status tidyvnc_endpoint_create(tidyvnc_bytes endpoint, tidyvnc_bytes route,
  uint32_t allow_unix_sockets, tidyvnc_handle*, tidyvnc_error*);
tidyvnc_status tidyvnc_endpoint_get(tidyvnc_handle, tidyvnc_endpoint_info*, tidyvnc_error*);
/* Strict decimal port 0..65535: digits only, no sign/whitespace/trailing text.
 * Invalid text leaves *port unchanged. */
tidyvnc_status tidyvnc_port_parse(tidyvnc_bytes, uint32_t* port, tidyvnc_error*);
/* SSH gateway ("via") grammar: [user@]host or ssh://[user@]host[:port], at most
 * 4096 bytes. Pure validation and canonicalization; nothing is resolved or run.
 * host/scope are the endpoint name and IPv6 zone; user is present only with
 * TIDYVNC_SSH_GATEWAY_USER. Borrowed bytes remain valid while the handle lives. */
enum { TIDYVNC_SSH_GATEWAY_USER = 1, TIDYVNC_SSH_GATEWAY_EXPLICIT_PORT = 2 };
typedef struct {
  uint32_t size, version, port, flags;
  tidyvnc_bytes host, scope, user, canonical_uri;
} tidyvnc_ssh_gateway_info;
tidyvnc_status tidyvnc_ssh_gateway_create(tidyvnc_bytes, tidyvnc_handle*, tidyvnc_error*);
tidyvnc_status tidyvnc_ssh_gateway_get(tidyvnc_handle, tidyvnc_ssh_gateway_info*, tidyvnc_error*);
/* Toolkit-independent file syntax, no IO/runtime/session/global mutation. All
 * operations are synchronous and thread safe. Parse borrows at most 1 MiB of
 * opaque bytes and returns one owned immutable handle (retain/release normally).
 * Both version-1 headers, 254-byte physical lines and at most 4096 assignments
 * are accepted. Syntax does not validate option names/values or apply settings.
 * Entry copies a name and either raw escaped bytes (decode_value=0) or decoded
 * value (1). Unknown entries should remain undecoded for compatibility. Index
 * past the end returns NO_CHANGE. Invalid decode flag fails without writing.
 * Serialize accepts at most 4096 decoded assignments, name/value spans each at
 * most 255 bytes, using only the shared non-secret export catalog. Unknown or
 * deprecated fields are rejected; parsed unknown records are never re-exported
 * implicitly. Canonical current header/names and LF endings are emitted.
 * A NULL/zero output buffer queries the required size. Otherwise it must fit the
 * entire output; no terminator is appended. Size and buffer remain unchanged on
 * any failure. Inputs/outputs must not overlap. Spans are copied before return.
 * Native text clients must reject invalid UTF-8, never silently replace bytes. */
tidyvnc_status tidyvnc_document_parse(tidyvnc_bytes, tidyvnc_handle*, tidyvnc_error*);
/* Stateless invocation syntax; arguments excludes argv[0]. At most 4096 args,
 * 65536 bytes each, 1 MiB total. Opaque bytes without NUL, no file line limit or
 * escaping. No settings validation/application, IO, environment, registry access,
 * shell processing or logging. All occurrences remain ordered for later semantic
 * validation. A successful parse does NOT authorize connection/tunnel/listen or
 * credential access. Help/version terminate at their position after prior syntax;
 * whole-input size/NUL validation precedes parsing. Prior assignments remain for
 * semantic validation; the unused positional operand is discarded.
 * Parse returns one immutable owned reference, released with tidyvnc_release.
 * Get/assignment return BORROWED operand/value spans, valid only while caller
 * retains the invocation. Names/catalog are copied NUL-terminated bytes. Copy
 * spans before releasing. No source argv pointers escape. NULL/zero input permits
 * an empty invocation. Index past end returns NO_CHANGE without modifying output.
 * Errors: DOMAIN_INVOCATION detail low 8 bits = reason; upper bits = one-based
 * argument (excluding executable), or zero for whole-input limits. No raw values
 * in error messages. Schema describes compiled/platform availability; frontend
 * application support must be checked separately. UTF-8 clients reject invalid
 * text rather than replacing it. All calls synchronous and thread safe. */
tidyvnc_status tidyvnc_invocation_parse(const tidyvnc_bytes*, uint32_t count, tidyvnc_handle*, tidyvnc_error*);
/* Return a new owned invocation with each occurrence validated/canonicalized.
 * Input owner is unchanged; invalid earlier values cannot be hidden by later
 * duplicates or help/version. Same get/assignment lifetime contract. Paths,
 * routes, geometry and desktop-size strings remain literal; Log validates only
 * triple structure, not registry targets. Host semantic interpretation, deprecated
 * migrations, platform-adapter readiness and launch authorization remain required.
 * No IO, global mutation, TLS handshake or connection is performed. */
tidyvnc_status tidyvnc_invocation_validate(tidyvnc_handle, tidyvnc_handle*, tidyvnc_error*);
tidyvnc_status tidyvnc_invocation_get(tidyvnc_handle, tidyvnc_invocation_info*, tidyvnc_error*);
tidyvnc_status tidyvnc_invocation_assignment_at(tidyvnc_handle, uint32_t index, tidyvnc_invocation_assignment*, tidyvnc_error*);
tidyvnc_status tidyvnc_invocation_option_at(uint32_t index, tidyvnc_invocation_option*, tidyvnc_error*);
tidyvnc_status tidyvnc_document_get(tidyvnc_handle, tidyvnc_document_info*, tidyvnc_error*);
tidyvnc_status tidyvnc_document_entry_at(tidyvnc_handle, uint32_t index, uint32_t decode_value, tidyvnc_document_entry*, tidyvnc_error*);
/* Canonical shared semantic validation for one understood historical field.
 * Same copied entry layout. Unknown names (including CLI-only aliases/options)
 * and out-of-range indices return NO_CHANGE without decoding or writing. Applies
 * no settings/migrations and performs no display, filesystem or network IO.
 * Recognized invalid/unavailable values return DOCUMENT errors at their line.
 * Cross-field deprecated migration, endpoint validation and local path/display
 * resolution are host responsibilities after validating every entry. */
tidyvnc_status tidyvnc_document_option_at(tidyvnc_handle, uint32_t index, tidyvnc_document_entry*, tidyvnc_error*);
tidyvnc_status tidyvnc_document_serialize(const tidyvnc_document_assignment*, uint32_t count, tidyvnc_mutable_bytes output, uint64_t* size, tidyvnc_error*);
tidyvnc_status tidyvnc_encoding_schema_at(uint32_t index, tidyvnc_encoding_schema*, tidyvnc_error*);
tidyvnc_status tidyvnc_encoding_choice_at(uint32_t index, tidyvnc_encoding_choice*, tidyvnc_error*);
tidyvnc_status tidyvnc_encoding_create(tidyvnc_handle base, const tidyvnc_encoding_assignment*, uint32_t count, uint32_t source, tidyvnc_handle*, tidyvnc_error*);
tidyvnc_status tidyvnc_encoding_get(tidyvnc_handle, uint32_t option, tidyvnc_encoding_value*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_create_with_encoding(tidyvnc_handle runtime, const tidyvnc_session_options*, tidyvnc_handle encoding, tidyvnc_handle*, tidyvnc_error*);
/* Init selects the shared viewer default (17 ms). Zero disables motion delay;
 * values through INT_MAX are accepted. Buttons/wheel bypass the delay; pending
 * motion flushes before keys and is discarded on focus/policy/lifetime changes.
 * Creation copies timing for all attempts. Existing create functions preserve
 * their original unthrottled input behavior. No live policy mutation is exposed. */
tidyvnc_status tidyvnc_input_timing_init(tidyvnc_input_timing*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_create_with_input_timing(tidyvnc_handle runtime, const tidyvnc_session_options*,
  tidyvnc_handle encoding, const tidyvnc_input_timing*, tidyvnc_handle*, tidyvnc_error*);
/* Init selects the shared incoming clipboard default (256 KiB). Values 0..INT_MAX
 * apply to plain wire bytes, extended wire payload and each decompressed format
 * separately, matching MaxCutText. Not an aggregate allocation budget. Independent
 * clipboard UTF-8 text/retained-byte budgets still apply. No outgoing limit change.
 * Creation copies limits and timing for all attempts. Older creation APIs keep
 * default message limits. Required structures are checked; failure leaves outputs
 * unchanged. No live message-limit mutation is exposed. */
/* Pure retained geometry parser: empty, +x+y, WxH or WxH+x+y. Signed
 * coordinates, C whitespace/signs and retained trailing-text acceptance apply.
 * Dimensions are 1..INT32_MAX; coordinates INT32_MIN..INT32_MAX. No display or UI
 * access; the host owns work-area clamping, coordinate conversion and placement.
 * Invalid text (including NUL/over 65536 bytes) leaves output unchanged. */
tidyvnc_status tidyvnc_window_geometry_parse(tidyvnc_bytes, tidyvnc_window_geometry*, tidyvnc_error*);
/* Initial remote desktop size (DesktopSize). LEGACY is the retained command-line
 * "%dx%d" form (C whitespace/'+' before each number, trailing text ignored);
 * STRICT is exactly decimal WxH of at most 32 bytes, for settings and profiles.
 * Empty text yields width = height = 0. Dimensions are 1..65535. Invalid text,
 * syntax or NUL leaves output unchanged. Pure and stateless. */
enum { TIDYVNC_DESKTOP_SIZE_LEGACY = 1, TIDYVNC_DESKTOP_SIZE_STRICT = 2 };
typedef struct {
  uint32_t size, version, width, height;
} tidyvnc_desktop_size;
tidyvnc_status tidyvnc_desktop_size_parse(tidyvnc_bytes, uint32_t syntax, tidyvnc_desktop_size*, tidyvnc_error*);
tidyvnc_status tidyvnc_message_limits_init(tidyvnc_message_limits*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_create_with_message_limits(tidyvnc_handle runtime, const tidyvnc_session_options*,
  tidyvnc_handle encoding, const tidyvnc_input_timing*, const tidyvnc_message_limits*, tidyvnc_handle*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_encoding(tidyvnc_handle, tidyvnc_handle*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_apply_encoding(tidyvnc_handle, uint64_t generation, tidyvnc_handle encoding, tidyvnc_operation*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_connect(tidyvnc_handle, const tidyvnc_connect_options*, tidyvnc_operation*, tidyvnc_error*);
/* Connect through an already prepared, host-owned local tunnel socket. target is
 * an endpoint handle with TCP transport and a nonempty route identity. options
 * describes only the forwarding socket: Unix or numeric 127.0.0.1/::1, no scope,
 * nonzero TCP port. TLS uses target's host, never the forwarding address. Copies
 * both endpoints before return. The host owns tunnel startup/cancellation/drain
 * and must key credentials/trust by target + route. Direct connect is unchanged. */
tidyvnc_status tidyvnc_session_connect_routed(tidyvnc_handle, tidyvnc_handle target,
  const tidyvnc_connect_options*, tidyvnc_operation*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_disconnect(tidyvnc_handle, uint64_t generation, tidyvnc_operation*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_refresh(tidyvnc_handle, uint64_t generation, tidyvnc_operation*, tidyvnc_error*);
/* Stateless shared geometry validation. Bounds 1..65535; unique screen IDs,
 * positive enclosed screens; gaps/overlap and all flag bits are preserved. */
/* Pure shared DesktopLayout mapping, without a session or OS calls. Preserves
 * logical gaps/order; device units normalize mixed-density regions to avoid
 * overlap. Mirrored/overlapping monitors fail. Outputs unchanged on failure. */
tidyvnc_status tidyvnc_display_layout_compute(const tidyvnc_display_layout_request*, tidyvnc_display_layout*, tidyvnc_error*);
tidyvnc_status tidyvnc_desktop_layout_validate(const tidyvnc_desktop_layout_request*, tidyvnc_error*);
/* Copies the current connected layout and coherent snapshot. STALE for another
 * generation, NOT_CONNECTED before/after connection; no borrowed output memory. */
tidyvnc_status tidyvnc_session_desktop_layout(tidyvnc_handle, uint64_t generation, tidyvnc_desktop_layout*, tidyvnc_error*);
/* Copies input before return. Admission checks generation, connection, server
 * capability, view-only, buffer limits and one pending resize. Completion means
 * server reply, timeout or teardown, not just wire submission. Server rejection
 * carries its numeric result. Cancellation can win only before wire submission;
 * after timeout a late reply is consumed before accepting another resize. */
tidyvnc_status tidyvnc_session_request_desktop_layout(tidyvnc_handle, uint64_t generation,
  const tidyvnc_desktop_layout_request*, tidyvnc_operation*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_cancel_operation(tidyvnc_handle, uint64_t generation, uint64_t operation, tidyvnc_error*);
tidyvnc_status tidyvnc_session_close(tidyvnc_handle, tidyvnc_error*);
tidyvnc_status tidyvnc_session_poll_drained(tidyvnc_handle, tidyvnc_error*);
tidyvnc_status tidyvnc_session_snapshot(tidyvnc_handle, tidyvnc_snapshot*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_subscribe(tidyvnc_handle, const tidyvnc_callbacks*, tidyvnc_handle*, tidyvnc_error*);
/* Cancel queued delivery; an already-started callback may finish. Idempotent,
 * never waits, including from inside ready(). Final subscription/session release
 * also cancels. Explicit session close/runtime shutdown still permits terminal
 * notifications: protocol drain and callback drain are separate obligations. */
tidyvnc_status tidyvnc_subscription_unsubscribe(tidyvnc_handle, tidyvnc_error*);
/* OK only after unsubscribe and context release have finished. Host work queued
 * by a callback is outside this drain: it must own its captures and validate
 * subscription/generation before changing UI. Returns PENDING otherwise. */
tidyvnc_status tidyvnc_subscription_poll_drained(tidyvnc_handle, tidyvnc_error*);
/* Advisory delivery check: CANCELLED after unsubscribe, STALE for another
 * generation. Serialize UI teardown/delivery on the host executor as well. */
tidyvnc_status tidyvnc_subscription_validate(tidyvnc_handle, uint64_t generation, tidyvnc_error*);
/* Exactly one consumer per session for each event/view/prompt/clipboard mailbox. */
tidyvnc_status tidyvnc_session_take_event(tidyvnc_handle, tidyvnc_event*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_take_view(tidyvnc_handle, tidyvnc_view_update*, tidyvnc_error*);
tidyvnc_status tidyvnc_image_get(tidyvnc_handle, tidyvnc_image_info*, tidyvnc_error*);
tidyvnc_status tidyvnc_session_key(tidyvnc_handle, uint64_t generation, uint32_t key_id, uint32_t keysym, uint32_t keycode, uint32_t down, tidyvnc_error*);
tidyvnc_status tidyvnc_session_pointer(tidyvnc_handle, uint64_t generation, int32_t x, int32_t y, uint32_t buttons, tidyvnc_error*);
tidyvnc_status tidyvnc_session_focus(tidyvnc_handle, uint64_t generation, uint32_t focused, tidyvnc_error*);
/* Release queued/held input and invalidate delayed routing, preserving focus and
 * view-only policy. Allowed while view-only/unfocused; generation must be current. */
tidyvnc_status tidyvnc_session_release_input(tidyvnc_handle, uint64_t generation, tidyvnc_error*);
tidyvnc_status tidyvnc_session_view_only(tidyvnc_handle, uint32_t enabled, tidyvnc_error*);
/* Atomic connection policy; boolean arguments. Default emulation is off.
 * Left/right chord delay is 50 ms on the session executor. A policy change
 * cancels unsent input and releases held keys/buttons when emulation changes
 * or view-only is enabled. Policy survives reconnect; delayed events do not. */
tidyvnc_status tidyvnc_session_input_policy(tidyvnc_handle, uint32_t view_only,
                                          uint32_t emulate_middle, tidyvnc_error*);
/* Shared shortcut classifier, independent of a session. One handle per input
 * surface. Operations serialize on that handle; there are no timers/callbacks.
 * Bits: Control=1, Shift=2, Alt/Option=4, Super/Command=8; zero disables shortcuts.
 * Hosts reset on focus/routing/disconnect and release held remote keys before
 * changing modifiers, or when acting on SHORTCUT / UNARM. The host owns command
 * dispatch and temporary Space bypass. This service sends no protocol input.
 * At most 1024 distinct pressed physical IDs; overflow leaves state/output
 * unchanged. Repeats of existing IDs do not consume capacity. Release ignores
 * keysym. Reset discards pressed state and keeps selected modifiers. */
enum { TIDYVNC_SHORTCUT_NORMAL = 0, TIDYVNC_SHORTCUT_UNARM = 1,
       TIDYVNC_SHORTCUT_ACTION = 2, TIDYVNC_SHORTCUT_IGNORE = 3 };
tidyvnc_status tidyvnc_shortcut_create(uint32_t modifiers, tidyvnc_handle*, tidyvnc_error*);
tidyvnc_status tidyvnc_shortcut_modifiers(tidyvnc_handle, uint32_t modifiers, tidyvnc_error*);
tidyvnc_status tidyvnc_shortcut_key(tidyvnc_handle, int32_t physical_id, uint32_t keysym,
                                  uint32_t down, uint32_t* action, tidyvnc_error*);
tidyvnc_status tidyvnc_shortcut_reset(tidyvnc_handle, tidyvnc_error*);

tidyvnc_status tidyvnc_session_take_prompt(tidyvnc_handle, tidyvnc_handle* prompt, tidyvnc_error*);
tidyvnc_status tidyvnc_prompt_get(tidyvnc_handle, tidyvnc_prompt_info*, tidyvnc_error*);
/* Immutable negotiated credential subtype; zero for trust/legacy prompts.
 * Output remains unchanged on failure. No session or active prompt required. */
tidyvnc_status tidyvnc_prompt_security_type(tidyvnc_handle, uint32_t*, tidyvnc_error*);
/* Credentials are copied into the rendezvous. Both mutable input spans are wiped
 * on every return, including rejection, when non-null and length <= 4096. The
 * caller owns/frees their storage. No zeroization guarantee for caller copies or
 * foreign runtimes. Plain immutable text submission is deliberately absent. */
tidyvnc_status tidyvnc_session_reply_credentials(tidyvnc_handle, uint64_t id, uint64_t generation,
  tidyvnc_mutable_bytes username, tidyvnc_mutable_bytes password, tidyvnc_error*);
/* CREDENTIAL_BYTES: same consuming prompt reply, accepting bounded non-NUL
 * legacy byte strings without UTF-8 conversion (for captured environment inputs).
 * Each span is bounded to 4096 bytes and wiped under the same ownership contract.
 * The ordinary credential text API remains UTF-8. No persistence or reuse. */
tidyvnc_status tidyvnc_session_reply_credential_bytes(tidyvnc_handle, uint64_t id, uint64_t generation,
  tidyvnc_mutable_bytes username, tidyvnc_mutable_bytes password, tidyvnc_error*);
/* PASSWORD_FILE_REPLY: decode exactly the first 8 bytes of a legacy VNC password
 * file through the shared codec, then answer only a current password-only prompt.
 * The block is obfuscated, not encrypted. No file IO or credential persistence.
 * Non-UTF-8 password bytes are preserved, terminating at the first decoded NUL.
 * Mutable input is wiped on every return when non-null and length <= 4096,
 * including invalid size, stale/wrong-kind requests and invalid error headers.
 * Host must gate file access on a current prompt and discard cancelled reads. */
tidyvnc_status tidyvnc_session_reply_password_file(tidyvnc_handle, uint64_t id, uint64_t generation,
  tidyvnc_mutable_bytes obfuscated, tidyvnc_error*);
tidyvnc_status tidyvnc_session_reply_trust(tidyvnc_handle, uint64_t id, uint64_t generation, uint32_t allowed, tidyvnc_error*);
#ifdef __cplusplus
}
#endif
#endif
