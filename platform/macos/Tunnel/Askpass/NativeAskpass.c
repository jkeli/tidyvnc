/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#define __STDC_WANT_LIB_EXT1__ 1
#include "NativeAskpass.h"
#include <sys/acl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct tidy_askpass_server {
  pthread_mutex_t lock;
  int listening, peer, directory, cancelled;
  unsigned requests;
  dev_t device;
  ino_t inode;
};
static int64_t milliseconds(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC,&t)) return 0;
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int wait_ready(int fd, short events, int64_t deadline) {
  for (;;) {
    int64_t remaining = deadline - milliseconds();
    if (remaining <= 0) return 0;
    struct pollfd p = {fd,events,0};
    int r = poll(&p,1,(int)(remaining > 100 ? 100 : remaining));
    if (r < 0 && errno == EINTR) continue;
    if (r < 0) return 0;
    if (r && (p.revents & events)) return 1;
    if (r && (p.revents & (POLLERR | POLLHUP | POLLNVAL))) return 0;
  }
}
static int transfer(int fd, void *bytes, size_t count, int writing, int64_t deadline) {
  size_t offset = 0;
  while (offset < count) {
    if (!wait_ready(fd,writing ? POLLOUT : POLLIN,deadline)) return 0;
    ssize_t n = writing ? send(fd,(char*)bytes+offset,count-offset,0) : recv(fd,(char*)bytes+offset,count-offset,0);
    if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
    if (n <= 0) return 0;
    offset += (size_t)n;
  }
  return 1;
}
static int socket_flags(int fd) {
  int yes = 1, flags = fcntl(fd,F_GETFL);
  return flags >= 0 && fcntl(fd,F_SETFL,flags | O_NONBLOCK) == 0 &&
    fcntl(fd,F_SETFD,FD_CLOEXEC) == 0 && setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes)) == 0;
}
static int private_directory(const char *path) {
  struct stat info;
  if (!path || path[0] != '/' || lstat(path,&info) || !S_ISDIR(info.st_mode) ||
      info.st_uid != geteuid() || (info.st_mode & 0777) != 0700) return -1;
  int fd = open(path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  struct stat actual;
  if (fd >= 0 && (!fstat(fd,&actual)) && actual.st_dev == info.st_dev && actual.st_ino == info.st_ino) {
    acl_t acl = acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
    acl_entry_t entry;
    /* Darwin represents an absent extended ACL as NULL/ENOENT. */
    int empty = acl ? acl_get_entry(acl,ACL_FIRST_ENTRY,&entry) == -1 && errno == EINVAL : errno == ENOENT;
    if (acl) acl_free(acl);
    if (empty) return fd;
  }
  if (fd >= 0) close(fd);
  return -1;
}
static int same_user(int fd) {
  uid_t uid; gid_t gid;
  return getpeereid(fd,&uid,&gid) == 0 && uid == geteuid();
}
static int cancelled(tidy_askpass_server *s) {
  pthread_mutex_lock(&s->lock); int value = s->cancelled; pthread_mutex_unlock(&s->lock); return value;
}
static void close_peer(tidy_askpass_server *s) {
  pthread_mutex_lock(&s->lock);
  if (s->peer >= 0) { close(s->peer); s->peer = -1; }
  pthread_mutex_unlock(&s->lock);
}
tidy_askpass_server *tidy_askpass_open(const char *directory) {
  struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
  if (!directory || strlen(directory) + 9 > sizeof(address.sun_path)) return NULL;
  int parent = private_directory(directory);
  if (parent < 0) return NULL;
  strcpy(address.sun_path,directory); strcat(address.sun_path,"/askpass");
  int fd = socket(AF_UNIX,SOCK_STREAM,0);
  if (fd < 0) { close(parent); return NULL; }
  if (!socket_flags(fd) || bind(fd,(struct sockaddr*)&address,sizeof(address))) { close(fd); close(parent); return NULL; }
  struct stat info;
  if (fstatat(parent,"askpass",&info,AT_SYMLINK_NOFOLLOW)) { close(fd); close(parent); return NULL; }
  tidy_askpass_server *s = calloc(1,sizeof(*s));
  if (!s) { unlinkat(parent,"askpass",0); close(fd); close(parent); return NULL; }
  pthread_mutex_init(&s->lock,NULL);
  s->listening = fd; s->peer = -1; s->directory = parent; s->device = info.st_dev; s->inode = info.st_ino;
  if (fchmodat(parent,"askpass",0600,0) || listen(fd,4)) { tidy_askpass_destroy(s); return NULL; }
  return s;
}
int tidy_askpass_receive(tidy_askpass_server *s, uint8_t *kind, uint8_t *text, uint32_t *length) {
  if (!s || !kind || !text || !length || s->peer >= 0 || s->requests >= 32) return -1;
  *length = 0;
  while (!cancelled(s)) {
    struct pollfd p = {s->listening,POLLIN,0};
    int result = poll(&p,1,100);
    if (result < 0 && errno == EINTR) continue;
    if (result < 0 || (p.revents & (POLLERR | POLLHUP | POLLNVAL))) return -1;
    if (!(p.revents & POLLIN)) continue;
    int peer = accept(s->listening,NULL,NULL);
    if (peer < 0) { if (errno == EINTR || errno == EAGAIN) continue; return -1; }
    s->requests++;
    pthread_mutex_lock(&s->lock); s->peer = peer;
    if (s->cancelled) shutdown(peer,SHUT_RDWR);
    pthread_mutex_unlock(&s->lock);
    uint8_t header[8]; int64_t deadline = milliseconds() + 2000;
    if (!socket_flags(peer) || !same_user(peer) || !transfer(peer,header,sizeof(header),0,deadline) ||
        memcmp(header,"TASK\1",5) || header[5] < 1 || header[5] > 4) { close_peer(s); return 0; }
    unsigned count = ((unsigned)header[6] << 8) | header[7];
    if (!count || count > TIDY_ASKPASS_PROMPT_LIMIT || !transfer(peer,text,count,0,deadline) || memchr(text,0,count)) {
      close_peer(s); return 0;
    }
    *kind = header[5]; *length = count; return 1;
  }
  return -1;
}
int tidy_askpass_peer_alive(tidy_askpass_server *s) {
  if (!s || cancelled(s) || s->peer < 0) return 0;
  uint8_t byte;
  ssize_t result = recv(s->peer,&byte,1,MSG_PEEK | MSG_DONTWAIT);
  /* No pipelining or unsolicited bytes are accepted while a reply is pending. */
  return result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR);
}
int tidy_askpass_reply(tidy_askpass_server *s, const uint8_t *bytes, uint32_t length, int accepted) {
  if (!s || s->peer < 0) return 0;
  if (length > TIDY_ASKPASS_REPLY_LIMIT || (length && (!bytes || memchr(bytes,0,length) || memchr(bytes,'\n',length) || memchr(bytes,'\r',length)))) accepted = 0;
  if (!accepted) length = 0;
  uint8_t header[8] = {'T','A','N','S',1,accepted ? 1 : 0,(uint8_t)(length >> 8),(uint8_t)length};
  int64_t deadline = milliseconds() + 2000;
  int result = !cancelled(s) && transfer(s->peer,header,sizeof(header),1,deadline) &&
    (!length || transfer(s->peer,(void*)bytes,length,1,deadline));
  close_peer(s); return result;
}
void tidy_askpass_cancel(tidy_askpass_server *s) {
  if (!s) return;
  pthread_mutex_lock(&s->lock); s->cancelled = 1;
  if (s->listening >= 0) shutdown(s->listening,SHUT_RDWR);
  if (s->peer >= 0) shutdown(s->peer,SHUT_RDWR);
  pthread_mutex_unlock(&s->lock);
}
void tidy_askpass_destroy(tidy_askpass_server *s) {
  if (!s) return;
  tidy_askpass_cancel(s); close_peer(s); close(s->listening);
  struct stat info;
  if (fstatat(s->directory,"askpass",&info,AT_SYMLINK_NOFOLLOW) == 0 && S_ISSOCK(info.st_mode) &&
      info.st_dev == s->device && info.st_ino == s->inode) unlinkat(s->directory,"askpass",0);
  close(s->directory); pthread_mutex_destroy(&s->lock); free(s);
}
int tidy_askpass_main(int argc, char **argv) {
  uint8_t response[TIDY_ASKPASS_REPLY_LIMIT+1] = {0}, header[8];
  char metadata[TIDY_ASKPASS_PROMPT_LIMIT+1];
  const char *prompt = argc == 2 ? argv[1] : NULL;
  int hostkey = argc == 6 && !strcmp(argv[1],"--host-key");
  if (hostkey) {
    /* Observe keys only; emit no known_hosts entries and never decide trust. */
    if (!strcmp(argv[2],"ORDER") || !strcmp(argv[2],"ADDRESS")) return 0;
    if (strcmp(argv[2],"HOSTNAME")) return 1;
    size_t used = 0;
    for (int i = 3; i < 6; i++) {
      size_t n = strnlen(argv[i],TIDY_ASKPASS_PROMPT_LIMIT+1);
      if (!n || used+n+1 > sizeof(metadata) || memchr(argv[i],'\n',n) || memchr(argv[i],'\r',n)) return 1;
      memcpy(metadata+used,argv[i],n); used += n;
      metadata[used++] = i == 5 ? 0 : '\n';
    }
    prompt = metadata;
  }
  int status = 1, fd = -1, parent = -1;
  const char *path = getenv("TIDYVNC_ASKPASS_SOCKET"), *hint = getenv("SSH_ASKPASS_PROMPT");
  struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
  if (!prompt || !path || path[0] != '/' || strnlen(path,sizeof(address.sun_path)) >= sizeof(address.sun_path)) goto done;
  size_t length = strnlen(prompt,TIDY_ASKPASS_PROMPT_LIMIT+1);
  if (!length || length > TIDY_ASKPASS_PROMPT_LIMIT) goto done;
  char directory[sizeof(address.sun_path)]; strcpy(directory,path);
  char *leaf = strrchr(directory,'/');
  if (!leaf || strcmp(leaf,"/askpass")) goto done;
  *leaf = 0; parent = private_directory(directory); if (parent < 0) goto done;
  struct stat info;
  if (fstatat(parent,"askpass",&info,AT_SYMLINK_NOFOLLOW) || !S_ISSOCK(info.st_mode) ||
      info.st_uid != geteuid() || (info.st_mode & 0777) != 0600) goto done;
  fd = socket(AF_UNIX,SOCK_STREAM,0);
  if (fd < 0 || !socket_flags(fd)) goto done;
  strcpy(address.sun_path,path);
  if (connect(fd,(struct sockaddr*)&address,sizeof(address)) && errno != EINPROGRESS) goto done;
  if (!wait_ready(fd,POLLOUT,milliseconds()+2000) || !same_user(fd)) goto done;
  unsigned kind = hostkey ? 4 : hint && !strcmp(hint,"confirm") ? 2 : hint && !strcmp(hint,"none") ? 3 : 1;
  if (!hostkey && hint && strcmp(hint,"confirm") && strcmp(hint,"none")) goto done;
  uint8_t request[8] = {'T','A','S','K',1,(uint8_t)kind,(uint8_t)(length >> 8),(uint8_t)length};
  if (!transfer(fd,request,sizeof(request),1,milliseconds()+2000) || !transfer(fd,(void*)prompt,length,1,milliseconds()+2000)) goto done;
  if (!transfer(fd,header,sizeof(header),0,milliseconds()+300000) || memcmp(header,"TANS\1\1",6)) goto done;
  length = ((unsigned)header[6] << 8) | header[7];
  if (hostkey) { if (length == 0) status = 0; goto done; }
  if (length > TIDY_ASKPASS_REPLY_LIMIT || !transfer(fd,response,length,0,milliseconds()+2000) ||
      memchr(response,0,length) || memchr(response,'\r',length) || memchr(response,'\n',length)) goto done;
  response[length++] = '\n';
  /* One bounded line, only to SSH's askpass pipe. Never stderr/logs/files. */
  if (write(STDOUT_FILENO,response,length) != (ssize_t)length) goto done;
  status = 0;
done:
  (void)memset_s(response,sizeof(response),0,sizeof(response));
  if (fd >= 0) close(fd);
  if (parent >= 0) close(parent);
  return status;
}
