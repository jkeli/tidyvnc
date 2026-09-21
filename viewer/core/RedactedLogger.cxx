/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include "RedactedLogger.h"
#include <core/i18n.h>
#include <cstring>
#include <cstdio>

using namespace viewer;
namespace {
struct Event {
  constexpr Event(const char* source_, const char* format_, const char* message_, bool numeric_ = false)
    : source(source_), format(format_), message(message_), numeric(numeric_) {}
  const char *source, *format, *message;
  bool numeric;
};
// Audited client/core templates. These are exact matches, not patterns applied
// to arbitrary messages. Only explicitly audited numeric templates are formatted,
// using the compiled original, never the caller's format or a translation. All
// other output is constant. New/changed templates fall back to redaction.
// A null message suppresses keyboard events, including their per-key timing.
constexpr Event events[] = {
  {"Socket","Failed to flush remaining socket data on close","Failed to flush remaining socket data on close"},
  {"Socket","Failed to flush remaining socket data on close: %s","Failed to flush remaining socket data on close: [redacted]"},
  {"TcpSocket","Connecting to %s [%s] port %d","Connecting to [redacted] [[redacted]] port [redacted]"},
  {"TcpSocket","Failed to connect to address %s port %d: %d","Failed to connect to address [redacted] port [redacted]: [redacted]"},
  {"TcpSocket","Failed to get peer name for socket","Failed to get peer name for socket"},
  {"TcpSocket","Failed to convert peer name to a string","Failed to convert peer name to a string"},
  {"TcpSocket","Unknown address family","Unknown address family"},
  {"TcpSocket","Failed to set TCP_NODELAY: %d","Failed to set TCP_NODELAY: [redacted]",true},
  {"TcpSocket","ACCEPT %s","ACCEPT [redacted]"},
  {"TcpSocket","QUERY %s","QUERY [redacted]"},
  {"TcpSocket","REJECT %s","REJECT [redacted]"},
  {"TcpSocket","[REJECT] %s","[REJECT] [redacted]"},
  {"UnixSocket","Failed to get peer name for socket","Failed to get peer name for socket"},
  {"UnixSocket","Failed to get local name for socket","Failed to get local name for socket"},
  {"RandomStream","No system random source available","No system random source available"},
  {"TLSSocket","Deferring completion of TLS handshake: %s","Deferring completion of TLS handshake: [redacted]"},
  {"TLSSocket","TLS handshake failed: %s","TLS handshake failed: [redacted]"},
  {"TLSSocket","Failed to flush remaining socket data on close","Failed to flush remaining socket data on close"},
  {"TLSSocket","Failed to flush remaining socket data on close: %s","Failed to flush remaining socket data on close: [redacted]"},
  {"TLSSocket","Failed to terminate TLS cleanly: %s","Failed to terminate TLS cleanly: [redacted]"},
  {"ZlibOutStream","Flush: avail_in %d","Flush: avail_in [redacted]",true},
  {"ZlibOutStream","Calling deflate, avail_in %d, avail_out %d","Calling deflate, avail_in [redacted], avail_out [redacted]",true},
  {"ZlibOutStream","After deflate: %d bytes","After deflate: [redacted] bytes",true},
  {"ZlibOutStream","Change: avail_in %d","Change: avail_in [redacted]",true},
  {"CConnection","Reading protocol version","Reading protocol version"},
  {"CConnection","Server supports RFB protocol version %d.%d","Server supports RFB protocol version [redacted].[redacted]",true},
  {"CConnection","Server gave unsupported RFB protocol version %d.%d","Server gave unsupported RFB protocol version [redacted].[redacted]",true},
  {"CConnection","Using RFB protocol version %d.%d","Using RFB protocol version [redacted].[redacted]",true},
  {"CConnection","Processing security types message","Processing security types message"},
  {"CConnection","Unknown 3.3 security type %d","Unknown 3.3 security type [redacted]",true},
  {"CConnection","Server offers security type %s(%d)","Server offers security type [redacted]([redacted])"},
  {"CConnection","Choosing security type %s (%d)","Choosing security type [redacted] ([redacted])"},
  {"CConnection","No matching security types","No matching security types"},
  {"CConnection","Processing security message","Processing security message"},
  {"CConnection","Processing security result message","Processing security result message"},
  {"CConnection","Auth failed","Auth failed"},
  {"CConnection","Auth failed: Too many tries","Auth failed: Too many tries"},
  {"CConnection","Processing security reason message","Processing security reason message"},
  {"CConnection","Reading server initialisation","Reading server initialisation"},
  {"CConnection","Authentication success!","Authentication success!"},
  {"CConnection","%s","Diagnostic details redacted."},
  {"CConnection","Failed to resize remote session: %d","Failed to resize remote session: [redacted]",true},
  {"CConnection","Initialisation done","Initialisation done"},
  {"CConnection","Enabling continuous updates","Enabling continuous updates"},
  {"CConnection","Requesting audio (format %d, %d channels, %d Hz)","Requesting audio (format [redacted], [redacted] channels, [redacted] Hz)",true},
  {"CConnection","Invalid SetColourMapEntries from server!","Invalid SetColourMapEntries from server!"},
  {"CConnection","Got server clipboard capabilities:","Got server clipboard capabilities:"},
  {"CConnection","    Unknown format 0x%x","    Unknown format 0x[redacted]",true},
  {"CConnection","    %s (only notify)","    [redacted] (only notify)"},
  {"CConnection","    %s (automatically send up to %s)","    [redacted] (automatically send up to [redacted])"},
  {"CConnection","Ignoring clipboard request for unsupported formats 0x%x","Ignoring clipboard request for unsupported formats 0x[redacted]",true},
  {"CConnection","Ignoring unexpected clipboard request","Ignoring unexpected clipboard request"},
  {"CConnection","Ignoring clipboard provide with unsupported formats 0x%x","Ignoring clipboard provide with unsupported formats 0x[redacted]",true},
  {"CConnection","Invalid UTF-8 sequence in clipboard","Invalid UTF-8 sequence in clipboard"},
  {"CConnection","Attempting unsolicited clipboard transfer...","Attempting unsolicited clipboard transfer..."},
  {"CConnection","Clipboard was too large for unsolicited clipboard transfer","Clipboard was too large for unsolicited clipboard transfer"},
  {"CConnection","Key pressed: %d => 0x%02x / XK_%s (0x%04x)",nullptr},
  {"CConnection","Unexpected release of key code %d",nullptr},
  {"CConnection","Key released: %d => 0x%02x / XK_%s (0x%04x)",nullptr},
  {"CMsgReader","Clipboard too large (%d bytes)","Clipboard too large ([redacted] bytes)",true},
  {"CMsgReader","Ignoring fence with too large payload","Ignoring fence with too large payload"},
  {"CMsgReader","Invalid rectangle received: %dx%d at %d,%d exceeds %dx%d","Invalid rectangle received: [redacted]x[redacted] at [redacted],[redacted] exceeds [redacted]x[redacted]",true},
  {"CMsgReader","Empty rectangle received","Empty rectangle received"},
  {"CMsgReader","Invalid desktop name received","Invalid desktop name received"},
  {"CSecurityRSAAES","Failed to flush remaining socket data on close","Failed to flush remaining socket data on close"},
  {"CSecurityRSAAES","Failed to flush remaining socket data on close: %s","Failed to flush remaining socket data on close: [redacted]"},
  {"TLS","TLS handshake completed with %s","TLS handshake completed with [redacted]"},
  {"TLS","Syntax error in GnuTLS priority string: %s","Syntax error in GnuTLS priority string: [redacted]"},
  {"TLS","Anonymous session has been set","Anonymous session has been set"},
  {"TLS","Failed to load the system certificate trust store","Failed to load the system certificate trust store"},
  {"TLS","Failed to load the user specified certificate authority","Failed to load the user specified certificate authority"},
  {"TLS","Failed to load the user specified certificate revocation list","Failed to load the user specified certificate revocation list"},
  {"TLS","Failed to configure the server name for TLS handshake","Failed to configure the server name for TLS handshake"},
  {"TLS","X509 session has been set","X509 session has been set"},
  {"TLS","Server certificate verification failed: %s","Server certificate verification failed: [redacted]"},
  {"CVeNCrypt","Server offers security type %s (%d)","Server offers security type [redacted] ([redacted])"},
  {"CVeNCrypt","Choosing security type %s (%d)","Choosing security type [redacted] ([redacted])"},
  {"DecodeManager","Unable to determine the number of CPU cores on this system","Unable to determine the number of CPU cores on this system"},
  {"DecodeManager","Detected %d CPU core(s)","Detected [redacted] CPU core(s)",true},
  {"DecodeManager","Creating %d decoder thread(s)","Creating [redacted] decoder thread(s)",true},
  {"DecodeManager","Unknown encoding %d","Unknown encoding [redacted]",true},
  {"DecodeManager","    %s: %s, %s","    [redacted]: [redacted], [redacted]"},
  {"DecodeManager","    %*s  %s (1:%g %s)","    [redacted]  [redacted] (1:[redacted] [redacted])"},
  {"DecodeManager","  %s %s, %s","  [redacted] [redacted], [redacted]"},
  {"DecodeManager","  %*s %s (1:%g %s)","  [redacted] [redacted] (1:[redacted] [redacted])"},
  {"KeyRemapper","Unknown operation %c>, assuming ->","Unknown operation [redacted]>, assuming ->"},
  {"KeyRemapper","Invalid mapping %s","Invalid mapping [redacted]"},
  {"ServerParams","Invalid screen layout for %dx%d:","Invalid screen layout for [redacted]x[redacted]:",true},
  {"ServerParams","%s","Diagnostic details redacted."},
};
// A table edit cannot accidentally make a string, pointer, width argument or
// printf side effect part of the numeric exception. Keep this checked at build
// time as well as reviewing whether the numeric field is appropriate to expose.
constexpr bool numericFormat(const char* text) {
  return !*text || (*text == '%' ?
    ((text[1] == 'd' || text[1] == 'x') && numericFormat(text+2)) : numericFormat(text+1));
}
constexpr bool validNumericEvents(size_t index) {
  return index == sizeof(events)/sizeof(events[0]) ||
    ((!events[index].numeric || numericFormat(events[index].format)) && validNumericEvents(index+1));
}
static_assert(validNumericEvents(0),"Redacted diagnostic numeric formats must contain only %d and %x");
constexpr const char* fallback = "Diagnostic details redacted.";
}

