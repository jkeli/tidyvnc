/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */

//
// wipe.h - clearing secrets from owned buffers
//
// The stores go through a volatile pointer so they are not removed as dead
// writes. This shortens how long secrets stay in memory the caller owns; it
// cannot clear copies held by the OS, other libraries, the compiler (registers,
// spills) or earlier reallocations.
//

#ifndef __CORE_WIPE_H__
#define __CORE_WIPE_H__

#include <assert.h>
#include <stddef.h>
#include <stdint.h>

#include <string>
#include <vector>

namespace core {

  inline void wipe(void* data, size_t length) noexcept
  {
    volatile uint8_t* bytes = static_cast<volatile uint8_t*>(data);
    while (length--)
      *bytes++ = 0;
  }

  // Wipes every registered object when the scope ends, including by an
  // exception. Declare it after the objects it covers, so it runs first.
  // Registration never allocates; at most eight objects of each kind (more is
  // a programming error and asserts).
  class ScopedWipe {
  public:
    ScopedWipe() : stringCount(0), vectorCount(0), rangeCount(0) {}
    ScopedWipe(const ScopedWipe&) = delete;
    ScopedWipe& operator=(const ScopedWipe&) = delete;
    ~ScopedWipe()
    {
      for (size_t i = 0; i < stringCount; ++i) {
        if (!strings[i]->empty())
          wipe(&(*strings[i])[0], strings[i]->size());
        strings[i]->clear();
      }
      for (size_t i = 0; i < vectorCount; ++i)
        if (!vectors[i]->empty())
          wipe(vectors[i]->data(), vectors[i]->size());
      for (size_t i = 0; i < rangeCount; ++i)
        wipe(ranges[i].data, ranges[i].length);
    }
    ScopedWipe& add(std::string& value)
    {
      assert(stringCount < limit);
      if (stringCount < limit) strings[stringCount++] = &value;
      return *this;
    }
    ScopedWipe& add(std::vector<uint8_t>& value)
    {
      assert(vectorCount < limit);
      if (vectorCount < limit) vectors[vectorCount++] = &value;
      return *this;
    }
    ScopedWipe& add(void* data, size_t length)
    {
      assert(rangeCount < limit);
      if (rangeCount < limit) { ranges[rangeCount].data = data; ranges[rangeCount].length = length; ++rangeCount; }
      return *this;
    }
  private:
    static const size_t limit = 8;
    struct Range { void* data; size_t length; };
    std::string* strings[limit];
    std::vector<uint8_t>* vectors[limit];
    Range ranges[limit];
    size_t stringCount, vectorCount, rangeCount;
  };

}

#endif
