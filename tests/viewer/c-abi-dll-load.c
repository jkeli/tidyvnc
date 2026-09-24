/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
/* Loads tidyvnc_viewer.dll at run time, as the .NET frontend does, resolves
 * functions by name and drives a runtime and an invocation through them.
 * Usage: viewer-c-abi-dll-load <path to tidyvnc_viewer.dll> */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#define TIDYVNC_STATIC /* Only the types are used; functions come from GetProcAddress. */
#include <tidyvnc.h>

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr,"DLL check failed at line %d\n",__LINE__); return 1; } } while (0)
#define INIT(value) do { memset(&(value),0,sizeof(value)); (value).size=sizeof(value); (value).version=TIDYVNC_ABI_VERSION; } while (0)

typedef tidyvnc_status (*get_abi_fn)(tidyvnc_abi_info*,tidyvnc_error*);
typedef tidyvnc_status (*runtime_options_init_fn)(tidyvnc_runtime_options*,tidyvnc_error*);
typedef tidyvnc_status (*runtime_create_fn)(const tidyvnc_runtime_options*,tidyvnc_handle*,tidyvnc_error*);
typedef tidyvnc_status (*runtime_shutdown_fn)(tidyvnc_handle,tidyvnc_error*);
typedef tidyvnc_status (*runtime_poll_drained_fn)(tidyvnc_handle,tidyvnc_error*);
typedef tidyvnc_status (*release_fn)(tidyvnc_handle,tidyvnc_error*);
typedef tidyvnc_status (*invocation_parse_fn)(const tidyvnc_bytes*,uint32_t,tidyvnc_handle*,tidyvnc_error*);

int main(int argc, char** argv)
{
  HMODULE module;
  get_abi_fn get_abi; runtime_options_init_fn options_init; runtime_create_fn create;
  runtime_shutdown_fn shutdown; runtime_poll_drained_fn drained; release_fn release;
  invocation_parse_fn parse;
  tidyvnc_abi_info abi; tidyvnc_error error; tidyvnc_runtime_options options;
  tidyvnc_handle runtime = 0, invocation = 0;
  tidyvnc_bytes argument = {(const uint8_t*)"-Shared", 7};
  unsigned i;
  CHECK(argc == 2);
  module = LoadLibraryExA(argv[1], NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
  CHECK(module != NULL);
  CHECK(GetProcAddress(module, "tidyvnc_no_such_function") == NULL);
  get_abi = (get_abi_fn)(void*)GetProcAddress(module, "tidyvnc_get_abi");
  options_init = (runtime_options_init_fn)(void*)GetProcAddress(module, "tidyvnc_runtime_options_init");
  create = (runtime_create_fn)(void*)GetProcAddress(module, "tidyvnc_runtime_create");
  shutdown = (runtime_shutdown_fn)(void*)GetProcAddress(module, "tidyvnc_runtime_shutdown");
  drained = (runtime_poll_drained_fn)(void*)GetProcAddress(module, "tidyvnc_runtime_poll_drained");
  release = (release_fn)(void*)GetProcAddress(module, "tidyvnc_release");
  parse = (invocation_parse_fn)(void*)GetProcAddress(module, "tidyvnc_invocation_parse");
  CHECK(get_abi && options_init && create && shutdown && drained && release && parse);
  INIT(abi); INIT(error);
  CHECK(get_abi(&abi, &error) == TIDYVNC_OK);
  CHECK((abi.features & TIDYVNC_FEATURE_LISTENER) != 0);
  CHECK((abi.features & TIDYVNC_FEATURE_TCP_UNIX_CONNECT) != 0);
  CHECK(parse(&argument, 1, &invocation, &error) == TIDYVNC_OK && invocation != 0);
  CHECK(release(invocation, &error) == TIDYVNC_OK);
  INIT(options);
  CHECK(options_init(&options, &error) == TIDYVNC_OK);
  CHECK(create(&options, &runtime, &error) == TIDYVNC_OK);
  CHECK(shutdown(runtime, &error) == TIDYVNC_OK);
  for (i = 0; i < 5000 && drained(runtime, NULL) != TIDYVNC_OK; ++i) Sleep(1);
  CHECK(drained(runtime, NULL) == TIDYVNC_OK);
  CHECK(release(runtime, &error) == TIDYVNC_OK);
  /* The runtime service keeps worker threads until process exit; the module
     stays loaded, as it does in the app (no FreeLibrary with live workers). */
  puts("DLL loaded and exercised");
  return 0;
}