std::vector<RedactedLogger::Pattern> RedactedLogger::capturePatterns() {
  std::vector<Pattern> result;
  result.reserve(sizeof(events)/sizeof(events[0]));
  for (const auto& event : events)
    result.push_back({event.source,event.format,event.message,event.numeric,_(event.format)});
  return result;
}

RedactedLogger::RedactedLogger(const char* name, core::Logger& output)
  : Logger(name), destination(output), patterns(capturePatterns()) {}

const char* RedactedLogger::safeSource(const char* source) {
  if (source) for (const auto& event : events)
    if (std::strcmp(source,event.source) == 0) return event.source;
  return "Core";
}

void RedactedLogger::emit(int level, const char* source, const char* message) {
  if (!message) return;
  std::lock_guard<std::recursive_mutex> lock(writeMutex);
  // Keep severity within the three legacy classes; do not forward arbitrary
  // caller-provided integers to a destination that might print the level.
  destination.write(level >= 100 ? 100 : (level >= 30 ? 30 : 0),source,message);
}

void RedactedLogger::write(int level, const char* source, const char* /*text*/) {
  emit(level,safeSource(source),fallback);
}

void RedactedLogger::write(int level, const char* source, const char* format, va_list args) {
  const auto safe = safeSource(source);
  if (format) for (const auto& pattern : patterns) {
    if (std::strcmp(safe,pattern.source) == 0 &&
        (std::strcmp(format,pattern.format) == 0 || format == pattern.translated)) {
      if (pattern.numeric) {
        char message[512]; va_list copy; va_copy(copy,args);
        const int size = std::vsnprintf(message,sizeof(message),pattern.format,copy);
        va_end(copy);
        emit(level,safe,size >= 0 && static_cast<size_t>(size) < sizeof(message) ? message : fallback);
      } else emit(level,safe,pattern.message);
      return;
    }
  }
  emit(level,safe,fallback);
}
