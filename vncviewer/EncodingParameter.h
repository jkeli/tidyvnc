/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_ENCODING_PARAMETER_H
#define TIDYVNC_ENCODING_PARAMETER_H

#include <core/Configuration.h>
#include <viewer/core/EncodingOptions.h>

// Compatibility adapters retain the parameter registry and existing UI while
// making defaults, ranges, enum capabilities and text validation core-owned.
template<class Base> class EncodingParameter : public Base {
public:
  using Base::setParam;
  bool setParam(const char* text) override {
    if (this->immutable) return true;
    if (!text) return false;
    try {
      const auto options = viewer::EncodingOptions().withPatch(
        {{this->getName(), text}}, viewer::OptionSource::Session);
      return Base::setParam(options.value(id).c_str());
    } catch (const viewer::OptionError&) {
      return false;
    }
  }
protected:
  template<typename... Args>
  EncodingParameter(viewer::EncodingOption option, const char* description, Args... args)
    : Base(viewer::encodingSchema(option).name, description, args...), id(option) {}
private:
  viewer::EncodingOption id;
};
class EncodingBoolParameter : public EncodingParameter<core::BoolParameter> {
public:
  EncodingBoolParameter(viewer::EncodingOption option, const char* description)
    : EncodingParameter(option, description,
        viewer::EncodingOptions().value(option) == "on") {}
};
class EncodingIntParameter : public EncodingParameter<core::IntParameter> {
public:
  EncodingIntParameter(viewer::EncodingOption option, const char* description)
    : EncodingParameter(option, description,
        std::stoi(viewer::EncodingOptions().value(option)),
        viewer::encodingSchema(option).minimum, viewer::encodingSchema(option).maximum) {}
};
class EncodingEnumParameter : public EncodingParameter<core::EnumParameter> {
public:
  EncodingEnumParameter(viewer::EncodingOption option, const char* description)
    : EncodingParameter(option, describe(description).c_str(), choices(),
                        viewer::encodingSchema(option).defaultValue) {}
private:
  static std::string describe(const char* description) {
    std::string result = std::string(description) + " (";
    for (const auto& choice : viewer::encodingChoices()) {
      if (!choice.available) continue;
      if (result.back() != '(') result += ", ";
      result += choice.name;
    }
    return result + ")";
  }
  static std::set<const char*> choices() {
    std::set<const char*> values;
    for (const auto& choice : viewer::encodingChoices())
      if (choice.available) values.insert(choice.name);
    return values;
  }
};
#endif
