/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// A small JSON reader for the shared conformance corpus (tests/conformance,
// plans/native-ui-winui CORE.md section 6): objects, arrays, strings with
// escapes (including \u0000 and surrogate pairs), numbers, booleans and null.
// Test-only; malformed input throws std::runtime_error with an offset.
#ifndef TIDYVNC_TESTS_CONFORMANCE_JSON_H
#define TIDYVNC_TESTS_CONFORMANCE_JSON_H

#include <cstdint>
#include <fstream>
#include <map>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace conformance {

struct Json {
  enum class Type { Null, Bool, Number, String, Array, Object } type = Type::Null;
  bool boolean = false;
  double number = 0;
  std::string text;
  std::vector<Json> items;
  std::map<std::string, Json> fields;

  bool has(const std::string& name) const { return type == Type::Object && fields.count(name) != 0; }
  const Json& operator[](const std::string& name) const
  {
    auto found = fields.find(name);
    if (type != Type::Object || found == fields.end()) throw std::runtime_error("Missing field " + name);
    return found->second;
  }
  const std::string& string() const
  {
    if (type != Type::String) throw std::runtime_error("Not a string");
    return text;
  }
  uint32_t u32() const
  {
    if (type != Type::Number || number < 0 || number > 4294967295.0 || number != static_cast<double>(static_cast<uint64_t>(number)))
      throw std::runtime_error("Not a 32-bit unsigned integer");
    return static_cast<uint32_t>(number);
  }
  std::string string(const std::string& name, const std::string& fallback) const { return has(name) ? (*this)[name].string() : fallback; }
  uint32_t u32(const std::string& name, uint32_t fallback) const { return has(name) ? (*this)[name].u32() : fallback; }
  bool flag(const std::string& name, bool fallback) const
  {
    if (!has(name)) return fallback;
    const auto& value = (*this)[name];
    if (value.type != Type::Bool) throw std::runtime_error("Not a boolean: " + name);
    return value.boolean;
  }
};

class Reader {
public:
  explicit Reader(const std::string& input) : text(input) {}
  Json document()
  {
    auto value = parse();
    space();
    if (at != text.size()) fail("Trailing text");
    return value;
  }

private:
  [[noreturn]] void fail(const char* what) { throw std::runtime_error(std::string(what) + " at offset " + std::to_string(at)); }
  void space() { while (at < text.size() && (text[at] == ' ' || text[at] == '\n' || text[at] == '\r' || text[at] == '\t')) ++at; }
  bool take(char c) { space(); if (at < text.size() && text[at] == c) { ++at; return true; } return false; }
  void expect(char c) { if (!take(c)) fail("Unexpected character"); }
  void word(const char* w) { for (const char* p = w; *p; ++p, ++at) if (at >= text.size() || text[at] != *p) fail("Invalid literal"); }

  Json parse()
  {
    space();
    if (at >= text.size()) fail("Unexpected end");
    Json value;
    const char c = text[at];
    if (c == '{') {
      ++at; value.type = Json::Type::Object;
      if (take('}')) return value;
      do {
        space();
        auto name = string();
        expect(':');
        value.fields[name] = parse();
      } while (take(','));
      expect('}');
    } else if (c == '[') {
      ++at; value.type = Json::Type::Array;
      if (take(']')) return value;
      do value.items.push_back(parse()); while (take(','));
      expect(']');
    } else if (c == '"') {
      value.type = Json::Type::String; value.text = string();
    } else if (c == 't') { word("true"); value.type = Json::Type::Bool; value.boolean = true; }
    else if (c == 'f') { word("false"); value.type = Json::Type::Bool; }
    else if (c == 'n') { word("null"); }
    else {
      const size_t start = at;
      while (at < text.size() && std::string("+-0123456789.eE").find(text[at]) != std::string::npos) ++at;
      if (start == at) fail("Invalid value");
      value.type = Json::Type::Number; value.number = std::stod(text.substr(start, at - start));
    }
    return value;
  }

  unsigned hex4()
  {
    if (at + 4 > text.size()) fail("Short escape");
    unsigned value = 0;
    for (int i = 0; i < 4; ++i) {
      const char c = text[at++];
      value <<= 4;
      if (c >= '0' && c <= '9') value |= unsigned(c - '0');
      else if (c >= 'a' && c <= 'f') value |= unsigned(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F') value |= unsigned(c - 'A' + 10);
      else fail("Invalid escape");
    }
    return value;
  }

  void utf8(std::string& out, unsigned code)
  {
    if (code < 0x80) out += char(code);
    else if (code < 0x800) { out += char(0xc0 | (code >> 6)); out += char(0x80 | (code & 0x3f)); }
    else if (code < 0x10000) { out += char(0xe0 | (code >> 12)); out += char(0x80 | ((code >> 6) & 0x3f)); out += char(0x80 | (code & 0x3f)); }
    else { out += char(0xf0 | (code >> 18)); out += char(0x80 | ((code >> 12) & 0x3f)); out += char(0x80 | ((code >> 6) & 0x3f)); out += char(0x80 | (code & 0x3f)); }
  }

  std::string string()
  {
    if (at >= text.size() || text[at] != '"') fail("Expected string");
    ++at;
    std::string out;
    while (true) {
      if (at >= text.size()) fail("Unterminated string");
      const char c = text[at++];
      if (c == '"') return out;
      if (c != '\\') { out += c; continue; }
      if (at >= text.size()) fail("Unterminated escape");
      const char e = text[at++];
      switch (e) {
      case '"': out += '"'; break;
      case '\\': out += '\\'; break;
      case '/': out += '/'; break;
      case 'b': out += '\b'; break;
      case 'f': out += '\f'; break;
      case 'n': out += '\n'; break;
      case 'r': out += '\r'; break;
      case 't': out += '\t'; break;
      case 'u': {
        unsigned code = hex4();
        if (code >= 0xd800 && code < 0xdc00) {
          if (at + 6 > text.size() || text[at] != '\\' || text[at + 1] != 'u') fail("Unpaired surrogate");
          at += 2;
          const unsigned low = hex4();
          if (low < 0xdc00 || low > 0xdfff) fail("Unpaired surrogate");
          code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
        }
        utf8(out, code);
        break;
      }
      default: fail("Invalid escape");
      }
    }
  }

  const std::string& text;
  size_t at = 0;
};

inline Json load(const std::string& path)
{
  std::ifstream file(path, std::ios::binary);
  if (!file) throw std::runtime_error("Cannot open " + path);
  std::stringstream buffer;
  buffer << file.rdbuf();
  const auto text = buffer.str();
  return Reader(text).document();
}

// Corpus strings may be literal or {"repeat": "x", "count": N} for long inputs.
inline std::string text(const Json& value)
{
  if (value.type == Json::Type::Object) {
    std::string out;
    const auto& unit = value["repeat"].string();
    for (uint32_t i = 0, n = value["count"].u32(); i < n; ++i) out += unit;
    return out;
  }
  return value.string();
}

inline std::string text(const Json& value, const std::string& name, const std::string& fallback)
{
  return value.has(name) ? text(value[name]) : fallback;
}
}
#endif
