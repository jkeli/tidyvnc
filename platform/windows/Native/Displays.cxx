// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
//
// Display topology (SERVICES.md section 7): active paths from
// QueryDisplayConfig, joined with the GDI monitor (bounds, work area, DPI).
// Mirrored paths (several targets on one source) are one display.

#include "tidyvnc_windows.h"

#include <windows.h>
#include <bcrypt.h>
#include <shellscalingapi.h>

#include <cstring>
#include <vector>

namespace {

uint64_t stableId(const wchar_t* devicePath)
{
  // SHA-256 of the monitor device interface path (it names the monitor's EDID
  // identity and connector, and is stable across reboots and ordering).
  uint8_t digest[32] = {};
  ULONG bytes = (ULONG)(wcslen(devicePath) * sizeof(wchar_t));
  if (BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0, (PUCHAR)devicePath, bytes, digest, sizeof(digest)) != 0)
    return 0;
  uint64_t id = 0;
  memcpy(&id, digest, sizeof(id));
  return id ? id : 1;
}

struct MonitorMatch {
  const wchar_t* gdiName;
  HMONITOR monitor;
};

BOOL CALLBACK findMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM data)
{
  auto* match = reinterpret_cast<MonitorMatch*>(data);
  MONITORINFOEXW info = {};
  info.cbSize = sizeof(info);
  if (GetMonitorInfoW(monitor, &info) && wcscmp(info.szDevice, match->gdiName) == 0) {
    match->monitor = monitor;
    return FALSE;
  }
  return TRUE;
}

} // namespace

extern "C" {

int32_t tvw_displays(tvw_display* displays, uint32_t capacity, uint32_t* count)
{
  if (!count || (capacity && !displays))
    return E_POINTER;
  *count = 0;

  std::vector<DISPLAYCONFIG_PATH_INFO> paths;
  std::vector<DISPLAYCONFIG_MODE_INFO> modes;
  LONG status;
  do {
    UINT32 pathCount = 0, modeCount = 0;
    status = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &pathCount, &modeCount);
    if (status != ERROR_SUCCESS)
      return HRESULT_FROM_WIN32(status);
    paths.resize(pathCount);
    modes.resize(modeCount);
    status = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &pathCount, paths.data(), &modeCount, modes.data(), nullptr);
    paths.resize(pathCount);
    modes.resize(modeCount);
  } while (status == ERROR_INSUFFICIENT_BUFFER);
  if (status != ERROR_SUCCESS)
    return HRESULT_FROM_WIN32(status);

  struct Source {
    LUID adapter;
    UINT32 id;
    uint32_t index;
  };
  std::vector<Source> seen;
  uint32_t total = 0;
  bool truncated = false;

  for (const auto& path : paths) {
    bool mirrored = false;
    for (const Source& source : seen) {
      if (source.id == path.sourceInfo.id && source.adapter.LowPart == path.sourceInfo.adapterId.LowPart &&
          source.adapter.HighPart == path.sourceInfo.adapterId.HighPart) {
        if (source.index < capacity)
          displays[source.index].mirrored = 1;
        mirrored = true;
        break;
      }
    }
    if (mirrored)
      continue;

    DISPLAYCONFIG_SOURCE_DEVICE_NAME sourceName = {};
    sourceName.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
    sourceName.header.size = sizeof(sourceName);
    sourceName.header.adapterId = path.sourceInfo.adapterId;
    sourceName.header.id = path.sourceInfo.id;
    if (DisplayConfigGetDeviceInfo(&sourceName.header) != ERROR_SUCCESS)
      continue;

    DISPLAYCONFIG_TARGET_DEVICE_NAME targetName = {};
    targetName.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
    targetName.header.size = sizeof(targetName);
    targetName.header.adapterId = path.targetInfo.adapterId;
    targetName.header.id = path.targetInfo.id;
    bool haveTarget = DisplayConfigGetDeviceInfo(&targetName.header) == ERROR_SUCCESS;

    MonitorMatch match = {sourceName.viewGdiDeviceName, nullptr};
    EnumDisplayMonitors(nullptr, nullptr, findMonitor, reinterpret_cast<LPARAM>(&match));
    if (!match.monitor)
      continue;
    MONITORINFOEXW info = {};
    info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(match.monitor, &info))
      continue;

    seen.push_back({path.sourceInfo.adapterId, path.sourceInfo.id, total});
    if (total >= capacity) {
      truncated = true;
      total++;
      continue;
    }

    tvw_display& display = displays[total];
    memset(&display, 0, sizeof(display));
    display.id = stableId(haveTarget && targetName.monitorDevicePath[0] ? targetName.monitorDevicePath : sourceName.viewGdiDeviceName);
    display.x = info.rcMonitor.left;
    display.y = info.rcMonitor.top;
    display.width = info.rcMonitor.right - info.rcMonitor.left;
    display.height = info.rcMonitor.bottom - info.rcMonitor.top;
    display.work_x = info.rcWork.left;
    display.work_y = info.rcWork.top;
    display.work_width = info.rcWork.right - info.rcWork.left;
    display.work_height = info.rcWork.bottom - info.rcWork.top;
    UINT dpiX = 96, dpiY = 96;
    if (FAILED(GetDpiForMonitor(match.monitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY)))
      dpiX = dpiY = 96;
    display.dpi_x = dpiX;
    display.dpi_y = dpiY;
    display.primary = (info.dwFlags & MONITORINFOF_PRIMARY) ? 1 : 0;
    display.monitor = (uint64_t)(uintptr_t)match.monitor;
    if (haveTarget)
      wcsncpy_s(reinterpret_cast<wchar_t*>(display.name), ARRAYSIZE(display.name), targetName.monitorFriendlyDeviceName,
                _TRUNCATE);
    total++;
  }

  *count = total;
  return truncated ? E_NOT_SUFFICIENT_BUFFER : S_OK;
}

} // extern "C"
