/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
/* Private process fixture: a control master, forwarding acknowledgement and
 * an actual Unix-to-loopback relay. No SSH/user configuration is accessed. */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static int local_socket(const char* path, int listening) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
  if (fd < 0 || strlen(path) >= sizeof(address.sun_path)) exit(81);
  strcpy(address.sun_path,path);
  if (listening) {
    if (bind(fd,(struct sockaddr*)&address,sizeof(address)) || chmod(path,0600) || listen(fd,4)) exit(82);
  } else if (connect(fd,(struct sockaddr*)&address,sizeof(address))) exit(83);
  return fd;
}
static void relay(int incoming, int port) {
  int remote = socket(AF_INET,SOCK_STREAM,0);
  struct sockaddr_in address = {0}; address.sin_family = AF_INET;
  address.sin_port = htons((unsigned short)port); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (remote < 0 || connect(remote,(struct sockaddr*)&address,sizeof(address))) _exit(84);
  for (;;) {
    struct pollfd sockets[2] = {{incoming,POLLIN,0},{remote,POLLIN,0}};
    if (poll(sockets,2,10000) <= 0) _exit(0);
    for (int i = 0; i < 2; ++i) if (sockets[i].revents) {
      char bytes[8192]; ssize_t count = read(sockets[i].fd,bytes,sizeof(bytes));
      if (count <= 0) _exit(0);
      ssize_t offset = 0;
      while (offset < count) {
        ssize_t sent = write(sockets[1-i].fd,bytes+offset,(size_t)(count-offset));
        if (sent <= 0) _exit(0); offset += sent;
      }
    }
  }
}
int main(int argc, char** argv) {
  if (argc == 3 && (!strcmp(argv[1],"--output") || !strcmp(argv[1],"--output-stderr"))) {
    if (!strcmp(argv[1],"--output-stderr") && dup2(2,1) < 0) return 1;
    if (!strcmp(argv[2],"hang")) { signal(SIGTERM,SIG_IGN); for (;;) pause(); }
    if (!strcmp(argv[2],"descendant")) {
      if (fork() == 0) { signal(SIGTERM,SIG_IGN); for (;;) pause(); }
      return 0;
    }
    int blocks = !strcmp(argv[2],"large") ? 256 : !strcmp(argv[2],"exact") ? 16 : 0;
    char bytes[4096]; memset(bytes,'x',sizeof(bytes));
    if (blocks) { for (int i = 0; i < blocks; ++i) if (write(1,bytes,sizeof(bytes)) != sizeof(bytes)) return 1; return 0; }
    const char* message = !strcmp(argv[2],"save-failure") ?
      "Failed to add the host to the list of known hosts (private-fixture-path).\r\n" :
      "hostname gateway.invalid\nuser fixture\nport 2222\n";
    for (const char* c = message; *c; ++c) if (write(1,c,1) != 1) return 1;
    return 0;
  }
  if (argc == 3 && !strcmp(argv[1],"--descriptors")) {
    errno = 0;
    return getpgrp() == getpid() && fcntl(atoi(argv[2]),F_GETFD) == -1 && errno == EBADF ? 0 : 79;
  }
  if (argc < 5) return 80;
  const char *command = argv[1], *socket_path = argv[2], *behavior = argv[3];
  const int port = atoi(argv[4]);
  char control[108];
  if (strlen(socket_path) >= sizeof(control)) return 80;
  strcpy(control,socket_path); char* slash = strrchr(control,'/'); if (!slash) return 80;
  strcpy(slash+1,"control");
  if (!strcmp(command,"master")) {
    if (!strcmp(behavior,"temp-control")) {
      signal(SIGTERM,SIG_IGN);
      strcat(control,".fixture"); (void)local_socket(control,1);
      for (;;) pause();
    }
    if (!strcmp(behavior,"noisy-ready")) {
      char bytes[4096] = {0};
      for (int i = 0; i < 512; ++i) if (write(STDERR_FILENO,bytes,sizeof(bytes)) != sizeof(bytes)) return 78;
    }
    if (!strcmp(behavior,"exit")) return 17;
    if (!strcmp(behavior,"no-ready") || !strcmp(behavior,"ignore-term")) {
      if (!strcmp(behavior,"ignore-term")) signal(SIGTERM,SIG_IGN);
      for (;;) pause();
    }
    signal(SIGPIPE,SIG_IGN); signal(SIGCHLD,SIG_IGN);
    int master = local_socket(control,1), forward = -1;
    for (;;) {
      struct pollfd sockets[2] = {{master,POLLIN,0},{forward,POLLIN,0}};
      if (poll(sockets,2,10000) <= 0) continue;
      if (sockets[0].revents) {
        int peer = accept(master,NULL,NULL); if (peer < 0) return 85;
        char message = 0; if (read(peer,&message,1) != 1) return 86;
        if (message == 'f') {
          if (!strcmp(behavior,"hang-forward")) { for (;;) pause(); }
          if (!strcmp(behavior,"fail-forward")) { close(peer); continue; }
          if (forward < 0) forward = local_socket(socket_path,1);
        }
        if (write(peer,"y",1) != 1) return 87;
        close(peer);
      }
      if (sockets[1].revents) {
        int peer = accept(forward,NULL,NULL); if (peer < 0) return 88;
        pid_t child = fork(); if (child < 0) return 89;
        if (child == 0) { close(master); close(forward); relay(peer,port); }
        close(peer);
      }
    }
  }
  int peer = local_socket(control,0);
  char message = !strcmp(command,"forward") ? 'f' : 'c', reply = 0;
  if (write(peer,&message,1) != 1 || read(peer,&reply,1) != 1 || reply != 'y') return 19;
  close(peer); return 0;
}
