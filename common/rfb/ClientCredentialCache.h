/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */

#ifndef RFB_CLIENT_CREDENTIAL_CACHE_H
#define RFB_CLIENT_CREDENTIAL_CACHE_H

#include <string>
#include <vector>

namespace rfb {

  // In-memory retention for retries of one logical session. The host owns this
  // longer than individual connection attempts and accesses it on one executor.
  // No environment, files, persistent stores or process-global state are read.
  // Not copyable/movable: connection attempts may hold a reference to the owner.
  class ClientCredentialCache {
  public:
    ClientCredentialCache() = default;
    ~ClientCredentialCache() { clear(); }
    ClientCredentialCache(const ClientCredentialCache&) = delete;
    ClientCredentialCache& operator=(const ClientCredentialCache&) = delete;

    // A null user requests password-only authentication. Preserve legacy
    // behavior: empty passwords (or usernames for pair auth) are not reused.
    // On a miss the supplied output values are left unchanged.
    bool recall(std::string* user, std::string& password) const {
      if (savedPassword.empty() || (user && savedUsername.empty()))
        return false;
      if (user)
        user->assign(savedUsername.begin(), savedUsername.end());
      password.assign(savedPassword.begin(), savedPassword.end());
      return true;
    }

    // Only retain credentials when explicitly requested. Replacing with a
    // password-only response also removes any previously retained username.
    void remember(const std::string* user, const std::string& password,
                  bool retain) {
      clear();
      if (!retain)
        return;
      try {
        if (user)
          savedUsername.assign(user->begin(), user->end());
        savedPassword.assign(password.begin(), password.end());
      } catch (...) {
        clear();
        throw;
      }
    }

    void clear() {
      wipe(savedUsername);
      wipe(savedPassword);
    }

  private:
    static void wipe(std::vector<char>& value) {
      // Wipe owned bytes before reuse/destruction, including short secrets
      // (vectors have no small-string buffer). Caller/protocol copies are not
      // owned here and must be handled by their respective lifetimes.
      volatile char* bytes = value.data();
      for (size_t i = 0; i < value.size(); ++i)
        bytes[i] = 0;
      value.clear();
    }

    std::vector<char> savedUsername;
    std::vector<char> savedPassword;
  };

}

#endif
