// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
// Run after building the app; see plans/native-ui/LOCALIZATION.md.
import Foundation
guard CommandLine.arguments.count == 3 else {
 fatalError("Usage: localization-bundle.swift APP_PATH CATALOG_PATH")
}
let bundle = Bundle(path: CommandLine.arguments[1])!
let data = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
let catalog = try JSONSerialization.jsonObject(with:data) as! [String:Any]
let strings = catalog["strings"] as! [String:[String:Any]]
for (key,entry) in strings {
 let locales = entry["localizations"] as! [String:[String:Any]]
 let unit = locales["en"]!["stringUnit"] as! [String:String]
 let expected = unit["value"]!
 let actual = bundle.localizedString(forKey:key,value:"MISSING CATALOG VALUE",table:nil)
 precondition(actual == expected,"Uncompiled or absent catalog key: \(key)")
}
let fallback = String(localized:"connection.issue.testMissing",defaultValue:"Safe English fallback",bundle:bundle,locale:Locale(identifier:"fr"))
precondition(fallback == "Safe English fallback")
let french = String(localized:"connection.issue.refused.title",defaultValue:"WRONG FALLBACK",bundle:bundle,locale:Locale(identifier:"fr"))
precondition(french == "Connection Refused")
precondition(bundle.developmentLocalization == "en")
// Values are arguments, never format strings; keep percent signs and Unicode
// literal when a server identity is inserted into a localized sentence.
let destination = "lab-%@-开发::5901"
let scope = String(localized:"authentication.confirm.key.scope",defaultValue:"This decision applies to \(destination). It can be forgotten in Saved Server Keys. Verify the fingerprint independently before saving.",bundle:bundle)
precondition(scope == "This decision applies to \(destination). It can be forgotten in Saved Server Keys. Verify the fingerprint independently before saving.")
let fingerprint = "AB:%@:CD"
let received = String(localized:"trust.received.spki",defaultValue:"Received SPKI SHA-256: \(fingerprint)",bundle:bundle)
precondition(received == "Received SPKI SHA-256: AB:%@:CD")
let bits: UInt32 = 2048
let keySize = String(localized:"trust.rsa.bits",defaultValue:"RSA server key: \(bits) bits",bundle:bundle)
precondition(keySize == "RSA server key: \(bits.formatted()) bits")
let algorithm = "SPKI SHA-256"
let saved = String(localized:"trust.library.fingerprint",defaultValue:"Saved \(algorithm): \(fingerprint)",bundle:bundle)
precondition(saved == "Saved SPKI SHA-256: AB:%@:CD")
let reason = "A fixed diagnostic containing % and 开发."
let launchFailure = String(localized:"credentials.launch.failure",defaultValue:"\(reason) Enter a password or cancel this attempt.",bundle:bundle)
precondition(launchFailure == reason + " Enter a password or cancel this attempt.")
let encoding = "fixture-%@-开发"
let unavailableEncoding = String(localized:"settings.encoding.choice.unavailable",defaultValue:"\(encoding) (unavailable)",bundle:bundle)
precondition(unavailableEncoding == encoding + " (unavailable)")
let inheritEncoding = String(localized:"settings.encoding.inherit.option",defaultValue:"Use app default for \(encoding)",bundle:bundle)
precondition(inheritEncoding == "Use app default for " + encoding)
let quality = "7"
let settingValue = String(localized:"settings.encoding.option.value",defaultValue:"\(encoding): \(quality)",bundle:bundle)
precondition(settingValue == encoding + ": " + quality)
let inherited = String(localized:"settings.inheritance.effective.value",defaultValue:"Effective value: \(encoding)",bundle:bundle)
precondition(inherited == "Effective value: " + encoding)
let mode = "125%x80%"
let scalingSource = String(localized:"settings.scaling.inherited.mode",defaultValue:"\(encoding): \(mode) (\(mode)).",bundle:bundle)
precondition(scalingSource == encoding + ": " + mode + " (" + mode + ").")
let aesBits = "256"
let security = String(localized:"settings.security.aes.authentication",defaultValue:"\(aesBits)-bit AES · \(encoding)",bundle:bundle)
precondition(security == "256-bit AES · " + encoding)
let percentLabel = String(localized:"settings.scaling.no.scaling.100",defaultValue:"No scaling (100%)",bundle:bundle)
precondition(percentLabel == "No scaling (100%)")
let displayIndex = 2.formatted(), displayName = "Studio-%@-开发", displayWidth = 1920.formatted()
let displayHeight = 1080.formatted(), displayScale = 2.formatted()
let display = String(localized:"settings.display.description",defaultValue:"\(displayIndex). \(displayName) — \(displayWidth) × \(displayHeight) points, \(displayScale)×",bundle:bundle)
precondition(display == displayIndex + ". " + displayName + " — " + displayWidth + " × " + displayHeight + " points, " + displayScale + "×")
let desktopSize = String(localized:"settings.resize.server.size",defaultValue:"The server’s desktop is now \(displayWidth) × \(displayHeight) pixels.",bundle:bundle)
precondition(desktopSize == "The server’s desktop is now " + displayWidth + " × " + displayHeight + " pixels.")
let resizeResult = UInt32.max.formatted()
let rejection = String(localized:"settings.resize.server.rejection",defaultValue:"The server rejected the requested size (result \(resizeResult)).",bundle:bundle)
precondition(rejection == "The server rejected the requested size (result " + resizeResult + ").")
let historyEndpoint = "[fe80::1%en0]::5901", historyGateway = "ssh://开发-%@.invalid:22"
let historyDestination = String(localized:"history.destination.gateway",defaultValue:"\(historyEndpoint) via \(historyGateway)",bundle:bundle)
precondition(historyDestination == historyEndpoint + " via " + historyGateway)
let removal = String(localized:"history.remove.destination",defaultValue:"Remove \(historyEndpoint) from recent connections",bundle:bundle)
precondition(removal == "Remove " + historyEndpoint + " from recent connections")
let historyLine = UInt32.max.formatted()
let lineIssue = String(localized:"history.import.invalid.text.line",defaultValue:"The history file contains invalid text on line \(historyLine).",bundle:bundle)
precondition(lineIssue == "The history file contains invalid text on line " + historyLine + ".")
let listenerFamily = "IPv6", listenerPort = "65535"
let listenerAddress = String(localized:"listener.address.port",defaultValue:"\(listenerFamily) port \(listenerPort)",bundle:bundle)
precondition(listenerAddress == "IPv6 port 65535")
let listenerSource = String(localized:"listener.source.port",defaultValue:"Source port \(listenerPort)",bundle:bundle)
precondition(listenerSource == "Source port 65535")
let enabledFamily = String(localized:"listener.family.enabled",defaultValue:"enabled",bundle:bundle)
let disabledFamily = String(localized:"listener.family.disabled",defaultValue:"disabled",bundle:bundle)
let listenerFamilies = String(localized:"listener.families",defaultValue:"IPv4: \(enabledFamily) · IPv6: \(disabledFamily)",bundle:bundle)
precondition(listenerFamilies == "IPv4: enabled · IPv6: disabled")
let documentName = "Studio-%@-开发", documentNumber = Int32.max.formatted()
let documentMonitor = String(localized:"document.monitor.file.assignment",defaultValue:"File monitor \(documentNumber): \(documentName)",bundle:bundle)
precondition(documentMonitor == "File monitor " + documentNumber + ": " + documentName)
let commandMonitor = String(localized:"document.monitor.commandline.assignment",defaultValue:"Command-line monitor \(documentNumber): \(documentName)",bundle:bundle)
precondition(commandMonitor == "Command-line monitor " + documentNumber + ": " + documentName)
let exportedMonitor = String(localized:"document.export.monitor.assignment",defaultValue:"\(documentName): monitor \(documentNumber)",bundle:bundle)
precondition(exportedMonitor == documentName + ": monitor " + documentNumber)
let documentLine = UInt32.max.formatted()
let ignoredField = String(localized:"document.notice.unknown",defaultValue:"Line \(documentLine): \(documentName) — Unknown field",bundle:bundle)
precondition(ignoredField == "Line " + documentLine + ": " + documentName + " — Unknown field")
let documentFailure = String(localized:"document.error.line",defaultValue:"Line \(documentLine): \(reason)",bundle:bundle)
precondition(documentFailure == "Line " + documentLine + ": " + reason)
let documentServer = String(localized:"document.server",defaultValue:"Server: \(historyEndpoint)",bundle:bundle)
precondition(documentServer == "Server: " + historyEndpoint)
let savedFile = String(localized:"document.save.success",defaultValue:"Saved \(documentName)",bundle:bundle)
precondition(savedFile == "Saved " + documentName)
let importOmission = String(localized:"import.defaults.not.imported",defaultValue:"Not imported",bundle:bundle)
let importNotice = String(localized:"import.defaults.notice",defaultValue:"Line \(documentLine), \(documentName): \(importOmission)",bundle:bundle)
precondition(importNotice == "Line " + documentLine + ", " + documentName + ": " + importOmission)
let clipboardSource = String(localized:"app.clipboard.send.source",defaultValue:"Send: \(documentName)",bundle:bundle)
precondition(clipboardSource == "Send: " + documentName)
let profileSource = String(localized:"app.profile.source",defaultValue:"Settings from profile: \(documentName)",bundle:bundle)
precondition(profileSource == "Settings from profile: " + documentName)
let informationSize = String(localized:"information.desktop.size",defaultValue:"\(displayWidth) × \(displayHeight)",bundle:bundle)
precondition(informationSize == displayWidth + " × " + displayHeight)
let informationRate = UInt64.max.formatted()
let informationSpeed = String(localized:"information.speed",defaultValue:"\(informationRate) kbit/s",bundle:bundle)
precondition(informationSpeed == informationRate + " kbit/s")
print("PASS \(strings.count) packaged catalog values; untranslated-language and missing-key fallbacks; English development region")
print("PASS destination/fingerprint/setting interpolation preserves literal values and UInt32 key sizes")
