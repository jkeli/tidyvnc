// Original TidyVNC work, 2026. SPDX-License-Identifier: GPL-2.0-or-later
#ifndef TIDYVNC_LEGACY_IMPORT_H
#define TIDYVNC_LEGACY_IMPORT_H
#include <string>
#ifndef _WIN32
// Returns no candidate if the current destination exists (even if malformed).
std::string legacyViewerFile(bool history);
void importLegacyHistory(const std::string& source);
void importLegacyPreferences(const std::string& source);
#endif
#endif
