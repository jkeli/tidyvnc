/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/RedactedLogger.h>
#include <core/Logger_file.h>
#include <core/LogWriter.h>
#include <cstdarg>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

namespace {
struct Record { int level; std::string source, message; };
class Capture final : public core::Logger {
public:
  Capture() : Logger("fixture-capture") {}
  void write(int level, const char* source, const char* text) override {
    records.push_back({level,source,text});
  }
  std::vector<Record> records;
};
void emit(core::Logger& logger, const char* source, const char* format, ...) {
  va_list args; va_start(args,format); logger.write(100,source,format,args); va_end(args);
}
std::string read(FILE* file) {
  std::fflush(file); std::rewind(file);
  char buffer[4096]; std::string result;
  while (const auto size = std::fread(buffer,1,sizeof(buffer),file)) result.append(buffer,size);
  return result;
}
}

TEST(RedactedLogger, KnownEventsRetainContextWithoutEvaluatingStrings) {
  Capture output; viewer::RedactedLogger logger("native-fixture",output);
  emit(logger,"CConnection","Reading protocol version");
  emit(logger,"CConnection","Server supports RFB protocol version %d.%d",3,8);
  emit(logger,"TcpSocket","Connecting to %s [%s] port %d","private-host","private-address",5999);
  emit(logger,"TLS","Server certificate verification failed: %s","private-certificate");
  emit(logger,"CMsgReader","Clipboard too large (%d bytes)",1234567);
  // An invalid string pointer would fail if printf ever evaluated it. The
  // adapter recognizes the event template and never reads its argument list.
  emit(logger,"TLS","TLS handshake completed with %s",reinterpret_cast<const char*>(1));
  ASSERT_EQ(output.records.size(),6u);
  EXPECT_EQ(output.records[0].message,"Reading protocol version");
  EXPECT_EQ(output.records[1].message,"Server supports RFB protocol version 3.8");
  EXPECT_EQ(output.records[2].source,"TcpSocket");
  EXPECT_EQ(output.records[2].message,"Connecting to [redacted] [[redacted]] port [redacted]");
  EXPECT_EQ(output.records[3].message,"Server certificate verification failed: [redacted]");
  EXPECT_EQ(output.records[4].message,"Clipboard too large (1234567 bytes)");
  EXPECT_EQ(output.records[5].message,"TLS handshake completed with [redacted]");
  for (const auto& record : output.records) EXPECT_EQ(record.message.find("private"),std::string::npos);
}

TEST(RedactedLogger, UnknownFormatsSourcesAndPreformattedTextNeverEscape) {
  Capture output; viewer::RedactedLogger logger("native-fixture",output);
  int sentinel = 71;
  emit(logger,"CConnection","private%n",&sentinel);
  emit(logger,"CConnection","%s","private-exception\nforged: output");
  emit(logger,"private-source\nforged","Reading protocol version");
  emit(logger,"CConnection","Reading protocol version private-suffix");
  emit(logger,"TLS",nullptr);
  logger.write(1234567,"TLS","TLS handshake completed with private-peer");
  logger.write(-1234567,nullptr,"private-key");
  // Even a direct message identical to a known safe template is not trusted.
  logger.write(50,"CConnection","Reading protocol version");
  ASSERT_EQ(output.records.size(),8u); EXPECT_EQ(sentinel,71);
  for (const auto& record : output.records) {
    EXPECT_EQ(record.message,"Diagnostic details redacted.");
    EXPECT_EQ(record.source.find("private"),std::string::npos);
  }
  EXPECT_EQ(output.records[2].source,"Core"); EXPECT_EQ(output.records[6].source,"Core");
  EXPECT_EQ(output.records[5].level,100); EXPECT_EQ(output.records[6].level,0);
  EXPECT_EQ(output.records[7].level,30);
}

TEST(RedactedLogger, AuditedNumericMetadataPreservesUsefulDiagnostics) {
  Capture output; viewer::RedactedLogger logger("native-fixture",output);
  emit(logger,"CConnection","Failed to resize remote session: %d",2);
  emit(logger,"DecodeManager","Unknown encoding %d",-42);
  emit(logger,"CMsgReader","Invalid rectangle received: %dx%d at %d,%d exceeds %dx%d",800,600,-1,10,640,480);
  emit(logger,"CConnection","Ignoring clipboard request for unsupported formats 0x%x",0x80u);
  emit(logger,"ZlibOutStream","Calling deflate, avail_in %d, avail_out %d",10,20);
  emit(logger,"NativeDesktop","Viewport logical %dx%d, backing %dx%d",640,480,1280,960);
  ASSERT_EQ(output.records.size(),6u);
  EXPECT_EQ(output.records[0].message,"Failed to resize remote session: 2");
  EXPECT_EQ(output.records[1].message,"Unknown encoding -42");
  EXPECT_EQ(output.records[2].message,"Invalid rectangle received: 800x600 at -1,10 exceeds 640x480");
  EXPECT_EQ(output.records[3].message,"Ignoring clipboard request for unsupported formats 0x80");
  EXPECT_EQ(output.records[4].message,"Calling deflate, avail_in 10, avail_out 20");
  EXPECT_EQ(output.records[5].message,"Viewport logical 640x480, backing 1280x960");
}

