/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "peer.h"
#include <iostream>
#include <string>
int main(int argc, char**) {
  void* peer = native_test_peer_create_pattern(argc > 1);
  if (!peer) return 1;
  std::cout << "127.0.0.1::" << native_test_peer_port(peer) << std::endl;
  std::string command;
  while (std::getline(std::cin, command) && command != "quit") {
    if (command == "resize") native_test_peer_resize(peer);
    if (command == "status") std::cout << "verified=" << native_test_peer_verified(peer)
      << " keyA=" << native_test_peer_has_key(peer) << std::endl;
  }
  native_test_peer_destroy(peer);
}
