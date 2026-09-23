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
    if (command == "bell") native_test_peer_bell(peer, 1);
    // "keys <keysym>": count of received down/up KeyEvents for that keysym.
    if (command.compare(0, 5, "keys ") == 0) {
      const auto symbol = static_cast<uint32_t>(std::stoul(command.substr(5), nullptr, 0));
      std::cout << "down=" << native_test_peer_count_input(peer, 1, symbol, 0, 0)
        << " up=" << native_test_peer_count_input(peer, 0, symbol, 0, 0) << std::endl;
    }
  }
  native_test_peer_destroy(peer);
}
