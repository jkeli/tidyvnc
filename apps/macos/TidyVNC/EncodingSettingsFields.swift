// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

// All effective defaults, ranges and decoder choices come from the core schema.
struct EncodingSettingsFields: View {
  let values: [NativeEncodingOption: NativeEncodingValue]
  let schema: [NativeEncodingSchema]
  let choices: [NativeEncodingChoice]
  var liveOnly = false
  let setValue: (NativeEncodingOption, String) -> Void
  var inheritValue: ((NativeEncodingOption) -> Void)? = nil
  var body: some View { fields(values.mapValues(\.value)) }
  private func fields(_ values: [NativeEncodingOption: String]) -> some View {
    let automatic = values[.autoSelect] == "on"
    return VStack(alignment: .leading, spacing: 10) {
      flag(String(localized:"settings.encoding.choose.encoding.and.quality.automatically", defaultValue:"Choose encoding and quality automatically"), .autoSelect, values)
      HStack {
        Picker(String(localized:"settings.encoding.preferred.encoding", defaultValue:"Preferred encoding"), selection: text(.preferred, values)) {
          ForEach(choices, id: \.name) { choice in
            Text(choice.available ? choice.name : String(localized:"settings.encoding.choice.unavailable", defaultValue:"\(choice.name) (unavailable)")).tag(choice.name).disabled(!choice.available)
          }
        }.disabled(automatic || isReadOnly(.preferred))
          .accessibilityLabel(String(localized:"settings.encoding.preferred.encoding", defaultValue:"Preferred encoding"))
          .accessibilityIdentifier("preferences.encoding.preferred")
        source(.preferred,label:String(localized:"settings.encoding.preferred.encoding", defaultValue:"Preferred encoding"))
      }
      flag(String(localized:"settings.encoding.full.color", defaultValue:"Full color"), .fullColor, values).disabled(automatic)
      HStack {
        Picker(String(localized:"settings.encoding.reduced.colors", defaultValue:"Reduced colors"), selection: text(.lowColorLevel, values)) {
          ForEach(bounds(.lowColorLevel), id: \.self) { value in
            Text(colorLabel(value)).tag(String(value))
          }
        }.disabled(automatic || values[.fullColor] == "on" || isReadOnly(.lowColorLevel))
          .accessibilityLabel(String(localized:"settings.encoding.reduced.colors", defaultValue:"Reduced colors"))
        source(.lowColorLevel,label:String(localized:"settings.encoding.reduced.colors", defaultValue:"Reduced colors"))
      }
      flag(String(localized:"settings.encoding.use.custom.compression", defaultValue:"Use custom compression"), .customCompression, values)
      number(String(localized:"settings.encoding.compression", defaultValue:"Compression"), .compression, values).disabled(values[.customCompression] != "on")
      flag(String(localized:"settings.encoding.allow.jpeg", defaultValue:"Allow JPEG"), .noJPEG, values, inverted: true)
      number(String(localized:"settings.encoding.jpeg.quality", defaultValue:"JPEG quality"), .quality, values).disabled(automatic || values[.noJPEG] == "on")
      Text(String(localized:"settings.encoding.automatic.selection.can.adjust.the.encoding.color.depth.and.jpeg.quality.during", defaultValue:"Automatic selection can adjust the encoding, color depth and JPEG quality during a connection."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func text(_ option: NativeEncodingOption, _ values: [NativeEncodingOption: String]) -> Binding<String> {
    Binding(get: { values[option] ?? "" }, set: { setValue(option, $0) })
  }
  private func source(_ option: NativeEncodingOption, label: String) -> some View {
    HStack(spacing: 4) {
      Text(sourceLabel(values[option]?.source)).font(.caption).foregroundStyle(.secondary)
      if let inheritValue, values[option]?.source == .profile {
        Button { inheritValue(option) } label: { Image(systemName: "arrow.uturn.backward") }
          .buttonStyle(.borderless).help(String(localized:"settings.encoding.inherit.option", defaultValue:"Use app default for \(label)"))
          .accessibilityLabel(String(localized:"settings.encoding.inherit.option", defaultValue:"Use app default for \(label)"))
          .accessibilityIdentifier("preferences.encoding.inherit.\(option.rawValue)")
      }
    }.frame(width: 100, alignment: .trailing)
  }
  private func sourceLabel(_ source: NativeOptionSource?) -> String {
    switch source {
    case .compiled: return String(localized:"settings.encoding.built.in", defaultValue:"Built-in")
    case .appDefaults: return String(localized:"settings.encoding.app.default", defaultValue:"App default")
    case .profile: return String(localized:"settings.encoding.profile", defaultValue:"Profile")
    case .session: return String(localized:"settings.encoding.connection.override", defaultValue:"Connection override")
    case .document: return String(localized:"settings.encoding.connection.file", defaultValue:"Connection file")
    case .commandLine: return String(localized:"settings.encoding.command.line", defaultValue:"Command line")
    case nil: return String(localized:"settings.encoding.unavailable", defaultValue:"Unavailable")
    }
  }
  private func flag(_ label: String, _ option: NativeEncodingOption, _ values: [NativeEncodingOption: String], inverted: Bool = false) -> some View {
    HStack {
      Toggle(label, isOn: Binding(get: { (values[option] == "on") != inverted },
        set: { setValue(option, $0 != inverted ? "on" : "off") }))
      Spacer(); source(option,label:label)
    }.disabled(isReadOnly(option))
  }
  private func isReadOnly(_ option: NativeEncodingOption) -> Bool {
    liveOnly && schema.first(where: { $0.id == option })?.live != true
  }
  private func bounds(_ option: NativeEncodingOption) -> ClosedRange<Int> {
    guard let field = schema.first(where: { $0.id == option }) else { return 0...0 }
    return Int(field.minimum)...Int(field.maximum)
  }
  private func number(_ label: String, _ option: NativeEncodingOption, _ values: [NativeEncodingOption: String]) -> some View {
    HStack {
      Stepper(String(localized:"settings.encoding.option.value", defaultValue:"\(label): \(values[option] ?? "")"), value: Binding(get: { Int(values[option] ?? "") ?? bounds(option).lowerBound },
        set: { setValue(option, String($0)) }), in: bounds(option))
        // The stepper's visible text is a sibling; name the incrementor itself for VoiceOver.
        .accessibilityLabel(label).accessibilityValue(values[option] ?? "")
      Spacer(); source(option,label:label)
    }.disabled(isReadOnly(option))
  }
  private func colorLabel(_ value: Int) -> String {
    switch value { case 0: return String(localized:"settings.encoding.8.colors", defaultValue:"8 colors"); case 1: return String(localized:"settings.encoding.64.colors", defaultValue:"64 colors"); case 2: return String(localized:"settings.encoding.256.colors", defaultValue:"256 colors"); default: return String(value) }
  }
}
