# Reviewed MSVC /W4 suppressions for the portable core (plans/native-ui-winui
# CORE.md section 2, TODO W1.3). Each entry says why it is suppressed rather
# than fixed. GCC and Clang builds keep their own stricter warning set.
set(TIDYVNC_MSVC_SUPPRESSED_WARNINGS
  # C4100 unreferenced formal parameter: virtual overrides and callbacks keep
  # named parameters for documentation, as GCC's -Wunused-parameter is off.
  4100
  # C4127 conditional expression is constant: used deliberately in templates
  # and sizeof checks.
  4127
  # C4200 zero-sized array in struct: none expected; kept visible (not listed).
  # C4244/C4267 narrowing conversions: the shared protocol code converts
  # between size_t, int and fixed-width wire types at checked boundaries;
  # GCC's -Wconversion is not enabled either.
  4244 4267
  # C4245 signed/unsigned conversion in initialisation, same policy as above.
  4245
  # C4389/C4018 signed/unsigned comparison: same policy as GCC's
  # -Wsign-compare, which the existing flags leave on only via -Wall for C++.
  4389 4018
  # C4456-C4459 declaration hides previous declaration: covered by GCC's
  # -Wshadow on the other toolchains.
  4456 4457 4458 4459
  # C4702 unreachable code: false positives after noreturn throws.
  4702
  # C4706 assignment within conditional expression: idiomatic loops.
  4706
  # C4101 unreferenced local variable: named catch parameters kept for
  # readability in shared code.
  4101
  # C4146 unary minus on unsigned: RFB pseudo-encodings are defined as
  # negative values of unsigned wire types on purpose.
  4146
  # C4310 cast truncates constant value: tests build deliberately invalid
  # fixed-width values to check ABI validation.
  4310
  # C4324 structure padded due to alignment specifier: informational.
  4324
  # C4611 setjmp and C++ destruction: libjpeg's error recovery; the jumps
  # never cross frames with live C++ objects (same code as the MinGW build).
  4611
  # C4996 deprecated POSIX names and CRT functions: the portable code keeps
  # the POSIX spellings shared with GCC and Clang.
  4996)
foreach(warning ${TIDYVNC_MSVC_SUPPRESSED_WARNINGS})
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /wd${warning}")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /wd${warning}")
endforeach()
