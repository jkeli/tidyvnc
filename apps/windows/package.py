"""The `package` stage of apps/windows/build.py (plans/native-ui-winui
PACKAGING.md sections 2-8; TODO W7.1-W7.5).

From the published app directory (the `app` stage) and the core build:

1. Assemble a staging payload: the published files minus symbols and test
   DLLs, the app-local Visual C++ runtime DLLs the payload imports, README and
   licence at the root, and every component's licence texts under ThirdParty.
2. Audit it (section 5): each PE image's architecture, imports resolved inside
   the payload or to Windows, no debug CRT, MinGW runtime or FLTK, no native
   DLL that nothing loads, the core's exports equal to tidyvnc.h, and a licence
   text for every shipped binary. The result is package-report.json.
3. Signing runs only with --sign (D23); otherwise the report says unsigned.
4. Relocation check (section 6): the payload copied to a path with spaces and
   non-ASCII characters runs `vncviewer --version` and `--help` with a
   minimal environment.
5. The per-user MSI (section 8), generated as WiX source from the payload and
   built with WiX 5, then validated (ICE).
6. Publication: everything is built in a private staging directory beside the
   output, which is renamed into place only when complete. An existing output
   is never replaced.
"""
from pathlib import Path
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import xml.etree.ElementTree as ElementTree
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pe  # noqa: E402
import toolchain  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
NUGET = Path(os.environ.get("NUGET_PACKAGES", Path.home() / ".nuget/packages"))
PRODUCT = "TidyVNC"
APP_USER_MODEL_ID = "io.github.jkeli.tidyvnc"
PROJECT_URL = "https://github.com/jkeli/tidyvnc"
PROG_ID = "TidyVNC.ConnectionFile.1"
# One UpgradeCode per architecture, generated once (PACKAGING.md section 4). Never change them.
UPGRADE_CODES = {"x64": "7B0E6C1A-3D52-4F7C-9A36-58E1C0B4D2F1", "arm64": "C4A1F9E2-8B37-4D05-A1C6-2E9F7B3D5A48"}
FIRST_WINDOWS_11_BUILD = 22000
# Built by this project; covered by LICENCE.TXT.
OWN_BINARIES = {"tidyvnc.exe", "tidyvnc.dll", "tidyvnc.native.dll", "vncviewer.exe", "vncviewer.dll",
                "tidyvnc-ssh-askpass.exe", "tidyvnc-ssh-askpass.dll", "tidyvnc_viewer.dll", "tidyvnc_windows.dll"}
# Loaded with P/Invoke rather than imported.
PINVOKE = {"tidyvnc_viewer.dll", "tidyvnc_windows.dll"}
EXCLUDED = [re.compile(p, re.I) for p in (r".*\.pdb$", r"^libpng16.*\.dll$", r"^(gtest|gmock).*\.dll$", r"^createdump\.exe$")]
VC_RUNTIME = re.compile(r"^(vcruntime140(_1|_threads)?|msvcp140(_1|_2|_atomic_wait|_codecvt_ids)?|concrt140|vccorlib140)\.dll$", re.I)
DEBUG_CRT = re.compile(r"^(vcruntime140(_1)?d|msvcp140d.*|ucrtbased|concrt140d|vccorlib140d)\.dll$", re.I)
MINGW_RUNTIME = re.compile(r"^(libstdc\+\+-6|libgcc_s_.*|libwinpthread-1|libc\+\+|libunwind)\.dll$", re.I)
MACHINE = {"x64": "x64", "arm64": "arm64"}


class PackageError(Exception):
    pass


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def version():
    match = re.search(r"^set\(VERSION (\d+\.\d+\.\d+)\)", (ROOT / "CMakeLists.txt").read_text(), re.M)
    if not match:
        raise PackageError("No VERSION in CMakeLists.txt")
    return match.group(1)


def catalog(key):
    """A string from the Windows catalog (Strings/en-US/Resources.resw)."""
    tree = ElementTree.parse(ROOT / "apps/windows/TidyVNC/Strings/en-US/Resources.resw")
    for data in tree.getroot().iter("data"):
        if data.get("name") == key.replace(".", "_"):
            return data.findtext("value")
    raise PackageError(f"Missing catalog string {key}")


