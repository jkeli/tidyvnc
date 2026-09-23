/* Copyright (C) 2002-2005 RealVNC Ltd.  All Rights Reserved.
 * Copyright 2011 Pierre Ossman <ossman@cendio.se> for Cendio AB
 * Copyright 2012 Samuel Mannehed <samuel@cendio.se> for Cendio AB
 * 
 * This is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 * 
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this software; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307,
 * USA.
 */

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#ifdef HAVE_GNUTLS
#include <rfb/CSecurityTLS.h>
#endif

#ifdef _WIN32
#include <windows.h>
#endif

#include "parameters.h"
#include "LegacyImport.h"
#include <vector>
#include <utility>
#include <memory>
#include <viewer/core/ConnectionDocument.h>
#include <viewer/core/DocumentOptions.h>
#include <sys/stat.h>
#ifndef _WIN32
#include <unistd.h>
#endif

#include <core/Exception.h>
#include <core/AtomicFile.h>
#include <core/LogWriter.h>
#include <core/i18n.h>
#include <core/string.h>
#include <core/xdgdirs.h>

#include <rfb/CConnection.h>
#include <rfb/SecurityClient.h>

#include <FL/fl_utf8.h>

#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <errno.h>
#include <assert.h>
#include <viewer/core/PointerEventPolicy.h>

static core::LogWriter vlog("Parameters");

core::IntParameter
  pointerEventInterval("PointerEventInterval",
                       _("Time in milliseconds to rate-limit "
                         "successive pointer events"),
                       viewer::defaultPointerEventInterval, 0, INT_MAX);
core::BoolParameter
  emulateMiddleButton("EmulateMiddleButton",
                      _("Emulate middle mouse button by pressing left "
                        "and right mouse buttons simultaneously"),
                      false);
core::BoolParameter
  dotWhenNoCursor("DotWhenNoCursor",
                  _("[DEPRECATED] Show a dot cursor when the server "
                    "sends an invisible cursor"),
                  false);
core::BoolParameter
  alwaysCursor("AlwaysCursor",
               _("Show local cursor when not provided by the server"),
               false);
core::EnumParameter
  cursorType("CursorType",
             core::format(
               "%s (%s)",
               _("Specify which local cursor type should be used when "
                 "AlwaysCursor is active"), ("Dot, System")).c_str(),
             {"Dot", "System"}, "Dot");

core::BoolParameter
  alertOnFatalError("AlertOnFatalError",
                    _("Show an error dialog on connection problems, "
                      "rather than exiting immediately"),
                    true);

core::BoolParameter
  reconnectOnError("ReconnectOnError",
                   _("Show an error dialog on connection problems, "
                     "rather than exiting immediately, and allow the "
                     "user to reconnect"),
                   true);

core::StringParameter
  passwordFile("PasswordFile",
               _("Password file for VNC authentication"),
               "");
core::AliasParameter
  passwd("passwd", &passwordFile);

EncodingBoolParameter
  autoSelect(viewer::EncodingOption::AutoSelect,
             _("Auto select pixel format and encoding"));
EncodingBoolParameter
  fullColour(viewer::EncodingOption::FullColor, _("Use all available colors"));
core::AliasParameter
  fullColourAlias("FullColour", &fullColour);
EncodingIntParameter
  lowColourLevel(viewer::EncodingOption::LowColorLevel,
                 _("Color level to use on slow connections, "
                   "0 = Very Low, 1 = Low, 2 = Medium"));
core::AliasParameter
  lowColourLevelAlias("LowColourLevel", &lowColourLevel);
EncodingEnumParameter
  preferredEncoding(viewer::EncodingOption::PreferredEncoding,
                    _("Preferred encoding to use"));
EncodingBoolParameter
  customCompressLevel(viewer::EncodingOption::CustomCompressLevel,
                      _("Use custom compression level as specified by "
                        "CompressLevel"));
EncodingIntParameter
  compressLevel(viewer::EncodingOption::CompressLevel,
                _("Use specified compression level, 0 = Low, 9 = High"));
EncodingIntParameter
  qualityLevel(viewer::EncodingOption::QualityLevel,
               _("JPEG quality level, 0 = Low, 9 = High"));

