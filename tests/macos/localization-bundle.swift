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
print("PASS \(strings.count) packaged catalog values; untranslated-language and missing-key fallbacks; English development region")
print("PASS destination/fingerprint interpolation preserves literal values and UInt32 key sizes")
