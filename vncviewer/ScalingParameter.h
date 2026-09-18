/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIGERVNC_SCALING_PARAMETER_H
#define TIGERVNC_SCALING_PARAMETER_H
#include <core/Configuration.h>
#include "DesktopTransform.h"
#include <stdexcept>
class ScalingParameter : public core::StringParameter {
public:
  ScalingParameter(const char* name, const char* desc)
    : core::StringParameter(name, desc, "100") {}
  bool setParam(const char* v) override {
    try {
      ScalingSettings parsed=ScalingSettings::parse(v);
      std::string canonical=parsed.serialize();
      if(!core::StringParameter::setParam(canonical.c_str())) return false;
      current=parsed;
      return true;
    } catch (const std::invalid_argument&) { return false; }
  }
  ScalingSettings settings() const { return current; }
private:
  ScalingSettings current;
};
#endif
