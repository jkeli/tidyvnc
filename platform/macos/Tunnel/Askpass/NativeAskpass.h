/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_NATIVE_ASKPASS_H
#define TIDYVNC_NATIVE_ASKPASS_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Private macOS implementation API; never part of the portable viewer ABI.
 * One worker owns receive/reply/alive. cancel may run concurrently and only
 * shuts descriptors down; destroy requires that worker and callbacks joined. */
typedef struct tidy_askpass_server tidy_askpass_server;
#define TIDY_ASKPASS_PROMPT_LIMIT 8192
#define TIDY_ASKPASS_REPLY_LIMIT 1023
/* Directory must be owned by euid, mode 0700, and not a symbolic link.
 * Creates only directory/askpass, with mode 0600, never replacing a leaf. */
tidy_askpass_server *tidy_askpass_open(const char *directory);
/* 1 = request; 0 = rejected peer/frame; -1 = closed/exhausted. kind:
 * 1 = response, 2 = permission hint, 3 = notification, 4 = observed host key.
 * text is not terminated. Host-key metadata is hostname/type/base64 with LF separators. */
int tidy_askpass_receive(tidy_askpass_server *, uint8_t *kind, uint8_t *text, uint32_t *length);
int tidy_askpass_peer_alive(tidy_askpass_server *);
/* Reply bytes are never retained. accepted=0 cancels the helper. */
int tidy_askpass_reply(tidy_askpass_server *, const uint8_t *, uint32_t length, int accepted);
void tidy_askpass_cancel(tidy_askpass_server *);
void tidy_askpass_destroy(tidy_askpass_server *);
/* SSH_ASKPASS executable entry; fixed failures produce no output. */
int tidy_askpass_main(int argc, char **argv);
#ifdef __cplusplus
}
#endif
#endif
