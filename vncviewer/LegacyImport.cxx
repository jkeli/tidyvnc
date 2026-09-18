// Original TidyVNC work, 2026. SPDX-License-Identifier: GPL-2.0-or-later
#ifndef _WIN32
#include "LegacyImport.h"
#include <core/AtomicFile.h>
#include <core/Exception.h>
#include <core/xdgdirs.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <fstream>
#include <set>
#include <stdexcept>

static bool exists(const std::string& path)
{
  struct stat st;
  if (lstat(path.c_str(), &st) == 0) return true;
  if (errno == ENOENT) return false;
  throw core::posix_error("Inspect viewer state", errno);
}

std::string legacyViewerFile(bool history)
{
  const char* dir = history ? core::gettidyvncstatedir() : core::gettidyvncconfigdir();
  if (!dir) throw std::runtime_error("Cannot determine viewer state directory");
  std::string current(dir);
  if (exists(current + (history ? "/tidyvnc.history" : "/default.tidyvnc"))) return "";
  std::string base = current.substr(0, current.find_last_of('/'));
  std::string file = history ? "/tigervnc.history" : "/default.tigervnc";
  std::string candidate = base + "/tigervnc" + file;
  if (exists(candidate)) return candidate;
  const char* home = core::getuserhomedir();
  if (!home) return "";
  candidate = std::string(home) + "/.vnc" + file;
  return exists(candidate) ? candidate : "";
}

void importLegacyHistory(const std::string& source)
{
  const char* dir = core::gettidyvncstatedir();
  if (!dir) throw std::runtime_error("Cannot determine viewer state directory");
  std::string destination = std::string(dir) + "/tidyvnc.history";
  if (exists(destination)) return;
  std::ifstream input(source);
  if (!input) throw std::runtime_error("Cannot read legacy history");
  std::string line;
  std::set<std::string> seen;
  std::string output;
  while (std::getline(input, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.size() > 254 || line.find('\0') != std::string::npos)
      throw std::runtime_error("Invalid legacy history entry");
    if (!line.empty() && seen.insert(line).second && seen.size() <= 20)
      output += line + "\n";
  }
  if (input.bad()) throw std::runtime_error("Cannot read legacy history");
  core::AtomicFile file(destination.c_str());
  fputs(output.c_str(), file.stream());
  struct stat sourceMode;
  if (stat(source.c_str(), &sourceMode) != 0 ||
      fchmod(fileno(file.stream()), sourceMode.st_mode & 0600) != 0)
    throw core::posix_error("Preserve private import permissions", errno);
  file.commit(false);
}
#endif
