/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <tidyvnc.h>
#include "trust-fixture.h"
#include "host-key-fixture.h"
#include <stdio.h>
#include <string.h>
#include <math.h>
/* Test-only helpers; no platform or C++ type enters this consumer or public ABI. */
void abi_test_sleep(void);
void abi_test_fail_after(unsigned count);
#define INIT(value) do { memset(&(value),0,sizeof(value)); (value).size = sizeof(value); (value).version = TIDYVNC_ABI_VERSION; } while (0)
#define CHECK(condition) do { if (!(condition)) { fprintf(stderr,"C ABI check failed at line %d\n",__LINE__); return 1; } } while (0)
static int drain_runtime(tidyvnc_handle runtime) {
  unsigned i;
  for (i=0;i<5000;++i) { tidyvnc_status status = tidyvnc_runtime_poll_drained(runtime,NULL);
    if (status == TIDYVNC_OK) return 1;
    if (status != TIDYVNC_PENDING) return 0;
    abi_test_sleep();
  }
  return 0;
}
struct callback_counts { unsigned retained, released, calls, errors; };
static void retain_context(void* context) { ++((struct callback_counts*)context)->retained; }
static void release_context(void* context) { ++((struct callback_counts*)context)->released; }
static void ready_callback(void* context,tidyvnc_handle subscription,uint64_t generation) {
  struct callback_counts* counts = (struct callback_counts*)context;
  ++counts->calls;
  if (generation != 1 || tidyvnc_subscription_validate(subscription,generation,NULL) != TIDYVNC_OK ||
      tidyvnc_subscription_unsubscribe(subscription,NULL) != TIDYVNC_OK ||
      tidyvnc_subscription_poll_drained(subscription,NULL) != TIDYVNC_PENDING) ++counts->errors;
}
static int drain_subscription(tidyvnc_handle subscription) {
  unsigned i;
  for (i=0;i<5000;++i) {
    tidyvnc_status status = tidyvnc_subscription_poll_drained(subscription,NULL);
    if (status == TIDYVNC_OK) return 1;
    if (status != TIDYVNC_PENDING) return 0;
    abi_test_sleep();
  }
  return 0;
}
int main(void)
{
  tidyvnc_abi_info abi; tidyvnc_error error; tidyvnc_runtime_options runtime_options;
  tidyvnc_session_options session_options; tidyvnc_connect_options connect_options;
  tidyvnc_snapshot snapshot; tidyvnc_operation operation; tidyvnc_event event;
  tidyvnc_handle runtime=0, session=0, second=0; unsigned n;
  INIT(abi); INIT(error); INIT(runtime_options); INIT(session_options); INIT(connect_options);
  INIT(snapshot); INIT(operation); INIT(event);
  {
    const char arg[] = "-Shared", host[] = "fixture-host";
    tidyvnc_bytes args[] = {{(const uint8_t*)arg,sizeof(arg)-1},{(const uint8_t*)host,sizeof(host)-1}};
    tidyvnc_handle invocation = 0, validated = 0;
    tidyvnc_invocation_info info;
    tidyvnc_invocation_assignment field;
    tidyvnc_invocation_option option;
    INIT(info); INIT(field); INIT(option);
    CHECK(tidyvnc_get_abi(&abi,&error) == TIDYVNC_OK);
    CHECK((abi.features & TIDYVNC_FEATURE_INVOCATION_SYNTAX) != 0);
    CHECK(tidyvnc_invocation_parse(args,2,&invocation,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_invocation_get(invocation,&info,&error) == TIDYVNC_OK);
    CHECK(info.action == TIDYVNC_INVOCATION_LAUNCH && info.count == 1 && info.operand_argument == 2);
    CHECK(info.operand.length == sizeof(host)-1 && memcmp(info.operand.data,host,sizeof(host)-1) == 0);
    CHECK(tidyvnc_invocation_assignment_at(invocation,0,&field,&error) == TIDYVNC_OK);
    CHECK(strcmp(field.name,"Shared") == 0 && field.value_argument == 0 && field.value.length == 1 && field.value.data[0] == '1');
    CHECK(tidyvnc_invocation_option_at(0,&option,&error) == TIDYVNC_OK);
    CHECK((abi.features & TIDYVNC_FEATURE_INVOCATION_VALUES) != 0);
    CHECK(tidyvnc_invocation_validate(invocation,&validated,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_invocation_assignment_at(validated,0,&field,&error) == TIDYVNC_OK);
    CHECK(field.value.length == 2 && memcmp(field.value.data,"on",2) == 0);
    CHECK(tidyvnc_release(validated,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_release(invocation,&error) == TIDYVNC_OK);
  }
  {
    const char source[] = "TidyVNC Configuration file Version 1.0\nServerName=fixture\\\\path\nFuture=\\q\n";
    const char name[] = "ServerName", value[] = "fixture\\path";
    tidyvnc_bytes input = {(const uint8_t*)source,sizeof(source)-1};
    tidyvnc_handle document = 0;
    tidyvnc_document_info info;
    tidyvnc_document_entry entry;
    tidyvnc_document_assignment assignment = {{(const uint8_t*)name,sizeof(name)-1},{(const uint8_t*)value,sizeof(value)-1}};
    uint8_t exported[512]; uint64_t length = 0;
    tidyvnc_mutable_bytes query = {NULL,0}, destination = {exported,sizeof(exported)};
    INIT(info); INIT(entry);
    CHECK(tidyvnc_get_abi(&abi,&error) == TIDYVNC_OK);
    CHECK((abi.features & TIDYVNC_FEATURE_CONNECTION_DOCUMENT) != 0);
    CHECK((abi.features & TIDYVNC_FEATURE_DOCUMENT_OPTIONS) != 0);
    CHECK(tidyvnc_document_parse(input,&document,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_document_get(document,&info,&error) == TIDYVNC_OK && info.count == 2 && !info.legacy_header);
    CHECK(tidyvnc_document_entry_at(document,0,1,&entry,&error) == TIDYVNC_OK);
    CHECK(strcmp(entry.name,name) == 0 && strcmp(entry.value,value) == 0 && entry.line == 2);
    CHECK(tidyvnc_document_option_at(document,0,&entry,&error) == TIDYVNC_OK && strcmp(entry.value,value) == 0);
    CHECK(tidyvnc_document_option_at(document,1,&entry,&error) == TIDYVNC_NO_CHANGE);
    CHECK(tidyvnc_document_entry_at(document,1,0,&entry,&error) == TIDYVNC_OK && strcmp(entry.value,"\\q") == 0);
    CHECK(tidyvnc_document_entry_at(document,1,1,&entry,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(error.domain == TIDYVNC_DOMAIN_DOCUMENT && error.detail == ((3u << 8) | TIDYVNC_DOCUMENT_INVALID_ESCAPE));
    CHECK(tidyvnc_document_serialize(&assignment,1,query,&length,&error) == TIDYVNC_OK && length < sizeof(exported));
    CHECK(tidyvnc_document_serialize(&assignment,1,destination,&length,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_release(document,&error) == TIDYVNC_OK);
    input.data = exported; input.length = length;
    CHECK(tidyvnc_document_parse(input,&document,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_document_get(document,&info,&error) == TIDYVNC_OK && info.count == 1);
    CHECK(tidyvnc_release(document,&error) == TIDYVNC_OK);
  }
  {
    tidyvnc_geometry_options options; tidyvnc_geometry geometry, previous;
    INIT(options); INIT(geometry);
    options.remote_width=400; options.remote_height=200;
    options.viewport_width=300; options.viewport_height=300; options.backing_scale=2;
    options.scaling.data=(const uint8_t*)"FixedRatio"; options.scaling.length=10;
    CHECK(tidyvnc_desktop_geometry(&options,150,150,&geometry,&error) == TIDYVNC_OK);
    CHECK(geometry.x == 0 && geometry.y == 75 && geometry.width == 300 && geometry.height == 150);
    CHECK(geometry.backing_width == 600 && geometry.backing_height == 300);
    CHECK(geometry.remote_x == 200 && geometry.remote_y == 100);
    CHECK(tidyvnc_desktop_geometry(&options,-100,500,&geometry,&error) == TIDYVNC_OK);
    CHECK(geometry.remote_x == 0 && geometry.remote_y == 199);
    previous=geometry; options.backing_scale=NAN;
    CHECK(tidyvnc_desktop_geometry(&options,0,0,&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(memcmp(&previous,&geometry,sizeof(geometry)) == 0);
    options.backing_scale=1.5; options.units=1;
    CHECK(tidyvnc_desktop_geometry(&options,150,150,&geometry,&error) == TIDYVNC_OK);
    /* The centered 225-pixel image rounds its half-pixel origin to 113. */
    CHECK(geometry.remote_x == 200 && geometry.remote_y == 99);
    CHECK(tidyvnc_desktop_geometry(&options,INFINITY,0,&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.version=2;
    CHECK(tidyvnc_desktop_geometry(&options,0,0,&geometry,&error) == TIDYVNC_ABI_MISMATCH);
    options.version=TIDYVNC_ABI_VERSION; options.reserved=1;
    CHECK(tidyvnc_desktop_geometry(&options,0,0,&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.reserved=0; options.remote_width=0;
    CHECK(tidyvnc_desktop_geometry(&options,0,0,&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.remote_width=400; options.scaling.length=UINT64_MAX;
    CHECK(tidyvnc_desktop_geometry(&options,0,0,&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.scaling.data=(const uint8_t*)"invalid"; options.scaling.length=7;
    CHECK(tidyvnc_desktop_geometry(&options,0,0,&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.scaling.data=(const uint8_t*)"FixedRatio"; options.scaling.length=10;
    options.viewport_width=65535; options.viewport_height=65535; options.backing_scale=2;
    CHECK(tidyvnc_desktop_geometry(&options,0,0,&geometry,&error) == TIDYVNC_RESOURCE_LIMIT);
    CHECK(tidyvnc_desktop_geometry(NULL,0,0,&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
  }
  CHECK(tidyvnc_get_abi(&abi,&error) == TIDYVNC_OK);
  {
    tidyvnc_listener_options options;
    tidyvnc_listener_snapshot snapshot;
    tidyvnc_listener_event event;
    tidyvnc_operation operation;
    tidyvnc_handle untouched = 99;
    INIT(options); INIT(snapshot); INIT(event); INIT(operation);
    CHECK((abi.features & TIDYVNC_FEATURE_LISTENER) != 0);
    CHECK(tidyvnc_listener_options_init(&options,&error) == TIDYVNC_OK);
    CHECK(options.port == 5500 && options.ipv4 && options.ipv6 && options.pending_capacity == 8);
    CHECK(tidyvnc_listener_create(0,&options,&untouched,&error) == TIDYVNC_INVALID_HANDLE && untouched == 99);
    CHECK(tidyvnc_listener_get_snapshot(0,&snapshot,&error) == TIDYVNC_INVALID_HANDLE);
    CHECK(tidyvnc_listener_take_event(0,&event,&error) == TIDYVNC_INVALID_HANDLE);
    CHECK(tidyvnc_listener_accept(0,1,0,&operation,&error) == TIDYVNC_INVALID_HANDLE);
    CHECK(tidyvnc_listener_reject(0,1,&error) == TIDYVNC_INVALID_HANDLE);
    CHECK(tidyvnc_listener_stop(0,&error) == TIDYVNC_INVALID_HANDLE);
    CHECK(tidyvnc_listener_poll_drained(0,&error) == TIDYVNC_INVALID_HANDLE);
  }
  {
    tidyvnc_certificate_policy policy = {0}, previous;
    policy.size=sizeof(policy); policy.version=TIDYVNC_ABI_VERSION;
    CHECK(abi.features & TIDYVNC_FEATURE_CERTIFICATE_POLICY);
    CHECK(tidyvnc_certificate_policy_get(66,&policy,&error) == TIDYVNC_OK);
    CHECK(policy.may_override == 1 && policy.fatal_status == 0);
    CHECK(policy.reasons == (TIDYVNC_CERT_INVALID|TIDYVNC_CERT_UNKNOWN_ISSUER));
    CHECK(tidyvnc_certificate_policy_get(34,&policy,&error) == TIDYVNC_OK);
    CHECK(policy.may_override == 0 && policy.fatal_status == 32);
    CHECK(policy.reasons == (TIDYVNC_CERT_INVALID|TIDYVNC_CERT_REVOKED));
    CHECK(tidyvnc_certificate_policy_get(0,&policy,&error) == TIDYVNC_OK);
    CHECK(policy.may_override == 0 && policy.reasons == TIDYVNC_CERT_MISSING_PROBLEM);
    CHECK(tidyvnc_certificate_policy_get(1u<<31,&policy,&error) == TIDYVNC_OK);
    CHECK(policy.may_override == 0 && policy.reasons == TIDYVNC_CERT_UNKNOWN_PROBLEM);
    policy.size=0; previous=policy;
    CHECK(tidyvnc_certificate_policy_get(66,&policy,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(memcmp(&previous,&policy,sizeof(policy)) == 0);
    policy.size=sizeof(policy); policy.version=2; previous=policy;
    CHECK(tidyvnc_certificate_policy_get(66,&policy,&error) == TIDYVNC_ABI_MISMATCH);
    CHECK(memcmp(&previous,&policy,sizeof(policy)) == 0);
    CHECK(tidyvnc_certificate_policy_get(66,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
  }
  {
    tidyvnc_handle key = 0, sentinel = 123;
    tidyvnc_certificate_key_info info = {0}, previous;
    tidyvnc_key_digest digest = {0}, saved_digest;
    info.size=sizeof(info); info.version=TIDYVNC_ABI_VERSION;
    digest.size=sizeof(digest); digest.version=TIDYVNC_ABI_VERSION;
    CHECK(tidyvnc_certificate_key_create((tidyvnc_bytes){NULL,1},&sentinel,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(sentinel == 123);
    CHECK(tidyvnc_certificate_key_create((tidyvnc_bytes){trust_fixture_certificate,65537},&sentinel,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(sentinel == 123);
    if (abi.features & TIDYVNC_FEATURE_CERTIFICATE_KEY) {
      CHECK(tidyvnc_certificate_key_create((tidyvnc_bytes){trust_fixture_certificate,3},&sentinel,&error) == TIDYVNC_INVALID_ARGUMENT);
      CHECK(sentinel == 123);
      CHECK(tidyvnc_certificate_key_create((tidyvnc_bytes){trust_fixture_certificate,sizeof(trust_fixture_certificate)},NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
      CHECK(tidyvnc_certificate_key_create((tidyvnc_bytes){trust_fixture_certificate,sizeof(trust_fixture_certificate)},&key,&error) == TIDYVNC_OK);
      CHECK(tidyvnc_certificate_key_get(key,&info,&error) == TIDYVNC_OK);
      CHECK(info.spki.length == sizeof(trust_fixture_spki));
      CHECK(memcmp(info.spki.data,trust_fixture_spki,sizeof(trust_fixture_spki)) == 0);
      CHECK(tidyvnc_certificate_key_digest(key,6,&digest,&error) == TIDYVNC_OK);
      CHECK(digest.length == sizeof(trust_fixture_sha256));
      CHECK(memcmp(digest.bytes,trust_fixture_sha256,sizeof(trust_fixture_sha256)) == 0);
      saved_digest=digest;
      CHECK(tidyvnc_certificate_key_digest(key,UINT32_MAX,&digest,&error) == TIDYVNC_INVALID_ARGUMENT);
      CHECK(memcmp(&saved_digest,&digest,sizeof(digest)) == 0);
      previous=info; info.version=2; previous=info;
      CHECK(tidyvnc_certificate_key_get(key,&info,&error) == TIDYVNC_ABI_MISMATCH);
      CHECK(memcmp(&previous,&info,sizeof(info)) == 0);
      CHECK(tidyvnc_certificate_key_get(key,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
      CHECK(tidyvnc_release(key,&error) == TIDYVNC_OK);
      info.version=TIDYVNC_ABI_VERSION; previous=info;
      CHECK(tidyvnc_certificate_key_get(key,&info,&error) == TIDYVNC_INVALID_HANDLE);
      CHECK(memcmp(&previous,&info,sizeof(info)) == 0);
    } else {
      CHECK(tidyvnc_certificate_key_create((tidyvnc_bytes){trust_fixture_certificate,sizeof(trust_fixture_certificate)},&sentinel,&error) == TIDYVNC_UNSUPPORTED);
      CHECK(sentinel == 123);
    }
  }
  {
    uint32_t bits=777;
    CHECK(abi.features & TIDYVNC_FEATURE_HOST_KEY_ENCODING);
    CHECK(abi.features & TIDYVNC_FEATURE_REQUIRED_TLS_FILES);
    CHECK(tidyvnc_host_key_validate((tidyvnc_bytes){host_key_fixture,sizeof(host_key_fixture)},&bits,&error) == TIDYVNC_OK && bits == 2048);
    bits=777;
    CHECK(tidyvnc_host_key_validate((tidyvnc_bytes){host_key_fixture,3},&bits,&error) == TIDYVNC_INVALID_ARGUMENT && bits == 777);
    CHECK(tidyvnc_host_key_validate((tidyvnc_bytes){host_key_fixture,UINT64_MAX},&bits,&error) == TIDYVNC_INVALID_ARGUMENT && bits == 777);
    CHECK(tidyvnc_host_key_validate((tidyvnc_bytes){NULL,0},&bits,&error) == TIDYVNC_INVALID_ARGUMENT && bits == 777);
    CHECK(tidyvnc_host_key_validate((tidyvnc_bytes){host_key_fixture,sizeof(host_key_fixture)},NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
  }
  CHECK(abi.features & TIDYVNC_FEATURE_RUNTIME); CHECK(abi.security_count > 0);
  {
    tidyvnc_endpoint_info info, before;
    tidyvnc_handle endpoint=0, untouched=777;
    tidyvnc_bytes address = {(const uint8_t*)"HOST:1",6}, route = {(const uint8_t*)"ssh-route",9};
    INIT(info);
    CHECK(tidyvnc_endpoint_create(address,route,1,&endpoint,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_endpoint_get(endpoint,&info,&error) == TIDYVNC_OK);
    CHECK(info.transport == TIDYVNC_ENDPOINT_TCP && info.port == 5901);
    CHECK(info.host.length == 4 && memcmp(info.host.data,"host",4) == 0);
    CHECK(info.route.length == 9 && memcmp(info.route.data,"ssh-route",9) == 0 && info.path.length == 0);
    CHECK(tidyvnc_endpoint_create(address,route,2,&untouched,&error) == TIDYVNC_INVALID_ARGUMENT && untouched == 777);
    route.data=NULL;
    CHECK(tidyvnc_endpoint_create(address,route,1,&untouched,&error) == TIDYVNC_INVALID_ARGUMENT && untouched == 777);
    route.data=(const uint8_t*)"x\0y"; route.length=3;
    CHECK(tidyvnc_endpoint_create(address,route,1,&untouched,&error) == TIDYVNC_INVALID_ARGUMENT && untouched == 777);
    route.data=(const uint8_t*)"\xff"; route.length=1;
    CHECK(tidyvnc_endpoint_create(address,route,1,&untouched,&error) == TIDYVNC_INVALID_ARGUMENT && untouched == 777);
    route.length=UINT64_MAX;
    CHECK(tidyvnc_endpoint_create(address,route,1,&untouched,&error) == TIDYVNC_INVALID_ARGUMENT && untouched == 777);
    CHECK(error.domain == TIDYVNC_DOMAIN_ENDPOINT && error.detail == TIDYVNC_ENDPOINT_TOO_LONG);
    route.data=NULL; route.length=0;
    CHECK(tidyvnc_endpoint_create(address,route,1,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
    { uint32_t type = 99;
      CHECK(tidyvnc_prompt_security_type(endpoint,&type,&error) == TIDYVNC_WRONG_HANDLE_TYPE);
      CHECK(type == 99);
      CHECK(tidyvnc_prompt_security_type(endpoint,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
    }
    { tidyvnc_certificate_key_info key_info, before_key; tidyvnc_key_digest key_digest, before_digest;
      INIT(key_info); INIT(key_digest); before_key=key_info; before_digest=key_digest;
      CHECK(tidyvnc_certificate_key_get(endpoint,&key_info,&error) == TIDYVNC_WRONG_HANDLE_TYPE);
      CHECK(tidyvnc_certificate_key_digest(endpoint,6,&key_digest,&error) == TIDYVNC_WRONG_HANDLE_TYPE);
      CHECK(memcmp(&key_info,&before_key,sizeof(key_info)) == 0);
      CHECK(memcmp(&key_digest,&before_digest,sizeof(key_digest)) == 0);
    }
    CHECK(tidyvnc_endpoint_get(endpoint,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
    info.size=sizeof(info)-1; before=info;
    CHECK(tidyvnc_endpoint_get(endpoint,&info,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(memcmp(&info,&before,sizeof(info)) == 0);
    INIT(info); info.version=2; before=info;
    CHECK(tidyvnc_endpoint_get(endpoint,&info,&error) == TIDYVNC_ABI_MISMATCH);
    CHECK(memcmp(&info,&before,sizeof(info)) == 0);
    CHECK(tidyvnc_release(endpoint,NULL) == TIDYVNC_OK);
    INIT(info); before=info;
    CHECK(tidyvnc_endpoint_get(endpoint,&info,&error) == TIDYVNC_INVALID_HANDLE);
    CHECK(memcmp(&info,&before,sizeof(info)) == 0);
    INIT(error);
  }
  {
    tidyvnc_bytes address = {(const uint8_t*)"[::1]:1",7};
    tidyvnc_error before;
    CHECK(abi.features & TIDYVNC_FEATURE_ENDPOINT_VALIDATION);
    CHECK(tidyvnc_endpoint_validate(address,1,&error) == TIDYVNC_OK);
    address.data=NULL; address.length=0;
    CHECK(tidyvnc_endpoint_validate(address,0,NULL) == TIDYVNC_OK);
    address.length=1;
    CHECK(tidyvnc_endpoint_validate(address,1,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(error.domain == TIDYVNC_DOMAIN_BRIDGE);
    address.length=UINT64_MAX;
    CHECK(tidyvnc_endpoint_validate(address,1,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(error.domain == TIDYVNC_DOMAIN_ENDPOINT && error.detail == TIDYVNC_ENDPOINT_TOO_LONG);
    address.data=(const uint8_t*)"bad\0host"; address.length=8;
    CHECK(tidyvnc_endpoint_validate(address,1,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(error.domain == TIDYVNC_DOMAIN_BRIDGE && strstr(error.message,"host") == NULL);
    address.data=(const uint8_t*)"\xff"; address.length=1;
    CHECK(tidyvnc_endpoint_validate(address,1,&error) == TIDYVNC_INVALID_ARGUMENT);
    address.data=(const uint8_t*)"/tmp/socket"; address.length=11;
    CHECK(tidyvnc_endpoint_validate(address,0,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(error.domain == TIDYVNC_DOMAIN_ENDPOINT && error.detail == TIDYVNC_ENDPOINT_UNSUPPORTED_TRANSPORT);
    CHECK(tidyvnc_endpoint_validate(address,2,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(error.domain == TIDYVNC_DOMAIN_BRIDGE);
    error.version=2; before=error;
    CHECK(tidyvnc_endpoint_validate(address,1,&error) == TIDYVNC_ABI_MISMATCH);
    CHECK(memcmp(&error,&before,sizeof(error)) == 0);
    INIT(error);
  }
  {
    tidyvnc_scaling value, before;
    tidyvnc_bytes input = {(const uint8_t*)"137.50%",7};
    INIT(value); CHECK(abi.features & TIDYVNC_FEATURE_SCALING);
    CHECK(tidyvnc_scaling_parse(input,&value,&error) == TIDYVNC_OK);
    CHECK(value.mode == TIDYVNC_SCALING_PERCENT && value.x == 13750 && !value.fits);
    CHECK(strcmp(value.canonical,"137.5") == 0);
    before=value; input.data=NULL; input.length=UINT64_MAX;
    CHECK(tidyvnc_scaling_parse(input,&value,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(memcmp(&value,&before,sizeof(value)) == 0);
    input.length=1; CHECK(tidyvnc_scaling_parse(input,&value,&error) == TIDYVNC_INVALID_ARGUMENT);
    input.data=(const uint8_t*)"1\0"; input.length=2;
    CHECK(tidyvnc_scaling_parse(input,&value,&error) == TIDYVNC_INVALID_ARGUMENT);
    input.data=(const uint8_t*)"\xff"; input.length=1;
    CHECK(tidyvnc_scaling_parse(input,&value,&error) == TIDYVNC_INVALID_ARGUMENT);
    input.data=(const uint8_t*)"100"; input.length=3;
    value.version=2; before=value;
    CHECK(tidyvnc_scaling_parse(input,&value,&error) == TIDYVNC_ABI_MISMATCH);
    CHECK(memcmp(&value,&before,sizeof(value)) == 0);
    INIT(value); value.size=4; before=value;
    CHECK(tidyvnc_scaling_parse(input,&value,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(memcmp(&value,&before,sizeof(value)) == 0);
    CHECK(tidyvnc_scaling_parse(input,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
    INIT(value); error.version=2; before=value;
    CHECK(tidyvnc_scaling_parse(input,&value,&error) == TIDYVNC_ABI_MISMATCH);
    CHECK(memcmp(&value,&before,sizeof(value)) == 0); INIT(error);
  }
  {
    tidyvnc_cursor_options options;
    tidyvnc_cursor_geometry geometry,before;
    tidyvnc_cursor_tile tile;
    tidyvnc_handle sampler=777;
    uint8_t pixels[16],original[16];
    tidyvnc_mutable_bytes destination={pixels,sizeof(pixels)};
    CHECK(abi.features & TIDYVNC_FEATURE_CURSOR_RENDERER);
    INIT(options); INIT(geometry); INIT(tile); before=geometry;
    options.scale_x=options.scale_y=1;
    options.quality=3;
    CHECK(tidyvnc_cursor_renderer_create(0,&options,&sampler,&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.quality=0; options.scale_x=NAN;
    CHECK(tidyvnc_cursor_renderer_create(0,&options,&sampler,&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.scale_x=INFINITY;
    CHECK(tidyvnc_cursor_renderer_create(0,&options,&sampler,&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.scale_x=0;
    CHECK(tidyvnc_cursor_renderer_create(0,&options,&sampler,&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.scale_x=65536;
    CHECK(tidyvnc_cursor_renderer_create(0,&options,&sampler,&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.scale_x=1; options.reserved=1;
    CHECK(tidyvnc_cursor_renderer_create(0,&options,&sampler,&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.reserved=0; options.version=2;
    CHECK(tidyvnc_cursor_renderer_create(0,&options,&sampler,&geometry,&error) == TIDYVNC_ABI_MISMATCH);
    options.version=1;
    CHECK(tidyvnc_cursor_renderer_create(0,&options,NULL,&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_cursor_renderer_create(0,&options,&sampler,&geometry,&error) == TIDYVNC_INVALID_HANDLE);
    CHECK(sampler == 777 && memcmp(&geometry,&before,sizeof(geometry)) == 0);
    memset(pixels,99,sizeof(pixels)); memcpy(original,pixels,sizeof(pixels));
    tile.width=257; tile.height=1;
    CHECK(tidyvnc_cursor_renderer_render(0,&tile,destination,&error) == TIDYVNC_INVALID_ARGUMENT);
    tile.width=2; tile.height=2; destination.length=15;
    CHECK(tidyvnc_cursor_renderer_render(0,&tile,destination,&error) == TIDYVNC_INVALID_ARGUMENT);
    destination.length=UINT64_MAX;
    CHECK(tidyvnc_cursor_renderer_render(0,&tile,destination,&error) == TIDYVNC_INVALID_ARGUMENT);
    destination.length=16; destination.data=NULL;
    CHECK(tidyvnc_cursor_renderer_render(0,&tile,destination,&error) == TIDYVNC_INVALID_ARGUMENT);
    destination.data=pixels; tile.reserved[1]=1;
    CHECK(tidyvnc_cursor_renderer_render(0,&tile,destination,&error) == TIDYVNC_INVALID_ARGUMENT);
    tile.reserved[1]=0; tile.version=2;
    CHECK(tidyvnc_cursor_renderer_render(0,&tile,destination,&error) == TIDYVNC_ABI_MISMATCH);
    tile.version=1;
    CHECK(tidyvnc_cursor_renderer_render(0,&tile,destination,&error) == TIDYVNC_INVALID_HANDLE);
    CHECK(memcmp(pixels,original,sizeof(pixels)) == 0);
  }
  {
    tidyvnc_handle renderer=0, untouched=777;
    tidyvnc_tile_options options;
    tidyvnc_tile_result result, before;
    uint8_t pixels[16], original[16];
    tidyvnc_mutable_bytes destination={pixels,sizeof(pixels)};
    CHECK(abi.features & TIDYVNC_FEATURE_TILE_RENDERER);
    CHECK(tidyvnc_renderer_create(UINT64_MAX,&untouched,&error) == TIDYVNC_INVALID_ARGUMENT && untouched == 777);
    CHECK(tidyvnc_renderer_create(0,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_renderer_create(1024,&renderer,&error) == TIDYVNC_OK && renderer != 0);
    INIT(options); INIT(result); options.width=options.height=options.tile_width=options.tile_height=2;
    memset(pixels,99,sizeof(pixels)); memcpy(original,pixels,sizeof(pixels)); before=result;
    options.quality=3;
    CHECK(tidyvnc_renderer_render(renderer,0,&options,destination,&result,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.quality=0; options.tile_width=257;
    CHECK(tidyvnc_renderer_render(renderer,0,&options,destination,&result,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.tile_width=2; options.x=UINT32_MAX;
    CHECK(tidyvnc_renderer_render(renderer,0,&options,destination,&result,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.x=0; destination.length=15;
    CHECK(tidyvnc_renderer_render(renderer,0,&options,destination,&result,&error) == TIDYVNC_INVALID_ARGUMENT);
    destination.length=UINT64_MAX;
    CHECK(tidyvnc_renderer_render(renderer,0,&options,destination,&result,&error) == TIDYVNC_INVALID_ARGUMENT);
    destination.length=16; destination.data=NULL;
    CHECK(tidyvnc_renderer_render(renderer,0,&options,destination,&result,&error) == TIDYVNC_INVALID_ARGUMENT);
    destination.data=pixels; options.version=2;
    CHECK(tidyvnc_renderer_render(renderer,0,&options,destination,&result,&error) == TIDYVNC_ABI_MISMATCH);
    options.version=1; options.reserved=1;
    CHECK(tidyvnc_renderer_render(renderer,0,&options,destination,&result,&error) == TIDYVNC_INVALID_ARGUMENT);
    options.reserved=0;
    CHECK(tidyvnc_renderer_render(renderer,0,&options,destination,&result,&error) == TIDYVNC_INVALID_HANDLE);
    CHECK(memcmp(pixels,original,sizeof(pixels)) == 0 && memcmp(&result,&before,sizeof(result)) == 0);
    CHECK(tidyvnc_renderer_clear(renderer,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_release(renderer,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_renderer_clear(renderer,&error) == TIDYVNC_INVALID_HANDLE);
    {
      unsigned i;
      for (i=1;i<=8;++i) {
        tidyvnc_status status; renderer=0; abi_test_fail_after(i);
        status=tidyvnc_renderer_create(1024,&renderer,&error); abi_test_fail_after(0);
        CHECK(status == TIDYVNC_OK || status == TIDYVNC_OUT_OF_MEMORY);
        if (status == TIDYVNC_OK) CHECK(tidyvnc_release(renderer,&error) == TIDYVNC_OK);
        else CHECK(renderer == 0);
      }
    }
  }
  {
    tidyvnc_geometry_options options; tidyvnc_damage damage; tidyvnc_rectangle result,before;
    INIT(options); INIT(damage); INIT(result);
    CHECK(abi.features & TIDYVNC_FEATURE_DAMAGE_GEOMETRY);
    options.remote_width=400; options.remote_height=200; options.viewport_width=300; options.viewport_height=300;
    options.backing_scale=2; options.scaling.data=(const uint8_t*)"FixedRatio"; options.scaling.length=10;
    damage.x=100; damage.y=50; damage.width=damage.height=1;
    CHECK(tidyvnc_desktop_damage(&options,&damage,&result,&error) == TIDYVNC_OK);
    CHECK(result.x == 75 && result.y == 112 && result.width == 1 && result.height == 2);
    damage.quality=TIDYVNC_FILTER_BILINEAR;
    CHECK(tidyvnc_desktop_damage(&options,&damage,&result,&error) == TIDYVNC_OK);
    CHECK(result.x == 74 && result.y == 111 && result.width == 3 && result.height == 3);
    before=result; damage.x=UINT32_MAX;
    CHECK(tidyvnc_desktop_damage(&options,&damage,&result,&error) == TIDYVNC_INVALID_ARGUMENT);
    damage.x=100; damage.width=UINT32_MAX;
    CHECK(tidyvnc_desktop_damage(&options,&damage,&result,&error) == TIDYVNC_INVALID_ARGUMENT);
    damage.width=1; damage.quality=3;
    CHECK(tidyvnc_desktop_damage(&options,&damage,&result,&error) == TIDYVNC_INVALID_ARGUMENT);
    damage.quality=0; damage.reserved=1;
    CHECK(tidyvnc_desktop_damage(&options,&damage,&result,&error) == TIDYVNC_INVALID_ARGUMENT);
    damage.reserved=0; damage.version=2;
    CHECK(tidyvnc_desktop_damage(&options,&damage,&result,&error) == TIDYVNC_ABI_MISMATCH);
    damage.version=1;
    CHECK(tidyvnc_desktop_damage(&options,NULL,&result,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(memcmp(&result,&before,sizeof(result)) == 0);
    result.version=2; before=result;
    CHECK(tidyvnc_desktop_damage(&options,&damage,&result,&error) == TIDYVNC_ABI_MISMATCH);
    CHECK(memcmp(&result,&before,sizeof(result)) == 0);
  }
  CHECK(tidyvnc_runtime_options_init(&runtime_options,&error) == TIDYVNC_OK);
  {
    tidyvnc_security_choice choice, saved_choice;
    tidyvnc_security_selection selected, saved_selection;
    unsigned index, available = 0;
    const uint8_t names[] = " vNcAuth,plain, vncAuth ";
    CHECK(abi.features & TIDYVNC_FEATURE_SECURITY_SELECTION);
    CHECK(abi.features & TIDYVNC_FEATURE_TLS_PRIORITY_VALIDATION);
    CHECK(tidyvnc_tls_priority_validate((tidyvnc_bytes){NULL,0},&error) == TIDYVNC_OK);
    CHECK(tidyvnc_tls_priority_validate((tidyvnc_bytes){NULL,1},&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_tls_priority_validate((tidyvnc_bytes){NULL,UINT64_MAX},&error) == TIDYVNC_RESOURCE_LIMIT);
    CHECK(error.domain == TIDYVNC_DOMAIN_SECURITY && error.detail == TIDYVNC_SECURITY_TOO_LONG);
    CHECK(tidyvnc_tls_priority_validate((tidyvnc_bytes){(const uint8_t*)"NORMAL",6},&error) ==
      ((abi.features & TIDYVNC_FEATURE_CERTIFICATE_KEY) ? TIDYVNC_OK : TIDYVNC_UNSUPPORTED));
    CHECK(tidyvnc_tls_priority_validate((tidyvnc_bytes){(const uint8_t*)"invalid-priority",16},&error) ==
      ((abi.features & TIDYVNC_FEATURE_CERTIFICATE_KEY) ? TIDYVNC_INVALID_ARGUMENT : TIDYVNC_UNSUPPORTED));
    if (abi.features & TIDYVNC_FEATURE_CERTIFICATE_KEY)
      CHECK(error.domain == TIDYVNC_DOMAIN_SECURITY && error.detail == TIDYVNC_SECURITY_INVALID_TLS_PRIORITY);

    for (index=0;index<15;++index) {
      INIT(choice); CHECK(tidyvnc_security_choice_at(index,&choice,&error) == TIDYVNC_OK);
      CHECK(choice.name[0] && choice.type && choice.protection <= TIDYVNC_SECURITY_LEGACY_AUTHENTICATION);
      INIT(selected); saved_selection=selected;
      if (choice.available) {
        ++available;
        CHECK(tidyvnc_security_resolve((tidyvnc_bytes){(const uint8_t*)choice.name,strlen(choice.name)},0,&selected,&error) == TIDYVNC_OK);
        CHECK(selected.count == 1 && selected.types[0] == choice.type);
      } else {
        CHECK(tidyvnc_security_resolve((tidyvnc_bytes){(const uint8_t*)choice.name,strlen(choice.name)},0,&selected,&error) == TIDYVNC_UNSUPPORTED);
        CHECK(error.domain == TIDYVNC_DOMAIN_SECURITY && error.detail == TIDYVNC_SECURITY_UNAVAILABLE);
        CHECK(memcmp(&selected,&saved_selection,sizeof(selected)) == 0);
      }
    }
    CHECK(available == abi.security_count);
    saved_choice=choice; CHECK(tidyvnc_security_choice_at(15,&choice,&error) == TIDYVNC_NO_CHANGE);
    CHECK(memcmp(&choice,&saved_choice,sizeof(choice)) == 0);
    CHECK(tidyvnc_security_choice_at(0,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
    choice.version=2; CHECK(tidyvnc_security_choice_at(0,&choice,&error) == TIDYVNC_ABI_MISMATCH);
    INIT(selected); CHECK(tidyvnc_security_resolve((tidyvnc_bytes){NULL,0},1,&selected,&error) == TIDYVNC_OK);
    CHECK(selected.count == abi.security_count && memcmp(selected.types,abi.security_types,abi.security_count*sizeof(uint32_t)) == 0);
    CHECK(tidyvnc_security_resolve((tidyvnc_bytes){names,sizeof(names)-1},0,&selected,&error) == TIDYVNC_OK);
    CHECK(selected.count == 2 && selected.types[0] == 2 && selected.types[1] == 256 && strcmp(selected.canonical,"VncAuth,Plain") == 0);
    CHECK(tidyvnc_security_resolve((tidyvnc_bytes){NULL,0},0,&selected,&error) == TIDYVNC_OK && selected.count == 0 && selected.canonical[0] == 0);
    saved_selection=selected;
    CHECK(tidyvnc_security_resolve((tidyvnc_bytes){names,UINT64_MAX},0,&selected,&error) == TIDYVNC_RESOURCE_LIMIT);
    CHECK(error.domain == TIDYVNC_DOMAIN_SECURITY && error.detail == TIDYVNC_SECURITY_TOO_LONG);
    CHECK(memcmp(&selected,&saved_selection,sizeof(selected)) == 0);
    CHECK(tidyvnc_security_resolve((tidyvnc_bytes){names,sizeof(names)-1},1,&selected,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_security_resolve((tidyvnc_bytes){NULL,1},0,&selected,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_security_resolve((tidyvnc_bytes){names,0},2,&selected,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_security_resolve((tidyvnc_bytes){(const uint8_t*)"VeNCrypt",8},0,&selected,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(error.domain == TIDYVNC_DOMAIN_SECURITY && error.detail == TIDYVNC_SECURITY_UNKNOWN_TYPE);
    CHECK(tidyvnc_security_resolve((tidyvnc_bytes){names,0},0,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(memcmp(&selected,&saved_selection,sizeof(selected)) == 0);
  }
  CHECK(tidyvnc_session_options_init(&session_options,&error) == TIDYVNC_OK);
  CHECK(tidyvnc_connect_options_init(&connect_options,&error) == TIDYVNC_OK);
  CHECK(tidyvnc_retain(UINT64_MAX,&error) == TIDYVNC_INVALID_HANDLE);
  CHECK(error.code == TIDYVNC_INVALID_HANDLE && error.message[0]);
  runtime_options.version = 2;
  CHECK(tidyvnc_runtime_create(&runtime_options,&runtime,&error) == TIDYVNC_ABI_MISMATCH && runtime == 0);
  runtime_options.version = 1; runtime_options.required_features = UINT64_MAX;
  CHECK(tidyvnc_runtime_create(&runtime_options,&runtime,&error) == TIDYVNC_UNSUPPORTED);
  runtime_options.required_features = 0; runtime_options.reserved = 1;
  CHECK(tidyvnc_runtime_create(&runtime_options,&runtime,&error) == TIDYVNC_INVALID_ARGUMENT);
  runtime_options.reserved = 0; runtime_options.session_capacity = 2;
  CHECK(tidyvnc_runtime_create(&runtime_options,&runtime,&error) == TIDYVNC_OK);
  CHECK(tidyvnc_runtime_poll_drained(runtime,NULL) == TIDYVNC_PENDING);
  CHECK(tidyvnc_session_snapshot(runtime,&snapshot,&error) == TIDYVNC_WRONG_HANDLE_TYPE);
  {
    unsigned wait_index;
    tidyvnc_session_options files = session_options;
    tidyvnc_handle configured = UINT64_MAX;
    const uint8_t invalid_path[] = {'/', 'x', 0, 'y'};
    files.ca_file = (tidyvnc_bytes){invalid_path,sizeof(invalid_path)};
    CHECK(tidyvnc_session_create(runtime,&files,&configured,&error) == TIDYVNC_INVALID_ARGUMENT && configured == UINT64_MAX);
    files.ca_file = (tidyvnc_bytes){(const uint8_t*)"/missing/native-ca.pem",21};
    /* Creation copies paths without opening files. A TLS-disabled build must
       reject explicit files instead of silently dropping the configuration. */
    if (abi.features & TIDYVNC_FEATURE_CERTIFICATE_KEY) {
      CHECK(tidyvnc_session_create(runtime,&files,&configured,&error) == TIDYVNC_OK);
      CHECK(tidyvnc_session_close(configured,&error) == TIDYVNC_OK);
      for (wait_index=0;wait_index<5000 && tidyvnc_session_poll_drained(configured,NULL) == TIDYVNC_PENDING;++wait_index) abi_test_sleep();
      CHECK(tidyvnc_session_poll_drained(configured,NULL) == TIDYVNC_OK);
      CHECK(tidyvnc_release(configured,&error) == TIDYVNC_OK);
    } else {
      CHECK(tidyvnc_session_create(runtime,&files,&configured,&error) == TIDYVNC_UNSUPPORTED && configured == UINT64_MAX);
    }
  }

  if (!(abi.features & TIDYVNC_FEATURE_CERTIFICATE_KEY)) {
    tidyvnc_session_options priority = session_options;
    tidyvnc_handle untouched = UINT64_MAX;
    priority.tls_priority = (tidyvnc_bytes){(const uint8_t*)"NORMAL",6};
    CHECK(tidyvnc_session_create(runtime,&priority,&untouched,&error) == TIDYVNC_UNSUPPORTED && untouched == UINT64_MAX);
  }
  {
    tidyvnc_window_geometry geometry, preserved;
    const uint8_t input[] = "800x600+-10+20";
    INIT(geometry);
    CHECK(abi.features & TIDYVNC_FEATURE_WINDOW_GEOMETRY);
    CHECK(tidyvnc_window_geometry_parse((tidyvnc_bytes){input,sizeof(input)-1},&geometry,&error) == TIDYVNC_OK);
    CHECK(geometry.flags == 3 && geometry.width == 800 && geometry.height == 600 && geometry.x == -10 && geometry.y == 20);
    preserved = geometry;
    CHECK(tidyvnc_window_geometry_parse((tidyvnc_bytes){input,sizeof(input)},&geometry,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(memcmp(&geometry,&preserved,sizeof(geometry)) == 0);
  }
  if (abi.features & TIDYVNC_FEATURE_PROCESS_LOGGING) {
    const uint8_t policy[] = "*::0";
    CHECK(tidyvnc_logging_validate((tidyvnc_bytes){policy,sizeof(policy)-1},&error) == TIDYVNC_OK);
    CHECK(tidyvnc_logging_configure((tidyvnc_bytes){policy,sizeof(policy)-1},&error) == TIDYVNC_BUSY);
    CHECK(error.domain == TIDYVNC_DOMAIN_LOGGING && error.detail == TIDYVNC_LOGGING_FROZEN);
    CHECK(abi.features & TIDYVNC_FEATURE_FILE_LOGGING);
    CHECK(tidyvnc_logging_validate((tidyvnc_bytes){(const uint8_t*)"*:file:30",9},&error) == TIDYVNC_OK);
    CHECK(tidyvnc_logging_configure_with_file((tidyvnc_bytes){policy,sizeof(policy)-1},
      (tidyvnc_bytes){NULL,0},&error) == TIDYVNC_BUSY);
    CHECK(error.domain == TIDYVNC_DOMAIN_LOGGING && error.detail == TIDYVNC_LOGGING_FROZEN);
  }
  {
    tidyvnc_input_timing timing, saved;
    tidyvnc_handle timed = UINT64_MAX;
    unsigned wait_index;
    INIT(timing);
    CHECK(abi.features & TIDYVNC_FEATURE_INPUT_TIMING);
    CHECK(tidyvnc_input_timing_init(&timing,&error) == TIDYVNC_OK);
    CHECK(timing.pointer_interval_ms == 17 && timing.reserved == 0);
    saved = timing; timing.version = 2;
    CHECK(tidyvnc_input_timing_init(&timing,&error) == TIDYVNC_ABI_MISMATCH && timing.version == 2);
    timing = saved; timing.pointer_interval_ms = UINT32_MAX;
    CHECK(tidyvnc_session_create_with_input_timing(runtime,&session_options,0,&timing,&timed,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(timed == UINT64_MAX);
    timing = saved; timing.pointer_interval_ms = 0;
    CHECK(tidyvnc_session_create_with_input_timing(runtime,&session_options,0,&timing,&timed,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_session_close(timed,&error) == TIDYVNC_OK);
    for (wait_index=0;wait_index<5000 && tidyvnc_session_poll_drained(timed,NULL) == TIDYVNC_PENDING;++wait_index) abi_test_sleep();
    CHECK(tidyvnc_session_poll_drained(timed,NULL) == TIDYVNC_OK);
    CHECK(tidyvnc_release(timed,&error) == TIDYVNC_OK);
  }
  {
    tidyvnc_message_limits limits;
    tidyvnc_input_timing timing;
    tidyvnc_handle limited = UINT64_MAX;
    unsigned wait_index;
    INIT(limits); INIT(timing);
    CHECK(abi.features & TIDYVNC_FEATURE_MESSAGE_LIMITS);
    CHECK(tidyvnc_message_limits_init(&limits,&error) == TIDYVNC_OK);
    CHECK(limits.max_cut_text == 256u*1024 && limits.reserved == 0);
    CHECK(tidyvnc_input_timing_init(&timing,&error) == TIDYVNC_OK);
    limits.max_cut_text = UINT32_MAX;
    CHECK(tidyvnc_session_create_with_message_limits(runtime,&session_options,0,&timing,&limits,&limited,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(limited == UINT64_MAX);
    limits.max_cut_text = 0;
    CHECK(tidyvnc_session_create_with_message_limits(runtime,&session_options,0,&timing,&limits,&limited,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_session_close(limited,&error) == TIDYVNC_OK);
    for (wait_index=0;wait_index<5000 && tidyvnc_session_poll_drained(limited,NULL) == TIDYVNC_PENDING;++wait_index) abi_test_sleep();
    CHECK(tidyvnc_session_poll_drained(limited,NULL) == TIDYVNC_OK);
    CHECK(tidyvnc_release(limited,&error) == TIDYVNC_OK);
  }
  CHECK(tidyvnc_session_create(runtime,&session_options,&session,&error) == TIDYVNC_OK);
  {
    tidyvnc_geometry_options options; tidyvnc_canvas_viewport canvas;
    tidyvnc_geometry geometry, preserved; tidyvnc_damage damage; tidyvnc_rectangle rectangle, kept;
    INIT(options); INIT(canvas); INIT(geometry); INIT(damage); INIT(rectangle);
    CHECK(abi.features & TIDYVNC_FEATURE_CANVAS_GEOMETRY);
    options.remote_width=800; options.remote_height=500; options.units=1;
    options.viewport_width=150; options.viewport_height=150; options.backing_scale=2;
    options.pan_x=25; options.pan_y=50; options.scaling=(tidyvnc_bytes){(const uint8_t*)"100",3};
    canvas.width=600; canvas.height=300; canvas.x=300; canvas.region_width=300; canvas.region_height=300;
    CHECK(tidyvnc_desktop_canvas_geometry(&options,&canvas,.25,.25,&geometry,&error)==TIDYVNC_OK);
    CHECK(geometry.backing_width==800 && geometry.backing_height==500 && geometry.x==-162.5 && geometry.y==-25);
    CHECK(geometry.remote_x==325 && geometry.remote_y==50);
    damage.x=325; damage.y=50; damage.width=2; damage.height=2;
    CHECK(tidyvnc_desktop_canvas_damage(&options,&canvas,&damage,&rectangle,&error)==TIDYVNC_OK);
    CHECK(rectangle.x==0 && rectangle.y==0 && rectangle.width==1 && rectangle.height==1);
    options.pan_x=65535; options.pan_y=65535;
    CHECK(tidyvnc_desktop_canvas_geometry(&options,&canvas,.25,.25,&geometry,&error)==TIDYVNC_OK);
    CHECK(geometry.remote_x==500 && geometry.remote_y==200);
    options.pan_x=0; options.pan_y=0; options.scaling=(tidyvnc_bytes){(const uint8_t*)"Auto",4};
    CHECK(tidyvnc_desktop_canvas_geometry(&options,&canvas,0,0,&geometry,&error)==TIDYVNC_OK);
    CHECK(geometry.backing_width==600 && geometry.backing_height==300 && geometry.remote_x==400);
    preserved=geometry; kept=rectangle;
    canvas.region_width=301;
    CHECK(tidyvnc_desktop_canvas_geometry(&options,&canvas,0,0,&geometry,&error)==TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_desktop_canvas_damage(&options,&canvas,&damage,&rectangle,&error)==TIDYVNC_INVALID_ARGUMENT);
    canvas.region_width=300; canvas.x=UINT32_MAX;
    CHECK(tidyvnc_desktop_canvas_geometry(&options,&canvas,0,0,&geometry,&error)==TIDYVNC_INVALID_ARGUMENT);
    canvas.x=300; canvas.height=65536;
    CHECK(tidyvnc_desktop_canvas_geometry(&options,&canvas,0,0,&geometry,&error)==TIDYVNC_INVALID_ARGUMENT);
    canvas.height=300; canvas.region_height=0;
    CHECK(tidyvnc_desktop_canvas_geometry(&options,&canvas,0,0,&geometry,&error)==TIDYVNC_INVALID_ARGUMENT);
    canvas.region_height=300; canvas.version=2;
    CHECK(tidyvnc_desktop_canvas_geometry(&options,&canvas,0,0,&geometry,&error)==TIDYVNC_ABI_MISMATCH);
    canvas.version=1; canvas.size=1;
    CHECK(tidyvnc_desktop_canvas_damage(&options,&canvas,&damage,&rectangle,&error)==TIDYVNC_INVALID_ARGUMENT);
    canvas.size=sizeof(canvas); damage.x=UINT32_MAX;
    CHECK(tidyvnc_desktop_canvas_damage(&options,&canvas,&damage,&rectangle,&error)==TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_desktop_canvas_geometry(&options,&canvas,NAN,0,&geometry,&error)==TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_desktop_canvas_geometry(&options,NULL,0,0,&geometry,&error)==TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_desktop_canvas_geometry(NULL,&canvas,0,0,&geometry,&error)==TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_desktop_canvas_geometry(&options,&canvas,0,0,NULL,&error)==TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_desktop_canvas_damage(&options,&canvas,NULL,&rectangle,&error)==TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_desktop_canvas_damage(&options,&canvas,&damage,NULL,&error)==TIDYVNC_INVALID_ARGUMENT);
    CHECK(memcmp(&geometry,&preserved,sizeof(geometry))==0 && memcmp(&rectangle,&kept,sizeof(rectangle))==0);
  }
  {
    tidyvnc_display_layout_request request; tidyvnc_display_layout output, preserved;
    tidyvnc_display_monitor monitors[2] = {{42,-1000,0,1000,800,2000,1600},{7,0,0,1000,800,1000,800}};
    INIT(request); INIT(output); CHECK(abi.features & TIDYVNC_FEATURE_DISPLAY_LAYOUT);
    request.monitors=monitors; request.monitor_count=2;
    CHECK(tidyvnc_display_layout_compute(&request,&output,&error)==TIDYVNC_OK);
    CHECK(output.width==2000 && output.height==800 && !output.normalized && output.screen_count==2);
    CHECK(output.screens[0].id==7 && output.screens[0].x==1000 && output.screens[1].id==42 && output.screens[1].x==0);
    CHECK(output.screens[2].id==0 && output.screens[63].width==0);
    request.device_pixels=1;
    CHECK(tidyvnc_display_layout_compute(&request,&output,&error)==TIDYVNC_OK);
    CHECK(output.width==3000 && output.height==1600 && output.normalized && output.screens[0].x==2000);
    preserved=output;
    request.monitor_count=65; CHECK(tidyvnc_display_layout_compute(&request,&output,&error)==TIDYVNC_INVALID_ARGUMENT);
    request.monitor_count=0; CHECK(tidyvnc_display_layout_compute(&request,&output,&error)==TIDYVNC_INVALID_ARGUMENT);
    request.monitor_count=2; request.monitors=NULL;
    CHECK(tidyvnc_display_layout_compute(&request,&output,&error)==TIDYVNC_INVALID_ARGUMENT);
    request.monitors=monitors; monitors[1].id=42;
    CHECK(tidyvnc_display_layout_compute(&request,&output,&error)==TIDYVNC_INVALID_ARGUMENT);
    monitors[1].id=7; monitors[1].x=-1;
    CHECK(tidyvnc_display_layout_compute(&request,&output,&error)==TIDYVNC_INVALID_ARGUMENT);
    monitors[1].x=INT32_MAX;
    CHECK(tidyvnc_display_layout_compute(&request,&output,&error)==TIDYVNC_INVALID_ARGUMENT);
    monitors[1].x=0; monitors[1].width=UINT32_MAX;
    CHECK(tidyvnc_display_layout_compute(&request,&output,&error)==TIDYVNC_INVALID_ARGUMENT);
    monitors[1].width=1000; monitors[1].backing_width=0;
    CHECK(tidyvnc_display_layout_compute(&request,&output,&error)==TIDYVNC_INVALID_ARGUMENT);
    monitors[1].backing_width=1000; request.device_pixels=2;
    CHECK(tidyvnc_display_layout_compute(&request,&output,&error)==TIDYVNC_INVALID_ARGUMENT);
    request.device_pixels=1; request.version=2;
    CHECK(tidyvnc_display_layout_compute(&request,&output,&error)==TIDYVNC_ABI_MISMATCH);
    request.version=1; request.size=1;
    CHECK(tidyvnc_display_layout_compute(&request,&output,&error)==TIDYVNC_INVALID_ARGUMENT);
    request.size=sizeof(request); monitors[1].x=65535;
    CHECK(tidyvnc_display_layout_compute(&request,&output,&error)==TIDYVNC_RESOURCE_LIMIT);
    CHECK(tidyvnc_display_layout_compute(NULL,&output,&error)==TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_display_layout_compute(&request,NULL,&error)==TIDYVNC_INVALID_ARGUMENT);
    CHECK(memcmp(&output,&preserved,sizeof(output))==0);
  }
  {
    tidyvnc_desktop_layout_request request; tidyvnc_desktop_layout output, preserved;
    tidyvnc_remote_screen screens[2] = {{7,0,0,2,2,9},{8,0,0,2,2,0}};
    tidyvnc_operation op, before;
    INIT(request); INIT(output); INIT(op); CHECK(abi.features & TIDYVNC_FEATURE_DESKTOP_LAYOUT);
    request.width=2; request.height=2; request.screen_count=1; request.screens=screens;
    CHECK(tidyvnc_desktop_layout_validate(&request,&error)==TIDYVNC_OK);
    request.screen_count=2; CHECK(tidyvnc_desktop_layout_validate(&request,&error)==TIDYVNC_OK);
    screens[1].id=7; CHECK(tidyvnc_desktop_layout_validate(&request,&error)==TIDYVNC_INVALID_ARGUMENT);
    request.screen_count=1; request.width=65536;
    CHECK(tidyvnc_desktop_layout_validate(&request,&error)==TIDYVNC_INVALID_ARGUMENT);
    request.width=2; request.screen_count=256;
    CHECK(tidyvnc_desktop_layout_validate(&request,&error)==TIDYVNC_INVALID_ARGUMENT);
    request.screen_count=0; CHECK(tidyvnc_desktop_layout_validate(&request,&error)==TIDYVNC_INVALID_ARGUMENT);
    request.screen_count=1; request.screens=NULL;
    CHECK(tidyvnc_desktop_layout_validate(&request,&error)==TIDYVNC_INVALID_ARGUMENT);
    request.screens=screens; request.reserved=1;
    CHECK(tidyvnc_desktop_layout_validate(&request,&error)==TIDYVNC_INVALID_ARGUMENT);
    request.reserved=0; request.version=99;
    CHECK(tidyvnc_desktop_layout_validate(&request,&error)==TIDYVNC_ABI_MISMATCH);
    request.version=TIDYVNC_ABI_VERSION;
    CHECK(tidyvnc_desktop_layout_validate(NULL,&error)==TIDYVNC_INVALID_ARGUMENT);
    preserved=output; before=op;
    CHECK(tidyvnc_session_desktop_layout(session,1,&output,&error)==TIDYVNC_NOT_CONNECTED);
    CHECK(memcmp(&output,&preserved,sizeof(output))==0);
    CHECK(tidyvnc_session_desktop_layout(session,2,&output,&error)==TIDYVNC_STALE);
    CHECK(memcmp(&output,&preserved,sizeof(output))==0);
    CHECK(tidyvnc_session_request_desktop_layout(session,1,&request,&op,&error)==TIDYVNC_NOT_CONNECTED);
    CHECK(memcmp(&op,&before,sizeof(op))==0);
    CHECK(tidyvnc_session_request_desktop_layout(runtime,1,&request,&op,&error)==TIDYVNC_WRONG_HANDLE_TYPE);
    CHECK(memcmp(&op,&before,sizeof(op))==0);
  }

  CHECK(tidyvnc_session_snapshot(session,&snapshot,&error) == TIDYVNC_OK);
  CHECK(snapshot.state == TIDYVNC_STATE_IDLE && snapshot.generation == 1);
  {
    tidyvnc_sharing sharing; uint64_t revision = UINT64_MAX;
    INIT(sharing); CHECK(abi.features & TIDYVNC_FEATURE_SHARED_SESSION);
    CHECK(tidyvnc_session_sharing(session,&sharing,&error) == TIDYVNC_OK && sharing.shared == 0 && sharing.editable == 1);
    CHECK(tidyvnc_session_set_shared(session,sharing.generation,sharing.revision,2,&revision,&error) == TIDYVNC_INVALID_ARGUMENT && revision == UINT64_MAX);
    CHECK(tidyvnc_session_set_shared(session,sharing.generation,sharing.revision,1,&revision,&error) == TIDYVNC_OK && revision == 2);
    revision = UINT64_MAX;
    CHECK(tidyvnc_session_set_shared(session,sharing.generation,sharing.revision,0,&revision,&error) == TIDYVNC_STALE && revision == UINT64_MAX);
    CHECK(tidyvnc_session_sharing(session,&sharing,&error) == TIDYVNC_OK && sharing.shared == 1);
    CHECK(tidyvnc_session_set_shared(session,sharing.generation,sharing.revision,0,&revision,&error) == TIDYVNC_OK);
    sharing.version = 2;
    CHECK(tidyvnc_session_sharing(session,&sharing,&error) == TIDYVNC_ABI_MISMATCH);
    CHECK(tidyvnc_session_sharing(session,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_session_set_shared(session,1,1,0,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
  }

  {
    tidyvnc_security_configuration state, before;
    tidyvnc_security_update update;
    uint64_t revision = UINT64_MAX;
    CHECK(abi.features & TIDYVNC_FEATURE_SECURITY_RECONFIGURATION);
    INIT(state); INIT(update);
    CHECK(tidyvnc_session_security(session,&state,&error) == TIDYVNC_OK);
    CHECK(state.editable == 1 && state.revision == 1 && state.generation == 1);
    before = state;
    update.types = (tidyvnc_bytes){(const uint8_t*)"None",4};
    CHECK(tidyvnc_session_set_security(session,state.generation,state.revision,&update,&revision,&error) == TIDYVNC_OK && revision == 2);
    revision = UINT64_MAX;
    CHECK(tidyvnc_session_set_security(session,state.generation,state.revision,&update,&revision,&error) == TIDYVNC_STALE && revision == UINT64_MAX);
    CHECK(tidyvnc_session_security(session,&state,&error) == TIDYVNC_OK && state.revision == 2 && strcmp(state.types,"None") == 0);
    update.types = (tidyvnc_bytes){NULL,1};
    CHECK(tidyvnc_session_set_security(session,state.generation,state.revision,&update,&revision,&error) == TIDYVNC_INVALID_ARGUMENT && revision == UINT64_MAX);
    update.types = (tidyvnc_bytes){(const uint8_t*)before.types,strlen(before.types)};
    CHECK(tidyvnc_session_set_security(session,state.generation,state.revision,&update,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
    update.version = 2;
    CHECK(tidyvnc_session_set_security(session,state.generation,state.revision,&update,&revision,&error) == TIDYVNC_ABI_MISMATCH);
    update.version = 1;
    CHECK(tidyvnc_session_set_security(session,state.generation,state.revision,&update,&revision,&error) == TIDYVNC_OK && revision == 3);
    before = state; state.version = 2;
    CHECK(tidyvnc_session_security(session,&state,&error) == TIDYVNC_ABI_MISMATCH && state.revision == before.revision);
    CHECK(tidyvnc_session_security(runtime,&before,&error) == TIDYVNC_WRONG_HANDLE_TYPE);
  }

  {
    tidyvnc_connection_info info, before;
    CHECK(abi.features & TIDYVNC_FEATURE_CONNECTION_INFO);
    CHECK(abi.features & TIDYVNC_FEATURE_ENDPOINT_IDENTITY);
    CHECK(abi.features & TIDYVNC_FEATURE_PROMPT_SECURITY);
    INIT(info); before=info;
    CHECK(tidyvnc_session_information(session,1,&info,&error) == TIDYVNC_NOT_CONNECTED);
    CHECK(memcmp(&info,&before,sizeof(info)) == 0);
    CHECK(tidyvnc_session_information(session,2,&info,&error) == TIDYVNC_STALE);
    CHECK(tidyvnc_session_information(runtime,1,&info,&error) == TIDYVNC_WRONG_HANDLE_TYPE);
    CHECK(tidyvnc_session_information(session,1,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
    info.size=4;
    CHECK(tidyvnc_session_information(session,1,&info,&error) == TIDYVNC_INVALID_ARGUMENT);
    INIT(info); info.version=2;
    CHECK(tidyvnc_session_information(session,1,&info,&error) == TIDYVNC_ABI_MISMATCH);
  }
  {
    tidyvnc_encoding_schema schema, saved_schema;
    tidyvnc_encoding_value value, saved_value;
    tidyvnc_encoding_choice choice;
    tidyvnc_encoding_assignment assignment = {{(const uint8_t*)"QualityLevel",12},{(const uint8_t*)"7",1}};
    tidyvnc_handle encoding=0, copy=0, unchanged=UINT64_MAX;
    INIT(schema); INIT(value); INIT(choice);
    CHECK(abi.features & TIDYVNC_FEATURE_ENCODING);
    CHECK(tidyvnc_encoding_schema_at(0,&schema,&error) == TIDYVNC_OK);
    saved_schema=schema; schema.version=2;
    CHECK(tidyvnc_encoding_schema_at(0,&schema,&error) == TIDYVNC_ABI_MISMATCH);
    schema=saved_schema;
    CHECK(tidyvnc_encoding_schema_at(UINT32_MAX,&schema,&error) == TIDYVNC_NO_CHANGE);
    CHECK(memcmp(&schema,&saved_schema,sizeof(schema)) == 0);
    CHECK(tidyvnc_encoding_create(0,NULL,1,0,&unchanged,&error) == TIDYVNC_INVALID_ARGUMENT && unchanged == UINT64_MAX);
    CHECK(tidyvnc_encoding_create(0,&assignment,257,0,&unchanged,&error) == TIDYVNC_RESOURCE_LIMIT);
    CHECK(tidyvnc_encoding_create(0,&assignment,1,UINT32_MAX,&unchanged,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_encoding_create(0,&assignment,1,TIDYVNC_SOURCE_PROFILE,&encoding,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_encoding_get(encoding,TIDYVNC_ENCODING_QUALITY,&value,&error) == TIDYVNC_OK);
    CHECK(strcmp(value.value,"7") == 0 && value.source == TIDYVNC_SOURCE_PROFILE);
    saved_value=value; value.size=4;
    CHECK(tidyvnc_encoding_get(encoding,0,&value,&error) == TIDYVNC_INVALID_ARGUMENT);
    value=saved_value;
    CHECK(tidyvnc_encoding_get(encoding,UINT32_MAX,&value,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(memcmp(&value,&saved_value,sizeof(value)) == 0);
    assignment.value.length=UINT64_MAX;
    CHECK(tidyvnc_encoding_create(encoding,&assignment,1,3,&unchanged,&error) == TIDYVNC_RESOURCE_LIMIT);
    assignment.value.data=(const uint8_t*)"a\0b"; assignment.value.length=3;
    CHECK(tidyvnc_encoding_create(encoding,&assignment,1,3,&unchanged,&error) == TIDYVNC_INVALID_ARGUMENT);
    assignment.value.data=NULL; assignment.value.length=1;
    CHECK(tidyvnc_encoding_create(encoding,&assignment,1,3,&unchanged,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_encoding_create(session,NULL,0,3,&unchanged,&error) == TIDYVNC_WRONG_HANDLE_TYPE);
    CHECK(tidyvnc_session_create_with_encoding(runtime,&session_options,session,&unchanged,&error) == TIDYVNC_WRONG_HANDLE_TYPE);
    CHECK(unchanged == UINT64_MAX);
    CHECK(tidyvnc_session_apply_encoding(session,1,encoding,&operation,&error) == TIDYVNC_NOT_CONNECTED);
    CHECK(tidyvnc_session_encoding(session,&copy,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_release(copy,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_release(encoding,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_encoding_get(encoding,0,&value,&error) == TIDYVNC_INVALID_HANDLE);
    for (n=0;tidyvnc_encoding_choice_at(n,&choice,&error) == TIDYVNC_OK;++n) {
      if (!choice.available) {
        assignment.name.data=(const uint8_t*)"PreferredEncoding"; assignment.name.length=17;
        assignment.value.data=(const uint8_t*)choice.name; assignment.value.length=strlen(choice.name);
        CHECK(tidyvnc_encoding_create(0,&assignment,1,3,&unchanged,&error) == TIDYVNC_UNSUPPORTED);
        CHECK(error.domain == TIDYVNC_DOMAIN_ENCODING && (error.detail & 0xffff) == TIDYVNC_ENCODING_UNAVAILABLE);
      }
    }
  }
  {
    tidyvnc_clipboard_update update; tidyvnc_clipboard_info info;
    tidyvnc_clipboard_route route; tidyvnc_bytes bytes = {NULL,0};
    INIT(update); INIT(info); INIT(route); route.generation=1;
    CHECK(abi.features & TIDYVNC_FEATURE_CLIPBOARD);
    CHECK(tidyvnc_session_clipboard_policy(session,1,2,1,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_session_clipboard_policy(session,2,1,1,&error) == TIDYVNC_STALE);
    CHECK(tidyvnc_clipboard_get(session,&info,&error) == TIDYVNC_WRONG_HANDLE_TYPE);
    CHECK(tidyvnc_session_clipboard_offer(session,1,bytes,session,0,&operation,&error) == TIDYVNC_WRONG_HANDLE_TYPE);
    bytes.length=UINT64_MAX;
    CHECK(tidyvnc_session_clipboard_offer(session,1,bytes,0,0,&operation,&error) == TIDYVNC_RESOURCE_LIMIT);
    bytes.length=1;
    CHECK(tidyvnc_session_clipboard_offer(session,1,bytes,0,0,&operation,&error) == TIDYVNC_INVALID_ARGUMENT);
    bytes.data=(const uint8_t*)"a\0b"; bytes.length=3;
    CHECK(tidyvnc_session_clipboard_offer(session,1,bytes,0,0,&operation,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(operation.operation == 0);
    CHECK(tidyvnc_session_clipboard_check(session,&route,2,&error) == TIDYVNC_INVALID_ARGUMENT);
    route.version=2;
    CHECK(tidyvnc_session_clipboard_check(session,&route,0,&error) == TIDYVNC_ABI_MISMATCH);
    CHECK(tidyvnc_session_clipboard_clear(session,1,&operation,&error) == TIDYVNC_NOT_CONNECTED);
    update.size=4;
    CHECK(tidyvnc_session_take_clipboard(session,&update,&error) == TIDYVNC_INVALID_ARGUMENT);
    INIT(update);
    for (n=1;n<=4;++n) {
      tidyvnc_status status;
      CHECK(tidyvnc_session_clipboard_policy(session,1,0,0,&error) == TIDYVNC_OK);
      CHECK(tidyvnc_session_clipboard_policy(session,1,1,1,&error) == TIDYVNC_OK);
      abi_test_fail_after(n);
      status=tidyvnc_session_take_clipboard(session,&update,&error);
      abi_test_fail_after(0);
      CHECK(status == TIDYVNC_OK || status == TIDYVNC_OUT_OF_MEMORY);
      if (status != TIDYVNC_OK) CHECK(tidyvnc_session_take_clipboard(session,&update,&error) == TIDYVNC_OK);
      CHECK(update.kind == TIDYVNC_CLIPBOARD_INVALIDATED && update.text == 0);
      CHECK(tidyvnc_session_take_clipboard(session,&update,&error) == TIDYVNC_NO_CHANGE);
    }
  }
  CHECK(abi.features & TIDYVNC_FEATURE_CALLBACKS);
  {
    tidyvnc_callbacks callbacks; tidyvnc_handle subscription = 0;
    struct callback_counts counts = {0,0,0,0};
    INIT(callbacks);
    CHECK(tidyvnc_session_subscribe(session,&callbacks,&subscription,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(subscription == 0);
    callbacks.context = &counts; callbacks.retain_context = retain_context;
    callbacks.release_context = release_context; callbacks.ready = ready_callback;
    callbacks.reserved = 1;
    CHECK(tidyvnc_session_subscribe(session,&callbacks,&subscription,&error) == TIDYVNC_INVALID_ARGUMENT);
    callbacks.reserved = 0;
    for (n=1;n<=8;++n) {
      tidyvnc_status status;
      memset(&counts,0,sizeof(counts)); subscription = 0;
      abi_test_fail_after(n);
      status = tidyvnc_session_subscribe(session,&callbacks,&subscription,&error);
      abi_test_fail_after(0);
      CHECK(status == TIDYVNC_OK || status == TIDYVNC_OUT_OF_MEMORY);
      if (status == TIDYVNC_OK) {
        CHECK(drain_subscription(subscription));
        CHECK(counts.retained == 1 && counts.released == 1 && counts.calls == 1 && counts.errors == 0);
        CHECK(tidyvnc_release(subscription,NULL) == TIDYVNC_OK);
      } else CHECK(subscription == 0 && counts.calls == 0 && counts.retained == counts.released);
    }
  }
  CHECK(tidyvnc_session_take_event(session,&event,&error) == TIDYVNC_OK);
  CHECK(event.kind == TIDYVNC_EVENT_SNAPSHOT && event.snapshot.state == TIDYVNC_STATE_IDLE);
  CHECK(tidyvnc_session_take_event(session,&event,&error) == TIDYVNC_NO_CHANGE);
  CHECK(tidyvnc_session_refresh(session,1,&operation,&error) == TIDYVNC_NOT_CONNECTED);
  CHECK(operation.operation == 0);
  connect_options.endpoint.data = NULL; connect_options.endpoint.length = UINT64_MAX;
  CHECK(tidyvnc_session_connect(session,&connect_options,&operation,&error) == TIDYVNC_INVALID_ARGUMENT);
  connect_options.endpoint.data = (const uint8_t*)"bad\0host"; connect_options.endpoint.length = 8;
  CHECK(tidyvnc_session_connect(session,&connect_options,&operation,&error) == TIDYVNC_INVALID_ARGUMENT);
  CHECK(tidyvnc_session_key(session,1,1,65,0,2,&error) == TIDYVNC_INVALID_ARGUMENT);
  CHECK(tidyvnc_session_pointer(session,1,0,0,UINT32_MAX,&error) == TIDYVNC_INVALID_ARGUMENT);
  CHECK(tidyvnc_session_focus(session,2,1,&error) == TIDYVNC_STALE);
  CHECK(abi.features & TIDYVNC_FEATURE_INPUT_POLICY);
  CHECK(abi.features & TIDYVNC_FEATURE_INPUT_RELEASE);
  CHECK(abi.features & TIDYVNC_FEATURE_SHORTCUTS);
  {
    tidyvnc_handle shortcut = 777;
    uint32_t action = 123;
    CHECK(tidyvnc_shortcut_create(16,&shortcut,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(shortcut == 777);
    CHECK(tidyvnc_shortcut_create(1,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_shortcut_create(1,&shortcut,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_shortcut_key(runtime,0,0,1,&action,&error) == TIDYVNC_WRONG_HANDLE_TYPE);
    CHECK(action == 123);
    CHECK(tidyvnc_shortcut_key(shortcut,1,0xffe3,1,&action,&error) == TIDYVNC_OK);
    CHECK(action == TIDYVNC_SHORTCUT_NORMAL);
    action = 123;
    CHECK(tidyvnc_shortcut_key(shortcut,2,0x61,2,&action,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(action == 123);
    CHECK(tidyvnc_shortcut_key(shortcut,2,0x61,1,NULL,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_shortcut_modifiers(shortcut,16,&error) == TIDYVNC_INVALID_ARGUMENT);
    CHECK(tidyvnc_shortcut_key(shortcut,2,0x61,1,&action,&error) == TIDYVNC_OK);
    CHECK(action == TIDYVNC_SHORTCUT_ACTION);
    CHECK(tidyvnc_shortcut_reset(shortcut,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_shortcut_key(shortcut,1,0xffe3,1,&action,&error) == TIDYVNC_OK);
    CHECK(tidyvnc_shortcut_key(shortcut,1,0,0,&action,&error) == TIDYVNC_OK);
    CHECK(action == TIDYVNC_SHORTCUT_UNARM);
    CHECK(tidyvnc_release(shortcut,&error) == TIDYVNC_OK);
    action = 123;
    CHECK(tidyvnc_shortcut_key(shortcut,1,0,0,&action,&error) == TIDYVNC_INVALID_HANDLE);
    CHECK(action == 123);
    CHECK(tidyvnc_shortcut_reset(shortcut,&error) == TIDYVNC_INVALID_HANDLE);
  }
  CHECK(tidyvnc_session_release_input(0,1,&error) == TIDYVNC_INVALID_HANDLE);
  CHECK(tidyvnc_session_release_input(runtime,1,&error) == TIDYVNC_WRONG_HANDLE_TYPE);
  CHECK(tidyvnc_session_release_input(session,1,&error) == TIDYVNC_NOT_CONNECTED);
  CHECK(tidyvnc_session_release_input(session,0,&error) == TIDYVNC_STALE);
  CHECK(tidyvnc_session_input_policy(0,0,1,&error) == TIDYVNC_INVALID_HANDLE);
  CHECK(tidyvnc_session_input_policy(runtime,0,1,&error) == TIDYVNC_WRONG_HANDLE_TYPE);
  CHECK(tidyvnc_session_input_policy(session,2,0,&error) == TIDYVNC_INVALID_ARGUMENT);
  CHECK(tidyvnc_session_input_policy(session,0,2,&error) == TIDYVNC_INVALID_ARGUMENT);
  CHECK(tidyvnc_session_input_policy(session,0,1,&error) == TIDYVNC_OK);
  CHECK(tidyvnc_session_input_policy(session,1,0,&error) == TIDYVNC_OK);
  CHECK(tidyvnc_session_view_only(session,1,&error) == TIDYVNC_OK);
  {
    uint8_t user[]={'a','b'}, password[]={'s','e','c','r','e','t'};
    tidyvnc_mutable_bytes u={user,sizeof(user)}, p={password,sizeof(password)};
    CHECK(tidyvnc_session_reply_credentials(UINT64_MAX,1,1,u,p,&error) == TIDYVNC_INVALID_HANDLE);
    for (n=0;n<sizeof(user);++n) CHECK(user[n] == 0);
    for (n=0;n<sizeof(password);++n) CHECK(password[n] == 0);
    CHECK(strstr(error.message,"secret") == NULL);
    {
      uint8_t block[]={0xdb,0xd8,0x3c,0xfd,0x72,0x7a,0x14,0x58};
      CHECK(abi.features & TIDYVNC_FEATURE_PASSWORD_FILE_REPLY);
      CHECK(tidyvnc_session_reply_password_file(UINT64_MAX,1,1,
        (tidyvnc_mutable_bytes){block,sizeof(block)},&error) == TIDYVNC_INVALID_HANDLE);
      for (n=0;n<sizeof(block);++n) CHECK(block[n] == 0);
      block[0]=0xff;
      CHECK(abi.features & TIDYVNC_FEATURE_CREDENTIAL_BYTES);
      CHECK(tidyvnc_session_reply_credential_bytes(UINT64_MAX,1,1,
        (tidyvnc_mutable_bytes){NULL,0},(tidyvnc_mutable_bytes){block,1},&error) == TIDYVNC_INVALID_HANDLE);
      CHECK(block[0] == 0);
    }
  }
  CHECK(tidyvnc_retain(session,&error) == TIDYVNC_OK);
  CHECK(tidyvnc_release(session,&error) == TIDYVNC_OK);
  CHECK(tidyvnc_session_snapshot(session,&snapshot,&error) == TIDYVNC_OK);
  CHECK(tidyvnc_session_close(session,&error) == TIDYVNC_OK);
  CHECK(tidyvnc_session_close(session,&error) == TIDYVNC_OK);
  CHECK(tidyvnc_release(session,&error) == TIDYVNC_OK);
  CHECK(tidyvnc_release(session,&error) == TIDYVNC_INVALID_HANDLE);
  CHECK(tidyvnc_session_snapshot(session,&snapshot,&error) == TIDYVNC_INVALID_HANDLE);
  CHECK(tidyvnc_runtime_shutdown(runtime,&error) == TIDYVNC_OK);
  CHECK(tidyvnc_session_create(runtime,&session_options,&second,&error) == TIDYVNC_CLOSING && second == 0);
  CHECK(drain_runtime(runtime)); CHECK(tidyvnc_release(runtime,&error) == TIDYVNC_OK);
  /* Verify extended output storage is untouched and short headers do not write. */
  {
    struct { tidyvnc_abi_info value; uint64_t tail; } extended;
    INIT(extended.value); extended.value.size = sizeof(extended); extended.tail = UINT64_MAX;
    CHECK(tidyvnc_get_abi(&extended.value,&error) == TIDYVNC_OK && extended.tail == UINT64_MAX);
    abi.size = 4; abi.features = UINT64_MAX;
    CHECK(tidyvnc_get_abi(&abi,&error) == TIDYVNC_INVALID_ARGUMENT && abi.features == UINT64_MAX);
    error.version = 2;
    CHECK(tidyvnc_get_abi(&extended.value,&error) == TIDYVNC_ABI_MISMATCH);
    INIT(error);
  }
  /* Fail allocations on this C caller's thread, including after handle reservation.
   * Background workers are unaffected. Every failed create must leave output and
   * runtime admission usable, without crossing C with a C++ exception. */
  for (n=1;n<=32;++n) {
    tidyvnc_status status; tidyvnc_handle created=0;
    abi_test_fail_after(n);
    status=tidyvnc_encoding_create(0,NULL,0,0,&created,&error);
    abi_test_fail_after(0);
    CHECK(status == TIDYVNC_OK || status == TIDYVNC_OUT_OF_MEMORY);
    if (status == TIDYVNC_OK) CHECK(tidyvnc_release(created,&error) == TIDYVNC_OK);
    else CHECK(created == 0 && error.code == TIDYVNC_OUT_OF_MEMORY);
  }
  for (n=1;n<=48;++n) {
    tidyvnc_status status; tidyvnc_handle created=0;
    CHECK(tidyvnc_runtime_create(&runtime_options,&runtime,&error) == TIDYVNC_OK);
    abi_test_fail_after(n);
    status = tidyvnc_session_create(runtime,&session_options,&created,&error);
    abi_test_fail_after(0);
    CHECK(status == TIDYVNC_OK || status == TIDYVNC_OUT_OF_MEMORY);
    if (status == TIDYVNC_OK) CHECK(tidyvnc_release(created,&error) == TIDYVNC_OK);
    else CHECK(created == 0 && error.code == TIDYVNC_OUT_OF_MEMORY);
    CHECK(tidyvnc_runtime_shutdown(runtime,NULL) == TIDYVNC_OK);
    CHECK(drain_runtime(runtime)); CHECK(tidyvnc_release(runtime,NULL) == TIDYVNC_OK);
  }
  return 0;
}
