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
      flag("Choose encoding and quality automatically", .autoSelect, values)
      HStack {
        Picker("Preferred encoding", selection: text(.preferred, values)) {
          ForEach(choices, id: \.name) { choice in
            Text(choice.available ? choice.name : "\(choice.name) (unavailable)").tag(choice.name).disabled(!choice.available)
          }
        }.disabled(automatic || isReadOnly(.preferred)).accessibilityIdentifier("preferences.encoding.preferred")
        source(.preferred)
      }
      flag("Full color", .fullColor, values).disabled(automatic)
      HStack {
        Picker("Reduced colors", selection: text(.lowColorLevel, values)) {
          ForEach(bounds(.lowColorLevel), id: \.self) { value in
            Text(colorLabel(value)).tag(String(value))
          }
        }.disabled(automatic || values[.fullColor] == "on" || isReadOnly(.lowColorLevel))
        source(.lowColorLevel)
      }
      flag("Use custom compression", .customCompression, values)
      number("Compression", .compression, values).disabled(values[.customCompression] != "on")
      flag("Allow JPEG", .noJPEG, values, inverted: true)
      number("JPEG quality", .quality, values).disabled(automatic || values[.noJPEG] == "on")
      Text("Automatic selection can adjust the encoding, color depth and JPEG quality during a connection.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func text(_ option: NativeEncodingOption, _ values: [NativeEncodingOption: String]) -> Binding<String> {
    Binding(get: { values[option] ?? "" }, set: { setValue(option, $0) })
  }
  private func source(_ option: NativeEncodingOption) -> some View {
    HStack(spacing: 4) {
      Text(sourceLabel(values[option]?.source)).font(.caption).foregroundStyle(.secondary)
      if let inheritValue, values[option]?.source == .profile {
        Button { inheritValue(option) } label: { Image(systemName: "arrow.uturn.backward") }
          .buttonStyle(.borderless).help("Use app default")
          .accessibilityLabel("Use app default for \(schema.first(where: { $0.id == option })?.name ?? "encoding")")
      }
    }.frame(width: 100, alignment: .trailing)
  }
  private func sourceLabel(_ source: NativeOptionSource?) -> String {
    switch source {
    case .compiled: return "Built-in"
    case .appDefaults: return "App default"
    case .profile: return "Profile"
    case .session: return "Connection override"
    case .document: return "Connection file"
    case .commandLine: return "Command line"
    case nil: return "Unavailable"
    }
  }
  private func flag(_ label: String, _ option: NativeEncodingOption, _ values: [NativeEncodingOption: String], inverted: Bool = false) -> some View {
    HStack {
      Toggle(label, isOn: Binding(get: { (values[option] == "on") != inverted },
        set: { setValue(option, $0 != inverted ? "on" : "off") }))
      Spacer(); source(option)
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
      Stepper("\(label): \(values[option] ?? "")", value: Binding(get: { Int(values[option] ?? "") ?? bounds(option).lowerBound },
        set: { setValue(option, String($0)) }), in: bounds(option))
      Spacer(); source(option)
    }.disabled(isReadOnly(option))
  }
  private func colorLabel(_ value: Int) -> String {
    switch value { case 0: return "8 colors"; case 1: return "64 colors"; case 2: return "256 colors"; default: return String(value) }
  }
}