TEST(RedactedLogger, KeyboardValuesAndPerKeyEventsAreSuppressed) {
  Capture output; viewer::RedactedLogger logger("native-fixture",output);
  emit(logger,"CConnection","Key pressed: %d => 0x%02x / XK_%s (0x%04x)",1,2,"private-key",3);
  emit(logger,"CConnection","Key released: %d => 0x%02x / XK_%s (0x%04x)",1,2,"private-key",3);
  emit(logger,"CConnection","Unexpected release of key code %d",12345);
  EXPECT_TRUE(output.records.empty());
  emit(logger,"CConnection","Authentication success!");
  ASSERT_EQ(output.records.size(),1u); EXPECT_EQ(output.records[0].message,"Authentication success!");
}

TEST(RedactedLogger, LegacyLogWriterDispatchIsInterceptedBeforePrintf) {
  Capture output; viewer::RedactedLogger logger("native-fixture",output);
  // Registry nodes must live until process exit. Detach before stack-owned sinks
  // disappear; no global configure calls or user streams are involved.
  static core::LogWriter writer("TLS");
  struct Detach { core::LogWriter& writer; ~Detach() { writer.setLog(nullptr); } } detach{writer};
  writer.setLog(&logger); writer.setLevel(30);
  writer.debug("TLS handshake completed with %s","not-emitted");
  EXPECT_TRUE(output.records.empty());
  writer.info("TLS handshake completed with %s","private-session");
  writer.error("%s","private-exception");
  ASSERT_EQ(output.records.size(),2u);
  EXPECT_EQ(output.records[0].message,"TLS handshake completed with [redacted]");
  EXPECT_EQ(output.records[0].level,30);
  EXPECT_EQ(output.records[1].message,"Diagnostic details redacted.");
}

TEST(RedactedLogger, ConcurrentCallsSerializeDestinationAndDoNotShareArguments) {
  Capture output; viewer::RedactedLogger logger("native-fixture",output);
  std::vector<std::thread> threads;
  for (int n = 0; n < 6; ++n) threads.emplace_back([&] {
    for (int i = 0; i < 100; ++i) {
      emit(logger,"TLS","TLS handshake completed with %s","private");
      emit(logger,"TcpSocket","Connecting to %s [%s] port %d","private","private",12345);
      logger.write(0,"private-source","private-direct");
    }
  });
  for (auto& thread : threads) thread.join();
  ASSERT_EQ(output.records.size(),1800u);
  size_t tls = 0, tcp = 0, other = 0;
  for (const auto& record : output.records) {
    EXPECT_EQ(record.source.find("private"),std::string::npos);
    EXPECT_EQ(record.message.find("private"),std::string::npos);
    if (record.source == "TLS") ++tls;
    else if (record.source == "TcpSocket") ++tcp;
    else if (record.source == "Core") ++other;
  }
  EXPECT_EQ(tls,600u); EXPECT_EQ(tcp,600u); EXPECT_EQ(other,600u);
}

TEST(RedactedLogger, FileOutputContainsOnlyRedactedRecordsAndNormalFormatting) {
  FILE* file = std::tmpfile(); ASSERT_NE(file,nullptr);
  core::Logger_File output("fixture-file"); output.setFile(file);
  viewer::RedactedLogger logger("native-fixture",output);
  emit(logger,"TLS","Syntax error in GnuTLS priority string: %s","private-path\nforged: secret");
  emit(logger,"CConnection","Reading protocol version");
  const auto text = read(file);
  EXPECT_NE(text.find("TLS:"),std::string::npos);
  EXPECT_NE(text.find("Syntax error in GnuTLS priority string: [redacted]"),std::string::npos);
  EXPECT_NE(text.find("Reading protocol version"),std::string::npos);
  EXPECT_EQ(text.find("private"),std::string::npos); EXPECT_EQ(text.find("forged"),std::string::npos);
  EXPECT_EQ(text.find("secret"),std::string::npos);
}
