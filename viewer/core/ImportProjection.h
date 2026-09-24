/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_IMPORT_PROJECTION_H
#define TIDYVNC_IMPORT_PROJECTION_H

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace viewer {
// The first step of an explicit import of the retained viewer's defaults or
// history (plans/native-ui-winui CORE.md section 6): what may enter native
// preferences and what is reported and dropped. The macOS
// NativeDefaultsImportProjection and NativeHistoryImport, with sources as
// either file bytes (the XDG defaults/history files) or decoded values (the
// Windows registry). Deprecated migrations, display mapping and preference
// conversion follow in the configuration resolver. No IO or settings change.

enum class ImportNoticeKind { Excluded = 1, Unknown = 2, PlatformOnly = 3 };
struct ImportNotice {
  uint32_t line; // File line, or the value's one-based position.
  std::string name; // As written in the source (never a value).
  ImportNoticeKind kind;
};
struct ImportAssignment {
  std::string name, value; // Canonical file-catalog name and validated value.
  uint32_t line;
};
struct DefaultsProjection {
  std::vector<ImportAssignment> assignments; // Source order.
  std::vector<ImportNotice> notices;         // Source order.
};

enum class ImportProblem { Unrepresentable, TooLarge, InvalidText, LineTooLong, TooManyEntries };
class ImportError : public std::invalid_argument {
public:
  ImportError(ImportProblem value, uint32_t lineNumber)
    : std::invalid_argument("Import source cannot be used"), problem(value), line(lineNumber) {}
  const ImportProblem problem;
  const uint32_t line;
};

// A defaults file (connection-file syntax and header). Malformed understood
// fields fail with the document's error; an understood field outside the
// import allow-list fails as Unrepresentable.
DefaultsProjection projectDefaultsFile(const std::string& bytes);
// Decoded (name, value) pairs, e.g. registry values; positions are one-based.
struct ImportValue { std::string name, value; };
DefaultsProjection projectDefaultsValues(const std::vector<ImportValue>& values);

struct HistoryProjection {
  std::vector<std::string> endpoints; // First 20 distinct non-empty entries, spelling kept.
  uint32_t duplicates = 0, omittedOlder = 0;
};
constexpr size_t historyCapacity = 20;          // The retained SERVER_HISTORY_SIZE.
constexpr size_t historyMaximumBytes = 1024 * 1024;
constexpr size_t historyMaximumEntryBytes = 254;
HistoryProjection projectHistoryFile(const std::string& bytes);
HistoryProjection projectHistoryValues(const std::vector<std::string>& entries);
}
#endif
