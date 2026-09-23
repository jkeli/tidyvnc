# Native UI parity and acceptance inventory

Inventory checkpoint: `6d69ccb5`, inspected 2026-09-22. This is the N0.1 map of
retained macOS behavior, native replacements and acceptance work. **No row is
accepted for cutover merely because its replacement exists.** Automated evidence
below is scoped to contracts/models/fixtures. Actual window/menu/panel keyboard,
VoiceOver, installed OS behavior and physical display/input gates remain open
unless a dated observation explicitly proves that particular action.

[CAPABILITIES.md](CAPABILITIES.md) is the companion inventory of **all 47 canonical
parameters**, three aliases, compiled defaults, ranges, feature availability and
live/next-attempt semantics. Parameter rows there are part of this control map,
including CLI-only parameters with no graphical control. [TODO.md](TODO.md)
remains the full implementation/acceptance tracker, not a count of screens drawn.

## Source and evidence notation

All app filenames below are in [apps/macos/TidyVNC](../../apps/macos/TidyVNC).
`Options` means [OptionsDialog.cxx](../../vncviewer/OptionsDialog.cxx), `Server`
means [ServerDialog.cxx](../../vncviewer/ServerDialog.cxx), `Auth` means
[AuthDialog.cxx](../../vncviewer/AuthDialog.cxx), `Viewport` means
[Viewport.cxx](../../vncviewer/Viewport.cxx), `Desktop` means
[DesktopWindow.cxx](../../vncviewer/DesktopWindow.cxx), and `Launch` means
[vncviewer.cxx](../../vncviewer/vncviewer.cxx) / [OSX glue](../../vncviewer/cocoa.mm).
These retained files define the comparison behavior, not native implementation.

The evidence codes refer to actual registered tests in
[tests/macos/CMakeLists.txt](../../tests/macos/CMakeLists.txt), with corresponding
Swift fixtures in the same directory. The latest full run of all **88** native
tests passed in `build/native-ui-frontend/verification/run-yhdlyz2o/`; this inventory
adds no new behavior/test result. A fixture proves only its assertions, not every
manual criterion sharing an evidence code.

