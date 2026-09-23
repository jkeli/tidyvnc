/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <tidyvnc.h>
#include <core/LogWriter.h>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <thread>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
extern "C" void abi_test_fail_after(unsigned);
namespace {
// Static registry lifetime; use known core event names for the redaction path.
core::LogWriter tls("TLS"), connection("CConnection");
void checkAt(bool value, int line) { if (!value) throw std::runtime_error("Process logging ABI check failed at line "+std::to_string(line)); }
#define check(value) checkAt((value),__LINE__)
template<class T> T init() { T value{}; value.size=sizeof(T); value.version=TIDYVNC_ABI_VERSION; return value; }
tidyvnc_bytes bytes(const std::string& text) { return {reinterpret_cast<const uint8_t*>(text.data()),text.size()}; }
unsigned descriptors() {
  unsigned count=0; for (int fd=0; fd<1024; ++fd) if (fcntl(fd,F_GETFD)>=0) ++count;
  return count;
}
struct Capture {
  Capture(int target_) : target(target_), saved(fcntl(target,F_DUPFD_CLOEXEC,3)), file(std::tmpfile()) {
    check(saved>=0 && file); check(dup2(fileno(file),target)==target);
  }
  ~Capture() { dup2(saved,target); close(saved); std::fclose(file); }
  std::string read() {
    std::fflush(file); std::rewind(file); char buffer[4096]; std::string text;
    while (const auto n=std::fread(buffer,1,sizeof(buffer),file)) text.append(buffer,n);
    return text;
  }
  int target, saved; FILE* file;
};
void runtime() {
  auto options=init<tidyvnc_runtime_options>(); check(tidyvnc_runtime_options_init(&options,nullptr)==TIDYVNC_OK);
  tidyvnc_handle owner=0; check(tidyvnc_runtime_create(&options,&owner,nullptr)==TIDYVNC_OK);
  check(tidyvnc_runtime_shutdown(owner,nullptr)==TIDYVNC_OK);
  const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
  while (tidyvnc_runtime_poll_drained(owner,nullptr)==TIDYVNC_PENDING) {
    check(std::chrono::steady_clock::now()<deadline); std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  check(tidyvnc_runtime_poll_drained(owner,nullptr)==TIDYVNC_OK);
  check(tidyvnc_release(owner,nullptr)==TIDYVNC_OK);
}
}
int main(int argc,char** argv) {
  try {
    check(argc>=2); const std::string mode=argv[1];
    check(argc==(mode=="file" ? 3 : 2));
    if (mode=="file") {
      auto abi=init<tidyvnc_abi_info>(); check(tidyvnc_get_abi(&abi,nullptr)==TIDYVNC_OK);
      check(abi.features&TIDYVNC_FEATURE_FILE_LOGGING);
      auto error=init<tidyvnc_error>();
      check(tidyvnc_logging_validate(bytes("*:file:100"),nullptr)==TIDYVNC_OK);
      check(tidyvnc_logging_configure_with_file(bytes("*:file:100"),bytes("private-relative-path"),&error)==TIDYVNC_INVALID_ARGUMENT);
      check(error.domain==TIDYVNC_DOMAIN_LOGGING && error.detail==TIDYVNC_LOGGING_INVALID_FILE_PATH);
      check(!std::strstr(error.message,"private"));
      const std::string path=argv[2]; struct stat before{}, after{};
      const bool existed=stat(path.c_str(),&before)==0;
      check(tidyvnc_logging_configure_with_file(bytes("*:file:100"),bytes(path),nullptr)==TIDYVNC_OK);
      check((stat(path.c_str(),&after)==0)==existed);
      if (existed) check(before.st_ino==after.st_ino && before.st_size==after.st_size);
      auto* selectedTLS=core::LogWriter::getLogWriter("TLS"); check(selectedTLS!=nullptr);
      selectedTLS->info("TLS handshake completed with %s","private-session");
      connection.info("Reading protocol version");
      connection.error("%s","private-exception\nforged: line");
      connection.debug("Key pressed: %d => 0x%02x / XK_%s (0x%04x)",1,2,"private-key",3);
      runtime(); // File ownership must continue after the last runtime drains.
      check(tidyvnc_logging_configure_with_file(bytes("*::0"),bytes(path),&error)==TIDYVNC_BUSY);
      check(error.detail==TIDYVNC_LOGGING_FROZEN);
      std::puts("READY"); std::fflush(stdout);
      check(std::getchar()=='\n');
      connection.info("Reading protocol version");
    } else if (mode=="freeze") {
      runtime();
      auto error=init<tidyvnc_error>();
      check(tidyvnc_logging_configure(bytes("*::0"),&error)==TIDYVNC_BUSY);
      check(error.domain==TIDYVNC_DOMAIN_LOGGING && error.detail==TIDYVNC_LOGGING_FROZEN);
      check(tidyvnc_logging_validate(bytes("*:stderr:30"),nullptr)==TIDYVNC_OK);
    } else {
      check(mode=="configure");
      auto* selectedTLS=core::LogWriter::getLogWriter("TLS"); check(selectedTLS!=nullptr);
      auto error=init<tidyvnc_error>();
      check(tidyvnc_logging_validate(bytes("TLS:stdout:100"),nullptr)==TIDYVNC_OK);
      check(tidyvnc_logging_validate(bytes("private-writer:stderr:30"),&error)==TIDYVNC_INVALID_ARGUMENT);
      check(error.domain==TIDYVNC_DOMAIN_LOGGING && error.detail==((1u<<8)|TIDYVNC_LOGGING_UNKNOWN_WRITER));
      check(!std::strstr(error.message,"private"));
      check(tidyvnc_logging_validate(bytes("*:syslog:30"),&error)==TIDYVNC_UNSUPPORTED);
      check(error.detail==((1u<<8)|TIDYVNC_LOGGING_UNKNOWN_TARGET));
      check(tidyvnc_logging_validate({nullptr,1},nullptr)==TIDYVNC_INVALID_ARGUMENT);
      check(tidyvnc_logging_validate(bytes(std::string("*::0\0x",6)),&error)==TIDYVNC_INVALID_ARGUMENT);
      check(error.domain==TIDYVNC_DOMAIN_LOGGING && error.detail==TIDYVNC_LOGGING_NULL_BYTE);
      check(tidyvnc_logging_validate(bytes(std::string(65537,'x')),&error)==TIDYVNC_RESOURCE_LIMIT);
      check(error.domain==TIDYVNC_DOMAIN_LOGGING && error.detail==TIDYVNC_LOGGING_TOO_LARGE);
      Capture errors(STDERR_FILENO), output(STDOUT_FILENO);
      // A failed second destination must close the prepared first destination,
      // leave all writers unchanged and permit a corrected startup attempt.
      const auto before=descriptors(); close(STDOUT_FILENO);
      check(tidyvnc_logging_configure(bytes("*:stderr:100,TLS:stdout:100"),nullptr)==TIDYVNC_FAILED);
      check(fcntl(STDOUT_FILENO,F_GETFD)<0); check(descriptors()==before-1);
      check(dup2(fileno(output.file),STDOUT_FILENO)==STDOUT_FILENO);
      check(tls.getLevel()==0 && connection.getLevel()==0);
      const std::string policy="*:stderr:100,TLS:stdout:100";
      unsigned failed=0; bool configured=false;
      for (unsigned n=1; n<=512; ++n) {
        abi_test_fail_after(n);
        const auto status=tidyvnc_logging_configure(bytes(policy),nullptr);
        abi_test_fail_after(0);
        if (status==TIDYVNC_OK) { configured=true; break; }
        check(status==TIDYVNC_OUT_OF_MEMORY); ++failed;
        check(descriptors()==before); check(tls.getLevel()==0 && connection.getLevel()==0);
      }
      check(configured && failed>5); check(descriptors()==before+2);
      // Original stdout can close independently; the owned destination remains.
      close(STDOUT_FILENO);
      selectedTLS->info("TLS handshake completed with %s","private-session");
      check(dup2(fileno(output.file),STDOUT_FILENO)==STDOUT_FILENO);
      connection.info("Reading protocol version");
      connection.error("%s","private-exception\nforged: line");
      connection.debug("Key pressed: %d => 0x%02x / XK_%s (0x%04x)",1,2,"private-key",3);
      check(tidyvnc_logging_configure(bytes("*::0"),&error)==TIDYVNC_BUSY);
      check(error.domain==TIDYVNC_DOMAIN_LOGGING && error.detail==TIDYVNC_LOGGING_FROZEN);
      runtime(); check(tidyvnc_logging_configure(bytes("*::0"),nullptr)==TIDYVNC_BUSY);
      auto abi = init<tidyvnc_abi_info>();
      check(tidyvnc_get_abi(&abi,nullptr)==TIDYVNC_OK && (abi.features & TIDYVNC_FEATURE_VIEWPORT_DIAGNOSTICS));
      check(tidyvnc_logging_viewport(0,480,1280,960,nullptr)==TIDYVNC_INVALID_ARGUMENT);
      check(tidyvnc_logging_viewport(640,480,UINT32_MAX,960,nullptr)==TIDYVNC_INVALID_ARGUMENT);
      check(tidyvnc_logging_viewport(640,480,1280,960,nullptr)==TIDYVNC_OK);
      const auto a=errors.read(), b=output.read();
      check(a.find("Viewport logical 640x480, backing 1280x960")!=std::string::npos);
      check(a.find("Reading protocol version")!=std::string::npos);
      check(a.find("Diagnostic details redacted.")!=std::string::npos);
      check(a.find("Key pressed")==std::string::npos);
      check(b.find("TLS handshake completed with [redacted]")!=std::string::npos);
      check(a.find("private")==std::string::npos && b.find("private")==std::string::npos);
      check(a.find("forged")==std::string::npos);
    }
    std::puts("PASS process logging ownership and ABI"); return 0;
  } catch (const std::exception& error) {
    abi_test_fail_after(0); std::fprintf(stderr,"FAIL %s\n",error.what()); return 1;
  }
}