viewer::EncodingOptions snapshotEncodingOptions()
{
  return viewer::EncodingOptions().withPatch({
    {"AutoSelect", autoSelect.getValueStr()},
    {"FullColor", fullColour.getValueStr()},
    {"LowColorLevel", lowColourLevel.getValueStr()},
    {"PreferredEncoding", preferredEncoding.getValueStr()},
    {"CustomCompressLevel", customCompressLevel.getValueStr()},
    {"CompressLevel", compressLevel.getValueStr()},
    {"NoJPEG", rfb::CConnection::noJpeg.getValueStr()},
    {"QualityLevel", qualityLevel.getValueStr()}
  }, viewer::OptionSource::Session);
}

core::BoolParameter
  maximize("Maximize", _("Maximize viewer window"), false);
core::BoolParameter
  fullScreen("FullScreen",
             _("Enable full screen as specified by FullScreenMode"),
             false);
core::EnumParameter
  fullScreenMode("FullScreenMode",
                 core::format(
                   "%s (%s)",
                   _("Specify which monitors to use when in "
                     "full screen"), "Current, Selected, All").c_str(),
                 {"Current", "Selected", "All"}, "Current");

core::BoolParameter
  fullScreenAllMonitors("FullScreenAllMonitors",
                        _("[DEPRECATED] Enable full screen over all "
                          "monitors"),
                        false);
MonitorIndicesParameter
  fullScreenSelectedMonitors("FullScreenSelectedMonitors",
                             _("Use the given list of monitors in full "
                               "screen when FullScreenMode is set to "
                               "Selected"),
                             {1});
core::StringParameter
  desktopSize("DesktopSize",
              _("Reconfigure the desktop size on the server to the "
                "specified size when connecting"),
              "");
core::StringParameter
  geometry("geometry",
           _("Specify size and position of viewer window"),
           "");

core::BoolParameter
  listenMode("listen",
             _("Listen for incoming connections from VNC servers"),
             false);

ScalingParameter scalingFactor("ScalingFactor",
  _("Desktop scaling: 100, Auto, FixedRatio, FitWidth, FitHeight, WxH, percent, or X%xY%"));
core::EnumParameter scalingQuality("ScalingQuality", _("Desktop resampling quality"),
  {"Nearest", "Bilinear", "Area"}, "Bilinear");
core::EnumParameter desktopPixelUnits("DesktopPixelUnits", _("Units for desktop pixels and fixed scaling"),
  {"Logical", "Device"}, "Logical");

core::BoolParameter
  remoteResize("RemoteResize",
               _("Dynamically resize the remote desktop size as the "
                 "size of the local client window changes"),
               true);

core::BoolParameter
  viewOnly("ViewOnly",
           _("Don't send any mouse or keyboard events to the server"),
           false);
core::BoolParameter
  shared("Shared",
         _("Don't disconnect other viewers upon connection"),
         false);

#ifdef HAVE_AUDIO
core::BoolParameter
  playAudio("Audio",
            _("Play audio sent by the server, if it offers any"),
            true);
#endif

core::BoolParameter
  acceptClipboard("AcceptClipboard",
                  _("Accept clipboard changes from the server"),
                  true);
core::BoolParameter
  sendClipboard("SendClipboard",
                _("Send clipboard changes to the server"),
                true);
#if !defined(WIN32) && !defined(__APPLE__)
core::BoolParameter
  setPrimary("SetPrimary",
             // TRANSLATORS: This refers to the two different X11
             //              clipboards
             _("Set the primary selection as well as the clipboard "
               "selection"),
             true);
core::BoolParameter
  sendPrimary("SendPrimary",
              // TRANSLATORS: This refers to the two different X11
              //              clipboards
              _("Send the primary selection to the server as well as "
                "the clipboard selection"),
              true);
core::StringParameter
  display("display", _("The X display to use"), "");
#endif

// Keep list of valid values in sync with ShortcutHandler
core::EnumListParameter
  shortcutModifiers("ShortcutModifiers",
                    // TRANSLATORS: The key names must be specified in
                    //              English
                    _("The combination of modifier keys that triggers "
                      "special actions in the viewer instead of being "
                      "sent to the remote session (possible keys are a "
                      "combination of Ctrl, Shift, Alt, and Super)"),
                    {"Ctrl", "Shift", "Alt", "Super",
                     "Win", "Option", "Cmd"},
                    {"Ctrl", "Alt"});

core::BoolParameter
  fullscreenSystemKeys("FullscreenSystemKeys",
                       _("Pass special keys (like Alt+Tab) directly to "
                         "the server when in full-screen mode"),
                       true);