| Code | Automated evidence / detail record |
| --- | --- |
| EP | `NativeEndpoint.ValidationAndFormGating`; CONNECTION.md |
| HI | `NativeHistory.ModelAndConnectionRouting`, `NativeProfiles.AtomicHistoryAndPersistence` |
| PR | `NativeProfiles.EditorAndSessionDefaults`, `NativePreferences.RevisionAndPersistence` |
| ST | `NativeSettings.DraftRendering`; expanded/RTL/minimum-size images, LOCALIZATION.md |
| AU | `NativeCredentials.AuthenticationRetention`, `NativeCredentials.StorePolicyAndLifetime`, `NativeCredentials.CanonicalIdentity`; KEYCHAIN.md, CREDENTIAL-INPUTS.md |
| TR | `NativeTrust.PolicyAndPresentation`, `NativeTrust.LegacyStoreAndDecisions`, `NativeTrust.ScopedPersistenceAndRecovery`, `NativeTrust.HostKeyPersistenceAndPolicy`; TRUST.md |
| SE | `NativeSecurity.SelectionPersistenceAndWire`, `NativeTrust.ConfiguredFilesAndInheritance`; SECURITY.md |
| EN | `NativeEncoding.DraftAndSessionIsolation`; shared encodingoptions/sessionencoding core tests |
| IN | `NativeInput.DraftRoutingAndRelease`, `NativeInput.PersistenceAndInitialPolicy`, `NativeShortcuts.ClassificationAndRouting`, `NativeShortcuts.AppKitDispatchAndCaptureLifetime` |
| CB | `NativeClipboard.PasteboardAndRouting`; core clipboard wire/channel tests |
| SC | `NativeScaling.DraftGeometryAndIsolation`, `NativeScaling.PersistenceAndInitialGeometry`, `NativeDesktop.CanvasGeometryAndPresentation`; CANVAS.md |
| FS | `NativeDisplay.TopologyAndSelection`, `NativeDesktop.FullscreenOwnershipAndTransitions`, `NativeFullscreen.ConnectionAndPresentation`, `NativeFullscreen.PersistenceAndSources`, `NativeDesktop.FullscreenComparisonHarness`; FULLSCREEN.md |
| RR | `NativeRemoteLayout.WireAndLifetime`, `NativeRemoteResize.PolicyAndViewport`, `NativeRemoteResize.PersistenceAndSources`, `NativeFullscreen.AutomaticRemoteLayout`; REMOTE-RESIZE.md |
| CO | `NativeConnection.OptionsPersistenceAndWire`, `NativeConnection.ErrorsAndRetry`, `NativePresentation.StructuredRecoveryAndRedaction`; CONNECTION.md |
| DT | `NativeDesktop.RenderingAndInput`, `NativeDesktop.SurfaceFocusAndCommands`, `NativeDesktop.SharedCanvasCoordination`, `NativePresentation.CompositionDamageAndDrain`, `NativeCursor.PresentationAndDrain`, `NativeRenderer.TilesAndBoundedScheduling` |
| CM | `NativeCommands.RoutingAndModifierLifetime`, `NativeDesktop.AccessiblePanning`, `NativeFullscreen.StatisticsAndInputIsolation` |
| DO | `NativeDocuments.FileReviewAndAdmission`, `NativeDocuments.SemanticsAndSessionResolution`, `NativeDocuments.LaunchRoutingAndQuit`, `NativeDocuments.SwiftUIWindowActionLifetime`, `NativeDocuments.DisplayMappingRecovery`; DOCUMENTS.md |
| EX | `NativeDocuments.LiveExportAndLossReview`, `NativeDocuments.AtomicSaveAndReviewLifecycle`, `NativeDocuments.ExportMappingAndSheetLifetime` |
| IM | `NativeImport.DefaultsProjectionAndCommit`, `NativeImport.SourceDiscoveryAndReviewLifetime`, `NativeImport.NativePresentationAndFirstUse`, `NativeImport.DefaultsMappingRecovery`; IMPORTS.md |
| IH | `NativeImport.HistoryProjectionAndTransaction`, `NativeImport.HistoryPresentationAndFirstUse`; IMPORTS.md |
| CL | `NativeInvocation.SyntaxOwnershipAndCatalog`, `NativeInvocation.ResolutionAndPrecedence`, `NativeInvocation.StrictBootstrapAndConnection`, `NativeInvocation.SwiftUIFirstWindowOwnership`, `NativeInvocation.SwiftUIFileReviewOwnership`, `NativeInvocation.FileMonitorPrecedenceAndRecovery`; CLI.md and 32 executable terminal cases |
| CP | `NativeInvocation.NetworkFamilyPolicyAndWire`, `NativeInvocation.PointerTimingAndWire`, `NativeInvocation.ClipboardMessageLimitsAndWire`, `NativeInvocation.InitialWindowPlacement`, `NativeInvocation.ProcessLoggingStartup` |
| LC | `NativeCredentials.PasswordFileReaderAndReply`, `NativeCredentials.LaunchOwnershipAndPrecedence`, `NativeCredentials.LaunchEnvironmentCapture` |
| LI | `NativeListener.CallbacksHandoffAndDrain`, `NativeListener.PresentationAndConnectionRouting`; LISTEN.md |
| SH | `NativeTunnel.ProcessOwnershipAndForwarding`, `NativeTunnel.ConnectionControllerLifecycle`, `NativeTunnel.AskpassTransportAndInteraction`, isolated/controller/askpass OpenSSH and three HostKey algorithm tests; TUNNELS.md, SSH-CONFIGURATION.md |
| LO | `NativeLocalization.CompilerCatalogAudit`, packaged 1050 UI + 2 InfoPlist values, strict signature/CLI and branding checks; LOCALIZATION.md, BUILD.md |

## PLAN §9 coverage index

Each original row has a dedicated group below. Shared Settings/profile/draft rules
apply to every field in the parameter inventory, rather than treating a tab as one
undifferentiated control.

| PLAN §9 row | Detailed IDs |
| --- | --- |
| Server dialog/recent/endpoint/import | C01–C10, F01–F14 |
| Authentication | A01–A09 |
| Certificate/server-key decisions | T01–T08 |
| Compression/color | O01–O08, CAPABILITIES encoding rows |
| Security | S01–S07, CAPABILITIES security rows |
| Input/shortcuts/clipboard | I01–I13, K01–K09 |
| Scaling | Z01–Z12 |
| Display/miscellaneous | D01–D12 |
| Live Options/saved defaults | P01–P09 |
| Desktop/secondary views | V01–V10 |
| Context/shortcut actions | M01–M14, K01–K09 |
| App/Dock/open/new/quit | L01–L13 |
| Connection info/performance overlay | Q01–Q04 |
| Errors/reconnect/Local Network | E01–E06 |
| Open/Save/overwrite/import | F01–F14 |
| About/credits/help | H01–H04 |

## Connection form, recent hosts and profiles