def vc_redist(arch):
    vs = toolchain.installation()
    base = vs / "VC/Redist/MSVC"
    versions = sorted((p for p in base.iterdir() if p.is_dir() and re.match(r"\d+\.\d+\.\d+$", p.name)),
                      key=lambda p: [int(x) for x in p.name.split(".")])
    for candidate in reversed(versions):
        found = next((d for d in (candidate / arch).glob("Microsoft.VC*.CRT") if d.is_dir()), None)
        if found:
            return found
    raise PackageError(f"No Visual C++ {arch} redistributable folder under {base}; "
                       "ARM64 needs the MSVC ARM64 build tools component")


# ---- Assembly -------------------------------------------------------------------------

def assemble(app, staging, arch):
    symbols = []
    for source in sorted(app.rglob("*")):
        relative = source.relative_to(app)
        if source.is_dir() or relative.name == "tidyvnc-app.json":
            continue
        if relative.suffix.lower() == ".pdb":
            symbols.append(source)
            continue
        if any(p.match(relative.name) for p in EXCLUDED):
            continue
        target = staging / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    for name in ("README.rst", "LICENCE.TXT"):
        shutil.copy2(ROOT / name, staging / name)
    add_vc_runtime(staging, arch)
    return symbols


def payload_images(staging):
    for path in sorted(staging.rglob("*")):
        if path.is_file() and path.suffix.lower() in (".dll", ".exe") and pe.is_pe(path):
            yield path


def add_vc_runtime(staging, arch):
    """App-local Visual C++ runtime: exactly the DLLs the payload imports, with their closure."""
    redist = vc_redist(arch)
    available = {p.name.lower(): p for p in redist.iterdir()}
    while True:
        present = {p.name.lower() for p in staging.iterdir()}
        wanted = set()
        for path in payload_images(staging):
            image = pe.read(path)
            for name in image.imports + image.delay_imports:
                if VC_RUNTIME.match(name) and name.lower() not in present and name.lower() in available:
                    wanted.add(name.lower())
        if not wanted:
            return
        for name in sorted(wanted):
            shutil.copy2(available[name], staging / available[name].name)


# ---- Notices ---------------------------------------------------------------------------

LICENCE_FILE = re.compile(r"^(licen[cs]e|copying|notice|third-?party-?notices|thirdpartynotices|authors|copyright)", re.I)


def copy_licences(source_dir, target, names=None):
    files = [p for p in sorted(Path(source_dir).iterdir()) if p.is_file() and (names is None and LICENCE_FILE.match(p.name) or
                                                                            names is not None and p.name in names)]
    if not files:
        return []
    target.mkdir(parents=True, exist_ok=True)
    for path in files:
        shutil.copyfile(path, target / path.name)
    return [p.name for p in files]


def nuget_dir(package, package_version):
    path = NUGET / package.lower() / package_version
    if not path.is_dir():
        raise PackageError(f"NuGet package {package} {package_version} is not in {NUGET}")
    return path