#ifndef WIN32
core::StringParameter
  via("via", _("SSH gateway to tunnel the connection via"), "");
#endif


/*
 * We only save the sub set of parameters that can be modified from
 * the graphical user interface
 */
static core::VoidParameter* parameterArray[] = {
  /* Security */
#ifdef HAVE_GNUTLS
  &rfb::CSecurityTLS::X509CA,
  &rfb::CSecurityTLS::X509CRL,
#endif // HAVE_GNUTLS
  &rfb::SecurityClient::secTypes,
  /* Misc. */
  &reconnectOnError,
  &shared,
#ifdef HAVE_AUDIO
  &playAudio,
#endif
  /* Compression */
  &autoSelect,
  &fullColour,
  &lowColourLevel,
  &preferredEncoding,
  &customCompressLevel,
  &compressLevel,
  &rfb::CConnection::noJpeg,
  &qualityLevel,
  /* Display */
  &scalingFactor,
  &scalingQuality,
  &desktopPixelUnits,
  &fullScreen,
  &fullScreenMode,
  &fullScreenSelectedMonitors,
  /* Input */
  &viewOnly,
  &emulateMiddleButton,
  &alwaysCursor,
  &cursorType,
  &acceptClipboard,
  &sendClipboard,
#if !defined(WIN32) && !defined(__APPLE__)
  &sendPrimary,
  &setPrimary,
#endif
  &fullscreenSystemKeys,
  /* Keyboard shortcuts */
  &shortcutModifiers,
};

static core::VoidParameter* readOnlyParameterArray[] = {
  &fullScreenAllMonitors,
  &dotWhenNoCursor
};

// Parsing and import are transactional: malformed files never leave partial
// settings in memory. Also used to validate an import without adopting secrets.
class ParameterSnapshot {
public:
  ParameterSnapshot() : keep(false) {
    for (auto* p : parameterArray) values.emplace_back(p, p->getValueStr());
    for (auto* p : readOnlyParameterArray) values.emplace_back(p, p->getValueStr());
  }
  ~ParameterSnapshot() {
    if (!keep) for (auto& entry : values) {
      if (entry.first->getValueStr() != entry.second)
        entry.first->setParam(entry.second.c_str());
    }
  }
  bool keep;
private:
  std::vector<std::pair<core::VoidParameter*, std::string>> values;
};

#ifdef _WIN32
// Registry strings retain the same escaping and bounded buffers as files.
static bool encodeValue(const char* value, char* dest, size_t size) {
  try {
    const auto encoded = viewer::ConnectionDocument::encodeValue(value);
    if (encoded.size() >= size) return false;
    memcpy(dest, encoded.c_str(), encoded.size() + 1);
    return true;
  } catch (const viewer::DocumentError&) { return false; }
}
static bool decodeValue(const char* value, char* dest, size_t size) {
  try {
    const auto decoded = viewer::ConnectionDocument::decodeValue(value);
    if (decoded.size() >= size) return false;
    memcpy(dest, decoded.c_str(), decoded.size() + 1);
    return true;
  } catch (const viewer::DocumentError&) { return false; }
}

static void setKeyString(const char *_name, const char *_value, HKEY* hKey) {
  
  const DWORD buffersize = 256;

  wchar_t name[buffersize];
  unsigned size = fl_utf8towc(_name, strlen(_name)+1, name, buffersize);
  if (size >= buffersize)
    throw std::length_error("The name of the parameter is too large");

  char encodingBuffer[buffersize];
  if (!encodeValue(_value, encodingBuffer, buffersize))
    throw std::length_error("The parameter is too large");

  wchar_t value[buffersize];
  size = fl_utf8towc(encodingBuffer, strlen(encodingBuffer)+1, value, buffersize);
  if (size >= buffersize)
    throw std::length_error("The parameter is too large");

  LONG res = RegSetValueExW(*hKey, name, 0, REG_SZ, (BYTE*)&value, (wcslen(value)+1)*2);
  if (res != ERROR_SUCCESS)
    throw core::win32_error("RegSetValueExW", res);
}


static void setKeyInt(const char *_name, const int _value, HKEY* hKey) {

  const DWORD buffersize = 256;
  wchar_t name[buffersize];
  DWORD value = _value;

  unsigned size = fl_utf8towc(_name, strlen(_name)+1, name, buffersize);
  if (size >= buffersize)
    throw std::length_error("The name of the parameter is too large");

  LONG res = RegSetValueExW(*hKey, name, 0, REG_DWORD, (BYTE*)&value, sizeof(DWORD));
  if (res != ERROR_SUCCESS)
    throw core::win32_error("RegSetValueExW", res);
}


