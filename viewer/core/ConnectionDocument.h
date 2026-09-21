/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_CONNECTION_DOCUMENT_H
#define TIDYVNC_CONNECTION_DOCUMENT_H

#include <cstddef>
#include <stdexcept>
#include <string>
#include <vector>

namespace viewer {
enum class DocumentErrorCode {
  Empty, InvalidHeader, NullByte, LineTooLong, InvalidAssignment,
  InvalidEscape, TooLarge, TooManyEntries, InvalidExportName, InvalidValue, Unavailable
};
class DocumentError : public std::invalid_argument {
public:
  DocumentError(DocumentErrorCode reason, size_t lineNumber = 0);
  const DocumentErrorCode code;
  const size_t line; // One-based; zero for a whole-document/value error.
};

struct DocumentAssignment { std::string name, value; };
struct DocumentEntry {
  std::string name, encodedValue;
  size_t line;
  // Decode only entries understood by the consumer. Historical readers ignore
  // unknown entries, including unknown escape sequences in their values.
  std::string value() const;
};

// Owned, toolkit-independent syntax. No parameter registry, IO, environment,
// migration, credentials or settings mutation. Semantic validation/application
// belongs to a separate transaction; this is not a validated session config.
class ConnectionDocument {
public:
  static constexpr size_t maximumBytes = 1024 * 1024;
  static constexpr size_t maximumEntries = 4096;
  // Historical fgets(256) rejects a read of 255 bytes, including the newline.
  static constexpr size_t maximumLineBytes = 254;
  static const char* header();
  static const char* legacyHeader();
  static ConnectionDocument parse(const std::string& bytes);
  // Always emits the current header. Accepts only the historical non-secret
  // export catalog (including ServerName); never round-trips unknown entries.
  // Preflights the complete document, including escaped line lengths.
  static std::string serialize(const std::vector<DocumentAssignment>& values);
  static const char* exportName(const std::string& name);
  static std::string encodeValue(const std::string& value);
  static std::string decodeValue(const std::string& value);

  bool isLegacy() const { return legacy; }
  const std::vector<DocumentEntry>& entries() const { return fields; }
private:
  bool legacy = false;
  std::vector<DocumentEntry> fields;
};
}
#endif