def add_notices(staging, app, deps_prefix):
    """ThirdParty\\<component>\\ for every component, and the owner of every shipped binary."""
    third = staging / "ThirdParty"
    owners, components = {}, {}

    def component(name, files, source, licence_files):
        if not licence_files:
            raise PackageError(f"No licence text for {name} ({source})")
        known = components.setdefault(name, {"source": str(source), "files": [], "licenceFiles": licence_files})
        known["files"] = sorted(set(known["files"]) | set(files))
        for file in files:
            owners.setdefault(file.lower(), name)

    # MSYS2 C libraries (deps.json from apps/windows/deps.py).
    deps = json.loads((deps_prefix / "deps.json").read_text())
    for package, info in deps["packages"].items():
        short = re.sub(r"^mingw-w64-clang-(x86_64|aarch64)-", "", package)
        target = third / short
        licence_dir = deps_prefix / (info.get("licence_dir") or f"share/licenses/{short}")
        texts = []
        if licence_dir.is_dir():
            shutil.copytree(licence_dir, target, dirs_exist_ok=True)
            texts = sorted(str(p.relative_to(target)) for p in target.rglob("*") if p.is_file())
        component(short, info["files"], f"MSYS2 {package} {info['version']}", texts)

    # .NET runtime pack and NuGet packages, from the published dependency manifests.
    for manifest in sorted(app.glob("*.deps.json")):
        data = json.loads(manifest.read_text())
        targets = data["targets"][data["runtimeTarget"]["name"]]
        for key, library in data["libraries"].items():
            name, package_version = key.split("/")
            if library["type"] not in ("package", "runtimepack"):
                continue
            entry = targets.get(key, {})
            files = [Path(f).name for kind in ("runtime", "native") for f in entry.get(kind, {})]
            if not files:
                continue
            if library["type"] == "runtimepack":
                package = name.removeprefix("runtimepack.")
            else:
                package = name
            source = nuget_dir(package, package_version)
            texts = copy_licences(source, third / package)
            if not texts and package.startswith("Microsoft.Windows.SDK.NET.Ref"):
                # The projection's licence is the Windows SDK licence (its nuspec links to it).
                kits = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Windows Kits/10/Licenses"
                newest = max((p for p in kits.iterdir() if p.is_dir()), key=lambda p: [int(x) for x in p.name.split(".")])
                texts = copy_licences(newest, third / package, {"sdk_license.rtf", "sdk_third_party_notices.rtf"})
            component(package, files, f"NuGet {package} {package_version}", texts)

    # Windows App SDK component payload (assembled by its self-contained targets, not deps.json).
    meta = next(NUGET.glob("microsoft.windowsappsdk/*"))
    for spec in (meta / "microsoft.windowsappsdk.nuspec",):
        for match in re.finditer(r'<dependency id="(Microsoft\.WindowsAppSDK\.[^"]+)" version="\[([^\]]+)\]"', spec.read_text()):
            package, package_version = match.groups()
            source = nuget_dir(package, package_version)
            native = source / "runtimes-framework"
            files = [p.name for p in native.rglob("*") if p.is_file()] if native.is_dir() else []
            shipped = [f for f in files if (staging / f).exists() or any(staging.rglob(f))]
            if shipped:
                component(package, shipped, f"NuGet {package} {package_version}", copy_licences(source, third / package))
            # Their own NuGet dependencies (WebView2 for WinUI) reach the payload as references.
            for dependency, dependency_version in re.findall(r'<dependency id="((?!Microsoft\.WindowsAppSDK)[^"]+)" version="\[?([^\],"]+)',
                                                             next(source.glob("*.nuspec")).read_text()):
                other = nuget_dir(dependency, dependency_version)
                names = {p.name for p in other.rglob("*.dll")}
                shipped = sorted(n for n in names if (staging / n).exists())
                if shipped:
                    component(dependency, shipped, f"NuGet {dependency} {dependency_version}", copy_licences(other, third / dependency))

    # The app-local Visual C++ runtime: Visual Studio's redistributable code.
    vc = [p.name for p in staging.iterdir() if VC_RUNTIME.match(p.name)]
    if vc:
        target = third / "Microsoft.VCRuntime"
        target.mkdir(parents=True, exist_ok=True)
        (target / "README.txt").write_text(
            "Microsoft Visual C++ runtime DLLs, copied from the Visual Studio redistributable folder\n"
            f"({vc_redist_name()}). They are Distributable Code under the Microsoft Visual Studio license terms,\n"
            "which permit shipping them app-locally with an application built with Visual Studio.\n", encoding="utf-8")
        component("Microsoft.VCRuntime", vc, "Visual Studio redistributable", ["README.txt"])
    return owners, components


def vc_redist_name():
    try:
        return str(vc_redist("x64").relative_to(toolchain.installation()))
    except PackageError:
        return "VC/Redist"


# ---- Audit -----------------------------------------------------------------------------

def header_functions():
    text = (ROOT / "viewer/bridge/tidyvnc.h").read_text(encoding="utf-8")
    return set(re.findall(r"TIDYVNC_API\s+[^;(]*?\b(tidyvnc_\w+)\s*\(", text))


def system_dll(name):
    lower = name.lower()
    if lower.startswith(("api-ms-win-", "ext-ms-")):
        return True
    if VC_RUNTIME.match(lower) or DEBUG_CRT.match(lower):
        return False
    return (Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / name).is_file()


def dynamic_dlls(staging, app):
    """Native DLLs legitimately loaded without an import: P/Invoke, WinRT activation, runtime packs."""
    names = set(PINVOKE)
    for manifest in app.glob("*.deps.json"):
        data = json.loads(manifest.read_text())
        for entry in data["targets"][data["runtimeTarget"]["name"]].values():
            names.update(Path(f).name.lower() for f in entry.get("native", {}))
    for exe in staging.glob("*.exe"):
        manifest = pe.read(exe).manifest
        names.update(m.lower() for m in re.findall(r"<(?:asmv3:)?file\s+name=['\"]([^'\"]+\.dll)['\"]", manifest, re.I))
    meta = next(NUGET.glob("microsoft.windowsappsdk/*"))
    for match in re.finditer(r'<dependency id="(Microsoft\.WindowsAppSDK\.[^"]+)" version="\[([^\]]+)\]"',
                             (meta / "microsoft.windowsappsdk.nuspec").read_text()):
        native = NUGET / match.group(1).lower() / match.group(2) / "runtimes-framework"
        if native.is_dir():
            names.update(p.name.lower() for p in native.rglob("*.dll"))
    return names