static bool getKeyString(const char* _name, char* dest, size_t destSize, HKEY* hKey) {
  
  const DWORD buffersize = 256;
  wchar_t name[buffersize];
  WCHAR* value;
  DWORD valuesize;

  unsigned size = fl_utf8towc(_name, strlen(_name)+1, name, buffersize);
  if (size >= buffersize)
    throw std::length_error("The name of the parameter is too large");

  value = new WCHAR[destSize];
  valuesize = destSize;
  LONG res = RegQueryValueExW(*hKey, name, nullptr, nullptr, (LPBYTE)value, &valuesize);
  if (res != ERROR_SUCCESS){
    delete [] value;
    if (res != ERROR_FILE_NOT_FOUND)
      throw core::win32_error("RegQueryValueExW", res);
    // The value does not exist, defaults will be used.
    return false;
  }

  char* utf8val = new char[destSize];
  size = fl_utf8fromwc(utf8val, destSize, value, wcslen(value)+1);
  delete [] value;
  if (size >= destSize) {
    delete [] utf8val;
    throw std::length_error("The parameter is too large");
  }

  bool ret = decodeValue(utf8val, dest, destSize);
  delete [] utf8val;

  if (!ret)
    throw std::invalid_argument("Invalid format or too large value");

  return true;
}


static bool getKeyInt(const char* _name, int* dest, HKEY* hKey) {
  
  const DWORD buffersize = 256;
  DWORD dwordsize = sizeof(DWORD);
  DWORD value = 0;
  wchar_t name[buffersize];

  unsigned size = fl_utf8towc(_name, strlen(_name)+1, name, buffersize);
  if (size >= buffersize)
    throw std::length_error("The name of the parameter is too large");

  LONG res = RegQueryValueExW(*hKey, name, nullptr, nullptr, (LPBYTE)&value, &dwordsize);
  if (res != ERROR_SUCCESS){
    if (res != ERROR_FILE_NOT_FOUND)
      throw core::win32_error("RegQueryValueExW", res);
    // The value does not exist, defaults will be used.
    return false;
  }

  *dest = (int)value;
  return true;
}

static void removeValue(const char* _name, HKEY* hKey) {
  const DWORD buffersize = 256;
  wchar_t name[buffersize];

  unsigned size = fl_utf8towc(_name, strlen(_name)+1, name, buffersize);
  if (size >= buffersize)
    throw std::length_error("The name of the parameter is too large");

  LONG res = RegDeleteValueW(*hKey, name);
  if (res != ERROR_SUCCESS) {
    if (res != ERROR_FILE_NOT_FOUND)
      throw core::win32_error("RegDeleteValueW", res);
    // The value does not exist, no need to remove it.
    return;
  }
}

void saveHistoryToRegKey(const std::list<std::string>& serverHistory)
{
  HKEY hKey;
  LONG res = RegCreateKeyExW(HKEY_CURRENT_USER,
                             L"Software\\TigerVNC\\vncviewer\\history", 0, nullptr,
                             REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS, nullptr,
                             &hKey, nullptr);

  if (res != ERROR_SUCCESS)
    throw core::win32_error(_("Failed to create registry key"), res);

  unsigned index = 0;
  assert(SERVER_HISTORY_SIZE < 100);
  char indexString[3];

  try {
    for (const std::string& entry : serverHistory) {
      if (index > SERVER_HISTORY_SIZE)
        break;
      snprintf(indexString, 3, "%d", index);
      setKeyString(indexString, entry.c_str(), &hKey);
      index++;
    }
  } catch (std::exception& e) {
    RegCloseKey(hKey);
    throw;
  }

  res = RegCloseKey(hKey);
  if (res != ERROR_SUCCESS)
    throw core::win32_error(_("Failed to close registry key"), res);
}

