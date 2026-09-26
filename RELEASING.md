# Releasing TidyVNC

A release is a tag `vX.Y.Z` on `master`. Pushing that tag is the only thing
that signs anything. `.github/workflows/release.yml` then:

1. checks that the tag matches `set(VERSION ...)` in `CMakeLists.txt` and is on `master`;
2. runs the Windows and macOS CI jobs (`windows-winui.yml`, `native-macos.yml`)
   on the tagged commit;
3. waits for approval on the `release` environment;
4. builds the Windows x64 Release package, signing the binaries and the MSI with
   Azure Artifact Signing;
5. builds the macOS arm64 Release package, signs it with the Developer ID
   certificate and provisioning profile, and has Apple notarize the app and the
   disk image, stapling both tickets;
6. creates a **draft** GitHub release with the MSI, the symbols ZIP, the DMG,
   both package reports, the source archives of the libraries the macOS app
   links statically, `SHA256SUMS.txt` and a build provenance attestation.

A person publishes the draft. Apart from signing dry runs (below), nothing else
is signed: builds from pushes, pull requests and local machines are unsigned.

## Rules

- **Version numbers.** `CMakeLists.txt` is the only version source. Patch
  releases (`2.0.1`) hold fixes only, minor releases (`2.1.0`) add features, and
  a major release breaks compatibility, for example of settings or connection
  files.
- **No pre-release tags yet.** Windows Installer compares only the first three
  version fields, so a `2.1.0-beta.1` MSI and the final `2.1.0` MSI would not
  upgrade cleanly. The workflow accepts only `vX.Y.Z`.
- **A published release is never changed.** Don't move a tag or replace
  assets. If a release is wrong, fix it in the next patch version.
- **Security fixes** get a patch release promptly, including fixes taken from
  upstream.

## Making a release

1. Set the version in `CMakeLists.txt`, and `version-string` in `vcpkg.json` to
   match. Commit to `master`, push, and wait for the **Windows native viewer**
   and **Native macOS viewer** workflows to pass.
2. Download the `winui-x64-unsigned` artifact from that run. Install it on a
   clean Windows 11 machine or VM, connect to a server, upgrade over the
   previous release, and uninstall. Do the same on a Mac with the DMG in the
   `native-development-release-arm64` artifact. It is ad hoc signed, so allow it
   in *System Settings* > *Privacy & Security* the first time it opens.
3. Write the release notes.
4. Tag and push:

   ```bash
   git tag -a v2.0.0 -m "TidyVNC 2.0.0"
   git push origin v2.0.0
   ```

5. When the **Release** run reaches **Build and sign x64** and **Build, sign and
   notarize macOS arm64**, review and approve the deployment to `release`.
   Notarization usually takes a few minutes per submission, occasionally much
   longer; the job waits up to an hour for each.
6. Open the draft release, replace the generated notes with yours, and publish
   it.

To check a downloaded MSI, look at *Properties* > *Digital Signatures*, or run:

```bash
gh attestation verify TidyVNC-2.0.0-x64.msi --repo jkeli/tidyvnc
```

To check a downloaded DMG, and the app after copying it to Applications:

```bash
spctl --assess -vv --type open --context context:primary-signature TidyVNC-2.0.0-arm64.dmg
```

```bash
spctl --assess -vv --type execute /Applications/TidyVNC.app
```

Both should report `source=Notarized Developer ID`. `gh attestation verify`
works for the DMG as for the MSI.

## Signing dry run

A dry run tests the signing setup without making a release. Use it after the
one-time setup, and after any change to the Apple, Azure or GitHub
configuration.

1. In *Actions* > **Release**, choose *Run workflow* on `master`. Other branches
   are refused.
2. Approve the deployment to `release` when asked.

The run builds, signs, notarizes and checks the packages exactly as a release
does. It keeps only the package reports, as the `dry-run-package-report` and
`dry-run-macos-package-report` artifacts for seven days. It creates no release
and keeps no signed binaries, so signed builds of unreleased code are never
distributed. Each dry run uses signatures from the Azure account's monthly
quota (about 30) and makes two notarization submissions, which Apple doesn't
charge for.

## One-time setup

### Apple Developer ID

The Account Holder of an Apple Developer Program membership does steps 1 to 4.
Gatekeeper shows the membership's name as the developer.

1. Create a **Developer ID Application** certificate, in Xcode (*Settings* >
   *Accounts* > *Manage Certificates*) or in the developer portal's
   *Certificates* with a certificate signing request from Keychain Access.
   Export it with its private key from Keychain Access as a `.p12` file with a
   strong password.
2. In *Identifiers*, register an explicit macOS **App ID** for
   `io.github.jkeli.tidyvnc`. It needs no capabilities.
3. In *Profiles*, create a **Developer ID** distribution profile for that App ID
   and the certificate, and download it. The profile provisions the
   application identifier the app needs for the Data Protection Keychain; the
   packager refuses to sign without it.