def audit(staging, app, arch, owners):
    problems, records = [], []
    images = {p: pe.read(p) for p in payload_images(staging)}
    by_name = {}
    for path in images:
        by_name.setdefault(path.name.lower(), []).append(path)
    imported = set()
    for path, image in images.items():
        relative = path.relative_to(staging).as_posix()
        if not image.managed and image.machine != MACHINE[arch]:
            problems.append(f"{relative}: {image.machine} image in a {arch} payload")
        if image.managed and image.machine not in (MACHINE[arch], "x86"):
            problems.append(f"{relative}: managed image for {image.machine}")
        resolved = {}
        for name in image.imports + image.delay_imports:
            lower = name.lower()
            imported.add(lower)
            if DEBUG_CRT.match(lower):
                problems.append(f"{relative}: imports the debug runtime {name}")
            if MINGW_RUNTIME.match(lower):
                problems.append(f"{relative}: imports the MinGW runtime {name}")
            if "fltk" in lower:
                problems.append(f"{relative}: imports FLTK ({name})")
            if lower in by_name and any(p.parent == path.parent or p.parent == staging for p in by_name[lower]):
                resolved[name] = "payload"
            elif system_dll(name):
                resolved[name] = "system"
            elif name in image.delay_imports and name not in image.imports:
                # Delay loads of optional OS components (for example UI Automation helpers) resolve on use.
                resolved[name] = "system (delay-load, absent here)"
            else:
                problems.append(f"{relative}: unresolved import {name}")
                resolved[name] = "unresolved"
        if any("fltk" in e.lower() for e in image.exports):
            problems.append(f"{relative}: exports FLTK symbols")
        if path.name.lower() not in OWN_BINARIES and path.name.lower() not in owners:
            problems.append(f"{relative}: no licence owner (ThirdParty) for this binary")
        records.append({"path": relative, "sha256": digest(path), "architecture": image.machine,
                        "managed": image.managed, "signed": image.signed,
                        "component": "TidyVNC" if path.name.lower() in OWN_BINARIES else owners.get(path.name.lower()),
                        "imports": resolved})
    dynamic = dynamic_dlls(staging, app)
    for path, image in images.items():
        lower = path.name.lower()
        if path.suffix.lower() == ".dll" and not image.managed and lower not in imported and lower not in dynamic:
            problems.append(f"{path.relative_to(staging).as_posix()}: native DLL that nothing loads")
    # The app's PRI carries its strings and compiled XAML; without it the first window cannot load.
    pri = staging / "TidyVNC.pri"
    content = pri.read_bytes() if pri.is_file() else b""
    for resource in (b"App.xbf", b"ConnectionWindow.xbf", b"app_menu_file"):
        if resource not in content:
            problems.append(f"TidyVNC.pri is missing or lacks {resource.decode()} (compiled XAML and strings)")
    core = staging / "tidyvnc_viewer.dll"
    exported, declared = set(images[core].exports), header_functions()
    if exported != declared:
        problems.append(f"tidyvnc_viewer.dll exports differ from tidyvnc.h: missing {sorted(declared - exported)[:10]}, "
                        f"extra {sorted(exported - declared)[:10]}")
    return problems, records, {"declared": len(declared), "exported": len(exported)}


# ---- Signing (D23) ---------------------------------------------------------------------

def sign(staging, args, files):
    signtool = next(Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")).glob(
        "Windows Kits/10/bin/*/x64/signtool.exe"), None)
    if signtool is None:
        raise PackageError("signtool.exe was not found in the Windows SDK")
    command = [signtool, "sign", "/fd", "SHA256", "/sha1", args.sign, "/tr", args.timestamp_url, "/td", "SHA256"]
    subprocess.run([str(c) for c in command + files], check=True)
    subprocess.run([str(c) for c in [signtool, "verify", "/pa", "/all", *files]], check=True)


