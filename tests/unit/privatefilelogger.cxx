/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/platform/PrivateFileLogger.h>
#include <viewer/core/RedactedLogger.h>
#include <cstdio>
#include <cstdarg>
#include <filesystem>
#include <fstream>
#include <thread>
#include <vector>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/acl.h>
#include <membership.h>
#endif
namespace {
struct Directory {
  Directory() {
    std::string pattern=(std::filesystem::temp_directory_path()/"tidyvnc-private-log-XXXXXX").string();
    std::vector<char> bytes(pattern.begin(),pattern.end()); bytes.push_back(0);
    if (!mkdtemp(bytes.data())) throw std::runtime_error("Private log fixture directory failed");
    path=bytes.data();
  }
  ~Directory() { std::error_code error; std::filesystem::remove_all(path,error); }
  std::filesystem::path path;
};
struct Capture {
  Capture() : saved(fcntl(STDERR_FILENO,F_DUPFD_CLOEXEC,3)), file(std::tmpfile()) {
    if (saved<0 || !file || dup2(fileno(file),STDERR_FILENO)<0) throw std::runtime_error("Capture failed");
  }
  ~Capture() { dup2(saved,STDERR_FILENO); close(saved); std::fclose(file); }
  std::string read() {
    std::fflush(file); std::rewind(file); char buffer[4096]; std::string value;
    while (const auto size=std::fread(buffer,1,sizeof(buffer),file)) value.append(buffer,size);
    return value;
  }
  int saved; FILE* file;
};
std::string read(const std::filesystem::path& path) {
  std::ifstream file(path); return std::string(std::istreambuf_iterator<char>(file),{});
}
void emit(core::Logger& logger,const char* format,...) {
  va_list args; va_start(args,format); logger.write(30,"CConnection",format,args); va_end(args);
}
void noTemporaries(const std::filesystem::path& directory) {
  for (const auto& item:std::filesystem::directory_iterator(directory))
    EXPECT_NE(item.path().filename().string().find(".tidyvnc-log-"),0u);
}
void privateFile(const std::filesystem::path& path) {
  struct stat info{}; ASSERT_EQ(lstat(path.c_str(),&info),0);
  EXPECT_TRUE(S_ISREG(info.st_mode)); EXPECT_EQ(info.st_uid,geteuid());
  EXPECT_EQ(info.st_mode&0777,0600); EXPECT_EQ(info.st_nlink,1u);
#ifdef __APPLE__
  acl_t acl=acl_get_file(path.c_str(),ACL_TYPE_EXTENDED);
  if (acl) {
    acl_entry_t entry; EXPECT_EQ(acl_get_entry(acl,ACL_FIRST_ENTRY,&entry),-1); EXPECT_EQ(errno,EINVAL);
    acl_free(acl);
  } else EXPECT_EQ(errno,ENOENT);
#endif
}
}

