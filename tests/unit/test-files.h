/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_TEST_FILES_H
#define TIDYVNC_TEST_FILES_H
// Unique temporary files and directories for tests on POSIX and Windows
// (mkstemp/mkdtemp are POSIX-only). Paths are narrow and ASCII.
#include <filesystem>
#include <fstream>
#include <random>
#include <stdexcept>
#include <string>

namespace testfiles {
inline std::filesystem::path uniquePath(const std::string& prefix) {
  static std::random_device random;
  for (int attempt = 0; attempt < 64; ++attempt) {
    auto path = std::filesystem::temp_directory_path() / (prefix + std::to_string(random()) + std::to_string(random()));
    if (!std::filesystem::exists(path)) return path;
  }
  throw std::runtime_error("No unique temporary path");
}
struct TemporaryDirectory {
  explicit TemporaryDirectory(const std::string& prefix = "tidyvnc-test-") : path(uniquePath(prefix)) {
    std::filesystem::create_directory(path);
  }
  ~TemporaryDirectory() { std::error_code ignored; std::filesystem::remove_all(path, ignored); }
  std::filesystem::path path;
};
struct TemporaryFile {
  explicit TemporaryFile(const std::string& bytes = std::string(), const std::string& prefix = "tidyvnc-test-")
    : path(uniquePath(prefix).string()) {
    std::ofstream file(path, std::ios::binary);
    file.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    if (!file) throw std::runtime_error("Temporary file write failed");
  }
  ~TemporaryFile() { std::error_code ignored; std::filesystem::remove(path, ignored); }
  std::string read() const { std::ifstream in(path, std::ios::binary); return {std::istreambuf_iterator<char>(in), {}}; }
  std::string path;
};
}
#endif
