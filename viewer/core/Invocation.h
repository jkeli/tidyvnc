/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_INVOCATION_H
#define TIDYVNC_INVOCATION_H
#include <cstddef>
#include <stdexcept>
#include <string>
#include <vector>

namespace viewer {
enum class InvocationAction { Launch, Help, Version };
enum class InvocationProblem { TooManyArguments, TooLarge, NullByte, UnknownOption, MissingValue, Unavailable, ExtraOperand, InvalidValue = 8 };
class InvocationError : public std::invalid_argument {
public:
  InvocationError(InvocationProblem problem_, size_t argument_)
    : std::invalid_argument("Invalid viewer invocation"), problem(problem_), argument(argument_) {}
  const InvocationProblem problem;
  const size_t argument; // One-based excluding executable; zero for total limits.
};
enum class InvocationCategory { Connection, Encoding, Input, Display, Security, CredentialFile, Logging, Network, Listen, Tunnel, Platform };
struct InvocationCapabilities {
  InvocationCapabilities(bool tls_ = false, bool audio_ = false, bool x11_ = false, bool tunnel_ = false)
    : tls(tls_), audio(audio_), x11(x11_), tunnel(tunnel_) {}
  bool tls, audio, x11, tunnel;
  static InvocationCapabilities compiled();
};
struct InvocationOption {
  std::string name, alias;
  bool boolean, available;
  InvocationCategory category;
};
// The viewer's argument catalog, including known unavailable platform options.
// Encoding names/aliases/types come from the shared encoding schema. Availability
// describes compiled/platform syntax, not completion of a frontend's adapters.
std::vector<InvocationOption> invocationOptions(InvocationCapabilities);

// One parameter's canonical name and value, with the same validation as
// InvocationSyntax::validatingValues: names and aliases match ASCII
// case-insensitively across the whole catalog (available or not), file-catalog
// fields use the connection-file rules, booleans become on/off and numbers
// decimal. Returns false for an unknown name; an invalid value throws
// InvocationError with argument 0. Paths, routes and geometry stay literal.
bool canonicalParameter(const std::string& name, const std::string& value,
                        std::string& canonicalName, std::string& canonicalValue);

struct InvocationAssignment {
  std::string name, value;
  InvocationCategory category;
  size_t argument, valueArgument; // valueArgument == 0 for an implicit true.
};

// Owned syntax only. Not a validated or authorized session configuration.
// All occurrences remain ordered for subsequent typed validation and precedence.
// Never consults globals/environment/files, runs commands, expands shell text,
// opens sockets, mutates settings, logs values or infers file-vs-Unix-socket type.
// PasswordFile is a path, never read here. No plaintext-password option is added.
class InvocationSyntax {
public:
  static constexpr size_t maximumArguments = 4096;
  static constexpr size_t maximumArgumentBytes = 65536;
  static constexpr size_t maximumBytes = 1024 * 1024;
  // arguments excludes argv[0]. Entire input is resource/NUL checked first.
  // Help/version stop parsing at their position, after earlier syntax succeeds.
  static InvocationSyntax parse(const std::vector<std::string>& arguments,
                                InvocationCapabilities = InvocationCapabilities::compiled());
  // Validate every occurrence before returning a canonical copy. String-valued
  // paths/routes/geometry remain literal; their interpretation belongs to the
  // host. Log triples/level bounds are checked without looking up/mutating log
  // writers or targets. No cross-field migration or frontend admission occurs.
  InvocationSyntax validatingValues() const;
  InvocationAction action() const { return requestedAction; }
  const std::vector<InvocationAssignment>& assignments() const { return fields; }
  bool hasOperand() const { return positionalArgument != 0; }
  const std::string& operand() const { return positional; }
  size_t operandArgument() const { return positionalArgument; }
private:
  InvocationAction requestedAction = InvocationAction::Launch;
  std::vector<InvocationAssignment> fields;
  std::string positional;
  size_t positionalArgument = 0;
};
}
#endif