| ID | Retained source / parameter or action | Native replacement | Evidence; remaining acceptance action |
| --- | --- | --- | --- |
| C01 | Server: endpoint entry, default Connect | ConnectionContent / ConnectionModel / EndpointIssueView | EP, CL; type host/display/explicit port/IPv6 scope/Unix path, invalid input gates Connect, Return acts once |
| C02 | Server: recent suggestions and history limit | RecentConnectionsView / NativeRecentHistory | HI; choose recent without unwanted connection, 20-entry bounded deduplication, history disabled/clear behavior, no secret display |
| C03 | Server: Connect | ConnectionModel / native controller | EP, CO; connect keeps local UI responsive and binds result to its own window |
| C04 | Server: Cancel / active connection Cancel | ConnectionContent / controller | CO, AU; Escape/cancel while DNS/transport/auth/store work is pending, no late sheet/session resurrection |
| C05 | Server: Options | PreferencesSettingsView plus per-connection settings menus | ST; distinguish defaults from this connection, preserve copied drafts |
| C06 | Server: Load | TidyVNCApp.openDocument / DocumentReviewView | DO; native panel/review/Cancel/keyboard flow; no premature connection |
| C07 | Server: Save As | DocumentExportView / document save coordinator | EX; actual panel extension/overwrite/cancel acceptance |
| C08 | Server: About | standard native About panel | LO; actual panel already has limited UI-ACCEPTANCE observations; finish keyboard/VoiceOver/selectable credits |
| C09 | Launch `via`; native addition gateway field | ConnectionContent / NativeSSHGateway / tunnel controller | SH; validate/edit gateway before attempt; show gateway identity distinct from VNC endpoint |
| C10 | Native addition saved-profile connection | ProfileLibraryView / profile WindowGroup / NativeProfileLibrary | PR; create/select/connect profile in its own window; defaults/overrides and gateway copied once |

## Authentication and trust

| ID | Retained source / parameter or action | Native replacement | Evidence; remaining acceptance action |
| --- | --- | --- | --- |
| A01 | Auth: server/security banner | AuthenticationSheet / NativePrompt | AU, TR; endpoint/protocol/security context visible, unencrypted variants never labeled secure |
| A02 | Auth: Username when required | AuthenticationSheet TextField | AU; focus/name/Unicode input, omitted for password-only methods |
| A03 | Auth: Password | AuthenticationSheet SecureField | AU; secure accessibility behavior, no clipboard/log/default/profile export leakage |
| A04 | Auth: keep password for reconnect | password lifetime picker: use once/session/Keychain | AU; each retention choice has actual lifetime/close/retry evidence; installed Keychain prompts still required |
| A05 | Auth: OK / Cancel | Authenticate / Cancel actions | AU; Return submits once, Escape cancels, generation/duplicate/close/quit safeguards |
| A06 | Native addition use session password | AuthenticationSheet / credential coordinator | AU; explicit use, retry after wrong credential, two-session isolation |
| A07 | Native addition use/forget saved password | AuthenticationSheet / NativeCredentialStore | AU; actual access-denied/locked/interaction policy and deletion of selected identity only |
| A08 | Native addition replace saved password | replace toggle / remember decision | AU; explicit replacement consent, store failure leaves authentication recovery possible |
| A09 | SSH password/passphrase | SSHAuthenticationSheet | SH; gateway/account/key context, secure field, Cancel/deadline/close and multiwindow prompt routing |
| T01 | CConn: certificate identity/reason | AuthenticationSheet / TrustDetailsView / NativeTrustPresentation | TR; issuer/subject/fingerprint/validity/reasons readable and copyable where appropriate |
| T02 | CConn: server key expected/received | TrustDetailsView / saved host-key policy | TR; changed expected/received identities remain distinct and expanded details scroll |
| T03 | CConn: reject/cancel default | trust Cancel action | TR; Return safely cancels; no accidental acceptance on presentation |
| T04 | CConn: connection-only decision | Connect Once | TR; scoped to this attempt, no saved exception; unsupported bypass is unavailable |
| T05 | Native addition save/replace decision | Review Decision → Save/Replace and Connect confirmation | TR; explicit scope/replacement, persistence failure and stale generation cannot auto-connect |
| T06 | Native addition reload saved decisions | AuthenticationSheet / store coordinator | TR; failed reads recover explicitly without silently trusting |
| T07 | Native addition trust libraries | TrustLibraryView: selection/details/reload/remove | TR, ST; separate key/certificate stores, per-entry Forget/confirmation, destination field + Ask Again/confirmation, legacy exception suppression, reload and corruption/revision failure recovery |
| T08 | SSH new/changed gateway key review | SSHAuthenticationSheet / NativeSSHHostKey | SH; Ed25519/RSA/ECDSA fingerprint and algorithm, explicit Trust and Save, changed key rejection, save failure never falls back to silent trust |

## Options: compression and security

Each of the eight encoding controls has its own parameter/default/range and
live-change row in CAPABILITIES. Available encodings and the 15 security methods
are listed individually there; unavailable choices cannot become fake controls.

