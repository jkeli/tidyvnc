/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include "Invocation.h"
#include "LoggingPolicy.h"
#include <viewer/core/EncodingOptions.h>
#include <viewer/core/DocumentOptions.h>
#include <core/ParameterArgument.h>
#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstdlib>

using namespace viewer;
InvocationCapabilities InvocationCapabilities::compiled() {
  InvocationCapabilities result;
#ifdef HAVE_GNUTLS
  result.tls = true;
#endif
#ifdef HAVE_AUDIO
  result.audio = true;
#endif
#if !defined(WIN32) && !defined(__APPLE__)
  result.x11 = true;
#endif
#ifndef WIN32
  result.tunnel = true;
#endif
  return result;
}

InvocationSyntax InvocationSyntax::validatingValues() const {
  auto result = *this;
  const auto schema = invocationOptions({true,true,true,true});
  for (auto& field : result.fields) {
    try {
      DocumentAssignment canonical;
      if (documentOptionValue({field.name,field.value},canonical)) {
        field.value = std::move(canonical.value); continue;
      }
      const auto spec = std::find_if(schema.begin(),schema.end(),[&](const InvocationOption& option) { return option.name == field.name; });
      if (spec == schema.end()) throw InvocationError(InvocationProblem::UnknownOption,field.argument);
      if (spec->boolean) {
        bool flag;
        if (!core::parseBooleanValue(field.value,flag)) throw InvocationError(InvocationProblem::InvalidValue,field.argument);
        field.value = flag ? "on" : "off";
      } else if (field.name == "PointerEventInterval" || field.name == "MaxCutText") {
        char* end; errno = 0; const auto value = std::strtol(field.value.c_str(),&end,0);
        if (errno == ERANGE || *end || value < 0 || value > INT_MAX) throw InvocationError(InvocationProblem::InvalidValue,field.argument);
        field.value = std::to_string(value);
      } else if (field.name == "Log") {
        // Pure candidate parsing only. Registry/target admission belongs to the
        // startup adapter. Preserve original spelling for later resolution.
        LoggingPolicy::parse(field.value);
      }
    } catch (const LoggingError&) {
      throw InvocationError(InvocationProblem::InvalidValue,field.argument);
    } catch (const DocumentError& error) {
      throw InvocationError(error.code == DocumentErrorCode::Unavailable ? InvocationProblem::Unavailable : InvocationProblem::InvalidValue,field.argument);
    }
  }
  return result;
}
std::vector<InvocationOption> viewer::invocationOptions(InvocationCapabilities caps) {
  using C = InvocationCategory;
  std::vector<InvocationOption> result;
  auto add = [&](const char* name, bool flag, C category, bool available = true, const char* alias = "") {
    result.push_back({name,alias,flag,available,category});
  };
  for (const auto& field : encodingSchema())
    add(field.name,field.type == OptionType::Boolean,C::Encoding,true,field.alias ? field.alias : "");
  add("PointerEventInterval",false,C::Input);
  add("EmulateMiddleButton",true,C::Input);
  add("DotWhenNoCursor",true,C::Input);
  add("AlwaysCursor",true,C::Input);
  add("CursorType",false,C::Input);
  add("AlertOnFatalError",true,C::Connection);
  add("ReconnectOnError",true,C::Connection);
  add("PasswordFile",false,C::CredentialFile,true,"passwd");
  add("Maximize",true,C::Display);
  add("FullScreen",true,C::Display);
  add("FullScreenMode",false,C::Display);
  add("FullScreenAllMonitors",true,C::Display);
  add("FullScreenSelectedMonitors",false,C::Display);
  add("DesktopSize",false,C::Display);
  add("geometry",false,C::Display);
  add("listen",true,C::Listen);
  add("ScalingFactor",false,C::Display);
  add("ScalingQuality",false,C::Display);
  add("DesktopPixelUnits",false,C::Display);
  add("RemoteResize",true,C::Display);
  add("ViewOnly",true,C::Input);
  add("Shared",true,C::Connection);
  add("Audio",true,C::Platform,caps.audio);
  add("AcceptClipboard",true,C::Input);
  add("SendClipboard",true,C::Input);
  add("SetPrimary",true,C::Platform,caps.x11);
  add("SendPrimary",true,C::Platform,caps.x11);
  add("display",false,C::Platform,caps.x11);
  add("ShortcutModifiers",false,C::Input);
  add("FullscreenSystemKeys",true,C::Input);
  add("via",false,C::Tunnel,caps.tunnel);
  add("SecurityTypes",false,C::Security);
  add("X509CA",false,C::Security,caps.tls);
  add("X509CRL",false,C::Security,caps.tls);
  add("GnuTLSPriority",false,C::Security,caps.tls);
  add("MaxCutText",false,C::Input);
  add("UseIPv4",true,C::Network);
  add("UseIPv6",true,C::Network);
  add("Log",false,C::Logging);
  return result;
}
InvocationSyntax InvocationSyntax::parse(const std::vector<std::string>& arguments, InvocationCapabilities caps) {
  if (arguments.size() > maximumArguments) throw InvocationError(InvocationProblem::TooManyArguments,0);
  size_t total = 0;
  for (size_t i = 0; i < arguments.size(); ++i) {
    const auto& arg = arguments[i];
    if (arg.size() > maximumArgumentBytes || arg.size() > maximumBytes-total)
      throw InvocationError(InvocationProblem::TooLarge,i+1);
    total += arg.size();
    if (arg.find('\0') != std::string::npos) throw InvocationError(InvocationProblem::NullByte,i+1);
  }
  const auto schema = invocationOptions(caps);
  InvocationSyntax result;
  for (size_t i = 0; i < arguments.size(); ++i) {
    const auto& arg = arguments[i];
    core::ParameterArgument part;
    if (core::splitParameterArgument(arg,part)) {
      const auto found = std::find_if(schema.begin(),schema.end(),[&](const InvocationOption& option) {
        return core::asciiParameterEqual(part.name,option.name.c_str()) ||
          (!option.alias.empty() && core::asciiParameterEqual(part.name,option.alias.c_str()));
      });
      if (found != schema.end()) {
        if (!found->available) throw InvocationError(InvocationProblem::Unavailable,i+1);
        const auto source = i+1;
        size_t valueSource = source;
        if (!part.hasValue) {
          // Retained BoolParameter lookahead excludes AliasParameter. Preserve
          // that distinction: '-FullColour off' enables color and leaves 'off'
          // as the operand; '-FullColour=off' disables it.
          const bool canonical = core::asciiParameterEqual(part.name,found->name.c_str());
          if (found->boolean && !(canonical && i+1 < arguments.size() && core::isSeparateBooleanArgument(arguments[i+1]))) {
            part.value = "1"; valueSource = 0;
          } else {
            if (i+1 == arguments.size()) throw InvocationError(InvocationProblem::MissingValue,source);
            part.value = arguments[++i]; valueSource = i+1;
          }
        }
        result.fields.push_back({found->name,std::move(part.value),found->category,source,valueSource});
        continue;
      }
    }
    if (arg == "-h" || arg == "--help" || arg == "-v" || arg == "--version") {
      // Keep preceding assignments for typed validation: an invalid option
      // before --help must still fail. The unused positional operand can go.
      result.positional.clear(); result.positionalArgument = 0;
      result.requestedAction = arg == "-h" || arg == "--help" ? InvocationAction::Help : InvocationAction::Version;
      return result;
    }
    if (!arg.empty() && arg[0] == '-') throw InvocationError(InvocationProblem::UnknownOption,i+1);
    // Retained empty argv operands do not occupy the single positional slot.
    if (arg.empty()) continue;
    if (result.hasOperand()) throw InvocationError(InvocationProblem::ExtraOperand,i+1);
    result.positional = arg; result.positionalArgument = i+1;
  }
  return result;
}
