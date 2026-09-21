/* Test-only local RFB peer; never part of the application ABI. */
#ifndef TIDYVNC_NATIVE_TEST_PEER_H
#define TIDYVNC_NATIVE_TEST_PEER_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void* native_resize_peer_create(void);
void native_resize_peer_destroy(void* peer);
uint16_t native_resize_peer_port(void* peer);
void native_resize_peer_reply(void* peer,uint32_t result);
uint32_t native_resize_peer_count(void* peer);
void* native_test_peer_create_reconnecting(uint32_t authentication);
void* native_test_peer_create_reverse(uint16_t port,uint32_t authentication);
void native_test_peer_hold_authentication(void* peer, uint32_t hold);
void native_test_peer_disconnect(void* peer);
void* native_test_peer_create(uint32_t authentication);
/* Loopback-only VeNCrypt Plain fixture; expected byte strings bounded to 64. */
void* native_test_peer_create_plain(const uint8_t* user,uint32_t user_length,const uint8_t* password,uint32_t password_length);
void* native_test_peer_create_pattern(uint32_t authentication);
/* family 4/6 binds IPv4/IPv6 loopback; 0 binds the supplied unique Unix path.
 * Reusable, no authentication, and removes only its own bound Unix socket. */
void* native_test_peer_create_network(uint32_t family, const char* unix_path);
void native_test_peer_resize(void* peer);
void native_test_peer_patch(void* peer);
void native_test_peer_patch_other(void* peer);
void native_test_peer_cursor(void* peer, uint32_t visible);
void native_test_peer_cursor_alpha(void* peer);
void native_test_peer_cursor_blank(void* peer);
uint32_t native_test_peer_has_input(void* peer, uint32_t kind, uint32_t value, uint32_t x, uint32_t y);
void native_test_peer_clipboard(void* peer);
/* Copies one bounded plain clipboard message followed by a framebuffer marker.
 * Returns zero for invalid/oversized input or an occupied fixture queue. */
uint32_t native_test_peer_clipboard_bytes(void* peer, const uint8_t* text, uint32_t length);
uint32_t native_test_peer_has_clipboard(void* peer);
uint32_t native_test_peer_count_clipboard(void* peer, const uint8_t* text, uint32_t length);
uint32_t native_test_peer_count_input(void* peer, uint32_t kind, uint32_t value, uint32_t x, uint32_t y);
uint32_t native_test_peer_has_control_alt_delete(void* peer);
void native_test_peer_destroy(void* peer);
uint16_t native_test_peer_port(void* peer);
uint32_t native_test_peer_verified(void* peer);
uint32_t native_test_peer_shared(void* peer);
uint32_t native_test_peer_has_key(void* peer);
#ifdef __cplusplus
}
#endif
#endif
