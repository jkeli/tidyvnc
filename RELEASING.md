# Releasing TidyVNC

A release is a tag `vX.Y.Z` on `master`. Pushing that tag is the only thing
that signs anything. `.github/workflows/release.yml` then:

1. checks that the tag matches `set(VERSION ...)` in `CMakeLists.txt` and is on `master`;
2. runs the Windows CI jobs (`windows-winui.yml`) on the tagged commit;
3. waits for approval on the `release` environment;
4. builds the x64 Release package, signing the binaries and the MSI with Azure
   Artifact Signing;
5. creates a **draft** GitHub release with the MSI, the symbols ZIP,
   `package-report.json`, `SHA256SUMS.txt` and a build provenance attestation.

A person publishes the draft. Nothing else is signed: builds from pushes,
pull requests and local machines are unsigned.

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
   workflow to pass.
2. Download the `winui-x64-unsigned` artifact from that run. Install it on a
   clean Windows 11 machine or VM, connect to a server, upgrade over the
   previous release, and uninstall.
3. Write the release notes.
4. Tag and push:

   ```bash
   git tag -a v2.0.0 -m "TidyVNC 2.0.0"
   git push origin v2.0.0
   ```

5. When the **Release** run reaches **Build and sign x64**, review and approve
   the deployment to `release`.
6. Open the draft release, replace the generated notes with yours, and publish
   it.

To check a downloaded MSI, look at *Properties* > *Digital Signatures*, or run:

```bash
gh attestation verify TidyVNC-2.0.0-x64.msi --repo jkeli/tidyvnc
```

## One-time setup

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
   - **Deployment branches and tags:** *Selected*, with a tag rule `v*`.
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
2. Optionally, add a tag ruleset for `v*` so that only you can create, move or
   delete release tags.

## Maintenance

- The workflow pins the Artifact Signing client (`ARTIFACT_SIGNING_CLIENT` in
  `release.yml`) and checks its Authenticode signature. Update the pin when
  Microsoft releases a new client.
- Windows App SDK and .NET runtime files keep Microsoft's signatures. The
  package stage signs only the project's binaries and binaries nobody else
  signed (the MSYS2 libraries), then checks that every shipped binary is signed.
- ARM64 isn't released yet. CI cross-builds it, but the package stage runs the
  packaged launcher, which needs an ARM64 machine or runner.
