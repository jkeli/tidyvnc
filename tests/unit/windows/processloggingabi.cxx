/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Windows counterpart of tests/unit/processloggingabi.cxx. Same modes and
// redaction checks; descriptor checks use the CRT's _get_osfhandle. One
// deliberate difference (plans/native-ui-winui CORE.md section 4): a GUI
// process may have no standard output, so a stdio route without a valid
// descriptor discards output instead of failing the configuration.
#include <tidyvnc.h>
#include <core/LogWriter.h>
#include <windows.h>
#include <io.h>
#include <crtdbg.h>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <thread>
extern "C" void abi_test_fail_after(unsigned);
extern "C" int abi_test_injection_enabled(void);
namespace {
core::LogWriter tls("TLS"), connection("CConnection");
void checkAt(bool value, int line) { if (!value) throw std::runtime_error("Process logging ABI check failed at line "+std::to_string(line)); }
#define check(value) checkAt((value),__LINE__)
template<class T> T init() { T value{}; value.size=sizeof(T); value.version=TIDYVNC_ABI_VERSION; return value; }
tidyvnc_bytes bytes(const std::string& text) { return {reinterpret_cast<const uint8_t*>(text.data()),text.size()}; }
void ignoreInvalidParameter(const wchar_t*,const wchar_t*,const wchar_t*,unsigned,uintptr_t) {}
// Probing closed descriptors is an invalid parameter for the CRT; ignore it here.
bool open(int fd) {
  const auto previous=_set_thread_local_invalid_parameter_handler(ignoreInvalidParameter);
  const intptr_t handle=_get_osfhandle(fd);
  _set_thread_local_invalid_parameter_handler(previous);
  return handle!=-1 && handle!=-2;
}
unsigned descriptors() { unsigned count=0; for (int fd=0; fd<2048; ++fd) if (open(fd)) ++count; return count; }
struct Capture {
  explicit Capture(int target_) : target(target_), saved(_dup(target_)), file(std::tmpfile()) {
    check(saved>=0 && file); std::fflush(target==1 ? stdout : stderr); check(_dup2(_fileno(file),target)==0);
  }
  ~Capture() { std::fflush(target==1 ? stdout : stderr); _dup2(saved,target); _close(saved); std::fclose(file); }
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
  _CrtSetReportMode(_CRT_ASSERT,0); // Descriptor probes below are expected to fail.
  try {
    check(argc>=2); const std::string mode=argv[1];
    check(argc==(mode=="file" ? 3 : 2));
    if (mode=="file") {
      auto abi=init<tidyvnc_abi_info>(); check(tidyvnc_get_abi(&abi,nullptr)==TIDYVNC_OK);
      check(abi.features&TIDYVNC_FEATURE_FILE_LOGGING);
      auto error=init<tidyvnc_error>();
      check(tidyvnc_logging_validate(bytes("*:file:100"),nullptr)==TIDYVNC_OK);
      for (const char* invalid : {"private-relative-path", "\\private-rooted", "C:private-drive-relative", "/private-posix"}) {
        check(tidyvnc_logging_configure_with_file(bytes("*:file:100"),bytes(invalid),&error)==TIDYVNC_INVALID_ARGUMENT);
        check(error.domain==TIDYVNC_DOMAIN_LOGGING && error.detail==TIDYVNC_LOGGING_INVALID_FILE_PATH);
        check(!std::strstr(error.message,"private"));
      }
      const std::string path=argv[2]; struct _stat64 before{}, after{};
      const bool existed=_stat64(path.c_str(),&before)==0;
      check(tidyvnc_logging_configure_with_file(bytes("*:file:100"),bytes(path),nullptr)==TIDYVNC_OK);
      check((_stat64(path.c_str(),&after)==0)==existed);          // Lazy: nothing touched yet.
      if (existed) check(before.st_size==after.st_size && before.st_mtime==after.st_mtime);
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
    } else if (mode=="default") {
      // The retained FLTK default: %TMP%, %TEMP%, then %USERPROFILE%.
      auto error=init<tidyvnc_error>();
      check(tidyvnc_logging_configure(bytes("*:file:30"),&error)==TIDYVNC_OK);
    } else if (mode=="nostdio") {
      // A GUI-subsystem process has no standard handles: stdio routes are
      // accepted and discard their output rather than failing startup.
      std::fflush(stdout); std::fflush(stderr); _close(1); _close(2);
      check(tidyvnc_logging_configure(bytes("*:stderr:100,TLS:stdout:100"),nullptr)==TIDYVNC_OK);
      connection.info("Reading protocol version");
      tls.info("TLS handshake completed with %s","private-session");
      runtime();
      return 0; // Nothing can be printed; the exit code is the result.
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
      Capture errors(2), output(1);
      const auto before=descriptors();
      const std::string policy="*:stderr:100,TLS:stdout:100";
      unsigned failed=0; bool configured=false;
      for (unsigned n=1; n<=512 && abi_test_injection_enabled(); ++n) {
        abi_test_fail_after(n);
        const auto status=tidyvnc_logging_configure(bytes(policy),nullptr);
        abi_test_fail_after(0);
        if (status==TIDYVNC_OK) { configured=true; break; }
        check(status==TIDYVNC_OUT_OF_MEMORY); ++failed;
        check(descriptors()==before); check(tls.getLevel()==0 && connection.getLevel()==0);
      }
      if (!configured) check(tidyvnc_logging_configure(bytes(policy),nullptr)==TIDYVNC_OK);
      check(!abi_test_injection_enabled() || failed>5);
      check(descriptors()==before+2); // Each stdio route owns a duplicate.
      // Original stdout can close independently; the owned destination remains.
      _close(1);
      selectedTLS->info("TLS handshake completed with %s","private-session");
      check(_dup2(_fileno(output.file),1)==0);
      connection.info("Reading protocol version");
      connection.error("%s","private-exception\nforged: line");
      connection.debug("Key pressed: %d => 0x%02x / XK_%s (0x%04x)",1,2,"private-key",3);
      check(tidyvnc_logging_configure(bytes("*::0"),&error)==TIDYVNC_BUSY);
      check(error.domain==TIDYVNC_DOMAIN_LOGGING && error.detail==TIDYVNC_LOGGING_FROZEN);
      runtime(); check(tidyvnc_logging_configure(bytes("*::0"),nullptr)==TIDYVNC_BUSY);
      auto abi = init<tidyvnc_abi_info>();
      check(tidyvnc_get_abi(&abi,nullptr)==TIDYVNC_OK && (abi.features & TIDYVNC_FEATURE_VIEWPORT_DIAGNOSTICS));
      check(tidyvnc_logging_viewport(0,480,1280,960,nullptr)==TIDYVNC_INVALID_ARGUMENT);
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
    std::puts("PASS process logging ownership and ABI"); std::fflush(stdout); return 0;
  } catch (const std::exception& error) {
    abi_test_fail_after(0); std::fprintf(stderr,"FAIL %s\n",error.what()); return 1;
  }
}
