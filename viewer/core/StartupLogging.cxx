/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "StartupLogging.h"
#include "RedactedLogger.h"
#include <algorithm>
#include <utility>

using namespace viewer;
namespace {
std::vector<std::string> namesOf(const std::vector<core::LogWriter*>& writers) {
  std::vector<std::string> names;
  names.reserve(writers.size());
  for (auto* writer : writers) {
    if (!writer || !writer->getName()) throw LoggingError(LoggingProblem::InvalidCatalog,0);
    names.emplace_back(writer->getName());
  }
  // Duplicate names are valid registry nodes; repeated pointers are not.
  auto pointers = writers;
  std::sort(pointers.begin(),pointers.end(),std::less<core::LogWriter*>());
  if (std::adjacent_find(pointers.begin(),pointers.end()) != pointers.end())
    throw LoggingError(LoggingProblem::InvalidCatalog,0);
  return names;
}
}
struct StartupLogging::Destination {
  Destination(std::string name_, std::unique_ptr<core::Logger> sink_)
    : name(std::move(name_)), sink(std::move(sink_)), redacted("native-redacted",*sink) {}
  const std::string name;
  std::unique_ptr<core::Logger> sink;
  RedactedLogger redacted; // destroyed before its borrowed sink
};

StartupLogging::StartupLogging(std::vector<core::LogWriter*> writers_, std::vector<std::string> targets_)
  : writers(std::move(writers_)), names(namesOf(writers)), targets(std::move(targets_)) {
  LoggingPolicy::parse("").resolve(names,targets); // validate host catalogs now
}

StartupLogging::~StartupLogging() {
  if (installed) for (auto* writer : writers) writer->setLog(nullptr);
}

void StartupLogging::validate(const LoggingPolicy& policy) const {
  // Immutable owned names; safe to validate after admission closes as well.
  policy.resolve(names,targets);
}

void StartupLogging::configure(const LoggingPolicy& policy, const Factory& factory) {
  std::lock_guard<std::mutex> lock(mutex);
  if (frozen) throw LoggingFrozen();
  const auto routes = policy.resolve(names,targets);
  std::vector<std::unique_ptr<Destination>> prepared;
  std::vector<core::Logger*> bindings;
  bindings.reserve(routes.size()); prepared.reserve(targets.size());
  for (const auto& route : routes) {
    if (route.target.empty()) { bindings.push_back(nullptr); continue; }
    auto found = std::find_if(prepared.begin(),prepared.end(),[&](const std::unique_ptr<Destination>& destination) {
      return destination->name == route.target;
    });
    if (found == prepared.end()) {
      auto sink = factory(route.target);
      if (!sink) throw std::invalid_argument("Logging destination is unavailable");
      prepared.emplace_back(new Destination(route.target,std::move(sink)));
      bindings.push_back(&prepared.back()->redacted);
    } else bindings.push_back(&(*found)->redacted);
  }
  // From here to publication there are no allocations, callbacks or operations
  // that can throw. A concurrent freeze cannot start workers until this returns.
  destinations.swap(prepared);
  for (size_t i = 0; i < writers.size(); ++i) {
    writers[i]->setLevel(routes[i].level);
    writers[i]->setLog(bindings[i]);
  }
  installed = frozen = true;
}

void StartupLogging::freeze() {
  std::lock_guard<std::mutex> lock(mutex);
  frozen = true;
}
