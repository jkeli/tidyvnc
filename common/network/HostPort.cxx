/* Copyright (C) 2002-2005 RealVNC Ltd.  All Rights Reserved.
 *
 * This is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this software; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307,
 * USA.
 */

/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <network/HostPort.h>

namespace {
bool space(char value)
{
  return value == ' ' || value == '\t' || value == '\r' || value == '\n' ||
         value == '\f' || value == '\v';
}

std::string trim(const std::string& value)
{
  size_t begin = 0, end = value.size();
  while (begin < end && space(value[begin])) ++begin;
  while (end > begin && space(value[end - 1])) --end;
  return value.substr(begin, end - begin);
}
}

network::HostPort network::parseHostAndPort(const std::string& address,
                                          int basePort)
{
  if (basePort < 1 || basePort > 65535)
    throw HostPortError(HostPortErrorCode::InvalidPort);
  if (address.find('\0') != std::string::npos)
    throw HostPortError(HostPortErrorCode::InvalidHost);

  const std::string text = trim(address);
  std::string host, suffix;
  if (!text.empty() && text[0] == '[') {
    const size_t end = text.find(']');
    if (end == std::string::npos)
      throw HostPortError(HostPortErrorCode::UnmatchedBracket);
    host = trim(text.substr(1, end - 1));
    suffix = text.substr(end + 1);
  } else {
    size_t end = text.rfind(':');
    if (end != std::string::npos && end > 0 && text[end - 1] == ':')
      --end;
    // More colons than the single/double suffix delimiter means bare IPv6.
    if (end == std::string::npos || text.find(':') != end) {
      host = text;
    } else {
      host = trim(text.substr(0, end));
      suffix = text.substr(end);
    }
  }
  if (host.find_first_of("[]") != std::string::npos)
    throw HostPortError(HostPortErrorCode::InvalidHost);
  for (char value : host) {
    if (static_cast<unsigned char>(value) <= 32 || value == 127)
      throw HostPortError(HostPortErrorCode::InvalidHost);
  }
  if (host.empty()) host = "localhost";

  unsigned int port = static_cast<unsigned int>(basePort);
  if (!suffix.empty()) {
    if (suffix[0] != ':')
      throw HostPortError(HostPortErrorCode::InvalidPort);
    const bool explicitPort = suffix.size() > 1 && suffix[1] == ':';
    std::string number = trim(suffix.substr(explicitPort ? 2 : 1));
    // strtol accepted a leading plus in the legacy parser.
    if (!number.empty() && number[0] == '+') number.erase(0, 1);
    if (number.empty())
      throw HostPortError(HostPortErrorCode::InvalidPort);
    port = 0;
    for (char value : number) {
      if (value < '0' || value > '9')
        throw HostPortError(HostPortErrorCode::InvalidPort);
      port = port * 10 + static_cast<unsigned int>(value - '0');
      if (port > 65535)
        throw HostPortError(HostPortErrorCode::InvalidPort);
    }
    if (!explicitPort && port < 100)
      port += static_cast<unsigned int>(basePort);
    if (port == 0 || port > 65535)
      throw HostPortError(HostPortErrorCode::InvalidPort);
  }
  return {host, static_cast<uint16_t>(port)};
}