static void saveToReg(const char* servername) {
  
  HKEY hKey;
    
  LONG res = RegCreateKeyExW(HKEY_CURRENT_USER,
                             L"Software\\TigerVNC\\vncviewer", 0, nullptr,
                             REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS, nullptr,
                             &hKey, nullptr);
  if (res != ERROR_SUCCESS)
    throw core::win32_error(_("Failed to create registry key"), res);

  try {
    setKeyString("ServerName", servername, &hKey);
  } catch (std::exception& e) {
    RegCloseKey(hKey);
    throw std::runtime_error(core::format(
      _("Failed to save \"%s\": %s"), "ServerName", e.what()));
  }

  for (core::VoidParameter* param : parameterArray) {
    core::IntParameter* iparam;
    core::BoolParameter* bparam;

    if (param->isDefault()) {
      try {
        removeValue(param->getName(), &hKey);
      } catch (std::exception& e) {
        RegCloseKey(hKey);
        throw std::runtime_error(
          core::format(_("Failed to remove \"%s\": %s"),
                       param->getName(), e.what()));
      }
      continue;
    }

    iparam = dynamic_cast<core::IntParameter*>(param);
    bparam = dynamic_cast<core::BoolParameter*>(param);

    try {
      if (iparam != nullptr) {
        setKeyInt(iparam->getName(), (int)*(iparam), &hKey);
      } else if (bparam != nullptr) {
        setKeyInt(bparam->getName(), (int)*(bparam), &hKey);
      } else {
        setKeyString(param->getName(), param->getValueStr().c_str(), &hKey);
      }
    } catch (std::exception& e) {
      RegCloseKey(hKey);
      throw std::runtime_error(
        core::format(_("Failed to save \"%s\": %s"),
                     param->getName(), e.what()));
    }
  }

  // Remove read-only parameters to replicate the behaviour of Linux/macOS when they
  // store a config to disk. If the parameter hasn't been migrated at this point it
  // will be lost.
  for (core::VoidParameter* param : readOnlyParameterArray) {
    try {
      removeValue(param->getName(), &hKey);
    } catch (std::exception& e) {
      RegCloseKey(hKey);
      throw std::runtime_error(
        core::format(_("Failed to remove \"%s\": %s"),
                     param->getName(), e.what()));
    }
  }

  res = RegCloseKey(hKey);
  if (res != ERROR_SUCCESS)
    throw core::win32_error(_("Failed to close registry key"), res);
}

std::list<std::string> loadHistoryFromRegKey()
{
  HKEY hKey;
  std::list<std::string> serverHistory;

  LONG res = RegOpenKeyExW(HKEY_CURRENT_USER,
                           L"Software\\TigerVNC\\vncviewer\\history", 0,
                           KEY_READ, &hKey);
  if (res != ERROR_SUCCESS) {
    if (res == ERROR_FILE_NOT_FOUND) {
      // The key does not exist, defaults will be used.
      return serverHistory;
    }

    throw core::win32_error(_("Failed to open registry key"), res);
  }

  unsigned index;
  const DWORD buffersize = 256;
  char indexString[3];

  for (index = 0;;index++) {
    snprintf(indexString, 3, "%d", index);
    char servernameBuffer[buffersize];

    try {
      if (!getKeyString(indexString, servernameBuffer,
                        buffersize, &hKey))
        break;
    } catch (std::exception& e) {
      // Just ignore this entry and try the next one
      vlog.error(_("Failed to read server history entry %d: %s"),
                 (int)index, e.what());
      continue;
    }

    serverHistory.push_back(servernameBuffer);
  }

  res = RegCloseKey(hKey);
  if (res != ERROR_SUCCESS)
    throw core::win32_error(_("Failed to close registry key"), res);

  return serverHistory;
}

static void getParametersFromReg(core::VoidParameter* parameters[],
                                 size_t parameters_len, HKEY* hKey)
{
  const size_t buffersize = 256;
  int intValue = 0;
  char stringValue[buffersize];

  for (size_t i = 0; i < parameters_len; i++) {
    core::IntParameter* iparam;
    core::BoolParameter* bparam;

    iparam = dynamic_cast<core::IntParameter*>(parameters[i]);
    bparam = dynamic_cast<core::BoolParameter*>(parameters[i]);

    try {
      if (iparam != nullptr) {
        if (getKeyInt(iparam->getName(), &intValue, hKey))
          iparam->setParam(intValue);
      } else if (bparam != nullptr) {
        if (getKeyInt(bparam->getName(), &intValue, hKey))
          bparam->setParam(intValue);
      } else {
        if (getKeyString(parameters[i]->getName(), stringValue, buffersize, hKey))
          parameters[i]->setParam(stringValue);
      }
    } catch(std::exception& e) {
      // Just ignore this entry and continue with the rest
      vlog.error(_("Failed to read parameter \"%s\": %s"),
                 parameters[i]->getName(), e.what());
    }
  }
}