# ---- Relocation check (section 6) ------------------------------------------------------

def relocation_check(staging, work):
    relocated = work / "relocation check ü" / "TidyVNC Ø"
    shutil.copytree(staging, relocated)
    system = Path(os.environ.get("SystemRoot", r"C:\Windows"))
    env = {"SystemRoot": str(system), "PATH": str(system / "System32"), "TEMP": str(work), "TMP": str(work)}
    results = {}
    for flag, expected in (("--version", 0), ("--help", 1)):
        run = subprocess.run([str(relocated / "vncviewer.exe"), flag], env=env, capture_output=True, text=True, timeout=60)
        output = run.stdout + run.stderr
        if run.returncode != expected or "TidyVNC" not in output:
            raise PackageError(f"Relocated vncviewer {flag} exited {run.returncode}: {output[:400]}")
        results[flag] = run.returncode
    # D6: the copied launcher refuses older Windows before anything else (simulated build).
    refused = subprocess.run([str(relocated / "vncviewer.exe"), "--version"], env=dict(env, TIDYVNC_TEST_WINDOWS_BUILD="19045"),
                             capture_output=True, text=True, timeout=60)
    if refused.returncode != 1 or "requires Windows 11" not in refused.stderr:
        raise PackageError(f"The launcher did not refuse Windows 10 ({refused.returncode}): {refused.stderr[:300]}")
    results["windows10Refusal"] = refused.returncode
    shutil.rmtree(relocated.parent)
    return results


# ---- MSI (section 8) -------------------------------------------------------------------

def wix_id(prefix, text):
    return f"{prefix}_{hashlib.sha1(text.encode('utf-8')).hexdigest()[:20]}"


