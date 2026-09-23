/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <core/Logger_file.h>
#include <core/Logger_stdio.h>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <random>
#include <set>
#include <sstream>
#include <thread>
#include <vector>

namespace {
void emit(core::Logger& logger, const char* format, ...) {
  va_list args; va_start(args,format); logger.write(30,"fixture",format,args); va_end(args);
}
std::string read(FILE* file) {
  std::fflush(file); std::rewind(file);
  std::string result; char buffer[4096];
  while (const auto count = std::fread(buffer,1,sizeof(buffer),file)) result.append(buffer,count);
  return result;
}
std::string read(const std::filesystem::path& path) {
  std::ifstream file(path); return std::string(std::istreambuf_iterator<char>(file),{});
}
struct Directory {
  Directory() {
    std::random_device random;
    for (int i = 0; i < 100; ++i) {
      path = std::filesystem::temp_directory_path()/ ("tidyvnc-logging-"+std::to_string(random())+"-"+std::to_string(random()));
      if (std::filesystem::create_directory(path)) return;
    }
    throw std::runtime_error("Cannot create log fixture directory");
  }
  ~Directory() { std::error_code error; std::filesystem::remove_all(path,error); }
  std::filesystem::path path;
};
}

TEST(Logging, PreservesTimestampPrefixWrappingMultilineAndTruncation) {
  FILE* file = std::tmpfile(); ASSERT_NE(file,nullptr);
  core::Logger_File logger("fixture-file"); logger.setFile(file);
  logger.indent = 13; logger.width = 28;
  emit(logger,"alpha beta gamma delta\nnext");
  const auto output = read(file);
  ASSERT_GT(output.size(),27u); EXPECT_EQ(output[0],'\n'); EXPECT_EQ(output[25],'\n');
  EXPECT_EQ(output.substr(26)," fixture:     alpha beta\n              gamma delta\n fixture:     next\n");
  logger.width = 10000;
  emit(logger,"%s",std::string(5000,'x').c_str());
  const auto truncated = read(file);
  // Existing formatter admits at most 4094 text bytes plus terminator.
  EXPECT_NE(truncated.find(std::string(4094,'x')+"\n"),std::string::npos);
  EXPECT_EQ(truncated.find(std::string(4095,'x')),std::string::npos);
}

TEST(Logging, ConcurrentFormattedRecordsRemainContiguousAndComplete) {
  FILE* file = std::tmpfile(); ASSERT_NE(file,nullptr);
  // StdIO inherits the same sink synchronization as file output; this stream is
  // fixture-owned, never the process stdout/stderr or a user's log file.
  core::Logger_StdIO logger("fixture-stdio",file); logger.indent = 0; logger.width = 10000;
  constexpr int workers = 6, records = 150;
  std::vector<std::thread> threads;
  for (int worker = 0; worker < workers; ++worker) threads.emplace_back([&,worker] {
    for (int record = 0; record < records; ++record)
      emit(logger,"begin-%d-%d\nend-%d-%d",worker,record,worker,record);
  });
  for (auto& thread : threads) thread.join();
  const auto output = read(file); std::set<std::string> lines;
  std::istringstream stream(output); std::string line;
  while (std::getline(stream,line)) if (line.find(" fixture: ") == 0) { ASSERT_TRUE(lines.insert(line).second); }
  ASSERT_EQ(lines.size(),workers*records*2u);
  for (int worker = 0; worker < workers; ++worker) for (int record = 0; record < records; ++record) {
    const auto id = std::to_string(worker)+"-"+std::to_string(record);
    EXPECT_NE(output.find(" fixture: begin-"+id+"\n fixture: end-"+id+"\n"),std::string::npos);
  }
}

TEST(Logging, ConcurrentDirectAndFormattedWritesCannotRaceFileReplacement) {
  core::Logger_File logger("fixture-replacement"); logger.indent = 0; logger.width = 10000;
  FILE* first = std::tmpfile(); ASSERT_NE(first,nullptr); logger.setFile(first);
  std::atomic<bool> failed{false}, start{false}; std::vector<std::thread> threads;
  for (int worker = 0; worker < 4; ++worker) threads.emplace_back([&,worker] {
    while (!start.load()) std::this_thread::yield();
    for (int i = 0; i < 200; ++i) {
      if (worker % 2) emit(logger,"worker-%d-record-%d\ncontinued",worker,i);
      else logger.write(30,"direct","complete direct record");
    }
  });
  std::thread replace([&] {
    while (!start.load()) std::this_thread::yield();
    for (int i = 0; i < 100; ++i) {
      FILE* next = std::tmpfile();
      if (!next) { failed = true; return; }
      logger.setFile(next); // transfers ownership, including synchronized fclose
    }
  });
  start = true;
  for (auto& thread : threads) thread.join();
  replace.join(); ASSERT_FALSE(failed);
  FILE* final = std::tmpfile(); ASSERT_NE(final,nullptr); logger.setFile(final);
  emit(logger,"last record"); EXPECT_NE(read(final).find(" fixture: last record\n"),std::string::npos);
}

TEST(Logging, IndependentSinkTimestampsHaveNoSharedScratch) {
  std::atomic<bool> failed{false}; std::vector<std::thread> threads;
  for (int worker = 0; worker < 4; ++worker) threads.emplace_back([&] {
    // Each new sink naturally needs a timestamp, exercising concurrent clock
    // formatting across independent locks without reaching into logger state.
    for (int i = 0; i < 60; ++i) {
      FILE* file = std::tmpfile(); if (!file) { failed = true; return; }
      core::Logger_File logger("fixture-timestamp"); logger.setFile(file);
      emit(logger,"owned timestamp"); const auto output = read(file);
      if (output.size() < 27 || output[0] != '\n' || output[25] != '\n' ||
          output.find(" fixture:     owned timestamp\n") == std::string::npos) failed = true;
    }
  });
  for (auto& thread : threads) thread.join();
  EXPECT_FALSE(failed);
}

TEST(Logging, LazyRotationAndFilenameSwitchPreserveLegacyLifecycle) {
  Directory directory; const auto a = directory.path/"a.log", b = directory.path/"b.log";
  { std::ofstream(a) << "old log"; std::ofstream(a.string()+".bak") << "old backup"; }
  {
    core::Logger_File logger("fixture-rotation"); logger.setFilename(a.string().c_str());
    EXPECT_EQ(read(a),"old log"); EXPECT_EQ(read(a.string()+".bak"),"old backup");
    emit(logger,"first destination");
    EXPECT_EQ(read(a.string()+".bak"),"old log"); EXPECT_NE(read(a).find("first destination"),std::string::npos);
    logger.setFilename(b.string().c_str()); EXPECT_FALSE(std::filesystem::exists(b));
    emit(logger,"second destination");
    EXPECT_NE(read(b).find("second destination"),std::string::npos);
    EXPECT_EQ(read(a).find("second destination"),std::string::npos);
  }
  EXPECT_NE(read(b).find("second destination"),std::string::npos);
}
