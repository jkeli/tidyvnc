/* Copyright (C) 2002-2005 RealVNC Ltd.  All Rights Reserved.
 * Copyright 2023 Pierre Ossman for Cendio AB
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

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <assert.h>
#include <string.h>

#include <stdexcept>

extern "C" {
#include <rfb/d3des.h>
}

#include <rfb/obfuscate.h>

static const unsigned char d3desObfuscationKey[] = {23,82,107,6,35,78,88,7};

std::vector<uint8_t> rfb::obfuscate(const char *str)
{
  std::vector<uint8_t> buf(8);

  assert(str != nullptr);

  size_t l = strlen(str), i;
  for (i=0; i<8; i++)
    buf[i] = i<l ? str[i] : 0;
  d3des_ctx context;
  d3des_set_key(&context, d3desObfuscationKey, EN0);
  d3des_transform(&context, buf.data(), buf.data());

  return buf;
}

size_t rfb::deobfuscate(const uint8_t *data, size_t len, uint8_t* output, size_t capacity)
{
  if (len != 8 || !data || !output || capacity < 8)
    throw std::invalid_argument("Bad obfuscated password buffer");
  d3des_ctx context;
  d3des_set_key(&context, d3desObfuscationKey, DE1);
  d3des_transform(&context, data, output);
  size_t count = 0;
  while (count < 8 && output[count]) ++count;
  return count;
}

std::string rfb::deobfuscate(const uint8_t *data, size_t len)
{
  struct Decoded {
    uint8_t bytes[8];
    ~Decoded() {
      volatile uint8_t* pointer = bytes;
      for (size_t i = 0; i < sizeof(bytes); ++i) pointer[i] = 0;
    }
  } decoded{};
  const auto count = deobfuscate(data,len,decoded.bytes,sizeof(decoded.bytes));
  return std::string(reinterpret_cast<const char*>(decoded.bytes),count);
}
