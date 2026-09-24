/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include "Invocation.h"
#include "LoggingPolicy.h"
#include <viewer/core/EncodingOptions.h>
#include <viewer/core/DocumentOptions.h>
#include <viewer/core/SecurityOptions.h>
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

bool viewer::canonicalParameter(const std::string& name, const std::string& value,
                                std::string& canonicalName, std::string& canonicalValue) {
  try {
    DocumentAssignment canonical;
    if (documentOptionValue({name,value},canonical)) {
      canonicalName = std::move(canonical.name); canonicalValue = std::move(canonical.value); return true;
    }
    const auto schema = invocationOptions({true,true,true,true});
    const auto spec = std::find_if(schema.begin(),schema.end(),[&](const InvocationOption& option) {
      return core::asciiParameterEqual(name,option.name.c_str()) ||
             (!option.alias.empty() && core::asciiParameterEqual(name,option.alias.c_str()));
    });
    if (spec == schema.end()) return false;
    std::string result = value;
    if (spec->boolean) {
      bool flag;
      if (!core::parseBooleanValue(value,flag)) throw InvocationError(InvocationProblem::InvalidValue,0);
      result = flag ? "on" : "off";
    } else if (spec->name == "PointerEventInterval" || spec->name == "MaxCutText") {
      char* end; errno = 0; const auto number = std::strtol(value.c_str(),&end,0);
      if (errno == ERANGE || *end || number < 0 || number > INT_MAX) throw InvocationError(InvocationProblem::InvalidValue,0);
      result = std::to_string(number);
    } else if (spec->name == "Log") {
      // Pure candidate parsing only. Registry/target admission belongs to the
      // startup adapter. Preserve original spelling for later resolution.
      LoggingPolicy::parse(value);
    } else if (spec->name == "GnuTLSPriority") {
      // The same bounded GnuTLS preflight as saved settings and drafts, so an
      // invalid command-line priority fails at startup rather than at connect.
      validateTLSPriority(value);
    }
    canonicalName = spec->name; canonicalValue = std::move(result);
    return true;
  } catch (const LoggingError&) {
    throw InvocationError(InvocationProblem::InvalidValue,0);
  } catch (const SecurityOptionError&) {
    throw InvocationError(InvocationProblem::InvalidValue,0);
  } catch (const DocumentError& error) {
    throw InvocationError(error.code == DocumentErrorCode::Unavailable ? InvocationProblem::Unavailable : InvocationProblem::InvalidValue,0);
  }
}

InvocationSyntax InvocationSyntax::validatingValues() const {
  auto result = *this;
  for (auto& field : result.fields) {
    std::string name, value;
    try {
      if (!canonicalParameter(field.name,field.value,name,value))
        throw InvocationError(InvocationProblem::UnknownOption,field.argument);
    } catch (const InvocationError& error) {
      throw InvocationError(error.problem,field.argument);
    }
    field.value = std::move(value);
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