| ID | Retained source / parameter or action | Native replacement | Evidence; remaining acceptance action |
| --- | --- | --- | --- |
| O01 | Options: AutoSelect | EncodingSettingsFields automatic toggle | EN, ST; manual dependent controls correctly disable, dormant choices survive |
| O02 | Options: PreferredEncoding six choices | encoding picker populated from shared catalog | EN; each available choice negotiates and displays correctly; H.264 disabled build is explicit |
| O03 | Options: FullColor | full-color toggle | EN; automatic policy/status versus stored preference is understandable |
| O04 | Options: LowColorLevel medium/low/very low | reduced-color picker | EN; all three levels, dormant value, dependent gating |
| O05 | Options: NoJPEG inverted allow toggle | Allow JPEG | EN; inversion and reset accessibility name correct |
| O06 | Options: CustomCompressLevel | custom compression toggle | EN; inactive level retained |
| O07 | Options: CompressLevel 0–9 | compression editor | EN; bounds, invalid draft, keyboard apply/cancel |
| O08 | Options: QualityLevel 0–9 | quality editor | EN; JPEG/auto dependency, bounds and draft preservation |
| S01 | Options: None / anonymous TLS / X.509 / RSA-AES encryption groups | SecuritySettingsFields leaf-method toggles | SE; mapping preserves every combination, unavailable methods explained, no unintended broadening |
| S02 | Options: None / VNC / username-password authentication | same explicit method catalog | SE; auth shape/security context coherent for each enabled method |
| S03 | Options: X509CA path and chooser | TrustFileSettingsFields | SE; choose/clear/inherit/path provenance and unreadable file recovery |
| S04 | Options: X509CRL path and chooser | TrustFileSettingsFields | SE; revocation input preserved independently of CA; failure does not silently remove policy |
| S05 | CLI GnuTLSPriority; advanced disclosure, override toggle, editor and Use Library Default | SecuritySettingsFields / shared preflight | SE; invalid expression blocks save/apply, independent inheritance |
| S06 | Native override/inherit allowed-methods toggle | SecuritySettingsFields / NativeSecurityPreferences | SE; empty explicit allow-list differs from inherited defaults |
| S07 | Live security policy changes | SessionSecuritySheet | SE; disconnect required; revision/generation checks; reconnect uses new policy only for this session |

## Options: input and clipboard

| ID | Retained source / parameter or action | Native replacement | Evidence; remaining acceptance action |
| --- | --- | --- | --- |
| I01 | Options: ViewOnly | InputSettingsSheet / InputDefaultsFields | IN; block physical and synthetic input; release held state when enabling |
| I02 | Options: EmulateMiddleButton | same input views | IN; left/right chord, timeout, capture loss and focus release with physical mouse |
| I03 | Options: AlwaysCursor | cursor fallback toggle | IN, DT; server invisible/missing cursor versus fallback |
| I04 | Options: CursorType Dot/System | cursor picker | IN, DT; selected shape survives disabling/re-enabling fallback, hotspot/density |
| I05 | Options: FullscreenSystemKeys | fullscreen keyboard toggle | IN; actual capture permission/denial/revocation; no global capture for ordinary input |
| I06 | Options: ShortcutModifiers Ctrl | modifier toggle | IN; exact mask and held-state release |
| I07 | Options: ShortcutModifiers Shift | modifier toggle | IN; exact mask and held-state release |
| I08 | Options: ShortcutModifiers Alt/Option | modifier toggle | IN; alias and macOS Option labeling |
| I09 | Options: ShortcutModifiers Super/Cmd | modifier toggle | IN; Cmd/Win/Super alias, native app shortcuts versus remote input |
| I10 | Options: AcceptClipboard | defaults/profile and connection receive toggle | CB; route to active session, disabled receive, remote echo suppression and Unicode/newlines |
| I11 | Options: SendClipboard | defaults/profile and connection send toggle | CB; active/focused route, size limits and no cross-session broadcast |
| I12 | Options: SetPrimary/SendPrimary | absent on macOS, rejected CLI | CL; X11-only exclusion, retained Linux behavior preserved |
| I13 | CLI PointerEventInterval/MaxCutText | invocation policy snapshots; no GUI control | CP; timing/zero/bounds/clipboard wire limits; see both exact parameter rows |

## Options: all scaling controls

Source: Options.createScalingPage; native ScalingDefaultsFields /
ScalingSettingsSheet with NativeScalingDraft. Every row requires SC/ST plus
physical density/viewport acceptance; a geometry fixture is not a screen capture
of physical presentation.

| ID | Retained control / parameter | Native replacement / acceptance action |
| --- | --- | --- |
| Z01 | ScalingFactor unscaled | mode picker; verify 100 logical and device identity at 1×/2× |
| Z02 | Auto | stretch mode; fill viewport with independent axes |
| Z03 | FixedRatio | aspect-fit mode; preserve aspect and centering |
| Z04 | FitWidth | fit width; vertical extent/pan correct |
| Z05 | FitHeight | fit height; horizontal extent/pan correct |
| Z06 | uniform percentage | editable percentage; fractional range and canonical save |
| Z07 | exact WxH | editable size; independent dimensions, remote size unchanged |
| Z08 | independent X%xY% | editable percentages; both axes preserve intended transform |
| Z09 | Size or percentage field/help/validation | mode-specific drafts, values survive mode switches, invalid input cannot apply |
| Z10 | ScalingQuality Nearest/Bilinear/Area | quality picker; all three filters and cursor sampling, downsampling damage/edges |
| Z11 | DesktopPixelUnits Logical/Device | units picker; move among differing scale displays without losing intent |
| Z12 | multi-monitor scaling warning / error recovery | fullscreen/canvas status and fallback; dimension limit, topology loss, fit recovery remain actionable |

