/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "LegacyKnownHosts.h"

#include <algorithm>
#include <cstring>
#include <map>

#include <core/string.h>

#include "IdentityDigest.h"

namespace viewer {
namespace {

std::vector<std::string> split(const std::string& text, char separator)
{
  std::vector<std::string> parts;
  size_t start = 0;
  while (true) {
    const size_t end = text.find(separator, start);
    parts.push_back(text.substr(start, end == std::string::npos ? std::string::npos : end - start));
    if (end == std::string::npos) return parts;
    start = end + 1;
  }
}

bool digits(const std::string& text)
{
  return !text.empty() && std::all_of(text.begin(), text.end(), [](char c) { return c >= '0' && c <= '9'; });
}

// Unsigned decimal with overflow detection (Swift UInt64("...")/UInt32("...")).
bool decimal(const std::string& text, uint64_t maximum, uint64_t& out)
{
  if (!digits(text)) return false;
  uint64_t value = 0;
  for (char c : text) {
    const uint64_t digit = uint64_t(c - '0');
    if (value > (maximum - digit) / 10) return false;
    value = value * 10 + digit;
  }
  out = value;
  return true;
}

const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string encode(const std::vector<uint8_t>& bytes)
{
  std::string out;
  size_t i = 0;
  for (; i + 3 <= bytes.size(); i += 3) {
    const uint32_t v = uint32_t(bytes[i]) << 16 | uint32_t(bytes[i + 1]) << 8 | bytes[i + 2];
    out += alphabet[v >> 18]; out += alphabet[(v >> 12) & 63]; out += alphabet[(v >> 6) & 63]; out += alphabet[v & 63];
  }
  if (bytes.size() - i == 1) {
    const uint32_t v = uint32_t(bytes[i]) << 16;
    out += alphabet[v >> 18]; out += alphabet[(v >> 12) & 63]; out += "==";
  } else if (bytes.size() - i == 2) {
    const uint32_t v = uint32_t(bytes[i]) << 16 | uint32_t(bytes[i + 1]) << 8;
    out += alphabet[v >> 18]; out += alphabet[(v >> 12) & 63]; out += alphabet[(v >> 6) & 63]; out += '=';
  }
  return out;
}

// Strict, padded base64 whose canonical encoding is the input itself (the
// macOS codec decodes with Foundation and requires an exact round trip).
bool decode(const std::string& text, std::vector<uint8_t>& out)
{
  if (text.empty() || text.size() % 4 != 0) return false;
  std::vector<uint8_t> bytes;
  bytes.reserve(text.size() / 4 * 3);
  for (size_t i = 0; i < text.size(); i += 4) {
    uint32_t v = 0;
    int padding = 0;
    for (size_t j = 0; j < 4; j++) {
      const char c = text[i + j];
      const char* found = c ? std::strchr(alphabet, c) : nullptr;
      if (c == '=' && i + 4 == text.size() && j >= 2) { padding++; v <<= 6; continue; }
      if (!found || padding) return false;
      v = (v << 6) | uint32_t(found - alphabet);
    }
    bytes.push_back(uint8_t(v >> 16));
    if (padding < 2) bytes.push_back(uint8_t(v >> 8));
    if (padding < 1) bytes.push_back(uint8_t(v));
  }
  if (encode(bytes) != text) return false;
  out = std::move(bytes);
  return true;
}

std::string lowerHex(const std::vector<uint8_t>& bytes)
{
  static const char hexDigits[] = "0123456789abcdef";
  std::string text;
  for (auto b : bytes) { text += hexDigits[b >> 4]; text += hexDigits[b & 15]; }
  return text;
}
}

std::vector<KnownHostsRecord> LegacyKnownHosts::parse(const std::string& data)
{
  if (data.size() > maximumBytes) throw KnownHostsError(KnownHostsProblem::TooLarge, 0);
  if (data.find('\0') != std::string::npos || !core::isValidUTF8(data.data(), data.size()))
    throw KnownHostsError(KnownHostsProblem::Corrupt, 0);
  std::vector<KnownHostsRecord> records;
  uint32_t number = 0;
  for (auto line : split(data, '\n')) {
    ++number;
    // Byte lines, as the legacy reader: only a final CR is dropped.
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty() || line[0] == '#') continue;
    if (records.size() >= maximumRecords || line.size() > maximumLine)
      throw KnownHostsError(KnownHostsProblem::TooLarge, number);
    const auto fields = split(line, '|');
    if (fields.size() < 2 || !fields[0].empty()) throw KnownHostsError(KnownHostsProblem::Corrupt, number);
    const bool key = fields[1] == "g0";
    if (!key && fields[1] != "c0") throw KnownHostsError(KnownHostsProblem::UnsupportedFormat, number);
    uint64_t expiration = 0;
    if (fields.size() != (key ? 6u : 7u) || fields[2].empty() || fields[3].empty() || fields[2].size() > 4096 ||
        fields[3].size() > 4096 || !decimal(fields[4], uint64_t(INT64_MAX), expiration))
      throw KnownHostsError(KnownHostsProblem::Corrupt, number);
    KnownHostsRecord record;
    record.host = fields[2];
    record.expiration = expiration;
    if (key) {
      if (!decode(fields[5], record.key) || record.key.empty() || record.key.size() > 65536)
        throw KnownHostsError(KnownHostsProblem::Corrupt, number);
    } else {
      uint64_t algorithm = 0;
      const auto& commitment = fields[6];
      if (!decimal(fields[5], UINT32_MAX, algorithm) || algorithm == 0 || commitment.empty() ||
          commitment.size() > 128 || commitment.size() % 2 != 0 ||
          commitment.find_first_not_of("0123456789abcdef") != std::string::npos)
        throw KnownHostsError(KnownHostsProblem::Corrupt, number);
      record.algorithm = uint32_t(algorithm);
      record.commitment = commitment;
    }
    records.push_back(std::move(record));
  }
  return records;
}

