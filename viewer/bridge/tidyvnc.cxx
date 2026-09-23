/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include <viewer/core/WindowGeometry.h>
#include <viewer/core/StartupLogging.h>
#include <core/Logger_file.h>
#include "tidyvnc.h"
#include <viewer/core/PointerEventPolicy.h>
#include <viewer/core/DesktopLayout.h>
#include <viewer/core/CertificateKey.h>
#include <viewer/core/SecurityOptions.h>
#include <viewer/core/CertificatePolicy.h>
#include <viewer/core/SessionWorker.h>
#include <viewer/core/ListenerWorker.h>
#include <viewer/core/Endpoint.h>
#include <viewer/core/ConnectionDocument.h>
#include <viewer/core/DocumentOptions.h>
#include <viewer/core/Invocation.h>
#include <viewer/core/DesktopTransform.h>
#include <viewer/core/FrameTileRenderer.h>
#include <viewer/core/CursorRenderer.h>
#include <viewer/core/ShortcutState.h>
#include <rfb/Security.h>
#include <rfb/RSAAESKey.h>
#include <rfb/obfuscate.h>
#include <rfb/encodings.h>
#include <cmath>
#if defined(__APPLE__) || defined(__linux__)
#include <viewer/platform/SocketConnector.h>
#include <viewer/platform/SocketListener.h>
#include <viewer/platform/PrivateFileLogger.h>
#endif
#include <core/string.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <limits>
#include <map>
#include <mutex>
#include <thread>
#include <system_error>
#include <cstdio>
#include <cerrno>
#if defined(__APPLE__) || defined(__linux__)
#include <fcntl.h>
#include <unistd.h>
#endif
using namespace viewer;
namespace {
core::LogWriter viewportLog("NativeDesktop");
constexpr size_t handleLimit = 4096, runtimeLimit = 8;
constexpr uint64_t features = TIDYVNC_FEATURE_VIEWPORT_DIAGNOSTICS | TIDYVNC_FEATURE_RUNTIME | TIDYVNC_FEATURE_EVENT_POLL |
  TIDYVNC_FEATURE_IMAGES | TIDYVNC_FEATURE_INPUT | TIDYVNC_FEATURE_PROMPTS | TIDYVNC_FEATURE_CALLBACKS | TIDYVNC_FEATURE_GEOMETRY | TIDYVNC_FEATURE_CLIPBOARD | TIDYVNC_FEATURE_ENCODING | TIDYVNC_FEATURE_ENDPOINT_VALIDATION | TIDYVNC_FEATURE_SCALING | TIDYVNC_FEATURE_TILE_RENDERER | TIDYVNC_FEATURE_DAMAGE_GEOMETRY | TIDYVNC_FEATURE_CURSOR_RENDERER | TIDYVNC_FEATURE_INPUT_POLICY | TIDYVNC_FEATURE_SHORTCUTS | TIDYVNC_FEATURE_INPUT_RELEASE
#if defined(__APPLE__) || defined(__linux__)
  | TIDYVNC_FEATURE_TCP_UNIX_CONNECT | TIDYVNC_FEATURE_LISTENER | TIDYVNC_FEATURE_ROUTED_CONNECT
#endif
#ifdef HAVE_GNUTLS
  | TIDYVNC_FEATURE_CERTIFICATE_KEY
#endif
  | TIDYVNC_FEATURE_CREDENTIAL_BYTES | TIDYVNC_FEATURE_PASSWORD_FILE_REPLY | TIDYVNC_FEATURE_CONNECTION_INFO | TIDYVNC_FEATURE_ENDPOINT_IDENTITY | TIDYVNC_FEATURE_PROMPT_SECURITY | TIDYVNC_FEATURE_CERTIFICATE_POLICY | TIDYVNC_FEATURE_HOST_KEY_ENCODING | TIDYVNC_FEATURE_REQUIRED_TLS_FILES | TIDYVNC_FEATURE_SECURITY_SELECTION | TIDYVNC_FEATURE_TLS_PRIORITY_VALIDATION | TIDYVNC_FEATURE_SECURITY_RECONFIGURATION | TIDYVNC_FEATURE_SHARED_SESSION | TIDYVNC_FEATURE_DESKTOP_LAYOUT | TIDYVNC_FEATURE_DISPLAY_LAYOUT | TIDYVNC_FEATURE_CANVAS_GEOMETRY | TIDYVNC_FEATURE_CONNECTION_DOCUMENT | TIDYVNC_FEATURE_DOCUMENT_OPTIONS | TIDYVNC_FEATURE_INVOCATION_SYNTAX | TIDYVNC_FEATURE_INVOCATION_VALUES | TIDYVNC_FEATURE_INPUT_TIMING | TIDYVNC_FEATURE_MESSAGE_LIMITS | TIDYVNC_FEATURE_WINDOW_GEOMETRY
#if defined(__APPLE__) || defined(__linux__)
  | TIDYVNC_FEATURE_PROCESS_LOGGING | TIDYVNC_FEATURE_FILE_LOGGING
#endif
  ;
struct Fault {
  explicit Fault(uint32_t status_, uint32_t domain_ = TIDYVNC_DOMAIN_BRIDGE, uint32_t detail_ = 0, int32_t native_ = 0)
    : status(status_), domain(domain_), detail(detail_), native(native_) {}
  uint32_t status, domain, detail; int32_t native;
};
void require(bool value, uint32_t status = TIDYVNC_INVALID_ARGUMENT) { if (!value) throw Fault(status); }
template<class T> void header(const T* value) {
  require(value != nullptr); require(value->size >= sizeof(T));
  require(value->version == TIDYVNC_ABI_VERSION,TIDYVNC_ABI_MISMATCH);
}
template<class T> T output() { T value{}; value.size = sizeof(T); value.version = TIDYVNC_ABI_VERSION; return value; }
const char* diagnostic(uint32_t status) noexcept {
  switch (status) {
  case TIDYVNC_OK: case TIDYVNC_NO_CHANGE: case TIDYVNC_PENDING: return "";
  case TIDYVNC_INVALID_ARGUMENT: return "Invalid argument";
  case TIDYVNC_ABI_MISMATCH: return "Unsupported ABI version";
  case TIDYVNC_UNSUPPORTED: return "Unsupported feature or value";
  case TIDYVNC_INVALID_HANDLE: return "Invalid or released handle";
  case TIDYVNC_WRONG_HANDLE_TYPE: return "Wrong handle type";
  case TIDYVNC_RESOURCE_LIMIT: return "Resource limit reached";
  case TIDYVNC_OUT_OF_MEMORY: return "Allocation failed";
  case TIDYVNC_STALE: return "Stale generation or request";
  case TIDYVNC_NOT_CONNECTED: return "Session is not connected";
  case TIDYVNC_CLOSING: return "Object is closing";
  case TIDYVNC_BUSY: return "Operation is busy";
  case TIDYVNC_QUEUE_FULL: return "Queue capacity reached";
  case TIDYVNC_CANCELLED: return "Operation cancelled";
  case TIDYVNC_NOT_PENDING: return "Operation is not pending";
  case TIDYVNC_VIEW_ONLY: return "View-only policy blocks input";
  case TIDYVNC_UNFOCUSED: return "Session is not focused";
  case TIDYVNC_DISABLED: return "Clipboard direction is disabled";
  case TIDYVNC_ECHO: return "Remote clipboard echo suppressed";
  default: return "Bridge operation failed";
  }
}
void errorValue(tidyvnc_error* error, Fault fault) noexcept {
  if (!error) return;
  auto value = output<tidyvnc_error>(); value.code = fault.status; value.domain = fault.domain;
  value.detail = fault.detail; value.native_error = fault.native;
  auto text = diagnostic(fault.status); std::memcpy(value.message,text,std::strlen(text)+1); *error = value;
}
uint32_t endpointDetail(EndpointErrorCode code) noexcept {
  switch (code) {
  case EndpointErrorCode::TooLong: return TIDYVNC_ENDPOINT_TOO_LONG;
  case EndpointErrorCode::InvalidHost: return TIDYVNC_ENDPOINT_INVALID_HOST;
  case EndpointErrorCode::UnmatchedBracket: return TIDYVNC_ENDPOINT_UNMATCHED_BRACKET;
  case EndpointErrorCode::InvalidPort: return TIDYVNC_ENDPOINT_INVALID_PORT;
  case EndpointErrorCode::InvalidPath: return TIDYVNC_ENDPOINT_INVALID_PATH;
  case EndpointErrorCode::InvalidRoute: return TIDYVNC_ENDPOINT_INVALID_ROUTE;
  case EndpointErrorCode::UnsupportedTransport: return TIDYVNC_ENDPOINT_UNSUPPORTED_TRANSPORT;
  }
  return 0;
}
static_assert(static_cast<unsigned>(ShortcutState::KeyNormal) == TIDYVNC_SHORTCUT_NORMAL &&
  static_cast<unsigned>(ShortcutState::KeyUnarm) == TIDYVNC_SHORTCUT_UNARM && static_cast<unsigned>(ShortcutState::KeyShortcut) == TIDYVNC_SHORTCUT_ACTION &&
  static_cast<unsigned>(ShortcutState::KeyIgnore) == TIDYVNC_SHORTCUT_IGNORE, "Shortcut action IDs changed");
static_assert(static_cast<unsigned>(ScalingSettings::Unscaled) == TIDYVNC_SCALING_UNSCALED &&
  static_cast<unsigned>(ScalingSettings::Auto) == TIDYVNC_SCALING_AUTO &&
  static_cast<unsigned>(ScalingSettings::FixedRatio) == TIDYVNC_SCALING_FIXED_RATIO &&
  static_cast<unsigned>(ScalingSettings::FitWidth) == TIDYVNC_SCALING_FIT_WIDTH &&
  static_cast<unsigned>(ScalingSettings::FitHeight) == TIDYVNC_SCALING_FIT_HEIGHT &&
  static_cast<unsigned>(ScalingSettings::Exact) == TIDYVNC_SCALING_EXACT &&
  static_cast<unsigned>(ScalingSettings::Percent) == TIDYVNC_SCALING_PERCENT &&
  static_cast<unsigned>(ScalingSettings::Independent) == TIDYVNC_SCALING_INDEPENDENT, "Scaling IDs changed");
static_assert(static_cast<unsigned>(ScalingSettings::Nearest) == TIDYVNC_FILTER_NEAREST &&
  static_cast<unsigned>(ScalingSettings::Bilinear) == TIDYVNC_FILTER_BILINEAR &&
  static_cast<unsigned>(ScalingSettings::Area) == TIDYVNC_FILTER_AREA, "Filter IDs changed");
static_assert(static_cast<unsigned>(EncodingOption::AutoSelect) == TIDYVNC_ENCODING_AUTO_SELECT &&
  static_cast<unsigned>(EncodingOption::FullColor) == TIDYVNC_ENCODING_FULL_COLOR &&
  static_cast<unsigned>(EncodingOption::LowColorLevel) == TIDYVNC_ENCODING_LOW_COLOR_LEVEL &&
  static_cast<unsigned>(EncodingOption::PreferredEncoding) == TIDYVNC_ENCODING_PREFERRED &&
  static_cast<unsigned>(EncodingOption::CustomCompressLevel) == TIDYVNC_ENCODING_CUSTOM_COMPRESSION &&
  static_cast<unsigned>(EncodingOption::CompressLevel) == TIDYVNC_ENCODING_COMPRESSION &&
  static_cast<unsigned>(EncodingOption::NoJPEG) == TIDYVNC_ENCODING_NO_JPEG &&
  static_cast<unsigned>(EncodingOption::QualityLevel) == TIDYVNC_ENCODING_QUALITY, "Encoding IDs changed");
static_assert(static_cast<unsigned>(OptionSource::Compiled) == TIDYVNC_SOURCE_COMPILED &&
  static_cast<unsigned>(OptionSource::AppDefaults) == TIDYVNC_SOURCE_APP_DEFAULTS &&
  static_cast<unsigned>(OptionSource::Profile) == TIDYVNC_SOURCE_PROFILE &&
  static_cast<unsigned>(OptionSource::Session) == TIDYVNC_SOURCE_SESSION &&
  static_cast<unsigned>(OptionSource::CommandLine) == TIDYVNC_SOURCE_COMMAND_LINE &&
  static_cast<unsigned>(OptionSource::Document) == TIDYVNC_SOURCE_DOCUMENT, "Source IDs changed");
Fault encodingFault(const OptionError& error) {
  uint32_t reason = TIDYVNC_ENCODING_INVALID_VALUE, status = TIDYVNC_INVALID_ARGUMENT;
  switch (error.code) {
  case OptionErrorCode::UnknownOption: reason = TIDYVNC_ENCODING_UNKNOWN_OPTION; break;
  case OptionErrorCode::InvalidValue: break;
  case OptionErrorCode::Unsupported: reason = TIDYVNC_ENCODING_UNAVAILABLE; status = TIDYVNC_UNSUPPORTED; break;
  case OptionErrorCode::TooLong: reason = TIDYVNC_ENCODING_TOO_LONG; status = TIDYVNC_RESOURCE_LIMIT; break;
  }
  const auto option = error.id == EncodingOption::Count ? 0 : static_cast<uint32_t>(error.id) + 1;
  return Fault(status,TIDYVNC_DOMAIN_ENCODING,(option << 16) | reason);
}
Fault documentFault(const DocumentError& error) {
  uint32_t reason = 0;
  switch (error.code) {
  case DocumentErrorCode::Empty: reason = TIDYVNC_DOCUMENT_EMPTY; break;
  case DocumentErrorCode::InvalidHeader: reason = TIDYVNC_DOCUMENT_INVALID_HEADER; break;
  case DocumentErrorCode::NullByte: reason = TIDYVNC_DOCUMENT_NULL_BYTE; break;
  case DocumentErrorCode::LineTooLong: reason = TIDYVNC_DOCUMENT_LINE_TOO_LONG; break;
  case DocumentErrorCode::InvalidAssignment: reason = TIDYVNC_DOCUMENT_INVALID_ASSIGNMENT; break;
  case DocumentErrorCode::InvalidEscape: reason = TIDYVNC_DOCUMENT_INVALID_ESCAPE; break;
  case DocumentErrorCode::TooLarge: reason = TIDYVNC_DOCUMENT_TOO_LARGE; break;
  case DocumentErrorCode::TooManyEntries: reason = TIDYVNC_DOCUMENT_TOO_MANY_ENTRIES; break;
  case DocumentErrorCode::InvalidExportName: reason = TIDYVNC_DOCUMENT_INVALID_EXPORT_NAME; break;
  case DocumentErrorCode::InvalidValue: reason = TIDYVNC_DOCUMENT_INVALID_VALUE; break;
  case DocumentErrorCode::Unavailable: reason = TIDYVNC_DOCUMENT_UNAVAILABLE; break;
  }
  const bool limit = error.code == DocumentErrorCode::TooLarge || error.code == DocumentErrorCode::TooManyEntries || error.code == DocumentErrorCode::LineTooLong;
  return Fault(limit ? TIDYVNC_RESOURCE_LIMIT : error.code == DocumentErrorCode::Unavailable ? TIDYVNC_UNSUPPORTED : TIDYVNC_INVALID_ARGUMENT,
               TIDYVNC_DOMAIN_DOCUMENT, (static_cast<uint32_t>(error.line) << 8) | reason);
}
Fault invocationFault(const InvocationError& error) {
  const uint32_t reason = static_cast<uint32_t>(error.problem)+1;
  const bool limit = error.problem == InvocationProblem::TooLarge || error.problem == InvocationProblem::TooManyArguments;
  return Fault(limit ? TIDYVNC_RESOURCE_LIMIT : error.problem == InvocationProblem::Unavailable ? TIDYVNC_UNSUPPORTED : TIDYVNC_INVALID_ARGUMENT,
    TIDYVNC_DOMAIN_INVOCATION,(static_cast<uint32_t>(error.argument) << 8) | reason);
}
static_assert(static_cast<unsigned>(InvocationProblem::TooManyArguments)+1 == TIDYVNC_INVOCATION_TOO_MANY_ARGUMENTS &&
  static_cast<unsigned>(InvocationProblem::ExtraOperand)+1 == TIDYVNC_INVOCATION_EXTRA_OPERAND, "Invocation problem IDs changed");
static_assert(static_cast<unsigned>(InvocationProblem::InvalidValue)+1 == TIDYVNC_INVOCATION_INVALID_VALUE, "Invocation invalid value changed");
static_assert(static_cast<unsigned>(InvocationAction::Launch) == TIDYVNC_INVOCATION_LAUNCH &&
  static_cast<unsigned>(InvocationAction::Help) == TIDYVNC_INVOCATION_HELP &&
  static_cast<unsigned>(InvocationAction::Version) == TIDYVNC_INVOCATION_VERSION, "Invocation action IDs changed");
static_assert(static_cast<unsigned>(InvocationCategory::Connection) == TIDYVNC_INVOCATION_CONNECTION, "Invocation category changed");
static_assert(static_cast<unsigned>(InvocationCategory::Encoding) == TIDYVNC_INVOCATION_ENCODING, "Invocation category changed");
static_assert(static_cast<unsigned>(InvocationCategory::Input) == TIDYVNC_INVOCATION_INPUT, "Invocation category changed");
static_assert(static_cast<unsigned>(InvocationCategory::Display) == TIDYVNC_INVOCATION_DISPLAY, "Invocation category changed");
static_assert(static_cast<unsigned>(InvocationCategory::Security) == TIDYVNC_INVOCATION_SECURITY, "Invocation category changed");
static_assert(static_cast<unsigned>(InvocationCategory::CredentialFile) == TIDYVNC_INVOCATION_CREDENTIAL_FILE, "Invocation category changed");
static_assert(static_cast<unsigned>(InvocationCategory::Logging) == TIDYVNC_INVOCATION_LOGGING, "Invocation category changed");
static_assert(static_cast<unsigned>(InvocationCategory::Network) == TIDYVNC_INVOCATION_NETWORK, "Invocation category changed");
static_assert(static_cast<unsigned>(InvocationCategory::Listen) == TIDYVNC_INVOCATION_LISTEN, "Invocation category changed");
static_assert(static_cast<unsigned>(InvocationCategory::Tunnel) == TIDYVNC_INVOCATION_TUNNEL, "Invocation category changed");
static_assert(static_cast<unsigned>(InvocationCategory::Platform) == TIDYVNC_INVOCATION_PLATFORM, "Invocation category changed");
static_assert(static_cast<unsigned>(InvocationProblem::TooLarge)+1 == TIDYVNC_INVOCATION_TOO_LARGE, "Invocation problem changed");
static_assert(static_cast<unsigned>(InvocationProblem::NullByte)+1 == TIDYVNC_INVOCATION_NULL_BYTE, "Invocation problem changed");
static_assert(static_cast<unsigned>(InvocationProblem::UnknownOption)+1 == TIDYVNC_INVOCATION_UNKNOWN_OPTION, "Invocation problem changed");
static_assert(static_cast<unsigned>(InvocationProblem::MissingValue)+1 == TIDYVNC_INVOCATION_MISSING_VALUE, "Invocation problem changed");
static_assert(static_cast<unsigned>(InvocationProblem::Unavailable)+1 == TIDYVNC_INVOCATION_UNAVAILABLE, "Invocation problem changed");
template<class F> tidyvnc_status call(tidyvnc_error* error,F body) noexcept {
  bool writable = false;
  try {
    if (error) { header(error); writable = true; }
    const uint32_t status = body(); errorValue(error,Fault(status)); return status;
  } catch (const Fault& fault) { if (writable) errorValue(error,fault); return fault.status; }
  catch (const EndpointError& fault) {
    if (writable) errorValue(error,Fault(TIDYVNC_INVALID_ARGUMENT,TIDYVNC_DOMAIN_ENDPOINT,endpointDetail(fault.code)));
    return TIDYVNC_INVALID_ARGUMENT;
  } catch (const InvocationError& problem) {
    const auto fault = invocationFault(problem); if (writable) errorValue(error,fault); return fault.status;
  } catch (const LoggingError& problem) {
    const auto status = problem.problem == LoggingProblem::TooLarge ? TIDYVNC_RESOURCE_LIMIT :
      problem.problem == LoggingProblem::UnknownTarget ? TIDYVNC_UNSUPPORTED : TIDYVNC_INVALID_ARGUMENT;
    const auto fault = Fault(status,TIDYVNC_DOMAIN_LOGGING,
      (static_cast<uint32_t>(problem.entry) << 8) | (static_cast<uint32_t>(problem.problem)+1));
    if (writable) errorValue(error,fault);
    return fault.status;
#if defined(__APPLE__) || defined(__linux__)
  } catch (const LogFilePathError&) {
    const auto fault = Fault(TIDYVNC_INVALID_ARGUMENT,TIDYVNC_DOMAIN_LOGGING,TIDYVNC_LOGGING_INVALID_FILE_PATH);
    if (writable) errorValue(error,fault);
    return fault.status;
#endif
  } catch (const LoggingFrozen&) {
    const auto fault = Fault(TIDYVNC_BUSY,TIDYVNC_DOMAIN_LOGGING,TIDYVNC_LOGGING_FROZEN);
    if (writable) errorValue(error,fault);
    return fault.status;
  } catch (const DocumentError& problem) {
    const auto fault = documentFault(problem); if (writable) errorValue(error,fault); return fault.status;
  } catch (const OptionError& error_) {
    const auto fault = encodingFault(error_); if (writable) errorValue(error,fault); return fault.status;
  } catch (const SecurityOptionError& problem) {
    const auto status = problem.problem == SecurityOptionProblem::Unavailable ? TIDYVNC_UNSUPPORTED :
      problem.problem == SecurityOptionProblem::TooLong ? TIDYVNC_RESOURCE_LIMIT : TIDYVNC_INVALID_ARGUMENT;
    if (writable) errorValue(error,Fault(status,TIDYVNC_DOMAIN_SECURITY,static_cast<uint32_t>(problem.problem)));
    return status;
  } catch (const std::bad_alloc&) { if (writable) errorValue(error,Fault(TIDYVNC_OUT_OF_MEMORY)); return TIDYVNC_OUT_OF_MEMORY; }
  catch (const std::invalid_argument&) { if (writable) errorValue(error,Fault(TIDYVNC_INVALID_ARGUMENT)); return TIDYVNC_INVALID_ARGUMENT; }
  catch (const std::length_error&) { if (writable) errorValue(error,Fault(TIDYVNC_RESOURCE_LIMIT)); return TIDYVNC_RESOURCE_LIMIT; }
  catch (const std::overflow_error&) { if (writable) errorValue(error,Fault(TIDYVNC_RESOURCE_LIMIT)); return TIDYVNC_RESOURCE_LIMIT; }
  catch (const std::system_error& fault) {
    if (writable) errorValue(error,Fault(TIDYVNC_FAILED,TIDYVNC_DOMAIN_BRIDGE,0,fault.code().value()));
    return TIDYVNC_FAILED;
  } catch (...) { if (writable) errorValue(error,Fault(TIDYVNC_INTERNAL)); return TIDYVNC_INTERNAL; }
}
std::string text(tidyvnc_bytes bytes, uint64_t maximum = 4096) {
  require(bytes.length <= maximum && (bytes.data || !bytes.length));
  if (!bytes.length) return {};
  const auto count = static_cast<size_t>(bytes.length);
  require(std::memchr(bytes.data,0,count) == nullptr && core::isValidUTF8(reinterpret_cast<const char*>(bytes.data),count));
  return std::string(reinterpret_cast<const char*>(bytes.data),count);
}
LoggingPolicy loggingPolicy(tidyvnc_bytes input) {
  if (input.length > LoggingPolicy::maximumBytes) throw LoggingError(LoggingProblem::TooLarge,0);
  require(input.data || !input.length);
  if (input.length && std::memchr(input.data,0,static_cast<size_t>(input.length)))
    throw LoggingError(LoggingProblem::NullByte,0);
  return LoggingPolicy::parse(text(input,LoggingPolicy::maximumBytes));
}
tidyvnc_bytes bytes(const std::string& value) { return {reinterpret_cast<const uint8_t*>(value.data()),value.size()}; }
std::string documentBytes(tidyvnc_bytes input, size_t maximum, DocumentErrorCode limit) {
  if (input.length > maximum) throw DocumentError(limit);
  require(input.data || !input.length);
  return input.length ? std::string(reinterpret_cast<const char*>(input.data),static_cast<size_t>(input.length)) : std::string();
}
Endpoint endpointValue(tidyvnc_bytes value, bool allowUnixSockets = true) {
  if (value.length > 4096) throw EndpointError(EndpointErrorCode::TooLong);
  return Endpoint::parse(text(value),allowUnixSockets);
}
void boolean(uint32_t value) { require(value <= 1); }

RemoteDesktopLayout desktopLayout(const tidyvnc_desktop_layout_request* input) {
  header(input); require(!input->reserved && input->screens && input->screen_count && input->screen_count <= 255);
  std::vector<RemoteScreen> screens; screens.reserve(input->screen_count);
  for (uint32_t i = 0; i < input->screen_count; ++i) {
    const auto& s = input->screens[i]; screens.push_back({s.id,s.x,s.y,s.width,s.height,s.flags});
  }
  return RemoteDesktopLayout(input->width,input->height,std::move(screens));
}
enum class Kind { Runtime, Session, Listener, Image, Prompt, Subscription, Clipboard, Encoding, Renderer, CursorSampler, Shortcut, Endpoint, CertificateKey, Document, Invocation };
struct Object { virtual ~Object() = default; virtual void released() noexcept {} };
struct Registry {
  struct Entry { Kind kind; uint64_t references = 0; std::shared_ptr<Object> object; };
  std::mutex mutex;
  std::map<uint64_t,Entry> entries;
  uint64_t next = 0;
  uint64_t reserve(Kind kind) {
    std::lock_guard<std::mutex> lock(mutex);
    require(entries.size() < handleLimit && next != UINT64_MAX,TIDYVNC_RESOURCE_LIMIT);
    const auto id = ++next; Entry entry; entry.kind = kind; entries.emplace(id,std::move(entry)); return id;
  }
  void discard(uint64_t id) noexcept { std::lock_guard<std::mutex> lock(mutex); entries.erase(id); }
  void commit(uint64_t id,std::shared_ptr<Object> object) noexcept {
    std::lock_guard<std::mutex> lock(mutex); auto& entry = entries.at(id); entry.object = std::move(object); entry.references = 1;
  }
  std::shared_ptr<Object> get(uint64_t id,Kind kind) {
    std::lock_guard<std::mutex> lock(mutex); auto found = entries.find(id);
    require(found != entries.end() && found->second.object,TIDYVNC_INVALID_HANDLE);
    require(found->second.kind == kind,TIDYVNC_WRONG_HANDLE_TYPE); return found->second.object;
  }
  void retain(uint64_t id) {
    std::lock_guard<std::mutex> lock(mutex); auto found = entries.find(id);
    require(found != entries.end() && found->second.object,TIDYVNC_INVALID_HANDLE);
    require(found->second.references != UINT64_MAX,TIDYVNC_RESOURCE_LIMIT); ++found->second.references;
  }
  void release(uint64_t id) {
    std::shared_ptr<Object> retired;
    {
      std::lock_guard<std::mutex> lock(mutex); auto found = entries.find(id);
      require(found != entries.end() && found->second.object,TIDYVNC_INVALID_HANDLE);
      if (--found->second.references) return;
      retired = std::move(found->second.object); entries.erase(found);
    }
    retired->released(); // No destructors or injected behavior under registry lock.
  }
};
Registry& registry() { static Registry value; return value; }
struct Reservation {
  explicit Reservation(Kind kind) : id(registry().reserve(kind)) {}
  ~Reservation() { if (id) registry().discard(id); }
  Reservation(const Reservation&) = delete;
  uint64_t commit(const std::shared_ptr<Object>& object) noexcept { auto result = id; registry().commit(id,object); id = 0; return result; }
  uint64_t id;
};
template<class T> std::shared_ptr<T> get(uint64_t handle,Kind kind) { return std::static_pointer_cast<T>(registry().get(handle,kind)); }
struct Runtime : Object {
  Runtime() : done(completion.get_future().share()) {}
  void close() noexcept;
  void released() noexcept override { close(); }
  std::mutex mutex;
  std::unique_ptr<SessionRuntime> core;
  std::unique_ptr<ListenerRuntime> listeners;
  bool closing = false;
  std::promise<void> completion;
  std::shared_future<void> done;
};
// Constructed before RuntimeService, therefore destroyed after that service has
// joined every runtime. No registry snapshot or destination is created merely
// by freezing legacy/default C consumers that never configure native logging.
struct ProcessLogging {
  std::mutex mutex;
  bool closed = false;
  std::unique_ptr<StartupLogging> owner;
  StartupLogging& get() {
    if (!owner) owner.reset(new StartupLogging(core::LogWriter::registeredWriters(),{"stderr","stdout","file"}));
    return *owner;
  }
  void freeze() {
    std::lock_guard<std::mutex> lock(mutex); closed = true;
    if (owner) owner->freeze();
  }
};
ProcessLogging& processLogging() { static ProcessLogging value; return value; }
// Not decltype(&fclose): GCC ignores glibc's attributes there and -Werror fails.
struct CloseStream { void operator()(FILE* stream) const noexcept { std::fclose(stream); } };
std::unique_ptr<core::Logger> loggingDestination(const std::string& name, const std::string& path) {
#if defined(__APPLE__) || defined(__linux__)
  if (name == "file") return std::unique_ptr<core::Logger>(new PrivateFileLogger(path));
  require(name == "stderr" || name == "stdout",TIDYVNC_UNSUPPORTED);
  const int source = name == "stderr" ? STDERR_FILENO : STDOUT_FILENO;
  const int fd = fcntl(source,F_DUPFD_CLOEXEC,3);
  if (fd < 0) throw std::system_error(errno,std::generic_category());
  FILE* stream = fdopen(fd,"w");
  if (!stream) { const int code = errno; close(fd); throw std::system_error(code,std::generic_category()); }
  std::unique_ptr<FILE,CloseStream> owned(stream);
  std::unique_ptr<core::Logger_File> sink(new core::Logger_File("native-stdio"));
  sink->setFile(owned.get()); owned.release();
  return std::unique_ptr<core::Logger>(sink.release());
#else
  (void)name; (void)path; throw Fault(TIDYVNC_UNSUPPORTED);
#endif
}
// The service retains each runtime until its coordinator has joined. Foreign
// callers only mark shutdown; they never destroy a SessionRuntime themselves.
class RuntimeService {
public:
  RuntimeService() : thread([this] { reap(); }) {}
  ~RuntimeService() {
    std::array<std::shared_ptr<Runtime>,runtimeLimit> closing;
    { std::lock_guard<std::mutex> lock(mutex); stopping = true; dirty = true; closing = live; }
    for (auto& runtime : closing) if (runtime) runtime->close();
    changed.notify_one(); thread.join();
  }
  std::shared_ptr<Runtime> create(size_t capacity) {
    auto runtime = std::make_shared<Runtime>(); size_t slot = runtimeLimit;
    {
      std::lock_guard<std::mutex> lock(mutex); require(!stopping,TIDYVNC_CLOSING);
      for (size_t i = 0; i < runtimeLimit; ++i) if (!live[i]) { slot = i; break; }
      require(slot != runtimeLimit,TIDYVNC_RESOURCE_LIMIT); live[slot] = runtime;
    }
    try { std::lock_guard<std::mutex> lock(runtime->mutex); runtime->core.reset(new SessionRuntime(capacity)); }
    catch (...) { std::lock_guard<std::mutex> lock(mutex); live[slot].reset(); throw; }
    return runtime;
  }
  void notify() noexcept {
    { std::lock_guard<std::mutex> lock(mutex); dirty = true; }
    changed.notify_one();
  }
private:
  void reap() noexcept {
    bool draining = false;
    for (;;) {
      std::array<std::shared_ptr<Runtime>,runtimeLimit> checking;
      {
        std::unique_lock<std::mutex> lock(mutex);
        if (draining) changed.wait_for(lock,std::chrono::milliseconds(20),[&] { return dirty; });
        else changed.wait(lock,[&] { return dirty; });
        dirty = false; checking = live;
      }
      draining = false;
      for (size_t i = 0; i < runtimeLimit; ++i) if (checking[i]) {
        auto& runtime = checking[i]; std::unique_ptr<SessionRuntime> retired;
        std::unique_ptr<ListenerRuntime> retiredListeners;
        {
          std::lock_guard<std::mutex> lock(runtime->mutex);
          if (runtime->closing && runtime->core && runtime->core->drained().wait_for(std::chrono::milliseconds(0)) == std::future_status::ready &&
              (!runtime->listeners || runtime->listeners->drained().wait_for(std::chrono::milliseconds(0)) == std::future_status::ready)) {
            retired = std::move(runtime->core); retiredListeners = std::move(runtime->listeners);
          }
          else if (runtime->closing && runtime->core) draining = true;
        }
        if (retired) {
          retiredListeners.reset(); retired.reset();
          { std::lock_guard<std::mutex> lock(mutex); live[i].reset(); }
          runtime->completion.set_value();
        }
      }
      std::lock_guard<std::mutex> lock(mutex);
      if (stopping && std::none_of(live.begin(),live.end(),[](const std::shared_ptr<Runtime>& value) { return bool(value); })) return;
    }
  }
  std::mutex mutex;
  std::condition_variable changed;
  std::array<std::shared_ptr<Runtime>,runtimeLimit> live;
  bool stopping = false, dirty = false;
  std::thread thread;
};
RuntimeService& service() { static RuntimeService value; return value; }
void Runtime::close() noexcept {
  { std::lock_guard<std::mutex> lock(mutex); closing = true; if (listeners) listeners->shutdown(); if (core) core->shutdown(); }
  service().notify();
}
constexpr size_t subscriptionLimit = 512;
struct Subscription;
struct CallbackState {
  std::mutex mutex;
  std::condition_variable changed;
  std::array<std::shared_ptr<Subscription>,subscriptionLimit> live;
  bool stopping = false;
};
struct NotificationSource : MailboxWakeup {
  explicit NotificationSource(std::shared_ptr<CallbackState> state_) : state(std::move(state_)) {}
  void wake() noexcept override;
  void close() noexcept;
  std::shared_ptr<CallbackState> state;
  std::weak_ptr<Subscription> subscription; // Guarded by state->mutex.
  bool closed = false;
};
struct Subscription : Object {
  ~Subscription() override { releaseContext(); }
  void releaseContext() noexcept {
    if (!retained) return;
    retained = false;
    // Foreign code must not throw. Contain a C++ caller's violation so cleanup
    // cannot terminate the dispatcher or unwind across an exported C function.
    try { callbacks.release_context(callbacks.context); } catch (...) {}
  }
  void released() noexcept override {
    { std::lock_guard<std::mutex> lock(source->state->mutex); active = false; }
    source->state->changed.notify_one();
  }
  std::shared_ptr<NotificationSource> source;
  std::weak_ptr<SessionWorker> core;
  std::weak_ptr<ListenerWorker> listener;
  tidyvnc_callbacks callbacks{};
  uint64_t id = 0;
  bool retained = false; // Caller owns until armed, dispatcher owns thereafter.
  bool active = true, armed = false, pending = true; // state mutex.
  std::atomic<bool> drained{false};
};
void NotificationSource::wake() noexcept {
  { std::lock_guard<std::mutex> lock(state->mutex);
    if (state->stopping || closed) return;
    auto value = subscription.lock();
    if (!value || !value->active || value->pending) return;
    value->pending = true;
  }
  state->changed.notify_one();
}
void NotificationSource::close() noexcept {
  { std::lock_guard<std::mutex> lock(state->mutex); closed = true;
    if (auto value = subscription.lock()) value->active = false;
  }
  state->changed.notify_one();
}
// Only this thread invokes published callbacks and disposes their contexts.
// Fixed slots bound pending work; readiness is a bit, never an allocated queue.
class CallbackService {
public:
  CallbackService() : state(std::make_shared<CallbackState>()), thread([this] { dispatch(); }) {}
  ~CallbackService() {
    { std::lock_guard<std::mutex> lock(state->mutex); state->stopping = true;
      for (auto& value : state->live) if (value) value->active = false;
    }
    state->changed.notify_one(); thread.join();
  }
  std::shared_ptr<NotificationSource> source() { return std::make_shared<NotificationSource>(state); }
  static void install(const std::shared_ptr<Subscription>& value) {
    auto source = value->source; auto state = source->state;
    std::lock_guard<std::mutex> lock(state->mutex);
    require(!state->stopping && !source->closed,TIDYVNC_CLOSING);
    auto previous = source->subscription.lock();
    require(!previous || previous->drained.load(),TIDYVNC_BUSY);
    const auto slot = std::find(state->live.begin(),state->live.end(),nullptr);
    require(slot != state->live.end(),TIDYVNC_RESOURCE_LIMIT);
    *slot = value; source->subscription = value;
  }
  static void arm(const std::shared_ptr<Subscription>& value) noexcept {
    { std::lock_guard<std::mutex> lock(value->source->state->mutex); value->armed = true; }
    value->source->state->changed.notify_one();
  }
private:
  void dispatch() noexcept {
    size_t next = 0;
    std::unique_lock<std::mutex> lock(state->mutex);
    for (;;) {
      size_t slot = subscriptionLimit;
      for (size_t i = 0; i < subscriptionLimit; ++i) {
        const auto index = (next + i) % subscriptionLimit;
        const auto& value = state->live[index];
        if (value && value->armed && (!value->active || value->pending)) { slot = index; break; }
      }
      if (slot == subscriptionLimit) {
        if (state->stopping && std::none_of(state->live.begin(),state->live.end(),
            [](const std::shared_ptr<Subscription>& value) { return bool(value); })) return;
        state->changed.wait(lock); continue;
      }
      next = (slot + 1) % subscriptionLimit; // A hot session cannot starve others.
      auto value = state->live[slot];
      const bool deliver = value->active;
      value->pending = false; // This delivery is started; cancellation won't wait.
      lock.unlock();
      if (deliver) {
        try {
          if (auto core = value->core.lock())
            value->callbacks.ready(value->callbacks.context,value->id,core->generation());
          else if (auto listener = value->listener.lock())
            value->callbacks.ready(value->callbacks.context,value->id,1);
          else value->released();
        } catch (...) { value->released(); }
      }
      lock.lock();
      if (!value->active) {
        lock.unlock(); value->releaseContext(); lock.lock();
        state->live[slot].reset();
        value->drained.store(true);
      }
      // Destructors (including possible captured host state) stay outside locks.
      lock.unlock(); value.reset(); lock.lock();
    }
  }
  std::shared_ptr<CallbackState> state;
  std::thread thread;
};
CallbackService& callbackService() { static CallbackService value; return value; }
struct Session : Object {
  std::shared_ptr<SessionWorker> core;
  std::shared_ptr<NotificationSource> notifications;
  void released() noexcept override {
    if (notifications) notifications->close();
    if (core) core->closeAndDrain();
  }
};
struct Listener : Object {
  std::shared_ptr<ListenerWorker> core;
  std::shared_ptr<NotificationSource> notifications;
  void released() noexcept override {
    if (notifications) notifications->close();
    if (core) core->closeAndDrain();
  }
};
// Adopts an already connected peer through the same reusable session admission
// gate as outbound attempts. The socket control also cancels before run starts.
class IncomingConnection final : public ConnectionAttempt {
public:
  explicit IncomingConnection(AcceptedPeer peer) : transport(std::move(peer.transport)), name(peer.peer->address.host), token(transport->control()) {
    const auto scope = name.find('%');
    if (name.find(':') != std::string::npos && scope != std::string::npos) name.resize(scope);
  }
  std::string serverName() const override { return name; }
  std::shared_ptr<TransportControl> control() const override { return token; }
  std::unique_ptr<SessionTransport> run(const Progress&) override { return std::move(transport); }
private:
  std::unique_ptr<SessionTransport> transport;
  std::string name;
  std::shared_ptr<TransportControl> token;
};
uint32_t peerStatus(PeerAdmission status) {
  switch (status) {
  case PeerAdmission::Accepted: return TIDYVNC_OK;
  case PeerAdmission::NotPending: return TIDYVNC_NOT_PENDING;
  case PeerAdmission::Expired: return TIDYVNC_STALE;
  case PeerAdmission::Closing: return TIDYVNC_CLOSING;
  case PeerAdmission::EventCapacity: return TIDYVNC_QUEUE_FULL;
  }
  return TIDYVNC_INTERNAL;
}
static_assert(static_cast<unsigned>(ListenerState::Starting) == TIDYVNC_LISTENER_STARTING &&
  static_cast<unsigned>(ListenerState::Listening) == TIDYVNC_LISTENER_LISTENING &&
  static_cast<unsigned>(ListenerState::Stopping) == TIDYVNC_LISTENER_STOPPING &&
  static_cast<unsigned>(ListenerState::Closed) == TIDYVNC_LISTENER_CLOSED &&
  static_cast<unsigned>(ListenerState::Failed) == TIDYVNC_LISTENER_FAILED, "Listener states changed");
static_assert(static_cast<unsigned>(ListenerEventKind::State) == TIDYVNC_LISTENER_STATE &&
  static_cast<unsigned>(ListenerEventKind::Incoming) == TIDYVNC_LISTENER_INCOMING &&
  static_cast<unsigned>(ListenerEventKind::Accepted) == TIDYVNC_LISTENER_ACCEPTED &&
  static_cast<unsigned>(ListenerEventKind::Rejected) == TIDYVNC_LISTENER_REJECTED &&
  static_cast<unsigned>(ListenerEventKind::Expired) == TIDYVNC_LISTENER_EXPIRED, "Listener events changed");
static_assert(static_cast<unsigned>(ListenerErrorCode::None) == TIDYVNC_LISTENER_ERROR_NONE &&
  static_cast<unsigned>(ListenerErrorCode::Cancelled) == TIDYVNC_LISTENER_ERROR_CANCELLED &&
  static_cast<unsigned>(ListenerErrorCode::Bind) == TIDYVNC_LISTENER_ERROR_BIND &&
  static_cast<unsigned>(ListenerErrorCode::Accept) == TIDYVNC_LISTENER_ERROR_ACCEPT &&
  static_cast<unsigned>(ListenerErrorCode::InvalidAddress) == TIDYVNC_LISTENER_ERROR_INVALID_ADDRESS &&
  static_cast<unsigned>(ListenerErrorCode::Unsupported) == TIDYVNC_LISTENER_ERROR_UNSUPPORTED &&
  static_cast<unsigned>(ListenerErrorCode::EventOverflow) == TIDYVNC_LISTENER_ERROR_EVENT_OVERFLOW &&
  static_cast<unsigned>(ListenerErrorCode::Internal) == TIDYVNC_LISTENER_ERROR_INTERNAL, "Listener errors changed");
tidyvnc_listener_address listenerAddress(const ListenerAddress& address) {
  tidyvnc_listener_address result{};
  // SocketListener produces at most INET6_ADDRSTRLEN + '%' + uint32 scope.
  require(address.host.size() < sizeof(result.host),TIDYVNC_INTERNAL);
  std::memcpy(result.host,address.host.c_str(),address.host.size()+1);
  result.port = address.port; return result;
}
tidyvnc_listener_snapshot listenerSnapshot(const ListenerSnapshot& snapshot) {
  auto result = output<tidyvnc_listener_snapshot>();
  result.state = static_cast<uint32_t>(snapshot.state); result.error = static_cast<uint32_t>(snapshot.error);
  result.native_error = snapshot.nativeError; result.pending = static_cast<uint32_t>(snapshot.pending);
  if (snapshot.addresses) {
    require(snapshot.addresses->size() <= 2,TIDYVNC_INTERNAL);
    result.address_count = static_cast<uint32_t>(snapshot.addresses->size());
    for (size_t i = 0; i < snapshot.addresses->size(); ++i) result.addresses[i] = listenerAddress((*snapshot.addresses)[i]);
  }
  return result;
}
struct Image : Object { FrameLease frame; CursorLease cursor; uint64_t source = 0; };
struct Renderer : Object {
  explicit Renderer(size_t bytes) : value(bytes) {}
  std::mutex mutex;
  FrameTileRenderer value;
};
struct CursorSampler : Object {
  CursorSampler(const Cursor& cursor, const tidyvnc_cursor_options& options)
    : value(cursor.pixels.data(),cursor.pixels.width(),cursor.pixels.height(),
            {int(cursor.hotspotX),int(cursor.hotspotY)}, options.scale_x,options.scale_y,
            static_cast<ScalingSettings::Quality>(options.quality)) {}
  const CursorRenderer value;
};
struct CertificateKeyIdentity : Object {
  explicit CertificateKeyIdentity(tidyvnc_bytes input) : key(input.data,static_cast<size_t>(input.length)) {}
  viewer::CertificateKey key;
};
struct EndpointIdentity : Object {
  explicit EndpointIdentity(Endpoint value_) : value(std::move(value_)) {}
  const Endpoint value;
};
struct Invocation : Object {
  explicit Invocation(InvocationSyntax input) : value(std::move(input)) {}
  const InvocationSyntax value;
};
struct Document : Object {
  explicit Document(ConnectionDocument input) : value(std::move(input)) {}
  const ConnectionDocument value;
};
struct Shortcut : Object { std::mutex mutex; ShortcutState value; };
struct Prompt : Object { AuthenticationPrompt value; };
struct Clipboard : Object { ClipboardLease value; uint64_t session = 0; };
struct Encoding : Object {
  explicit Encoding(const EncodingOptions& options) : value(options) {}
  const EncodingOptions value;
};
template<size_t N> void copyText(char (&out)[N], const std::string& value) {
  require(value.size() < N,TIDYVNC_RESOURCE_LIMIT); std::memcpy(out,value.c_str(),value.size()+1);
}
tidyvnc_clipboard_route clipboardRoute(ClipboardRoute route,uint64_t session) {
  auto value = output<tidyvnc_clipboard_route>(); value.generation = route.generation;
  value.session = session;
  value.focus_revision = route.focus; value.policy_revision = route.policy; return value;
}
uint32_t clipboardResult(ClipboardResult result) {
  switch (result) {
  case ClipboardResult::Accepted: return TIDYVNC_OK;
  case ClipboardResult::Stale: return TIDYVNC_STALE;
  case ClipboardResult::NotConnected: return TIDYVNC_NOT_CONNECTED;
  case ClipboardResult::Unfocused: return TIDYVNC_UNFOCUSED;
  case ClipboardResult::ViewOnly: return TIDYVNC_VIEW_ONLY;
  case ClipboardResult::Disabled: return TIDYVNC_DISABLED;
  case ClipboardResult::Echo: return TIDYVNC_ECHO;
  case ClipboardResult::InvalidText: return TIDYVNC_INVALID_ARGUMENT;
  case ClipboardResult::TooLarge: case ClipboardResult::Backpressure: return TIDYVNC_RESOURCE_LIMIT;
  }
  return TIDYVNC_INTERNAL;
}
std::shared_ptr<SessionWorker> session(uint64_t id) { return get<Session>(id,Kind::Session)->core; }
uint32_t stateValue(SessionState state) {
  switch (state) {
  case SessionState::Idle: return TIDYVNC_STATE_IDLE;
  case SessionState::Resolving: return TIDYVNC_STATE_RESOLVING;
  case SessionState::Connecting: return TIDYVNC_STATE_CONNECTING;
  case SessionState::Negotiating: return TIDYVNC_STATE_NEGOTIATING;
  case SessionState::Authenticating: return TIDYVNC_STATE_AUTHENTICATING;
  case SessionState::Connected: return TIDYVNC_STATE_CONNECTED;
  case SessionState::Disconnecting: return TIDYVNC_STATE_DISCONNECTING;
  case SessionState::Closed: return TIDYVNC_STATE_CLOSED;
  case SessionState::Failed: return TIDYVNC_STATE_FAILED;
  }
  throw Fault(TIDYVNC_INTERNAL);
}
uint32_t endValue(SessionEndReason reason) {
  switch (reason) {
  case SessionEndReason::None: return TIDYVNC_END_NONE;
  case SessionEndReason::Cancelled: return TIDYVNC_END_CANCELLED;
  case SessionEndReason::PeerClosed: return TIDYVNC_END_PEER_CLOSED;
  case SessionEndReason::PromptTimedOut: return TIDYVNC_END_PROMPT_TIMEOUT;
  case SessionEndReason::AuthenticationRejected: return TIDYVNC_END_AUTH_REJECTED;
  case SessionEndReason::TransportFailure: return TIDYVNC_END_TRANSPORT;
  case SessionEndReason::ProtocolFailure: return TIDYVNC_END_PROTOCOL;
  case SessionEndReason::ResourceFailure: return TIDYVNC_END_RESOURCE;
  case SessionEndReason::InternalFailure: return TIDYVNC_END_INTERNAL;
  case SessionEndReason::EventOverflow: return TIDYVNC_END_EVENT_OVERFLOW;
  case SessionEndReason::ResolutionFailure: return TIDYVNC_END_RESOLUTION;
  case SessionEndReason::ConnectionFailure: return TIDYVNC_END_CONNECTION;
  case SessionEndReason::ResolutionTimedOut: return TIDYVNC_END_RESOLUTION_TIMEOUT;
  case SessionEndReason::ConnectionTimedOut: return TIDYVNC_END_CONNECTION_TIMEOUT;
  case SessionEndReason::UnsupportedEndpoint: return TIDYVNC_END_UNSUPPORTED_ENDPOINT;
  case SessionEndReason::InvalidEndpoint: return TIDYVNC_END_INVALID_ENDPOINT;
  }
  throw Fault(TIDYVNC_INTERNAL);
}
tidyvnc_snapshot snapshot(const SessionSnapshot& in) {
  auto out = output<tidyvnc_snapshot>(); out.state = stateValue(in.state); out.end_reason = endValue(in.endReason);
  out.native_error = in.nativeError; out.width = in.width; out.height = in.height;
  out.supports_resize = in.supportsDesktopResize; out.resize_pending = in.resizePending;
  out.generation = in.generation; out.frames = in.frames; out.bells = in.bells; return out;
}
void submitted(CommandSubmission submission,tidyvnc_operation* out) {
  uint32_t status = TIDYVNC_INTERNAL;
  switch (submission.status) {
  case CommandAdmission::Accepted: { auto value = output<tidyvnc_operation>(); value.operation = submission.operation;
    value.generation = submission.generation; *out = value; return; }
  case CommandAdmission::Closing: status = TIDYVNC_CLOSING; break;
  case CommandAdmission::NotConnected: status = TIDYVNC_NOT_CONNECTED; break;
  case CommandAdmission::StaleGeneration: status = TIDYVNC_STALE; break;
  case CommandAdmission::QueueFull: case CommandAdmission::EventCapacity: status = TIDYVNC_QUEUE_FULL; break;
  case CommandAdmission::Busy: status = TIDYVNC_BUSY; break;
  case CommandAdmission::Unsupported: status = TIDYVNC_UNSUPPORTED; break;
  case CommandAdmission::GenerationExhausted: case CommandAdmission::ResourceLimit: status = TIDYVNC_RESOURCE_LIMIT; break;
  case CommandAdmission::ViewOnly: status = TIDYVNC_VIEW_ONLY; break;
  case CommandAdmission::Unfocused: status = TIDYVNC_UNFOCUSED; break;
  case CommandAdmission::InvalidValue: status = TIDYVNC_INVALID_ARGUMENT; break;
  case CommandAdmission::Disabled: status = TIDYVNC_DISABLED; break;
  case CommandAdmission::Echo: status = TIDYVNC_ECHO; break;
  }
  throw Fault(status,TIDYVNC_DOMAIN_OPERATION);
}
void inputResult(InputResult result) {
  uint32_t status = TIDYVNC_INTERNAL;
  switch (result) {
  case InputResult::Accepted: case InputResult::Coalesced: return;
  case InputResult::StaleGeneration: status = TIDYVNC_STALE; break;
  case InputResult::NotConnected: status = TIDYVNC_NOT_CONNECTED; break;
  case InputResult::ViewOnly: status = TIDYVNC_VIEW_ONLY; break;
  case InputResult::Unfocused: status = TIDYVNC_UNFOCUSED; break;
  case InputResult::Overflow: status = TIDYVNC_QUEUE_FULL; break;
  case InputResult::Invalid: status = TIDYVNC_INVALID_ARGUMENT; break;
  }
  throw Fault(status,TIDYVNC_DOMAIN_INPUT);
}
void promptResult(PromptReply result) {
  if (result == PromptReply::Accepted) return;
  uint32_t status = result == PromptReply::PolicyRejected ? TIDYVNC_UNSUPPORTED :
    result == PromptReply::StaleRequest ? TIDYVNC_STALE :
    result == PromptReply::NoPendingRequest || result == PromptReply::Expired ? TIDYVNC_NOT_PENDING : TIDYVNC_INVALID_ARGUMENT;
  throw Fault(status,TIDYVNC_DOMAIN_AUTHENTICATION);
}
void wipe(uint8_t* data,uint64_t size) noexcept { if (data && size <= 4096) { volatile uint8_t* p = data; while (size--) *p++ = 0; } }
DesktopTransform desktopTransform(const tidyvnc_geometry_options* options, const tidyvnc_canvas_viewport* canvas = nullptr) {
    header(options); require(!options->reserved && options->units <= 1);
    require(options->remote_width && options->remote_width <= 65535 && options->remote_height && options->remote_height <= 65535);
    require(std::isfinite(options->viewport_width) && options->viewport_width > 0 && options->viewport_width <= 65535 &&
            std::isfinite(options->viewport_height) && options->viewport_height > 0 && options->viewport_height <= 65535 &&
            std::isfinite(options->backing_scale) && options->backing_scale > 0 && options->backing_scale <= 64 &&
            std::isfinite(options->pan_x) && options->pan_x >= 0 && options->pan_x <= 65535 &&
            std::isfinite(options->pan_y) && options->pan_y >= 0 && options->pan_y <= 65535);
    auto scaling = ScalingSettings::parse(text(options->scaling,64)); DisplayMetrics metrics;
    metrics.pixelsPerUnitX = metrics.pixelsPerUnitY = options->backing_scale;
    const auto units = options->units ? ScalingSettings::Device : ScalingSettings::Logical;
    const double factor = options->units ? options->backing_scale : 1;
    if (canvas) {
      header(canvas);
      require(canvas->width > 0 && canvas->width <= 65535 && canvas->height > 0 && canvas->height <= 65535 &&
        canvas->x < canvas->width && canvas->y < canvas->height && canvas->region_width > 0 && canvas->region_height > 0 &&
        canvas->region_width <= canvas->width-canvas->x && canvas->region_height <= canvas->height-canvas->y);
    }
    const double availableWidth = canvas ? canvas->width/factor : options->viewport_width;
    const double availableHeight = canvas ? canvas->height/factor : options->viewport_height;
    DesktopTransform transform(options->remote_width,options->remote_height,availableWidth,availableHeight,metrics,scaling,units);
    const int width = canvas ? int(canvas->width) : int(std::ceil(options->viewport_width*factor));
    const int height = canvas ? int(canvas->height) : int(std::ceil(options->viewport_height*factor));
    const core::Rect region = canvas ? core::Rect(canvas->x,canvas->y,canvas->x+canvas->region_width,canvas->y+canvas->region_height) : core::Rect(0,0,width,height);
    transform.placeOnCanvas(width,height,region,units,options->pan_x,options->pan_y);
    return transform;
}
void desktopDamage(const tidyvnc_geometry_options* options,const tidyvnc_canvas_viewport* canvas,
                   const tidyvnc_damage* damage,tidyvnc_rectangle* out) {
    header(options); header(damage); header(out);
    require(!damage->reserved && damage->quality <= TIDYVNC_FILTER_AREA &&
      damage->x <= options->remote_width && damage->width <= options->remote_width-damage->x &&
      damage->y <= options->remote_height && damage->height <= options->remote_height-damage->y);
    const auto transform = desktopTransform(options,canvas);
    const auto rectangle = transform.logicalDamage({int(damage->x),int(damage->y),int(damage->x+damage->width),int(damage->y+damage->height)},
      static_cast<ScalingSettings::Quality>(damage->quality));
    auto value = output<tidyvnc_rectangle>(); value.x = rectangle.tl.x; value.y = rectangle.tl.y;
    value.width = rectangle.width(); value.height = rectangle.height(); *out = value;
}
void desktopGeometry(const tidyvnc_geometry_options* options,const tidyvnc_canvas_viewport* canvas,
                     double px,double py,tidyvnc_geometry* out) {
    header(out); require(std::isfinite(px) && std::isfinite(py));
    const auto transform = desktopTransform(options,canvas);
    const auto point = transform.remotePoint(px,py); auto value = output<tidyvnc_geometry>();
    value.backing_width = transform.backingWidth; value.backing_height = transform.backingHeight;
    value.x = transform.originBX / options->backing_scale; value.y = transform.originBY / options->backing_scale;
    value.width = transform.logicalWidth; value.height = transform.logicalHeight;
    value.remote_x = point.x; value.remote_y = point.y; *out = value;
}
struct WipeInput { tidyvnc_mutable_bytes bytes; ~WipeInput() { wipe(bytes.data,bytes.length); } };
struct Secret { std::string value; ~Secret() { if (!value.empty()) wipe(reinterpret_cast<uint8_t*>(&value[0]),value.size()); } };
}
extern "C" {
tidyvnc_status tidyvnc_session_clipboard_policy(tidyvnc_handle id,uint64_t generation,uint32_t send,uint32_t receive,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { boolean(send); boolean(receive); auto live = session(id);
    require(generation == live->generation(),TIDYVNC_STALE);
    live->setClipboardPolicy({bool(send),bool(receive)}); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_clipboard_offer(tidyvnc_handle id,uint64_t generation,tidyvnc_bytes bytes,tidyvnc_handle origin,uint64_t change,tidyvnc_operation* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); auto live = session(id);
    ClipboardLease source; if (origin) source = get<Clipboard>(origin,Kind::Clipboard)->value;
    require(bytes.length <= 256*1024,TIDYVNC_RESOURCE_LIMIT);
    submitted(live->offerClipboard(generation,text(bytes,256*1024),source,change),out); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_clipboard_clear(tidyvnc_handle id,uint64_t generation,tidyvnc_operation* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); submitted(session(id)->clearClipboard(generation),out); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_take_clipboard(tidyvnc_handle id,tidyvnc_clipboard_update* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); auto live = session(id);
    // Allocate/reserve before consumption, preserving the mailbox on failure.
    Reservation slot(Kind::Clipboard); auto lease = std::make_shared<Clipboard>(); ClipboardUpdate update;
    if (!live->clipboard()->take(update)) return TIDYVNC_NO_CHANGE;
    auto value = output<tidyvnc_clipboard_update>(); value.sequence = update.sequence;
    value.route = clipboardRoute(update.route,id); value.result = clipboardResult(update.result);
    switch (update.kind) {
    case ClipboardUpdateKind::Offered: value.kind = TIDYVNC_CLIPBOARD_OFFERED; break;
    case ClipboardUpdateKind::Text: value.kind = TIDYVNC_CLIPBOARD_TEXT; break;
    case ClipboardUpdateKind::Unavailable: value.kind = TIDYVNC_CLIPBOARD_UNAVAILABLE; break;
    case ClipboardUpdateKind::Invalidated: value.kind = TIDYVNC_CLIPBOARD_INVALIDATED; break;
    case ClipboardUpdateKind::Rejected: value.kind = TIDYVNC_CLIPBOARD_REJECTED; break;
    }
    if (update.text) { lease->value = std::move(update.text); lease->session = id; value.text = slot.commit(lease); }
    *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_clipboard_get(tidyvnc_handle id,tidyvnc_clipboard_info* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); auto lease = get<Clipboard>(id,Kind::Clipboard);
    auto value = output<tidyvnc_clipboard_info>(); value.from_remote = lease->value->fromRemote();
    value.route = clipboardRoute(lease->value->route(),lease->session); const auto& bytes = lease->value->text();
    value.text = {reinterpret_cast<const uint8_t*>(bytes.data()),bytes.size()}; *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_clipboard_check(tidyvnc_handle id,const tidyvnc_clipboard_route* route,uint32_t sending,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(route); boolean(sending); auto live = session(id);
    require(route->session == id && route->generation == live->generation(),TIDYVNC_STALE);
    ClipboardRoute expected; expected.generation = route->generation; expected.focus = route->focus_revision; expected.policy = route->policy_revision;
    const auto result = clipboardResult(live->clipboard()->check(expected,bool(sending)));
    require(result == TIDYVNC_OK,result); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_renderer_create(uint64_t budget,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(out && budget <= 32*1024*1024); Reservation slot(Kind::Renderer);
    auto value = std::make_shared<Renderer>(static_cast<size_t>(budget));
    *out = slot.commit(value); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_renderer_clear(tidyvnc_handle id,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    auto renderer = get<Renderer>(id,Kind::Renderer);
    std::lock_guard<std::mutex> lock(renderer->mutex); renderer->value.clear(); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_renderer_render(tidyvnc_handle id,tidyvnc_handle imageID,const tidyvnc_tile_options* options,
    tidyvnc_mutable_bytes destination,tidyvnc_tile_result* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(options); header(out);
    require(!options->reserved && options->quality <= TIDYVNC_FILTER_AREA &&
      options->width >= 1 && options->width <= 65535 && options->height >= 1 && options->height <= 65535 &&
      options->tile_width >= 1 && options->tile_width <= 256 && options->tile_height >= 1 && options->tile_height <= 256 &&
      options->x <= options->width && options->tile_width <= options->width-options->x &&
      options->y <= options->height && options->tile_height <= options->height-options->y &&
      destination.data && destination.length <= 256*256*4 && destination.length >= uint64_t(options->tile_width)*options->tile_height*4);
    auto renderer = get<Renderer>(id,Kind::Renderer); auto image = get<Image>(imageID,Kind::Image);
    require(bool(image->frame),TIDYVNC_UNSUPPORTED);
    const auto tile = core::Rect(options->x,options->y,options->x+options->tile_width,options->y+options->tile_height);
    const auto damage = Damage(options->damage_x,options->damage_y,options->damage_width,options->damage_height);
    std::lock_guard<std::mutex> lock(renderer->mutex); auto value = output<tidyvnc_tile_result>();
    value.cache_hit = renderer->value.render(image->source,image->frame,options->previous_sequence,damage,
      options->width,options->height,static_cast<ScalingSettings::Quality>(options->quality),tile,
      destination.data,static_cast<size_t>(destination.length));
    value.cache_bytes = renderer->value.bytes(); *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_cursor_renderer_create(tidyvnc_handle imageID,const tidyvnc_cursor_options* options,
    tidyvnc_handle* out,tidyvnc_cursor_geometry* geometry,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(options); header(geometry); require(out && !options->reserved && options->quality <= TIDYVNC_FILTER_AREA);
    require(std::isfinite(options->scale_x) && options->scale_x > 0 && options->scale_x <= 65535 &&
            std::isfinite(options->scale_y) && options->scale_y > 0 && options->scale_y <= 65535);
    const auto image = get<Image>(imageID,Kind::Image); require(bool(image->cursor),TIDYVNC_UNSUPPORTED);
    const auto& pixels = image->cursor->pixels;
    require(pixels.format() == PixelFormat::RGBA8 && pixels.alpha() == AlphaMode::Straight &&
            pixels.stride() == size_t(pixels.width())*4,TIDYVNC_UNSUPPORTED);
    require(pixels.length() <= 4*1024*1024,TIDYVNC_RESOURCE_LIMIT);
    Reservation slot(Kind::CursorSampler);
    auto sampler = std::make_shared<CursorSampler>(*image->cursor,*options);
    auto value = output<tidyvnc_cursor_geometry>(); value.width = sampler->value.width(); value.height = sampler->value.height();
    value.hotspot_x = sampler->value.hotspot().x; value.hotspot_y = sampler->value.hotspot().y;
    value.blank = 1;
    for (size_t i=3;i<pixels.length();i+=4) if (pixels.data()[i]) { value.blank = 0; break; }
    value.source_bytes = pixels.length(); *out = slot.commit(sampler); *geometry = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_cursor_renderer_render(tidyvnc_handle id,const tidyvnc_cursor_tile* tile,
    tidyvnc_mutable_bytes destination,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(tile);
    require(!tile->reserved[0] && !tile->reserved[1] && tile->width >= 1 && tile->width <= 256 &&
      tile->height >= 1 && tile->height <= 256 && destination.data && destination.length <= 256*256*4 &&
      destination.length >= uint64_t(tile->width)*tile->height*4);
    const auto sampler = get<CursorSampler>(id,Kind::CursorSampler);
    require(tile->x <= uint32_t(sampler->value.width()) && tile->width <= uint32_t(sampler->value.width())-tile->x &&
            tile->y <= uint32_t(sampler->value.height()) && tile->height <= uint32_t(sampler->value.height())-tile->y);
    sampler->value.render(destination.data,size_t(tile->width)*4,
      {int(tile->x),int(tile->y),int(tile->x+tile->width),int(tile->y+tile->height)});
    return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_scaling_parse(tidyvnc_bytes input,tidyvnc_scaling* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); const auto settings = ScalingSettings::parse(text(input,64));
    auto value = output<tidyvnc_scaling>(); value.mode = settings.mode;
    value.x = settings.x; value.y = settings.y; value.fits = settings.fits();
    copyText(value.canonical,settings.serialize()); *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_desktop_damage(const tidyvnc_geometry_options* options,const tidyvnc_damage* damage,
    tidyvnc_rectangle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { desktopDamage(options,nullptr,damage,out); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_desktop_geometry(const tidyvnc_geometry_options* options,double px,double py,tidyvnc_geometry* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { desktopGeometry(options,nullptr,px,py,out); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_desktop_canvas_damage(const tidyvnc_geometry_options* options,const tidyvnc_canvas_viewport* canvas,
    const tidyvnc_damage* damage,tidyvnc_rectangle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(canvas); desktopDamage(options,canvas,damage,out); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_desktop_canvas_geometry(const tidyvnc_geometry_options* options,const tidyvnc_canvas_viewport* canvas,
    double px,double py,tidyvnc_geometry* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(canvas); desktopGeometry(options,canvas,px,py,out); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_security_choice_at(uint32_t index,tidyvnc_security_choice* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); const auto& entries = securityChoices(); if (index >= entries.size()) return TIDYVNC_NO_CHANGE;
    const auto& entry = entries[index]; auto value = output<tidyvnc_security_choice>();
    value.type = entry.type; value.available = entry.available;
    value.protection = static_cast<uint32_t>(entry.protection); value.credentials = static_cast<uint32_t>(entry.credentials);
    value.aes_bits = entry.aesBits; copyText(value.name,entry.name); *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_tls_priority_validate(tidyvnc_bytes input,tidyvnc_error* error) {
  return call(error,[&] {
    if (input.length > 4096) throw SecurityOptionError(SecurityOptionProblem::TooLong);
    validateTLSPriority(text(input)); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_security_resolve(tidyvnc_bytes input,uint32_t defaults,tidyvnc_security_selection* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); boolean(defaults); require(!defaults || input.length == 0);
    if (input.length > 1024) throw SecurityOptionError(SecurityOptionProblem::TooLong);
    const auto token = text(input,1024);
    const auto selection = defaults ? SecuritySelection() : SecuritySelection(token);
    auto value = output<tidyvnc_security_selection>();
    for (auto type : selection.types()) {
      require(value.count < 32,TIDYVNC_RESOURCE_LIMIT); value.types[value.count++] = type;
    }
    copyText(value.canonical,selection.text()); *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_get_abi(tidyvnc_abi_info* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); auto value = output<tidyvnc_abi_info>();
    value.features = features; value.handle_capacity = handleLimit; value.runtime_capacity = runtimeLimit;
    for (auto type : rfb::SecurityClient::supportedTypes()) {
      require(value.security_count < 32,TIDYVNC_RESOURCE_LIMIT); value.security_types[value.security_count++] = type;
    }
    *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_retain(uint64_t id,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { registry().retain(id); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_release(uint64_t id,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { registry().release(id); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_runtime_options_init(tidyvnc_runtime_options* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); auto value = output<tidyvnc_runtime_options>(); value.session_capacity = 16; *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_logging_viewport(uint32_t width,uint32_t height,uint32_t backingWidth,uint32_t backingHeight,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    for (auto value : {width,height,backingWidth,backingHeight})
      require(value > 0 && value <= static_cast<uint32_t>(INT32_MAX));
    viewportLog.debug("Viewport logical %dx%d, backing %dx%d",
      static_cast<int>(width),static_cast<int>(height),static_cast<int>(backingWidth),static_cast<int>(backingHeight));
    return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_logging_validate(tidyvnc_bytes policy,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(features & TIDYVNC_FEATURE_PROCESS_LOGGING,TIDYVNC_UNSUPPORTED);
    const auto parsed = loggingPolicy(policy);
    auto& state = processLogging(); std::lock_guard<std::mutex> lock(state.mutex);
    state.get().validate(parsed); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_logging_configure(tidyvnc_bytes policy,tidyvnc_error* error) {
#if defined(__APPLE__) || defined(__linux__)
  const char* path = PrivateFileLogger::defaultPath();
  return tidyvnc_logging_configure_with_file(policy,
    {reinterpret_cast<const uint8_t*>(path),std::strlen(path)},error);
#else
  return call(error,[]() -> uint32_t { throw Fault(TIDYVNC_UNSUPPORTED); });
#endif
}
tidyvnc_status tidyvnc_logging_configure_with_file(tidyvnc_bytes policy,tidyvnc_bytes file_path,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(features & TIDYVNC_FEATURE_PROCESS_LOGGING,TIDYVNC_UNSUPPORTED);
    auto& state = processLogging(); std::lock_guard<std::mutex> lock(state.mutex);
    if (state.closed) throw LoggingFrozen();
    const auto parsed = loggingPolicy(policy);
    const auto path = text(file_path,4096);
#if defined(__APPLE__) || defined(__linux__)
    PrivateFileLogger::validatePath(path);
#endif
    state.get().configure(parsed,[&path](const std::string& name) { return loggingDestination(name,path); });
    state.closed = true;
    return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_options_init(tidyvnc_session_options* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); auto value = output<tidyvnc_session_options>();
    for (auto type : rfb::SecurityClient::supportedTypes()) {
      require(value.security_count < 32,TIDYVNC_RESOURCE_LIMIT); value.security_types[value.security_count++] = type;
    }
    SessionWorkerOptions defaults; value.prompt_timeout_ms = defaults.promptTimeout.count();
    value.event_capacity = defaults.eventCapacity; value.command_capacity = defaults.commandCapacity;
    value.framebuffer_bytes = defaults.buffers.framebufferBytes; value.publication_bytes = defaults.buffers.publicationBytes;
    *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_connect_options_init(tidyvnc_connect_options* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); auto value = output<tidyvnc_connect_options>();
    value.ipv4 = value.ipv6 = 1; value.resolve_timeout_ms = value.connect_timeout_ms = 10000;
    value.address_timeout_ms = 2000; *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_runtime_create(const tidyvnc_runtime_options* options,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(options); require(out != nullptr && !options->reserved);
    require(!(options->required_features & ~features),TIDYVNC_UNSUPPORTED);
    require(options->session_capacity >= 1 && options->session_capacity <= 64);
    Reservation slot(Kind::Runtime); processLogging().freeze();
    auto runtime = service().create(options->session_capacity);
    *out = slot.commit(runtime); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_runtime_shutdown(tidyvnc_handle id,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { get<Runtime>(id,Kind::Runtime)->close(); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_runtime_poll_drained(tidyvnc_handle id,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { return get<Runtime>(id,Kind::Runtime)->done.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready ? TIDYVNC_OK : TIDYVNC_PENDING; });
}
tidyvnc_status tidyvnc_listener_options_init(tidyvnc_listener_options* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); auto value = output<tidyvnc_listener_options>();
    value.port = 5500; value.ipv4 = value.ipv6 = 1; value.backlog = 16;
    value.pending_capacity = 8; value.event_capacity = 32; value.pending_timeout_ms = 30000;
    *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_listener_create(tidyvnc_handle id,const tidyvnc_listener_options* options,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(options); require(out && !options->reserved && options->port <= 65535);
    boolean(options->ipv4); boolean(options->ipv6);
    require(options->pending_capacity >= 1 && options->pending_capacity <= 64 &&
      options->event_capacity >= 4 && options->event_capacity <= 4096 &&
      options->pending_timeout_ms >= 1 && options->pending_timeout_ms <= 60000);
#if defined(__APPLE__) || defined(__linux__)
    SocketListenOptions sockets; sockets.address = text(options->address,255);
    sockets.port = static_cast<uint16_t>(options->port); sockets.ipv4 = options->ipv4; sockets.ipv6 = options->ipv6; sockets.backlog = options->backlog;
    auto source = prepareSocketListener(sockets);
    ListenerOptions settings; settings.pendingCapacity = options->pending_capacity; settings.eventCapacity = options->event_capacity;
    settings.pendingTimeout = std::chrono::milliseconds(options->pending_timeout_ms);
    auto runtime = get<Runtime>(id,Kind::Runtime); Reservation slot(Kind::Listener); auto value = std::make_shared<Listener>();
    value->notifications = callbackService().source(); settings.mailboxWakeup = value->notifications;
    { std::lock_guard<std::mutex> lock(runtime->mutex); require(!runtime->closing && runtime->core,TIDYVNC_CLOSING);
      if (!runtime->listeners) runtime->listeners.reset(new ListenerRuntime(4));
      value->core = runtime->listeners->listen(std::move(source),settings); }
    *out = slot.commit(value); return TIDYVNC_OK;
#else
    (void)id; return TIDYVNC_UNSUPPORTED;
#endif
  });
}
tidyvnc_status tidyvnc_listener_get_snapshot(tidyvnc_handle id,tidyvnc_listener_snapshot* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); const auto value = get<Listener>(id,Kind::Listener);
    *out = listenerSnapshot(value->core->events()->snapshot()); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_listener_take_event(tidyvnc_handle id,tidyvnc_listener_event* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); const auto listener = get<Listener>(id,Kind::Listener); ListenerEvent event;
    if (!listener->core->events()->take(event)) return TIDYVNC_NO_CHANGE;
    auto value = output<tidyvnc_listener_event>(); value.sequence = event.sequence; value.kind = static_cast<uint32_t>(event.kind);
    value.snapshot = listenerSnapshot(event.snapshot);
    if (event.peer) { value.incoming_id = event.peer->id; value.peer = listenerAddress(event.peer->address); }
    *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_listener_reject(tidyvnc_handle id,uint64_t incoming,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { require(incoming != 0);
    return peerStatus(get<Listener>(id,Kind::Listener)->core->reject(incoming)); });
}
tidyvnc_status tidyvnc_listener_accept(tidyvnc_handle id,uint64_t incoming,tidyvnc_handle target,tidyvnc_operation* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); require(incoming != 0);
    auto live = session(target); auto listener = get<Listener>(id,Kind::Listener);
    auto peer = listener->core->takePeer(incoming); const auto status = peerStatus(peer.status);
    if (status != TIDYVNC_OK) return status;
    std::unique_ptr<ConnectionAttempt> connection(new IncomingConnection(std::move(peer)));
    submitted(live->connect(std::move(connection)),out); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_listener_stop(tidyvnc_handle id,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { get<Listener>(id,Kind::Listener)->core->closeAndDrain(); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_listener_poll_drained(tidyvnc_handle id,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { return get<Listener>(id,Kind::Listener)->core->drained().wait_for(std::chrono::milliseconds(0)) == std::future_status::ready ? TIDYVNC_OK : TIDYVNC_PENDING; });
}
tidyvnc_status tidyvnc_session_create(tidyvnc_handle runtimeId,const tidyvnc_session_options* options,tidyvnc_handle* out,tidyvnc_error* error) {
  return tidyvnc_session_create_with_encoding(runtimeId,options,0,out,error);
}
tidyvnc_status tidyvnc_endpoint_validate(tidyvnc_bytes endpoint,uint32_t allowUnixSockets,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    boolean(allowUnixSockets); (void)endpointValue(endpoint,allowUnixSockets != 0); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_endpoint_create(tidyvnc_bytes endpoint,tidyvnc_bytes route,uint32_t allowUnixSockets,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(out != nullptr); boolean(allowUnixSockets);
    if (endpoint.length > 4096 || route.length > 4096) throw EndpointError(EndpointErrorCode::TooLong);
    auto parsed = Endpoint::parse(text(endpoint),allowUnixSockets != 0,text(route));
    Reservation slot(Kind::Endpoint);
    auto value = std::make_shared<EndpointIdentity>(std::move(parsed));
    *out = slot.commit(value); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_endpoint_get(tidyvnc_handle id,tidyvnc_endpoint_info* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); auto owner = get<EndpointIdentity>(id,Kind::Endpoint); const auto& parsed = owner->value;
    auto value = output<tidyvnc_endpoint_info>();
    value.transport = parsed.transport() == EndpointTransport::Tcp ? TIDYVNC_ENDPOINT_TCP : TIDYVNC_ENDPOINT_UNIX;
    value.port = parsed.port(); value.host = bytes(parsed.host()); value.scope = bytes(parsed.scope());
    value.path = bytes(parsed.path()); value.route = bytes(parsed.route()); *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_invocation_parse(const tidyvnc_bytes* args,uint32_t count,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(out != nullptr && (args || !count));
    if (count > InvocationSyntax::maximumArguments) throw InvocationError(InvocationProblem::TooManyArguments,0);
    size_t total = 0;
    // Preflight all lengths before allocation/copy; arithmetic cannot overflow.
    for (uint32_t i = 0; i < count; ++i) {
      if (args[i].length > InvocationSyntax::maximumArgumentBytes || args[i].length > InvocationSyntax::maximumBytes-total)
        throw InvocationError(InvocationProblem::TooLarge,i+1);
      require(args[i].data || !args[i].length); total += static_cast<size_t>(args[i].length);
    }
    std::vector<std::string> input; input.reserve(count);
    for (uint32_t i = 0; i < count; ++i)
      input.push_back(args[i].length ? std::string(reinterpret_cast<const char*>(args[i].data),static_cast<size_t>(args[i].length)) : std::string());
    auto parsed = InvocationSyntax::parse(input);
    Reservation slot(Kind::Invocation);
    auto owner = std::make_shared<Invocation>(std::move(parsed));
    *out = slot.commit(owner); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_invocation_validate(tidyvnc_handle id,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(out != nullptr); auto input = get<Invocation>(id,Kind::Invocation);
    auto canonical = input->value.validatingValues();
    Reservation slot(Kind::Invocation);
    auto owner = std::make_shared<Invocation>(std::move(canonical));
    *out = slot.commit(owner); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_invocation_get(tidyvnc_handle id,tidyvnc_invocation_info* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); auto owner = get<Invocation>(id,Kind::Invocation);
    auto value = output<tidyvnc_invocation_info>();
    value.action = static_cast<uint32_t>(owner->value.action());
    value.count = static_cast<uint32_t>(owner->value.assignments().size());
    value.operand_argument = static_cast<uint32_t>(owner->value.operandArgument());
    const auto& operand = owner->value.operand();
    value.operand = {reinterpret_cast<const uint8_t*>(operand.data()),operand.size()};
    *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_invocation_assignment_at(tidyvnc_handle id,uint32_t index,tidyvnc_invocation_assignment* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); auto owner = get<Invocation>(id,Kind::Invocation);
    if (index >= owner->value.assignments().size()) return TIDYVNC_NO_CHANGE;
    const auto& entry = owner->value.assignments()[index];
    auto value = output<tidyvnc_invocation_assignment>();
    value.category = static_cast<uint32_t>(entry.category); value.argument = static_cast<uint32_t>(entry.argument);
    value.value_argument = static_cast<uint32_t>(entry.valueArgument); copyText(value.name,entry.name);
    value.value = {reinterpret_cast<const uint8_t*>(entry.value.data()),entry.value.size()};
    *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_invocation_option_at(uint32_t index,tidyvnc_invocation_option* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); const auto schema = invocationOptions(InvocationCapabilities::compiled());
    if (index >= schema.size()) return TIDYVNC_NO_CHANGE;
    const auto& entry = schema[index]; auto value = output<tidyvnc_invocation_option>();
    value.category = static_cast<uint32_t>(entry.category); value.boolean = entry.boolean; value.available = entry.available;
    copyText(value.name,entry.name); copyText(value.alias,entry.alias);
    *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_document_parse(tidyvnc_bytes input,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(out != nullptr);
    auto parsed = ConnectionDocument::parse(documentBytes(input,ConnectionDocument::maximumBytes,DocumentErrorCode::TooLarge));
    Reservation slot(Kind::Document);
    auto owner = std::make_shared<Document>(std::move(parsed));
    *out = slot.commit(owner); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_document_get(tidyvnc_handle id,tidyvnc_document_info* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); auto owner = get<Document>(id,Kind::Document);
    auto value = output<tidyvnc_document_info>();
    value.count = static_cast<uint32_t>(owner->value.entries().size());
    value.legacy_header = owner->value.isLegacy(); *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_document_entry_at(tidyvnc_handle id,uint32_t index,uint32_t decodeValue,tidyvnc_document_entry* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); boolean(decodeValue); auto owner = get<Document>(id,Kind::Document);
    if (index >= owner->value.entries().size()) return TIDYVNC_NO_CHANGE;
    const auto& entry = owner->value.entries()[index];
    auto value = output<tidyvnc_document_entry>(); value.line = static_cast<uint32_t>(entry.line);
    copyText(value.name,entry.name); copyText(value.value,decodeValue ? entry.value() : entry.encodedValue);
    *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_document_serialize(const tidyvnc_document_assignment* input,uint32_t count,tidyvnc_mutable_bytes buffer,uint64_t* size,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(size != nullptr && (input || !count) && (buffer.data || !buffer.length));
    if (count > ConnectionDocument::maximumEntries) throw DocumentError(DocumentErrorCode::TooManyEntries);
    std::vector<DocumentAssignment> values; values.reserve(count);
    for (uint32_t i = 0; i < count; ++i)
      values.push_back({documentBytes(input[i].name,255,DocumentErrorCode::LineTooLong),
                        documentBytes(input[i].value,255,DocumentErrorCode::LineTooLong)});
    const auto serialized = ConnectionDocument::serialize(values);
    if (buffer.data) {
      require(buffer.length >= serialized.size(),TIDYVNC_RESOURCE_LIMIT);
      std::memcpy(buffer.data,serialized.data(),serialized.size());
    }
    *size = serialized.size(); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_document_option_at(tidyvnc_handle id,uint32_t index,tidyvnc_document_entry* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); auto owner = get<Document>(id,Kind::Document);
    if (index >= owner->value.entries().size()) return TIDYVNC_NO_CHANGE;
    const auto& entry = owner->value.entries()[index]; DocumentAssignment canonical;
    if (!documentOption(entry,canonical)) return TIDYVNC_NO_CHANGE;
    auto value = output<tidyvnc_document_entry>(); value.line = static_cast<uint32_t>(entry.line);
    copyText(value.name,canonical.name); copyText(value.value,canonical.value);
    *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_encoding_schema_at(uint32_t index,tidyvnc_encoding_schema* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); const auto& entries = encodingSchema(); if (index >= entries.size()) return TIDYVNC_NO_CHANGE;
    const auto& entry = entries[index]; auto value = output<tidyvnc_encoding_schema>();
    value.id = static_cast<uint32_t>(entry.id);
    value.type = entry.type == OptionType::Boolean ? TIDYVNC_OPTION_BOOLEAN : entry.type == OptionType::Integer ? TIDYVNC_OPTION_INTEGER : TIDYVNC_OPTION_ENUMERATION;
    value.minimum = entry.minimum; value.maximum = entry.maximum; value.persistent = entry.persistent; value.live = entry.live;
    copyText(value.name,entry.name); copyText(value.alias,entry.alias ? entry.alias : ""); copyText(value.default_value,entry.defaultValue);
    *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_encoding_choice_at(uint32_t index,tidyvnc_encoding_choice* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); const auto& entries = encodingChoices(); if (index >= entries.size()) return TIDYVNC_NO_CHANGE;
    const auto& entry = entries[index]; auto value = output<tidyvnc_encoding_choice>();
    value.available = entry.available; value.wire_encoding = entry.wireEncoding; copyText(value.name,entry.name);
    *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_encoding_create(tidyvnc_handle base,const tidyvnc_encoding_assignment* assignments,uint32_t count,uint32_t source,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(out != nullptr && (assignments || !count) && source <= TIDYVNC_SOURCE_DOCUMENT);
    if (count > 256) throw OptionError(OptionErrorCode::TooLong,EncodingOption::Count);
    auto options = base ? get<Encoding>(base,Kind::Encoding)->value : EncodingOptions();
    OptionPatch patch; patch.reserve(count);
    for (uint32_t i = 0; i < count; ++i) {
      if (assignments[i].name.length > 128 || assignments[i].value.length > 128) throw OptionError(OptionErrorCode::TooLong,EncodingOption::Count);
      patch.push_back({text(assignments[i].name,128),text(assignments[i].value,128)});
    }
    options = options.withPatch(patch,static_cast<OptionSource>(source));
    Reservation slot(Kind::Encoding); auto value = std::make_shared<Encoding>(options);
    *out = slot.commit(value); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_encoding_get(tidyvnc_handle id,uint32_t option,tidyvnc_encoding_value* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); auto owner = get<Encoding>(id,Kind::Encoding);
    if (option >= static_cast<uint32_t>(EncodingOption::Count)) throw OptionError(OptionErrorCode::UnknownOption,EncodingOption::Count);
    const auto key = static_cast<EncodingOption>(option); auto value = output<tidyvnc_encoding_value>();
    value.id = option; value.source = static_cast<uint32_t>(owner->value.source(key)); copyText(value.value,owner->value.value(key));
    *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_sharing(tidyvnc_handle id,tidyvnc_sharing* out,tidyvnc_error* error) {
  return call(error,[&] {
    header(out); const auto snapshot = session(id)->sharing(); auto value = output<tidyvnc_sharing>();
    value.shared = snapshot.shared; value.editable = snapshot.editable; value.revision = snapshot.revision; value.generation = snapshot.generation;
    *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_set_shared(tidyvnc_handle id,uint64_t generation,uint64_t revision,uint32_t shared,uint64_t* out,tidyvnc_error* error) {
  return call(error,[&] {
    require(out != nullptr); boolean(shared);
    const auto status = session(id)->setShared(generation,revision,shared != 0);
    tidyvnc_operation unused; submitted({status},&unused);
    *out = revision + 1; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_security(tidyvnc_handle id,tidyvnc_security_configuration* out,tidyvnc_error* error) {
  return call(error,[&] {
    header(out); const auto snapshot = session(id)->securityOptions();
    const auto& tls = snapshot.options->clientTLSOptions(); auto value = output<tidyvnc_security_configuration>();
    value.generation = snapshot.generation; value.revision = snapshot.revision; value.editable = snapshot.editable;
    copyText(value.types,snapshot.options->ToString());
    require(tls.priority.size() <= 4096 && tls.caFile.size() <= 4096 && tls.crlFile.size() <= 4096,TIDYVNC_RESOURCE_LIMIT);
    value.tls_priority_length = tls.priority.size(); value.ca_file_length = tls.caFile.size(); value.crl_file_length = tls.crlFile.size();
    std::memcpy(value.tls_priority,tls.priority.data(),tls.priority.size());
    std::memcpy(value.ca_file,tls.caFile.data(),tls.caFile.size()); std::memcpy(value.crl_file,tls.crlFile.data(),tls.crlFile.size());
    *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_set_security(tidyvnc_handle id,uint64_t generation,uint64_t revision,
  const tidyvnc_security_update* input,uint64_t* out,tidyvnc_error* error) {
  return call(error,[&] {
    header(input); require(out != nullptr);
    const SecuritySelection selection(text(input->types,1024));
    rfb::ClientTLSOptions tls; tls.priority = text(input->tls_priority);
    tls.caFile = text(input->ca_file); tls.crlFile = text(input->crl_file); tls.requireConfiguredFiles = true;
#ifndef HAVE_GNUTLS
    require(tls.priority.empty() && tls.caFile.empty() && tls.crlFile.empty(),TIDYVNC_UNSUPPORTED);
#endif
    const rfb::SecurityClient policy(selection.types(),tls);
    const auto status = session(id)->setSecurity(generation,revision,policy);
    tidyvnc_operation unused; submitted({status},&unused); // Shared admission-to-status mapping; no async operation.
    *out = revision + 1; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_encoding(tidyvnc_handle id,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(out != nullptr); auto options = session(id)->encodingOptions(); Reservation slot(Kind::Encoding);
    auto value = std::make_shared<Encoding>(options); *out = slot.commit(value); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_apply_encoding(tidyvnc_handle id,uint64_t generation,tidyvnc_handle encoding,tidyvnc_operation* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); auto value = get<Encoding>(encoding,Kind::Encoding);
    submitted(session(id)->applyEncodingOptions(generation,value->value),out); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_create_with_encoding(tidyvnc_handle runtimeId,const tidyvnc_session_options* options,tidyvnc_handle encoding,tidyvnc_handle* out,tidyvnc_error* error) {
  auto timing = output<tidyvnc_input_timing>(); // Preserve the original zero-delay API.
  return tidyvnc_session_create_with_input_timing(runtimeId,options,encoding,&timing,out,error);
}
tidyvnc_status tidyvnc_input_timing_init(tidyvnc_input_timing* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); auto value = output<tidyvnc_input_timing>();
    value.pointer_interval_ms = defaultPointerEventInterval; *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_create_with_input_timing(tidyvnc_handle runtimeId,const tidyvnc_session_options* options,
  tidyvnc_handle encoding,const tidyvnc_input_timing* timing,tidyvnc_handle* out,tidyvnc_error* error) {
  auto limits = output<tidyvnc_message_limits>(); limits.max_cut_text = rfb::defaultMaxCutText;
  return tidyvnc_session_create_with_message_limits(runtimeId,options,encoding,timing,&limits,out,error);
}
tidyvnc_status tidyvnc_window_geometry_parse(tidyvnc_bytes input,tidyvnc_window_geometry* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); const auto parsed = WindowGeometry::parse(text(input,65536));
    auto value = output<tidyvnc_window_geometry>();
    value.flags = (parsed.hasSize ? TIDYVNC_WINDOW_GEOMETRY_SIZE : 0) |
                  (parsed.hasPosition ? TIDYVNC_WINDOW_GEOMETRY_POSITION : 0);
    value.width = parsed.width; value.height = parsed.height; value.x = parsed.x; value.y = parsed.y;
    *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_message_limits_init(tidyvnc_message_limits* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); auto value = output<tidyvnc_message_limits>();
    value.max_cut_text = rfb::defaultMaxCutText; *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_create_with_message_limits(tidyvnc_handle runtimeId,const tidyvnc_session_options* options,
  tidyvnc_handle encoding,const tidyvnc_input_timing* timing,const tidyvnc_message_limits* limits,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(options); require(out != nullptr && !options->reserved && options->security_count <= 32);
    require(options->framebuffer_bytes && options->framebuffer_bytes <= 1024ULL*1024*1024 &&
            options->publication_bytes && options->publication_bytes <= 1024ULL*1024*1024);
    header(timing); require(!timing->reserved && timing->pointer_interval_ms <= INT_MAX);
    header(limits); require(!limits->reserved && limits->max_cut_text <= INT_MAX);
    std::list<uint32_t> types;
    const auto& supported = rfb::SecurityClient::supportedTypes();
    for (uint32_t i = 0; i < options->security_count; ++i) {
      require(std::find(supported.begin(),supported.end(),options->security_types[i]) != supported.end(),TIDYVNC_UNSUPPORTED);
      types.push_back(options->security_types[i]);
    }
    rfb::ClientTLSOptions tls; tls.priority = text(options->tls_priority); tls.caFile = text(options->ca_file); tls.crlFile = text(options->crl_file);
    tls.requireConfiguredFiles = true; tls.validate();
#ifndef HAVE_GNUTLS
    require(tls.priority.empty() && tls.caFile.empty() && tls.crlFile.empty(),TIDYVNC_UNSUPPORTED);
#endif
    rfb::SecurityClient security(types,tls); SessionWorkerOptions settings;
    settings.messages.maxCutText = limits->max_cut_text;
    settings.pointerEventInterval = std::chrono::milliseconds(timing->pointer_interval_ms);
    if (encoding) settings.encoding = get<Encoding>(encoding,Kind::Encoding)->value;
    settings.promptTimeout = std::chrono::milliseconds(options->prompt_timeout_ms);
    settings.eventCapacity = options->event_capacity; settings.commandCapacity = options->command_capacity;
    settings.buffers.framebufferBytes = static_cast<size_t>(options->framebuffer_bytes);
    settings.buffers.publicationBytes = static_cast<size_t>(options->publication_bytes);
    auto runtime = get<Runtime>(runtimeId,Kind::Runtime); Reservation slot(Kind::Session); auto value = std::make_shared<Session>();
    value->notifications = callbackService().source(); settings.mailboxWakeup = value->notifications;
    { std::lock_guard<std::mutex> lock(runtime->mutex); require(!runtime->closing && runtime->core,TIDYVNC_CLOSING);
      value->core = runtime->core->createSession(security,settings); }
    *out = slot.commit(value); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_connect(tidyvnc_handle id,const tidyvnc_connect_options* options,tidyvnc_operation* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(options); header(out); require(!options->reserved); boolean(options->ipv4); boolean(options->ipv6);
    auto live = session(id); auto address = endpointValue(options->endpoint);
#if defined(__APPLE__) || defined(__linux__)
    SocketConnectOptions settings; settings.ipv4 = options->ipv4; settings.ipv6 = options->ipv6;
    settings.resolveTimeout = std::chrono::milliseconds(options->resolve_timeout_ms);
    settings.connectTimeout = std::chrono::milliseconds(options->connect_timeout_ms);
    settings.addressTimeout = std::chrono::milliseconds(options->address_timeout_ms);
    submitted(live->connect(prepareSocketConnection(address,settings)),out); return TIDYVNC_OK;
#else
    return TIDYVNC_UNSUPPORTED;
#endif
  });
}
tidyvnc_status tidyvnc_session_connect_routed(tidyvnc_handle id,tidyvnc_handle target,
  const tidyvnc_connect_options* options,tidyvnc_operation* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(options); header(out); require(!options->reserved); boolean(options->ipv4); boolean(options->ipv6);
    auto live = session(id); auto identity = get<EndpointIdentity>(target,Kind::Endpoint);
    auto local = endpointValue(options->endpoint);
#if defined(__APPLE__) || defined(__linux__)
    SocketConnectOptions settings; settings.ipv4 = options->ipv4; settings.ipv6 = options->ipv6;
    settings.resolveTimeout = std::chrono::milliseconds(options->resolve_timeout_ms);
    settings.connectTimeout = std::chrono::milliseconds(options->connect_timeout_ms);
    settings.addressTimeout = std::chrono::milliseconds(options->address_timeout_ms);
    submitted(live->connect(prepareRoutedSocketConnection(identity->value,local,settings)),out); return TIDYVNC_OK;
#else
    return TIDYVNC_UNSUPPORTED;
#endif
  });
}
tidyvnc_status tidyvnc_session_disconnect(tidyvnc_handle id,uint64_t generation,tidyvnc_operation* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); submitted(session(id)->disconnect(generation),out); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_refresh(tidyvnc_handle id,uint64_t generation,tidyvnc_operation* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); submitted(session(id)->requestRefresh(generation),out); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_display_layout_compute(const tidyvnc_display_layout_request* input,tidyvnc_display_layout* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(input); header(out); boolean(input->device_pixels);
    require(input->monitor_count > 0 && input->monitor_count <= 64 && input->monitors);
    std::vector<DesktopMonitor> monitors; monitors.reserve(input->monitor_count);
    for (size_t i = 0; i < input->monitor_count; ++i) {
      const auto& m = input->monitors[i];
      require(m.x >= -1000000 && m.x <= 1000000 && m.y >= -1000000 && m.y <= 1000000 &&
        m.width > 0 && m.width <= 65535 && m.height > 0 && m.height <= 65535 &&
        m.backing_width > 0 && m.backing_width <= 65535 && m.backing_height > 0 && m.backing_height <= 65535);
      monitors.push_back({m.id,int(i),{m.x,m.y,m.x+int(m.width),m.y+int(m.height)},int(m.backing_width),int(m.backing_height)});
    }
    const DesktopLayout layout(monitors,input->device_pixels ? ScalingSettings::Device : ScalingSettings::Logical);
    auto value = output<tidyvnc_display_layout>();
    value.width = layout.width; value.height = layout.height;
    value.screen_count = layout.regions.size(); value.normalized = layout.normalized;
    for (size_t i = 0; i < layout.regions.size(); ++i) {
      const auto& r = layout.regions[i];
      value.screens[i] = {r.monitor.id,uint32_t(r.canvas.tl.x),uint32_t(r.canvas.tl.y),
        uint32_t(r.canvas.width()),uint32_t(r.canvas.height()),0};
    }
    *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_desktop_layout_validate(const tidyvnc_desktop_layout_request* input,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { (void)desktopLayout(input); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_desktop_layout(tidyvnc_handle id,uint64_t generation,tidyvnc_desktop_layout* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); const auto current = session(id)->events()->snapshot();
    if (current.generation != generation) return TIDYVNC_STALE;
    if (current.state != SessionState::Connected || !current.layout) return TIDYVNC_NOT_CONNECTED;
    auto value = output<tidyvnc_desktop_layout>(); value.snapshot = snapshot(current);
    value.screen_count = current.layout->screens().size();
    for (size_t i = 0; i < value.screen_count; ++i) {
      const auto& screen = current.layout->screens()[i];
      value.screens[i] = {screen.id,screen.x,screen.y,screen.width,screen.height,screen.flags};
    }
    *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_request_desktop_layout(tidyvnc_handle id,uint64_t generation,const tidyvnc_desktop_layout_request* input,tidyvnc_operation* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); const auto layout = desktopLayout(input);
    submitted(session(id)->requestDesktopLayout(generation,layout),out); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_cancel_operation(tidyvnc_handle id,uint64_t generation,uint64_t operation,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { require(operation != 0); const auto result = session(id)->cancelOperation(generation,operation);
    return result == CommandCancellation::Cancelled ? TIDYVNC_OK : result == CommandCancellation::StaleGeneration ? TIDYVNC_STALE : TIDYVNC_NOT_PENDING; });
}
tidyvnc_status tidyvnc_session_close(tidyvnc_handle id,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { session(id)->closeAndDrain(); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_poll_drained(tidyvnc_handle id,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { return session(id)->drained().wait_for(std::chrono::milliseconds(0)) == std::future_status::ready ? TIDYVNC_OK : TIDYVNC_PENDING; });
}
tidyvnc_status tidyvnc_session_snapshot(tidyvnc_handle id,tidyvnc_snapshot* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); *out = snapshot(session(id)->events()->snapshot()); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_information(tidyvnc_handle id,uint64_t generation,tidyvnc_connection_info* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(out); const auto current = session(id)->events()->snapshot();
    if (current.generation != generation) return TIDYVNC_STALE;
    if (current.state != SessionState::Connected || !current.information) return TIDYVNC_NOT_CONNECTED;
    const auto& info = *current.information; auto value = output<tidyvnc_connection_info>();
    value.snapshot = snapshot(current); value.bits_per_second = info.bitsPerSecond;
    value.protocol_major = info.protocolMajor; value.protocol_minor = info.protocolMinor;
    value.security_type = info.securityType; value.credentials_secure = info.secure; value.name_truncated = info.nameTruncated;
    value.requested_encoding = info.requestedEncoding; value.last_encoding = info.lastEncoding;
    std::memcpy(value.desktop_name,info.desktopName.data(),sizeof(value.desktop_name));
    info.pixelFormat.print(value.pixel_format,sizeof(value.pixel_format));
    std::strncpy(value.security_name,rfb::secTypeName(info.securityType),sizeof(value.security_name)-1);
    std::strncpy(value.requested_encoding_name,rfb::encodingName(info.requestedEncoding),sizeof(value.requested_encoding_name)-1);
    std::strncpy(value.last_encoding_name,info.lastEncoding < 0 ? "" : rfb::encodingName(info.lastEncoding),sizeof(value.last_encoding_name)-1);
    *out = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_subscribe(tidyvnc_handle id,const tidyvnc_callbacks* callbacks,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(callbacks); require(out && !callbacks->reserved && callbacks->ready && callbacks->retain_context && callbacks->release_context);
    auto owner = get<Session>(id,Kind::Session); Reservation slot(Kind::Subscription);
    auto value = std::make_shared<Subscription>(); value->source = owner->notifications;
    value->core = owner->core; value->callbacks = *callbacks;
    value->callbacks.retain_context(value->callbacks.context); value->retained = true;
    CallbackService::install(value);
    value->id = slot.commit(value); *out = value->id;
    CallbackService::arm(value); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_listener_subscribe(tidyvnc_handle id,const tidyvnc_callbacks* callbacks,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    header(callbacks); require(out && !callbacks->reserved && callbacks->ready && callbacks->retain_context && callbacks->release_context);
    auto owner = get<Listener>(id,Kind::Listener); Reservation slot(Kind::Subscription);
    auto value = std::make_shared<Subscription>(); value->source = owner->notifications;
    value->listener = owner->core; value->callbacks = *callbacks;
    value->callbacks.retain_context(value->callbacks.context); value->retained = true;
    CallbackService::install(value);
    value->id = slot.commit(value); *out = value->id;
    CallbackService::arm(value); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_subscription_unsubscribe(tidyvnc_handle id,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { get<Subscription>(id,Kind::Subscription)->released(); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_subscription_poll_drained(tidyvnc_handle id,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { return get<Subscription>(id,Kind::Subscription)->drained.load() ? TIDYVNC_OK : TIDYVNC_PENDING; });
}
tidyvnc_status tidyvnc_subscription_validate(tidyvnc_handle id,uint64_t generation,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    auto value = get<Subscription>(id,Kind::Subscription);
    { std::lock_guard<std::mutex> lock(value->source->state->mutex); if (!value->active) return TIDYVNC_CANCELLED; }
    if (value->listener.lock()) return generation == 1 ? TIDYVNC_OK : TIDYVNC_STALE;
    auto core = value->core.lock();
    if (!core) return TIDYVNC_CANCELLED;
    return core->generation() == generation ? TIDYVNC_OK : TIDYVNC_STALE;
  });
}
tidyvnc_status tidyvnc_session_take_event(tidyvnc_handle id,tidyvnc_event* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); SessionEvent event;
    if (!session(id)->events()->take(event)) return TIDYVNC_NO_CHANGE;
    auto value = output<tidyvnc_event>(); value.snapshot = snapshot(event.snapshot);
    switch (event.kind) {
    case SessionEventKind::Snapshot: value.kind = TIDYVNC_EVENT_SNAPSHOT; break;
    case SessionEventKind::State: value.kind = TIDYVNC_EVENT_STATE; break;
    case SessionEventKind::Desktop: value.kind = TIDYVNC_EVENT_DESKTOP; break;
    case SessionEventKind::Bell: value.kind = TIDYVNC_EVENT_BELL; break;
    case SessionEventKind::Statistics: value.kind = TIDYVNC_EVENT_STATISTICS; break;
    case SessionEventKind::Completion: value.kind = TIDYVNC_EVENT_COMPLETION; break;
    case SessionEventKind::Overflow: value.kind = TIDYVNC_EVENT_OVERFLOW; break;
    }
    value.result = event.result == OperationResult::Succeeded ? TIDYVNC_OPERATION_SUCCEEDED : event.result == OperationResult::Cancelled ? TIDYVNC_OPERATION_CANCELLED : TIDYVNC_OPERATION_FAILED;
    value.failure = event.failure == OperationFailure::None ? TIDYVNC_OPERATION_FAILURE_NONE : event.failure == OperationFailure::TimedOut ? TIDYVNC_OPERATION_TIMED_OUT : TIDYVNC_OPERATION_SERVER_REJECTED;
    value.native_result = event.nativeResult; value.sequence = event.sequence; value.operation = event.operation; value.origin = event.origin;
    *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_take_view(tidyvnc_handle id,tidyvnc_view_update* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); auto live = session(id);
    // Reserve handles/metadata before consuming an update, so OOM cannot lose it.
    Reservation frameSlot(Kind::Image), cursorSlot(Kind::Image);
    auto frame = std::make_shared<Image>(), cursor = std::make_shared<Image>(); ViewUpdate update;
    if (!live->view()->take(update)) return TIDYVNC_NO_CHANGE;
    auto value = output<tidyvnc_view_update>(); value.generation = update.generation;
    value.frame_changed = update.frameChanged; value.cursor_changed = update.cursorChanged;
    value.damage_x = update.damage.x; value.damage_y = update.damage.y;
    value.damage_width = update.damage.width; value.damage_height = update.damage.height;
    if (update.frame) { frame->source = id; frame->frame = std::move(update.frame); value.frame = frameSlot.commit(frame); }
    if (update.cursor) { cursor->cursor = std::move(update.cursor); value.cursor = cursorSlot.commit(cursor); }
    *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_image_get(tidyvnc_handle id,tidyvnc_image_info* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); auto image = get<Image>(id,Kind::Image); auto value = output<tidyvnc_image_info>();
    const auto& pixels = image->frame ? image->frame->pixels : image->cursor->pixels;
    value.width = pixels.width(); value.height = pixels.height(); value.stride = pixels.stride();
    value.format = pixels.format() == PixelFormat::BGRA8 ? TIDYVNC_PIXEL_BGRA8 : TIDYVNC_PIXEL_RGBA8;
    value.alpha = pixels.alpha() == AlphaMode::Opaque ? TIDYVNC_ALPHA_OPAQUE : pixels.alpha() == AlphaMode::Straight ? TIDYVNC_ALPHA_STRAIGHT : TIDYVNC_ALPHA_PREMULTIPLIED;
    value.origin = TIDYVNC_ORIGIN_TOP_LEFT; value.pixels = {pixels.data(),pixels.length()};
    if (image->frame) { value.generation = image->frame->generation; value.size_generation = image->frame->sizeGeneration; value.sequence = image->frame->sequence; }
    else { value.generation = image->cursor->generation; value.sequence = image->cursor->sequence;
      value.hotspot_x = image->cursor->hotspotX; value.hotspot_y = image->cursor->hotspotY; }
    *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_key(tidyvnc_handle id,uint64_t generation,uint32_t key,uint32_t symbol,uint32_t code,uint32_t down,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { boolean(down); auto live = session(id);
    auto result = live->input()->key(generation,key,symbol,code,down); live->wake(); inputResult(result); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_pointer(tidyvnc_handle id,uint64_t generation,int32_t x,int32_t y,uint32_t buttons,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { require(buttons <= UINT16_MAX); auto live = session(id);
    auto result = live->input()->pointer(generation,x,y,static_cast<uint16_t>(buttons)); live->wake(); inputResult(result); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_focus(tidyvnc_handle id,uint64_t generation,uint32_t focused,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { boolean(focused); auto live = session(id);
    auto result = live->input()->setFocused(generation,focused); live->wake(); inputResult(result); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_shortcut_create(uint32_t modifiers,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(out && !(modifiers & ~15u)); Reservation slot(Kind::Shortcut);
    auto shortcut = std::make_shared<Shortcut>(); shortcut->value.setModifiers(modifiers);
    *out = slot.commit(shortcut); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_shortcut_modifiers(tidyvnc_handle id,uint32_t modifiers,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(!(modifiers & ~15u)); auto shortcut = get<Shortcut>(id,Kind::Shortcut);
    std::lock_guard<std::mutex> lock(shortcut->mutex); shortcut->value.setModifiers(modifiers); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_shortcut_key(tidyvnc_handle id,int32_t physical,uint32_t symbol,uint32_t down,uint32_t* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(out); boolean(down); auto shortcut = get<Shortcut>(id,Kind::Shortcut);
    std::lock_guard<std::mutex> lock(shortcut->mutex);
    const auto action = down ? shortcut->value.handleKeyPress(physical,symbol) : shortcut->value.handleKeyRelease(physical);
    *out = static_cast<uint32_t>(action); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_shortcut_reset(tidyvnc_handle id,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    auto shortcut = get<Shortcut>(id,Kind::Shortcut); std::lock_guard<std::mutex> lock(shortcut->mutex);
    shortcut->value.reset(); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_input_policy(tidyvnc_handle id,uint32_t viewOnly,uint32_t emulateMiddle,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { boolean(viewOnly); boolean(emulateMiddle);
    auto live = session(id); live->input()->setPolicy(viewOnly,emulateMiddle); live->wake(); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_release_input(tidyvnc_handle id,uint64_t generation,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { auto live = session(id);
    auto result = live->input()->releaseAll(generation); live->wake(); inputResult(result); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_view_only(tidyvnc_handle id,uint32_t enabled,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { boolean(enabled); auto live = session(id); live->input()->setViewOnly(enabled); live->wake(); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_take_prompt(tidyvnc_handle id,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { require(out != nullptr); auto live = session(id);
    Reservation slot(Kind::Prompt); auto value = std::make_shared<Prompt>();
    if (!live->authentication()->takeRequest(value->value)) return TIDYVNC_NO_CHANGE;
    *out = slot.commit(value); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_prompt_get(tidyvnc_handle id,tidyvnc_prompt_info* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); auto owned = get<Prompt>(id,Kind::Prompt); const auto& prompt = owned->value;
    auto value = output<tidyvnc_prompt_info>();
    value.kind = prompt.kind == PromptKind::Credentials ? TIDYVNC_PROMPT_CREDENTIALS : prompt.kind == PromptKind::Certificate ? TIDYVNC_PROMPT_CERTIFICATE : TIDYVNC_PROMPT_HOST_KEY;
    value.id = prompt.id; value.generation = prompt.generation; value.secure = prompt.secure;
    value.username_required = prompt.usernameRequired; value.certificate_status = prompt.certificateStatus;
    value.server_name = bytes(prompt.serverName); value.fingerprint = bytes(prompt.fingerprint);
    value.identity = {prompt.identity.data(),prompt.identity.size()}; *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_host_key_validate(tidyvnc_bytes key,uint32_t* bits,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(bits && key.data && key.length <= rfb::rsaAESMaximumEncoding);
    uint32_t value = 0;
    require(rfb::validRSAKeyEncoding(key.data,static_cast<size_t>(key.length),&value));
    *bits = value; return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_certificate_key_create(tidyvnc_bytes input,tidyvnc_handle* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t {
    require(out && input.data && input.length && input.length <= 65536);
    require(viewer::CertificateKey::supported(),TIDYVNC_UNSUPPORTED);
    Reservation slot(Kind::CertificateKey);
    auto value = std::make_shared<CertificateKeyIdentity>(input);
    *out = slot.commit(value); return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_certificate_key_get(tidyvnc_handle id,tidyvnc_certificate_key_info* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); const auto owner = get<CertificateKeyIdentity>(id,Kind::CertificateKey);
    const auto& key = owner->key.bytes(); auto value = output<tidyvnc_certificate_key_info>();
    value.spki = {key.data(),key.size()}; *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_certificate_key_digest(tidyvnc_handle id,uint32_t algorithm,tidyvnc_key_digest* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out); const auto owner = get<CertificateKeyIdentity>(id,Kind::CertificateKey);
    const auto digest = owner->key.digest(algorithm); auto value = output<tidyvnc_key_digest>();
    require(digest.size() <= sizeof(value.bytes)); value.length = static_cast<uint32_t>(digest.size());
    std::copy(digest.begin(),digest.end(),value.bytes); *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_certificate_policy_get(uint32_t status,tidyvnc_certificate_policy* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { header(out);
    const auto policy = viewer::certificatePolicy(status);
    auto value = output<tidyvnc_certificate_policy>();
    value.reasons = policy.reasons; value.fatal_status = policy.fatalStatus; value.may_override = policy.mayOverride;
    *out = value; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_prompt_security_type(tidyvnc_handle id,uint32_t* out,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { require(out != nullptr);
    const auto owned = get<Prompt>(id,Kind::Prompt); *out = owned->value.securityType; return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_reply_credentials(tidyvnc_handle id,uint64_t request,uint64_t generation,
  tidyvnc_mutable_bytes username,tidyvnc_mutable_bytes password,tidyvnc_error* error) {
  WipeInput wipeUser{username}, wipePassword{password};
  return call(error,[&]() -> uint32_t { Secret user, secret;
    user.value = text({username.data,username.length}); secret.value = text({password.data,password.length});
    promptResult(session(id)->authentication()->replyCredentials(request,generation,user.value,secret.value)); return TIDYVNC_OK; });
}
tidyvnc_status tidyvnc_session_reply_credential_bytes(tidyvnc_handle id,uint64_t request,uint64_t generation,
  tidyvnc_mutable_bytes username,tidyvnc_mutable_bytes password,tidyvnc_error* error) {
  WipeInput wipeUser{username}, wipePassword{password};
  return call(error,[&]() -> uint32_t {
    const auto copy = [](tidyvnc_mutable_bytes input,Secret& output) {
      require(input.length <= 4096 && (input.data || !input.length));
      if (input.length) {
        require(std::memchr(input.data,0,static_cast<size_t>(input.length)) == nullptr);
        output.value.assign(reinterpret_cast<const char*>(input.data),static_cast<size_t>(input.length));
      }
    };
    Secret user, secret; copy(username,user); copy(password,secret);
    promptResult(session(id)->authentication()->replyCredentials(request,generation,user.value,secret.value));
    return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_reply_password_file(tidyvnc_handle id,uint64_t request,uint64_t generation,
  tidyvnc_mutable_bytes obfuscated,tidyvnc_error* error) {
  WipeInput wipeObfuscated{obfuscated};
  return call(error,[&]() -> uint32_t {
    require(obfuscated.data && obfuscated.length == 8);
    std::array<uint8_t,8> decoded{}; WipeInput wipeDecoded{{decoded.data(),decoded.size()}};
    const auto count = rfb::deobfuscate(obfuscated.data,obfuscated.length,decoded.data(),decoded.size());
    Secret secret; secret.value.assign(reinterpret_cast<const char*>(decoded.data()),count);
    promptResult(session(id)->authentication()->replyCredentials(request,generation,{},secret.value,true));
    return TIDYVNC_OK;
  });
}
tidyvnc_status tidyvnc_session_reply_trust(tidyvnc_handle id,uint64_t request,uint64_t generation,uint32_t allowed,tidyvnc_error* error) {
  return call(error,[&]() -> uint32_t { boolean(allowed); promptResult(session(id)->authentication()->replyTrust(request,generation,allowed)); return TIDYVNC_OK; });
}
}