## Display, remote resize and miscellaneous

| ID | Retained source / parameter or action | Native replacement | Evidence; remaining acceptance action |
| --- | --- | --- | --- |
| D01 | Options: windowed FullScreen off | FullscreenDefaultsFields / FullscreenSettingsSheet | FS; windowed startup and restore frame/focus |
| D02 | Options: current monitor | current-display mode | FS; choose based on actual host window, not stale display index |
| D03 | Options: all monitors | all-display mode | FS; physical arrangement/mixed density/Spaces/hotplug |
| D04 | Options: selected monitors | selected mode + visual chooser | FS; each monitor toggle/number, nonempty requirement, disconnected selection recovery |
| D05 | Options: visual monitor arrangement | Native display snapshot and selection views | FS; physical order preserved in RTL, labels/keyboard/VoiceOver/selection feedback |
| D06 | DesktopSize initial server dimensions | RemoteResizeSettingsFields / RemoteResizePolicySheet | RR; blank/valid/invalid size, next-attempt effect clear |
| D07 | RemoteResize dynamic policy | same policy controls | RR; coalescing, server capability/refusal, view-only gate and fullscreen layout |
| D08 | Native explicit remote layout | RemoteResizeSheet | RR; width/height/screens validation, one operation, result/timeout/cancel and late reply |
| D09 | Options: Shared | ConnectionSettingsFields / SessionConnectionSheet in same source | CO; ClientInit wire value, disconnected edit only |
| D10 | Options: ReconnectOnError | same connection controls | CO; Retry optional, explicit and scoped to matching failure/endpoint |
| D11 | Options: Audio when compiled | no native audio control/backend | CAPABILITIES; disabled build explicit; no unsupported feature masquerading as usable |
| D12 | CLI geometry/Maximize | NativeWindowStartupPolicy / coordinator | CP; initial size/edge anchors/zoom; no repeated reapplication after user movement |

## Saved defaults, live drafts and profile management

Source: Options OK/Cancel and saved parameter subset; native
PreferencesSettingsView, per-session sheets and ProfileLibraryView. For **each**
field in CAPABILITIES that has a GUI editor, test the applicable rules here,
including dormant values and field-specific reset labels.

| ID | Action | Native implementation | Evidence; remaining acceptance action |
| --- | --- | --- | --- |
| P01 | Open defaults / switch sections | PreferencesSettingsView / NativePreferencesDraft | ST, PR; keyboard/VoiceOver section navigation, min size, no field lost |
| P02 | Change field / effective source | shared fields / sourced snapshots | ST, PR; built-in/default/profile/session provenance visible and accurate |
| P03 | Apply/save defaults | preferences draft/store | PR; atomic revision update, other open sessions unchanged, next connection receives update |
| P04 | Cancel/reload draft | preference and session draft owners | ST, PR; Escape discards edits; stale external revision requires reload |
| P05 | Reset field / use inherited value | per-option reset/inheritance controls | ST, EN, IN, SC, SE; distinguish explicit default value from absent override, accessible name matches label |
| P06 | Apply live connection draft / cancel | Input/Scaling/Fullscreen/RemoteResize/Encoding sheets | relevant feature fixtures; changes affect one session, stale generation closes/rejects, Cancel has no mutation |
| P07 | Create/edit/delete profile | ProfileLibraryView / NativeProfileLibrary | PR; name/endpoint/gateway, per-field override/inherit, deletion confirmation, conflicts/failures |
| P08 | Profile Connect / refresh / recovery | profile library/model / profile connection scene | PR; selected immutable profile snapshot, no late replacement, no secret profile serialization |
| P09 | Defaults/profile storage unavailable | ConnectionRoot retry/use-built-ins paths | PR, CO; explicit fallback only, selected profile errors not silently discarded |

## Desktop views, menu actions and shortcuts

