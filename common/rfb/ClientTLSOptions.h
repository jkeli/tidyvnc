/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */

#ifndef RFB_CLIENT_TLS_OPTIONS_H
#define RFB_CLIENT_TLS_OPTIONS_H

#include <stdexcept>
#include <string>

namespace rfb {

  // Value-only client TLS policy; no GnuTLS or platform types in this header.
  // Empty priority uses the library default. Empty paths add no user CA/CRL;
  // system trust is still loaded. These are not credentials or trust exceptions.
  struct ClientTLSOptions {
    std::string priority;
    std::string caFile;
    std::string crlFile;

    void validate() const {
      // GnuTLS takes C strings. Never silently truncate explicit policy values.
      if (priority.find('\0') != std::string::npos ||
          caFile.find('\0') != std::string::npos ||
          crlFile.find('\0') != std::string::npos)
        throw std::invalid_argument("TLS policy contains an embedded NUL");
    }
  };

}

#endif
