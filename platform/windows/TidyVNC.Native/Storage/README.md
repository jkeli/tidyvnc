# Windows stores

Owner-only JSON records in `%LOCALAPPDATA%\TidyVNC` (Debug builds honour
`TIDYVNC_STATE_ROOT`). The design is in
`plans/native-ui-winui/SERVICES.md` section 2. Every record has
`"schema": <int>` and `"revision": "<uuid D>"` plus the fields below. Decoding
is strict:

- an unknown field is `UnsupportedFields`;
- a wrong type, a non-canonical value or a broken invariant is `Corrupt`;
- a larger schema is `FutureSchema`, which is read-only and never replaced.

Records are read with `JsonDocument` and written with `Utf8JsonWriter`. Neither
uses reflection, so both are trim- and AOT-safe.

## preferences.json (schema 1)

```json
{
  "schema": 1, "revision": "…",
  "settings": {
    "parameters": { "SendClipboard": "0", "ScalingFactor": "150" },
    "fullscreenDisplays": ["<stable display id, lowercase hex>"]
  },
  "importedFrom": "registry"
}
```

`parameters` holds canonical values, as the core configuration resolver
produces them. The names come from `NativeSettings.Allowed`, which lists the
connection, clipboard, fullscreen, resize, security, scaling, input and encoding
parameters. Endpoints, credentials, `via`, `Log`, `listen` and `PasswordFile`
are never stored as settings.

Fullscreen monitors are stored as stable display IDs.
`FullScreenSelectedMonitors` numbers are used only by `.tigervnc` files and the
command line.

`importedFrom` is absent until the one-time registry import has run.

## profiles-history.json (schema 1)

```json
{
  "schema": 1, "revision": "…",
  "profiles": [
    { "id": "<uuid>", "name": "Office", "endpoint": "desk::5901",
      "settings": { "parameters": {} },
      "sshGateway": "ssh://alice@jump.example:2222",
      "credentialReference": "<uuid>" }
  ],
  "recentConnections": [ { "endpoint": "desk::5901", "sshGateway": "…" } ],
  "historyState": "uninitialized" | "native" | "registry"
}
```

- `profiles`: at most 256, with unique IDs.
- `recentConnections`: at most 20, newest first, with no duplicates.
- `sshGateway`: the canonical gateway URI. It is part of the destination's
  identity.
- `credentialReference`: names a Credential Manager entry (W4.2). It never holds
  a secret.

## window-state.json (schema 1)

```json
{ "schema": 1, "revision": "…",
  "windows": { "connection": { "x": 0, "y": 0, "width": 800, "height": 600,
                               "maximized": false, "display": "<id>" } } }
```

Coordinates are physical virtual-screen pixels. Window state is kept apart from
settings, so moving a window never conflicts with an edit to preferences.