| ID | Retained source / behavior | Native replacement | Evidence; remaining acceptance action |
| --- | --- | --- | --- |
| V01 | Desktop: title/size/status and close | ConnectionContent / NativeDesktopView / AppCoordinator | DT, CO; correct owning endpoint/session, close joins work |
| V02 | Desktop: framebuffer/scrollbars/pan | NativeDesktopCanvas / native view | SC, DT; scroll/trackpad/keyboard pan, bounds and pointer inverse transform |
| V03 | Desktop: primary/secondary fullscreen | NativeFullscreenController / shared canvas | FS, DT; one session, multiple views, primary ownership/handoff |
| V04 | Desktop: focus/activation | surface and desktop focus coordinators | DT, IN; key window/menu/clipboard/capture follow active view; focus loss releases |
| V05 | Viewport: cursor shape/hotspot/visibility | NativeCursorPresentation / cursor sampler | DT; invisible/missing/large/color cursor and density changes |
| V06 | Viewport: key repeats/modifier-only/layout | native key mapper / shortcut state / input queue | IN; physical layout/dead keys/IME policy, no duplicated text/key events |
| V07 | Viewport: buttons/wheel/pointer timing | native input adapter / bounded core queue | DT, IN, CP; physical wheel/chord/move/release and overflow behavior |
| V08 | Desktop: resize/damage/filter redraw | NativePresentation / tile scheduler | DT, SC; stress resize, correct old-frame lease/damage and no stale delivery |
| V09 | Desktop: hotplug/Spaces/sleep/wake | display/fullscreen/input coordinators | FS, IN; physical topology and network transitions; clean capture/release/reconnect recovery |
| V10 | Desktop performance/long lifetime | retained frame/tile/presentation ownership | DT; matched FLTK/native idle/scroll/1080p/4K/multiview p50/p95/CPU/memory budgets still unmeasured |
| M01 | Viewport Disconnect | DesktopActions / DesktopContextMenu | CM, CO; active session only, no unrelated window closed |
| M02 | Viewport Full screen | same / NativeDesktopCommand.fullscreen | CM, FS; correct selection state, entry/exit/focus, Ctrl-Cmd-F |
| M03 | Viewport Minimize | same / .minimize | CM; owning window, Cmd-M, fullscreen restrictions |
| M04 | Viewport Resize window to session | same / .fitWindow | CM, SC; transformed desktop size and visible-frame limit |
| M05 | Viewport Ctrl toggle | same / .control | CM; held state/checkmark and release on focus/disconnect/close |
| M06 | Viewport Alt toggle | same / .alt | CM; held state/checkmark and release rules |
| M07 | Viewport Send Ctrl-Alt-Del | same / .controlAltDelete | CM; ordered synthetic chord, existing held modifiers, view-only enforcement |
| M08 | Viewport Refresh | model.refresh | CM; request belongs to active connection, disconnected disabled |
| M09 | Viewport Options | Connection Settings submenu / separate context entries | ST, CM; Fullscreen/Input/Remote Resize/Scaling/Connection/Security/Encoding all reachable; disconnected requirements clear |
| M10 | Viewport Connection info | ConnectionInformationSheet | CM; owning-session information and close/focus |
| M11 | Viewport About | standard About panel | LO; same identity/credits as app menu |
| M12 | Native pan menu | NativeDesktopPan actions | CM; Left/Right/Up/Down/Return to Top Left correctly enabled, accessible desktop actions |
| M13 | Native Capture/Release Keyboard | native desktop command/capture | IN, CM; actual denial/revocation and release shortcut recovery |
| M14 | Native remote resize/statistics | RemoteResizeSheet / statistics toggle | RR, CM; all toolbar/menu/context entry points route identically |
| K01 | Shortcut modifier chord only | NativeShortcutState unarm/release | IN; physical release capture without emitting a stuck modifier |
| K02 | modifier+G | native shortcut dispatcher | IN; capture only on intended desktop |
| K03 | modifier+Enter | fullscreen action | IN, FS; exact modifiers, repeated press/release |
| K04 | modifier+M | native context menu | IN, CM; focus, Escape dismiss, keyboard navigation |
| K05 | modifier+Space bypass | shortcut classifier | IN; temporary pass-through and rearming, no stuck keys |
| K06 | modifier+unrecognized key | shared classifier/dispatcher | IN; retained treatment, extra modifiers and layout candidate mapping |
| K07 | native Cmd-N/O/Shift-S | ConnectionCommands | CL, DO, EX; new/open/export target ownership |
| K08 | native Cmd-Shift-L/P, Cmd-? | listener/profiles/help commands | LI, PR, LO; open/reuse correct auxiliary window |
| K09 | native Cmd-Q / Settings / close | SwiftUI commands + delegate | DO, AU; quit drains prompts/IO/services; Settings shortcut and Cmd-W focus behavior |

## App launch, files, imports and recovery

