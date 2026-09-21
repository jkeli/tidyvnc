/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <chrono>
#include <cstdlib>
#include <new>
#include <thread>
namespace { thread_local unsigned remaining = 0; }
extern "C" void abi_test_fail_after(unsigned count) { remaining = count; }
extern "C" void abi_test_sleep() { std::this_thread::sleep_for(std::chrono::milliseconds(1)); }
void* operator new(std::size_t size) {
  if (remaining && !--remaining) throw std::bad_alloc();
  if (auto pointer = std::malloc(size ? size : 1)) return pointer;
  throw std::bad_alloc();
}
void* operator new[](std::size_t size) { return ::operator new(size); }
void operator delete(void* pointer) noexcept { std::free(pointer); }
void operator delete[](void* pointer) noexcept { std::free(pointer); }
#if __cplusplus >= 201402L
void operator delete(void* pointer,std::size_t) noexcept { std::free(pointer); }
void operator delete[](void* pointer,std::size_t) noexcept { std::free(pointer); }
#endif