static char* loadFromReg() {

  HKEY hKey;

  LONG res = RegOpenKeyExW(HKEY_CURRENT_USER,
                           L"Software\\TigerVNC\\vncviewer", 0,
                           KEY_READ, &hKey);
  if (res != ERROR_SUCCESS) {
    if (res == ERROR_FILE_NOT_FOUND) {
      // The key does not exist, defaults will be used.
      return nullptr;
    }

    throw core::win32_error(_("Failed to open registry key"), res);
  }

  const size_t buffersize = 256;
  static char servername[buffersize];

  char servernameBuffer[buffersize];
  try {
    if (getKeyString("ServerName", servernameBuffer, buffersize, &hKey))
      snprintf(servername, buffersize, "%s", servernameBuffer);
  } catch(std::exception& e) {
    vlog.error(_("Failed to read parameter \"%s\": %s"),
               "ServerName", e.what());
    strcpy(servername, "");
  }

  getParametersFromReg(parameterArray,
                       sizeof(parameterArray) /
                         sizeof(core::VoidParameter*),
                       &hKey);
  getParametersFromReg(readOnlyParameterArray,
                       sizeof(readOnlyParameterArray) /
                         sizeof(core::VoidParameter*),
                       &hKey);

  res = RegCloseKey(hKey);
  if (res != ERROR_SUCCESS)
    throw core::win32_error(_("Failed to close registry key"), res);

  migrateDeprecatedOptions();

  return servername;
}
#endif // _WIN32


void saveViewerParameters(const char *filename, const char *servername) {
  char filepath[PATH_MAX];
  if (filename == nullptr) {
#ifdef _WIN32
    saveToReg(servername);
    return;
#endif
    const char* configDir = core::gettidyvncconfigdir();
    if (!configDir)
      throw std::runtime_error(_("Could not determine VNC config directory path"));
    snprintf(filepath, sizeof(filepath), "%s/default.tidyvnc", configDir);
  } else {
    snprintf(filepath, sizeof(filepath), "%s", filename);
  }

  std::vector<viewer::DocumentAssignment> fields{{"ServerName", servername ? servername : ""}};
  for (auto* param : parameterArray)
    if (!param->isDefault()) fields.push_back({param->getName(), param->getValueStr()});
  // Validate the complete output before opening/replacing any destination.
  const auto document = viewer::ConnectionDocument::serialize(fields);
#ifndef _WIN32
  core::AtomicFile output(filepath);
  FILE* f = output.stream();
#else
  FILE* f = fopen(filepath, "wb");
#endif
  if (!f)
    throw core::posix_error(core::format(_("Failed to open \"%s\""), filepath), errno);
  const bool writeError = fwrite(document.data(), 1, document.size(), f) != document.size();
#ifndef _WIN32
  if (writeError) throw core::posix_error("Write settings file", errno ? errno : EIO);
  output.commit();
#else
  if (fclose(f) != 0 || writeError)
    throw core::posix_error("Write settings file", errno ? errno : EIO);
#endif
}

static bool setDocumentParameter(core::VoidParameter* parameters[], size_t count,
                                 const viewer::DocumentEntry& entry) {
  for (size_t i = 0; i < count; ++i) {
    if (strcasecmp(entry.name.c_str(), parameters[i]->getName()) != 0) continue;
    viewer::DocumentAssignment validated;
    (void)viewer::documentOption(entry, validated);
    if (!parameters[i]->setParam(entry.value().c_str()))
      throw std::runtime_error(_("Invalid parameter value"));
    return true;
  }
  return false;
}