std::string LegacyKnownHosts::fingerprint(const std::vector<uint8_t>& bytes)
{
  Sha256 hash;
  hash.update(bytes.data(), bytes.size());
  static const char hexDigits[] = "0123456789ABCDEF";
  std::string text;
  for (auto b : hash.finish()) {
    if (!text.empty()) text += ':';
    text += hexDigits[b >> 4]; text += hexDigits[b & 15];
  }
  return text;
}

KnownHostsMatch LegacyKnownHosts::lookup(const std::vector<KnownHostsRecord>& records, const std::string& host,
                                         const std::vector<uint8_t>& spki, uint64_t now,
                                         const std::function<std::vector<uint8_t>(uint32_t)>& digest)
{
  if (host.empty() || host.size() > 4096 || host.find_first_of(std::string("\0|\n\r", 4)) != std::string::npos ||
      !core::isValidUTF8(host.data(), host.size()) || spki.empty() || spki.size() > 65536)
    throw KnownHostsError(KnownHostsProblem::Corrupt, 0);
  KnownHostsMatch result;
  bool matched = false, found = false;
  std::map<uint32_t, std::string> digests;
  for (const auto& record : records) {
    if (!(record.host[0] == '*' || record.host == host) || !(record.expiration == 0 || now <= record.expiration)) continue;
    found = true;
    result.wildcard = result.wildcard || record.host[0] == '*';
    KnownHostsIdentity identity;
    if (!record.key.empty()) {
      identity.text = fingerprint(record.key);
      matched = matched || record.key == spki;
    } else {
      auto cached = digests.find(record.algorithm);
      if (cached == digests.end()) cached = digests.emplace(record.algorithm, lowerHex(digest(record.algorithm))).first;
      identity.commitment = true;
      identity.algorithm = record.algorithm;
      identity.text = record.commitment;
      matched = matched || cached->second == record.commitment;
    }
    if (std::find(result.expected.begin(), result.expected.end(), identity) == result.expected.end()) {
      if (result.expected.size() < maximumIdentities) result.expected.push_back(identity);
      else result.hasMore = true;
    }
  }
  result.state = matched ? KnownHostsMatch::State::Match : found ? KnownHostsMatch::State::Changed : KnownHostsMatch::State::Missing;
  result.received = fingerprint(spki);
  return result;
}
}
