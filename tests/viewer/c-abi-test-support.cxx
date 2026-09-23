/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <chrono>
#include <cstdlib>
#include <new>
#include <thread>
namespace { thread_local unsigned remaining = 0; }
#if defined(_MSC_VER) && defined(_ITERATOR_DEBUG_LEVEL) && _ITERATOR_DEBUG_LEVEL > 0
// MSVC debug iterators allocate container proxies inside noexcept moves, where
// an injected failure terminates the process. Injection is off in those builds;
// MSVC Release (and every other toolchain) runs it.
extern "C" void abi_test_fail_after(unsigned) {}
extern "C" int abi_test_injection_enabled(void) { return 0; }
#else
extern "C" void abi_test_fail_after(unsigned count) { remaining = count; }
extern "C" int abi_test_injection_enabled(void) { return 1; }
#endif
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
// Replace every variant a consumer may call (gtest uses nothrow new), so no
// allocation from the default implementation reaches the free() above.
void* operator new(std::size_t size, const std::nothrow_t&) noexcept {
  try { return ::operator new(size); } catch (...) { return nullptr; }
}
void* operator new[](std::size_t size, const std::nothrow_t&) noexcept {
  try { return ::operator new[](size); } catch (...) { return nullptr; }
}
void operator delete(void* pointer, const std::nothrow_t&) noexcept { std::free(pointer); }
void operator delete[](void* pointer, const std::nothrow_t&) noexcept { std::free(pointer); }