char* loadViewerParameters(const char *filename) {
  ParameterSnapshot snapshot;

  char filepath[PATH_MAX];
  static char servername[256];

  memset(servername, '\0', sizeof(servername));

  // Load from the registry or a predefined file if no filename was specified.
  if(filename == nullptr) {

#ifdef _WIN32
    char* result = loadFromReg();
    snapshot.keep = true;
    return result;
#endif

    const char* configDir = core::gettidyvncconfigdir();
    if (configDir == nullptr)
      throw std::runtime_error(_("Could not determine VNC config directory path"));

    snprintf(filepath, sizeof(filepath), "%s/default.tidyvnc", configDir);
  } else {
    snprintf(filepath, sizeof(filepath), "%s", filename);
  }

  // A deleter type, not decltype(&fclose): GCC rejects glibc's attributes there.
  struct CloseFile { void operator()(FILE* f) const { fclose(f); } };
  std::unique_ptr<FILE, CloseFile> file(fopen(filepath, "rb"));
  if (!file) {
    if (!filename && errno == ENOENT) return nullptr;
    throw core::posix_error(core::format(_("Failed to open \"%s\""), filepath), errno);
  }
  std::string bytes;
  char chunk[4096];
  while (const auto count = fread(chunk, 1, sizeof(chunk), file.get())) {
    if (count > viewer::ConnectionDocument::maximumBytes - bytes.size())
      throw viewer::DocumentError(viewer::DocumentErrorCode::TooLarge);
    bytes.append(chunk, count);
  }
  if (ferror(file.get())) throw core::posix_error("Read settings file", errno ? errno : EIO);
  file.reset();
  const auto document = viewer::ConnectionDocument::parse(bytes);
  for (const auto& entry : document.entries()) {
    try {
      if (strcasecmp(entry.name.c_str(), "ServerName") == 0) {
        const auto value = entry.value();
        memcpy(servername, value.c_str(), value.size() + 1);
      } else if (!setDocumentParameter(parameterArray, sizeof(parameterArray) / sizeof(*parameterArray), entry) &&
                 !setDocumentParameter(readOnlyParameterArray, sizeof(readOnlyParameterArray) / sizeof(*readOnlyParameterArray), entry)) {
        vlog.error("%s: %s", core::format(_("Failed to read line %d in file \"%s\""),
                   int(entry.line), filepath).c_str(), _("Unknown parameter"));
      }
    } catch (const std::exception& error) {
      throw std::runtime_error(core::format(_("Failed to read line %d in file \"%s\""),
                               int(entry.line), filepath) + ": " + error.what());
    }
  }

  migrateDeprecatedOptions();

  snapshot.keep = true;
  return servername;
}

void migrateDeprecatedOptions()
{
  if (fullScreenAllMonitors) {
    vlog.info(_("FullScreenAllMonitors is deprecated, set FullScreenMode to 'all' instead"));

    fullScreenMode.setParam("all");
  }
  if (dotWhenNoCursor) {
    vlog.info(_("DotWhenNoCursor is deprecated, set AlwaysCursor to 1 and CursorType to 'Dot' instead"));

    alwaysCursor.setParam(true);
    cursorType.setParam("Dot");
  }
}

#ifndef _WIN32
void importLegacyPreferences(const std::string& source)
{
  const char* dir = core::gettidyvncconfigdir();
  if (!dir) throw std::runtime_error("Cannot determine viewer configuration directory");
  std::string destination = std::string(dir) + "/default.tidyvnc";
  struct stat st;
  if (lstat(destination.c_str(), &st) == 0) return;
  if (errno != ENOENT) throw core::posix_error("Inspect viewer preferences", errno);
  ParameterSnapshot restore;
  // Reset ordinary options before reading so imported values do not inherit
  // unrelated process-local preferences. Restore everything on return/failure.
  for (auto* p : parameterArray)
    if (!p->isDefault()) p->setParam(p->getDefaultStr().c_str());
  for (auto* p : readOnlyParameterArray)
    if (!p->isDefault()) p->setParam(p->getDefaultStr().c_str());
  loadViewerParameters(source.c_str());
  std::vector<viewer::DocumentAssignment> fields;
  for (auto* p : parameterArray) {
    std::string name(p->getName());
    // Separate, explicit choices; migration never adopts addresses or security.
    if (name == "X509CA" || name == "X509CRL" || name == "SecurityTypes") continue;
    if (!p->isDefault()) fields.push_back({name, p->getValueStr()});
  }
  const auto document = viewer::ConnectionDocument::serialize(fields);
  core::AtomicFile file(destination.c_str());
  if (fwrite(document.data(), 1, document.size(), file.stream()) != document.size())
    throw core::posix_error("Write imported preferences", errno ? errno : EIO);
  struct stat sourceMode;
  if (stat(source.c_str(), &sourceMode) != 0 ||
      fchmod(fileno(file.stream()), sourceMode.st_mode & 0600) != 0)
    throw core::posix_error("Preserve private import permissions", errno);
  file.commit(false);
}
#endif