TEST(PrivateFileLogger, LazyRedactedCreationAndBackupPreserveExistingBytes) {
  Directory directory; const auto path=directory.path/"秘密.log";
  const auto backup=path.string()+".bak";
  { std::ofstream(path)<<"previous log"; std::ofstream(backup)<<"previous backup"; }
  {
    viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture",raw);
    EXPECT_EQ(read(path),"previous log"); EXPECT_EQ(read(backup),"previous backup");
    EXPECT_FALSE(std::filesystem::exists(path.string()+".lock"));
    emit(logger,"Reading protocol version"); emit(logger,"%s","private-endpoint\nforged: secret");
    EXPECT_EQ(read(backup),"previous log");
    const auto current=read(path);
    EXPECT_NE(current.find("Reading protocol version"),std::string::npos);
    EXPECT_NE(current.find("Diagnostic details redacted."),std::string::npos);
    EXPECT_EQ(current.find("private"),std::string::npos); EXPECT_EQ(current.find("forged"),std::string::npos);
    privateFile(path); privateFile(backup); privateFile(path.string()+".lock");
    noTemporaries(directory.path);
  }
  const auto previous=read(path);
  { viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture",raw); emit(logger,"Initialisation done"); }
  EXPECT_EQ(read(backup),previous); EXPECT_NE(read(path).find("Initialisation done"),std::string::npos);
}

TEST(PrivateFileLogger, SuppressedEventsAndUnusedSinksNeverTouchTheFilesystem) {
  Directory directory; const auto path=directory.path/"viewer.log";
  { viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture",raw);
    emit(logger,"Key pressed: %d => 0x%02x / XK_%s (0x%04x)",1,2,"private-key",3); }
  EXPECT_TRUE(std::filesystem::is_empty(directory.path));
}

TEST(PrivateFileLogger, UnsafeLeavesArePreservedAndFallbackWarnsOnceWithoutPaths) {
  for (const auto* suffix : {"",".bak",".lock"}) for (int kind=0;kind<3;++kind) {
    Directory directory; Capture capture; const auto path=directory.path/"private-path.log";
    const auto unsafe=path.string()+suffix;
    const auto victim=directory.path/"victim";
    { std::ofstream(victim)<<"unrelated original"; }
    if (kind==0) ASSERT_EQ(symlink(victim.c_str(),unsafe.c_str()),0);
    else if (kind==1) ASSERT_EQ(link(victim.c_str(),unsafe.c_str()),0);
    else ASSERT_EQ(mkfifo(unsafe.c_str(),0600),0);
    {
      viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture",raw);
      emit(logger,"Reading protocol version"); emit(logger,"%s","private-value");
      const auto text=capture.read();
      const std::string warning="File logging is unavailable; using standard error.";
      const auto first=text.find(warning); ASSERT_NE(first,std::string::npos);
      EXPECT_EQ(text.find(warning,first+1),std::string::npos);
      EXPECT_NE(text.find("Reading protocol version"),std::string::npos);
      EXPECT_EQ(text.find("private"),std::string::npos);
    }
    EXPECT_EQ(read(victim),"unrelated original");
    struct stat info{}; ASSERT_EQ(lstat(unsafe.c_str(),&info),0);
    if (kind==0) EXPECT_TRUE(S_ISLNK(info.st_mode));
    else if (kind==1) EXPECT_EQ(info.st_nlink,2u);
    else EXPECT_TRUE(S_ISFIFO(info.st_mode));
    noTemporaries(directory.path);
  }
}

TEST(PrivateFileLogger, CooperativeOwnersCannotRotateAnActiveLog) {
  Directory directory; Capture capture; const auto path=directory.path/"viewer.log";
  viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger first("first",raw);
  emit(first,"Reading protocol version"); const auto before=read(path);
  { viewer::PrivateFileLogger otherRaw(path.string()); viewer::RedactedLogger other("second",otherRaw);
    emit(other,"Initialisation done"); }
  EXPECT_EQ(read(path),before); EXPECT_FALSE(std::filesystem::exists(path.string()+".bak"));
  EXPECT_NE(capture.read().find("File logging is unavailable"),std::string::npos);
  emit(first,"Initialisation done"); EXPECT_NE(read(path).find("Initialisation done"),std::string::npos);
}

TEST(PrivateFileLogger, ConcurrentFirstWritesCreateOnePrivateDestination) {
  Directory directory; const auto path=directory.path/"viewer.log";
  viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture",raw);
  std::vector<std::thread> threads;
  for (int worker=0;worker<6;++worker) threads.emplace_back([&] {
    for (int i=0;i<100;++i) emit(logger,"Reading protocol version");
  });
  for (auto& thread:threads) thread.join();
  const auto text=read(path); const std::string record="Reading protocol version";
  size_t count=0,position=0;
  while ((position=text.find(record,position))!=std::string::npos) { ++count; position+=record.size(); }
  EXPECT_EQ(count,600u); EXPECT_FALSE(std::filesystem::exists(path.string()+".bak"));
  privateFile(path); noTemporaries(directory.path);
}

TEST(PrivateFileLogger, OutputFailureFallsBackAndRetainsTheFailedRecord) {
  Directory directory; Capture capture; const auto path=directory.path/"viewer.log";
  viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture",raw);
  emit(logger,"Reading protocol version");
  struct stat fileInfo{}; ASSERT_EQ(stat(path.c_str(),&fileInfo),0);
  int output=-1;
  for (int fd=3;fd<1024;++fd) {
    struct stat info{};
    if (fstat(fd,&info)==0 && info.st_dev==fileInfo.st_dev && info.st_ino==fileInfo.st_ino &&
        (fcntl(fd,F_GETFL)&O_ACCMODE)==O_WRONLY) { output=fd; break; }
  }
  ASSERT_GE(output,3); EXPECT_NE(fcntl(output,F_GETFD)&FD_CLOEXEC,0);
  // Invalidate only this fixture's owned output descriptor to exercise a real
  // fflush/ferror failure without filling a disk or changing process limits.
  ASSERT_EQ(close(output),0); emit(logger,"Initialisation done");
  const auto text=capture.read();
  EXPECT_NE(text.find("File logging is unavailable"),std::string::npos);
  EXPECT_NE(text.find("Initialisation done"),std::string::npos);
  EXPECT_EQ(read(path).find("Initialisation done"),std::string::npos);
}

TEST(PrivateFileLogger, InvalidPathsAndUnsafeDirectoriesDoNotCreateLogs) {
  for (const auto& path:std::vector<std::string>{"","relative","/","/tmp/.","/tmp/..",std::string("/tmp/a\0b",8),"/"+std::string(PATH_MAX,'a')})
    EXPECT_THROW(viewer::PrivateFileLogger{path},viewer::LogFilePathError);
  Directory directory; Capture capture; const auto path=directory.path/"viewer.log";
  ASSERT_EQ(chmod(directory.path.c_str(),0777),0);
  { viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture",raw); emit(logger,"Reading protocol version"); }
  EXPECT_FALSE(std::filesystem::exists(path)); EXPECT_TRUE(std::filesystem::is_empty(directory.path));
  EXPECT_NE(capture.read().find("File logging is unavailable"),std::string::npos);
  ASSERT_EQ(chmod(directory.path.c_str(),0700),0);
}

TEST(PrivateFileLogger, FileAndLockNeverOccupyClosedStandardDescriptors) {
  Directory directory; const auto path=directory.path/"viewer.log";
  const int saved=fcntl(STDOUT_FILENO,F_DUPFD_CLOEXEC,3); ASSERT_GE(saved,3);
  ASSERT_EQ(close(STDOUT_FILENO),0);
  {
    viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture",raw);
    emit(logger,"Reading protocol version");
    const int flags=fcntl(STDOUT_FILENO,F_GETFD);
    // Restore before test reporting and before the sink is destroyed, so an
    // accidental fd 1 owner would also be detected by the following check.
    ASSERT_EQ(dup2(saved,STDOUT_FILENO),STDOUT_FILENO);
    EXPECT_EQ(flags,-1);
  }
  EXPECT_GE(fcntl(STDOUT_FILENO,F_GETFD),0); close(saved);
  EXPECT_NE(read(path).find("Reading protocol version"),std::string::npos);
}

#ifdef __APPLE__
TEST(PrivateFileLogger, ExtendedDirectoryACLIsRejectedBeforeCreation) {
  Directory directory; Capture capture;
  acl_t acl=acl_init(1); ASSERT_NE(acl,nullptr);
  acl_entry_t entry; ASSERT_EQ(acl_create_entry(&acl,&entry),0);
  ASSERT_EQ(acl_set_tag_type(entry,ACL_EXTENDED_ALLOW),0);
  uuid_t owner; ASSERT_EQ(mbr_uid_to_uuid(geteuid(),owner),0);
  ASSERT_EQ(acl_set_qualifier(entry,owner),0);
  acl_permset_t permissions; ASSERT_EQ(acl_get_permset(entry,&permissions),0);
  ASSERT_EQ(acl_add_perm(permissions,ACL_READ_DATA),0);
  acl_flagset_t flags; ASSERT_EQ(acl_get_flagset_np(entry,&flags),0);
  ASSERT_EQ(acl_add_flag_np(flags,ACL_ENTRY_FILE_INHERIT),0);
  const int applied=acl_set_file(directory.path.c_str(),ACL_TYPE_EXTENDED,acl);
  acl_free(acl); ASSERT_EQ(applied,0);
  {
    viewer::PrivateFileLogger raw((directory.path/"viewer.log").string());
    viewer::RedactedLogger logger("fixture",raw); emit(logger,"Reading protocol version");
  }
  EXPECT_TRUE(std::filesystem::is_empty(directory.path));
  EXPECT_NE(capture.read().find("File logging is unavailable"),std::string::npos);
}
#endif

TEST(PrivateFileLogger, ExistingBackupWithoutALogKeepsItsBytesPrivately) {
  Directory directory; const auto path=directory.path/"viewer.log";
  const auto backup=path.string()+".bak";
  { std::ofstream file(backup); file << "previous diagnostic bytes"; }
  ASSERT_EQ(chmod(backup.c_str(),0644),0);
  {
    viewer::PrivateFileLogger raw(path.string()); viewer::RedactedLogger logger("fixture",raw);
    emit(logger,"Reading protocol version");
  }
  EXPECT_EQ(read(backup),"previous diagnostic bytes"); privateFile(backup); privateFile(path);
  noTemporaries(directory.path);
}