| ID | Retained source / launch path | Native replacement | Evidence; remaining acceptance action |
| --- | --- | --- | --- |
| L01 | Launch no arguments | TidyVNCMain → ordinary WindowGroup | CL; one initial form, no implicit connect or legacy write |
| L02 | Launch host/display/port | bootstrap → first-window request | CL; same-process argv, connect exactly once after defaults readiness |
| L03 | Launch Unix socket | endpoint classifier / socket transport | CL; literal path policy and cancellation; no SSH/listen misuse |
| L04 | Launch explicit connection file | bootstrap → reviewed document window | CL, DO; file overrides CLI, monitor mapping and manual Connect |
| L05 | Launch help/version/invalid args | NativeInvocationBootstrap before SwiftUI | CL; exact exit behavior and redacted errors, no stores/credential reads/windows |
| L06 | Launch PasswordFile/environment | NativeLaunchCredentials | LC; priority, first-window ownership, unclaimed cleanup and no relaunch/export |
| L07 | Launch -listen / numeric port | ListenerModel / ListenerView | LI, CL; start/stop, port bounds/ephemeral port, every pending peer accept/reject/expiry |
| L08 | Launch -listen explicit file | reviewed listener startup | LI, DO; file ServerName port, review before bind, no unsupported endpoint |
| L09 | Launch via / SSH config/env | native tunnel controller | SH; immutable captured configuration, password/passphrase/key trust, cancellation and owned descendant cleanup |
| L10 | Finder Open / app openFiles/openURLs | NativeDocumentLaunchRouter | DO; actual registration/Launch Services delivery, multiple files, exact once review and unsupported URL rejection |
| L11 | App/Dock new/reopen/activate | SwiftUI window actions / AppCoordinator | CL, DO; actual Dock reactivation/reopen/no-window behavior still requires acceptance |
| L12 | App Quit / OS termination | AppCoordinator requestQuit/delegate | DO, AU, LI, SH; joining every connection/listener/store/tunnel, no duplicate termination reply |
| L13 | Login/session restoration | scene/delegate startup policy | actual OS restoration test still open; do not automatically restore live connections without intent |
| F01 | Server Load native/legacy file | NSOpenPanel / NativeDocumentFile | DO; both extensions accepted explicitly, wrong header/oversize/unreadable file recovery |
| F02 | Review known/unknown/secret fields | DocumentReviewView | DO; ignored fields disclosed; secret fields never applied/exported; manual Connect/Cancel |
| F03 | Review numeric monitor mapping | DocumentMonitorMappingView | DO; unmapped/disconnected/duplicate numbers require explicit choices; cancel/back/reload |
| F04 | Reload changed source / retry read | document model | DO; immutable accepted snapshot, late read after close discarded |
| F05 | Save As active/idle configuration | DocumentExportView | EX; current nonsecret values, editable destination, no raw credential/trust export |
| F06 | Review export losses/monitor numbering | export mapping/review | EX; native-only fields and stale/disconnected display mapping disclosed before writing |
| F07 | Save panel extension/overwrite | AppCoordinator NSSavePanel | EX; `.tidyvnc` header/extension, explicit replacement, Cancel leaves existing bytes |
| F08 | Atomic write/failure | NativeDocumentWriter | EX; read-only path/disk failure/interrupted save rollback; actual sandbox scope only if packaging needs it |
| F09 | First-use defaults import / Skip | DefaultsImportView / availability model | IM; separate consent from history; no automatic legacy reads that mutate state |
| F10 | Defaults source discovery/chooser | NativeImportSources / defaults flow | IM; source/provenance/retry, no secret import |
| F11 | Defaults field selection/review/mapping | DefaultsImportView / shared fields | IM; per-field selection, rejected/warning values, mapping, explicit commit/cancel |
| F12 | Defaults commit/conflict/reimport | transactional store/import model | IM; native stores only, idempotence, marker/save failures and explicit recovery |
| F13 | History source/review/selection | HistoryImportView | IH; addresses only, deduplication/limit/privacy, independent consent |
| F14 | History import/skip/cancel/retry | history import transaction | IH; no defaults/credentials imported, no user-history clearing by tests |
| E01 | Launch/CConn DNS/refusal/routing/timeout | NativeConnectionIssue / ConnectionContent alerts | CO; distinct fixed messages, private diagnostics not interpolated |
| E02 | Auth/protocol/peer disappearance | same | CO; auth vs protocol context, unexpected close versus requested cancellation |
| E03 | ReconnectOnError Retry/Cancel | bound problem identity / model retry | CO; stale endpoint/generation/replaced alert cannot reconnect; two-session isolation |
| E04 | Local Network permission suspicion | structured recovery + InfoPlist purpose text | CO, LO; actual installed Finder allow/deny/retry/real LAN still open; errno alone is not permission denial |
| E05 | Renderer/cursor/input/fullscreen failure | NativePresentationIssue | CO, DT; fixed safe recovery, coalescing, fallback and later recovery |
| E06 | AlertOnFatalError=false | immutable session/launch policy; one-shot joined window closure | CO, LI, CL, EX; retry precedence, fatal startup, reverse/bind isolation and export disclosure fixtures; actual window closure/keyboard acceptance remains open |

## Information, help and global UI acceptance

| ID | Retained source / action | Native replacement | Evidence; remaining acceptance action |
| --- | --- | --- | --- |
| Q01 | CConn connection information | ConnectionInformationSheet | CM; negotiated host/security/encoding/format/dimensions reflect current generation |
| Q02 | connection diagnostics copy/select | native selectable information | CM, LO; private values redacted, keyboard selection/copy/VoiceOver |
| Q03 | performance overlay | ConnectionStatisticsOverlay | CM; throttled snapshots, independent primary/secondary overlays and show/hide |
| Q04 | input/clipboard/render statistics | information/overlay model | CM, DT; counters refer to intended session, diagnostic visibility does not imply measured performance budgets |
| H01 | About identity/version/icon | NSApplication standard About panel | LO; actual panel snapshot in UI-ACCEPTANCE; keyboard/VoiceOver still open |
| H02 | Credits/license/upstream attribution | Credits.rtf / About resource | LO; selectable readable credits, branding ledger preserved |
| H03 | Help menu / help window sections | ApplicationHelpView | LO; actual opening/content observed, finish links/keyboard/VoiceOver at minimum size |
| H04 | support/source/license links | ApplicationHelpView Links | LO; actual destinations, expected browser behavior, keyboard/VoiceOver |