4. In App Store Connect, *Users and Access* > *Integrations* > *Team Keys*,
   create an API key with the **Developer** role. Download the `.p8` file (it
   can be downloaded only once) and note its key ID and the issuer ID.

To check the certificate and profile locally before storing them, package a
build with them (notarization is optional here):

```bash
python3 apps/macos/build.py --configuration Release --package --sign-identity "Developer ID Application: <name> (<team ID>)" --provisioning-profile TidyVNC.provisionprofile
```

### Azure Artifact Signing

1. In an Azure subscription, register the `Microsoft.CodeSigning` resource
   provider. Then create an **Artifact Signing account**. Note its region
   endpoint, such as `https://eus.codesigning.azure.net`.
2. Complete **identity validation** for public trust. The validated name is the
   publisher Windows shows.
3. Create a **Public Trust** certificate profile on that validation.
4. In Microsoft Entra ID, create an **app registration**, such as
   `tidyvnc-release-signing`, with no client secret.
5. On the app registration, add a **federated credential** for *GitHub Actions
   deploying Azure resources*: organization `jkeli` (owner ID `25450`),
   repository `tidyvnc` (repository ID `1375743845`), entity type
   *Environment*, environment `release`. The repository was created after
   2026-07-15, so GitHub issues immutable subjects that include both IDs:
   `repo:jkeli@25450/tidyvnc@1375743845:environment:release`. The IDs never
   change or get reused, and no other workflow, branch or environment can sign.
   To look them up again, use `https://api.github.com/repos/jkeli/tidyvnc`
   (`id` and `owner.id`).
6. Assign the app the **Artifact Signing Certificate Profile Signer** role.
   The portal offers *Access control (IAM)* only on the account, where the
   role covers every profile in it. That's fine while the account has one
   profile. To limit it to one profile, assign it with the Azure CLI, using
   the profile's resource ID (its *JSON View*) as the scope:

   ```bash
   az role assignment create --assignee "<client ID>" \
     --role "Artifact Signing Certificate Profile Signer" \
     --scope "<certificate profile resource ID>"
   ```

### GitHub

1. In *Settings* > *Environments*, create `release`:
   - **Required reviewers:** yourself.
   - **Deployment branches and tags:** *Selected branches and tags*, with a
     tag rule `v*` for releases and a branch rule `master` for dry runs.
   - **Environment secrets:**

     | Secret | Value |
     | --- | --- |
     | `AZURE_CLIENT_ID` | The app registration's application (client) ID |
     | `AZURE_TENANT_ID` | The directory (tenant) ID |
     | `ARTIFACT_SIGNING_ENDPOINT` | The account's region endpoint |
     | `ARTIFACT_SIGNING_ACCOUNT` | The Artifact Signing account name |
     | `ARTIFACT_SIGNING_PROFILE` | The certificate profile name |

   None of these grants access on its own; the federated credential does.
   They are stored as secrets so that the public workflow logs mask them.
   Apple has no federated credentials, so the macOS secrets do grant access:
   anyone who can read them can sign and notarize as the project.

     | Secret | Value |
     | --- | --- |
     | `MACOS_CERTIFICATE` | The `.p12` file, base64: `base64 -i certificate.p12` |
     | `MACOS_CERTIFICATE_PASSWORD` | Its password |
     | `MACOS_PROVISIONING_PROFILE` | The profile, base64: `base64 -i TidyVNC.provisionprofile` |
     | `NOTARY_KEY` | The contents of the `.p8` file |
     | `NOTARY_KEY_ID` | The API key's ID |
     | `NOTARY_ISSUER` | The issuer ID |
2. Optionally, add a tag ruleset for `v*` so that only you can create, move or
   delete release tags.

## Maintenance

- The Developer ID certificate expires after five years. A new certificate
  needs a new provisioning profile that includes it; update both secrets.
  Keychain items the app saved stay readable, because they belong to the team
  and App ID, not the certificate.
- `release.yml` pins the macOS runner image and Xcode (`DEVELOPER_DIR`), and
  Apple's Developer ID intermediate certificate by SHA-256
  (`DEVELOPER_ID_CA_SHA256`; it expires in 2031). Update the Xcode pin together
  with CI's `release-arm64` job.
- The macOS app links its C libraries statically from pinned source archives
  (`apps/macos/deps.py`). Each release carries those archives in
  `TidyVNC-X.Y.Z-macos-third-party-sources.tar`. Update the pins for security
  fixes like any other dependency.

- The workflow pins the Artifact Signing client (`ARTIFACT_SIGNING_CLIENT` in
  `release.yml`) and checks its Authenticode signature. Update the pin when
  Microsoft releases a new client.
- Windows App SDK and .NET runtime files keep Microsoft's signatures. The
  package stage signs only the project's binaries and binaries nobody else
  signed (the MSYS2 libraries), then checks that every shipped binary is signed.
- ARM64 isn't released yet. CI cross-builds it, but the package stage runs the
  packaged launcher, which needs an ARM64 machine or runner.
