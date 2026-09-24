/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */

#ifndef RFB_TLS_FILE_PATH_H
#define RFB_TLS_FILE_PATH_H

#include <string>

#if defined(_WIN32) && defined(_UCRT)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace rfb {

  // The path GnuTLS should open for a CA or CRL file. On Windows with the UCRT,
  // narrow paths reach CreateFileW through the active code page (UTF-8 in the
  // WinUI app), so a path of MAX_PATH or more characters is given in its
  // extended-length form (\\?\C:\... or \\?\UNC\server\share\...), which opens
  // without the LongPathsEnabled system setting (plans/native-ui-winui CORE.md
  // section 4, W1.9). Shorter paths, already-extended or device paths, paths
  // that do not convert, and other platforms (including msvcrt MinGW builds)
  // are returned unchanged.
  inline std::string tlsFilePath(const std::string& path)
  {
#if defined(_WIN32) && defined(_UCRT)
    const int length = ::MultiByteToWideChar(CP_ACP, MB_ERR_INVALID_CHARS, path.data(), static_cast<int>(path.size()), nullptr, 0);
    if (length < MAX_PATH)
      return path;
    std::wstring wide(static_cast<size_t>(length), L'\0');
    ::MultiByteToWideChar(CP_ACP, MB_ERR_INVALID_CHARS, path.data(), static_cast<int>(path.size()), &wide[0], length);
    if (wide.compare(0, 4, L"\\\\?\\") == 0 || wide.compare(0, 4, L"\\\\.\\") == 0)
      return path;
    // \\?\ turns off normalisation, so resolve separators and . or .. segments first.
    const DWORD needed = ::GetFullPathNameW(wide.c_str(), 0, nullptr, nullptr);
    if (needed == 0)
      return path;
    std::wstring full(needed, L'\0');
    const DWORD written = ::GetFullPathNameW(wide.c_str(), needed, &full[0], nullptr);
    if (written == 0 || written >= needed)
      return path;
    full.resize(written);
    const std::wstring extended = full.compare(0, 2, L"\\\\") == 0 ? L"\\\\?\\UNC\\" + full.substr(2) : L"\\\\?\\" + full;
    const int bytes = ::WideCharToMultiByte(CP_ACP, 0, extended.data(), static_cast<int>(extended.size()), nullptr, 0, nullptr, nullptr);
    if (bytes <= 0)
      return path;
    std::string result(static_cast<size_t>(bytes), '\0');
    ::WideCharToMultiByte(CP_ACP, 0, extended.data(), static_cast<int>(extended.size()), &result[0], bytes, nullptr, nullptr);
    return result;
#else
    return path;
#endif
  }

}

#endif