For **every dialog, sheet, menu and window above**, acceptance must additionally
cover Return/default and Escape/cancel, tab order/visible focus, VoiceOver label/
role/value/action, light/dark/high contrast, reduced motion, long localized text,
RTL where appropriate, minimum window size and scrolling reachability. The
compiler catalog proves annotated strings/defaults/interpolation, not dynamic
text provenance or assistive-technology behavior. Rendering fixtures prove their
measured layouts only. [UI-ACCEPTANCE.md](UI-ACCEPTANCE.md) records the limited
actual-app observations and computer-use access failures; do not expand those
observations to all rows here.

## Gaps that determine the next work

1. Complete actual E06 / AlertOnFatalError window acceptance. Native policy now
   preserves Retry precedence and scopes silent closure to the failed owner;
   startup, cancellation, connected-peer isolation, listener/reverse and CLI/export
   regressions supplement the remaining actual-app checks in CONNECTION.md.
2. Review visible compatibility differences: explicit native trust files and
   stable display selection, no arbitrary SSH command/proxy customization, native
   own-store imports, no implicit live session restoration. A restriction being
   documented does not itself satisfy final acceptance.
3. Execute the per-row native interaction matrix and full protocol matrix;
   current tests, repeated tunnel/sanitizer checks and compiled queries are
   supporting evidence. Complete physical layout/IME/mixed-display/Spaces/hotplug
   and matched performance measurements, installed privacy/Keychain/update/rollback,
   portable distribution dependencies and remote CI before cutover.
4. Review source changes against this inventory and CAPABILITIES. Add new controls
   and options explicitly. N0 inventory completion is not N4/N5/N6 completion;
   FLTK stays the default until all original gates pass.


### Actual executable protocol evidence (2026-09-23)

[PROTOCOL.md](PROTOCOL.md) records all 55 baseline cases through the native app
and the retained FLTK harness regression. This adds actual command-line startup,
fragmented update/framebuffer/cursor replacement and measured resize-wire evidence
to the scaling rows. It does not accept their displayed pixels, input, physical
hardware or interaction columns, or the broader security/encoding matrix.

### Side-by-side baseline and actual-app evidence (2026-09-23)

[BASELINE.md](BASELINE.md) holds window-only screenshots of the retained FLTK
viewer and the native app in five matching states: connection, connected
desktop, password prompt, untrusted certificate and connection refused. The
comparison found one gap, which is now fixed: T01 certificate issuer, serial,
validity, key and signature details. The following rows gained actual-app
evidence this session (details in UI-ACCEPTANCE.md, ACCESSIBILITY.md and
TODO.md):

- **A01/A03/A05 (password prompt).** Structure, Cancel and Escape (keyboard
  test). The truncated credential warning is fixed.
- **T01/T03/T04/T05/T07 (certificate trust).** Fingerprint and SPKI verified
  against the peer certificate. Return is Cancel (keyboard test, with a
  mutation check). Connect Once saves nothing. A confirmed save is reused.
  Forget re-prompts.
- **Handshakes against the project's server side.** VncAuth, TLS, CA-trusted
  X509 and all RSA-AES variants (`macos-security-smoke.py`).
- **Tunnel and reconnect.** SSH tunnel through a loopback sshd, and Retry
  reconnect (`macos-tunnel-smoke.py`, `reconnect`).
- **Labels.** All 26 reachable screens expose VoiceOver labels
  (`accessibility-audit.py`).

#### Differences proposed as intentional (owner review pending)

| Retained behaviour | Native behaviour | Rationale |
| --- | --- | --- |
| Connection refused: "Attempt to reconnect?" with **Yes** as the default | "Connection Refused" guidance with **Cancel** as the default and a separate Retry | A refused port rarely succeeds on an immediate retry, and Return must not start network activity unasked. Retry stays one click or Tab-then-Space away. |
| Password prompt: single "Keep password for reconnect" toggle | Password lifetime: use once / this session's reconnect / remember on this Mac (Keychain) | A superset. "This session's reconnect" matches the FLTK toggle; "remember" is explicit and saves only after successful authentication. |
| Red "This connection is not secure" banner | Accessible warning colour: "may not adequately protect your credentials", plus a note that this is not a statement about traffic encryption | Precise wording, because the core's policy assesses credential protection rather than transport encryption. It meets contrast requirements. |
| Certificate: "Add exception" (saved) | Connect Once, or a confirmed Save Exception and Connect… | A one-time decision needs no persistence. Saving shows its scope and confirms. |
| Certificate: SPKI pin (base64) | Certificate SHA-256 on the sheet; SPKI SHA-256 in Saved Certificate Decisions | Administrators usually publish certificate fingerprints. The SPKI value stays available for saved-key comparison. |