def escape(value):
    return (value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;"))


def wxs(staging, arch, product_version):
    """WiX source: one component per folder with an HKCU key path (per-user ICE38/ICE64 rules)."""
    registry = r"Software\TidyVNC\WinUI Installer"
    lines = []
    directories, components = {}, []

    def directory_id(relative):
        return "INSTALLFOLDER" if relative == Path(".") else wix_id("dir", relative.as_posix())

    def emit(folder, indent):
        relative = folder.relative_to(staging)
        files = sorted(p for p in folder.iterdir() if p.is_file())
        component = wix_id("cmp", relative.as_posix() or ".")
        pad = " " * indent
        if files or folder != staging:
            components.append(component)
            lines.append(f'{pad}<Component Id="{component}" Guid="{uuid.uuid5(uuid.NAMESPACE_URL, "tidyvnc:" + arch + ":" + relative.as_posix())}">')
            lines.append(f'{pad}  <RegistryValue Root="HKCU" Key="{registry}\\Folders" Name="{escape(relative.as_posix())}" Type="integer" Value="1" KeyPath="yes" />')
            if folder != staging:
                lines.append(f'{pad}  <RemoveFolder Id="rm_{component}" On="uninstall" />')
            for file in files:
                file_id = "TidyVNC.exe" if relative == Path(".") and file.name == "TidyVNC.exe" else wix_id("fil", (relative / file.name).as_posix())
                lines.append(f'{pad}  <File Id="{file_id}" Source="{escape(str(file))}" Name="{escape(file.name)}" />')
            lines.append(f"{pad}</Component>")
        for child in sorted(p for p in folder.iterdir() if p.is_dir()):
            child_id = directory_id(child.relative_to(staging))
            lines.append(f'{pad}<Directory Id="{child_id}" Name="{escape(child.name)}">')
            emit(child, indent + 2)
            lines.append(f"{pad}</Directory>")

    emit(staging, 10)
    body = "\n".join(lines)
    refs = "\n".join(f'      <ComponentRef Id="{c}" />' for c in components)
    icon = ROOT / "media/icons/tidyvnc.ico"
    file_type = escape(catalog("document.file.type"))
    refusal = escape(catalog("app.windows.11.required"))
    return f'''<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by apps/windows/package.py (PACKAGING.md section 8). Do not edit. -->
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="{PRODUCT}" Manufacturer="{PRODUCT}" Version="{product_version}" UpgradeCode="{UPGRADE_CODES[arch]}"
           Scope="perUser" Compressed="yes" Language="1033">
    <SummaryInformation Description="{PRODUCT} {product_version} ({arch})" />
    <MajorUpgrade DowngradeErrorMessage="A newer version of {PRODUCT} is already installed." AllowSameVersionUpgrades="no" />
    <MediaTemplate EmbedCab="yes" CompressionLevel="high" />

    <!-- Windows 11 only (D6). VersionNT is capped for installers, so read the build number. -->
    <Property Id="TIDYVNCWINDOWSBUILD">
      <RegistrySearch Id="WindowsBuild" Root="HKLM" Key="SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion" Name="CurrentBuildNumber" Type="raw" />
    </Property>
    <Launch Condition="Installed OR TIDYVNCWINDOWSBUILD &gt;= {FIRST_WINDOWS_11_BUILD}" Message="{refusal}" />

    <Icon Id="TidyVNC.ico" SourceFile="{escape(str(icon))}" />
    <Property Id="ARPPRODUCTICON" Value="TidyVNC.ico" />
    <Property Id="ARPURLINFOABOUT" Value="{PROJECT_URL}" />
    <Property Id="ARPHELPLINK" Value="{PROJECT_URL}/issues" />
    <Property Id="ARPNOMODIFY" Value="1" />

    <StandardDirectory Id="LocalAppDataFolder">
      <Directory Id="ProgramsFolder" Name="Programs">
        <Directory Id="INSTALLFOLDER" Name="{PRODUCT}">
{body}
          <Component Id="FileAssociation" Guid="{uuid.uuid5(uuid.NAMESPACE_URL, "tidyvnc:" + arch + ":association")}">
            <RegistryValue Root="HKCU" Key="Software\\Classes\\{PROG_ID}" Value="{file_type}" Type="string" KeyPath="yes" />
            <RegistryValue Root="HKCU" Key="Software\\Classes\\{PROG_ID}" Name="AppUserModelID" Value="{APP_USER_MODEL_ID}" Type="string" />
            <RegistryValue Root="HKCU" Key="Software\\Classes\\{PROG_ID}\\DefaultIcon" Value="&quot;[INSTALLFOLDER]TidyVNC.exe&quot;,0" Type="string" />
            <RegistryValue Root="HKCU" Key="Software\\Classes\\{PROG_ID}\\shell\\open\\command" Value="&quot;[INSTALLFOLDER]TidyVNC.exe&quot; &quot;%1&quot;" Type="string" />
            <RegistryValue Root="HKCU" Key="Software\\Classes\\.tidyvnc\\OpenWithProgids" Name="{PROG_ID}" Value="" Type="string" />
            <!-- Per-user folders are removed when empty (ICE64); Programs is shared and stays while used. -->
            <RemoveFolder Id="RemoveInstallFolder" Directory="INSTALLFOLDER" On="uninstall" />
            <RemoveFolder Id="RemoveProgramsFolder" Directory="ProgramsFolder" On="uninstall" />
          </Component>
          <Component Id="CommandLinePath" Guid="{uuid.uuid5(uuid.NAMESPACE_URL, "tidyvnc:" + arch + ":path")}">
            <RegistryValue Root="HKCU" Key="{registry}" Name="CommandLinePath" Type="integer" Value="1" KeyPath="yes" />
            <Environment Id="UserPath" Name="PATH" Value="[INSTALLFOLDER]" Part="last" System="no" Action="set" Permanent="no" />
          </Component>
        </Directory>
      </Directory>
    </StandardDirectory>
    <StandardDirectory Id="ProgramMenuFolder">
      <Component Id="StartMenuShortcut" Guid="{uuid.uuid5(uuid.NAMESPACE_URL, "tidyvnc:" + arch + ":shortcut")}">
        <Shortcut Id="StartShortcut" Name="{PRODUCT}" Target="[INSTALLFOLDER]TidyVNC.exe" WorkingDirectory="INSTALLFOLDER" Icon="TidyVNC.ico">
          <ShortcutProperty Key="System.AppUserModel.ID" Value="{APP_USER_MODEL_ID}" />
        </Shortcut>
        <RegistryValue Root="HKCU" Key="{registry}" Name="StartMenuShortcut" Type="integer" Value="1" KeyPath="yes" />
      </Component>
    </StandardDirectory>

    <Feature Id="Main" Title="{PRODUCT}" Level="1" AllowAbsent="no">
{refs}
      <ComponentRef Id="FileAssociation" />
      <ComponentRef Id="StartMenuShortcut" />
    </Feature>
    <!-- Optional, off by default: msiexec /i ... ADDLOCAL=Main,CommandLine -->
    <Feature Id="CommandLine" Title="vncviewer on PATH" Level="1000">
      <ComponentRef Id="CommandLinePath" />
    </Feature>
  </Package>
</Wix>
'''


def build_msi(staging, work, arch, product_version):
    source = work / "TidyVNC.wxs"
    source.write_text(wxs(staging, arch, product_version), encoding="utf-8")
    msi = work / f"TidyVNC-{product_version}-{arch}.msi"
    subprocess.run(["wix", "build", str(source), "-arch", arch, "-o", str(msi)], check=True)
    # ICE03: Microsoft's WinUI resource files carry language IDs the Language column rejects (gd-GB,
    # mi-NZ, ug-CN; the main DLL lists more than fit). The column only affects file versioning.
    # ICE91: every file of a per-user package is in the user profile by design (D5).
    validation = subprocess.run(["wix", "msi", "validate", "-sice", "ICE03", "-sice", "ICE91", str(msi)],
                                capture_output=True, text=True)
    (work / "msi-validation.txt").write_text(validation.stdout + validation.stderr, encoding="utf-8")
    if validation.returncode != 0:
        kept = work.parent / f"{msi.stem}-validation.txt"
        shutil.copyfile(work / "msi-validation.txt", kept)
        errors = [line for line in (validation.stdout + validation.stderr).splitlines() if " error " in line]
        raise PackageError(f"MSI validation failed ({kept}):\n" + "\n".join(errors[:20]))
    source.unlink()
    return msi


# ---- Stage entry point -----------------------------------------------------------------

def build(args, core, app):
    arch = args.arch
    product_version = version()
    output = (getattr(args, "output", None) or ROOT / "build/winui/release" / f"TidyVNC-{product_version}-{arch}").resolve()
    if output.exists():
        raise PackageError(f"Output already exists; choose a fresh directory: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    deps_prefix = ROOT / "build/winui/deps" / arch
    with tempfile.TemporaryDirectory(prefix=".tidyvnc-package-", dir=output.parent) as tmp:
        work = Path(tmp)
        staging = work / "payload"
        staging.mkdir()
        symbols = assemble(Path(app), staging, arch)
        symbols += sorted((Path(core) / "bin").glob("tidyvnc_*.pdb"))
        owners, components = add_notices(staging, Path(app), deps_prefix)
        problems, records, exports = audit(staging, Path(app), arch, owners)
        if problems:
            raise PackageError("Package audit failed:\n  " + "\n  ".join(problems))
        signed = False
        if getattr(args, "sign", None):
            sign(staging, args, [r["path"] for r in records if r["component"] == "TidyVNC"])
            signed = True
        relocation = relocation_check(staging, work)
        msi = build_msi(staging, work, arch, product_version) if not getattr(args, "no_msi", False) else None
        if signed and msi:
            sign(work, args, [msi.name])
        symbols += sorted(work.glob("*.wixpdb"))
        with zipfile.ZipFile(work / f"TidyVNC-{product_version}-{arch}-symbols.zip", "w", zipfile.ZIP_DEFLATED) as archive:
            for pdb in symbols:
                archive.write(pdb, pdb.name)
        report = {"schemaVersion": 1, "product": PRODUCT, "version": product_version, "architecture": arch,
                  "configuration": args.configuration, "created": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
                  "signed": signed, "upgradeCode": UPGRADE_CODES[arch], "toolchain": toolchain.describe(),
                  "msi": {"path": msi.name, "sha256": digest(msi), "validation": "passed"} if msi else None,
                  "relocation": relocation, "coreExports": exports, "components": components,
                  "payload": {"files": sum(1 for p in staging.rglob("*") if p.is_file()),
                              "bytes": sum(p.stat().st_size for p in staging.rglob("*") if p.is_file())},
                  "binaries": records}
        (work / "package-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        # The output holds the deliverables only (section 1); the payload is inside the MSI.
        shutil.rmtree(staging)
        for leftover in [*work.glob("*.wixpdb"), work / "msi-validation.txt"]:
            if leftover.exists() and (leftover.suffix == ".wixpdb" or leftover.stat().st_size == 0):
                leftover.unlink()
        # Publish only a complete result; os.rename refuses an existing destination on Windows.
        os.rename(work, output)
        # The temporary directory no longer exists; recreate it so the context manager can clean up.
        work.mkdir()
    print(f"Package: {output}", flush=True)
    return output
