/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_DOCUMENT_OPTIONS_H
#define TIDYVNC_DOCUMENT_OPTIONS_H
#include <viewer/core/ConnectionDocument.h>
namespace viewer {
// Validate one understood connection-file entry without consulting globals.
// Unknown names are returned unchanged as false and are never decoded. Names
// match the historical file catalog, not the broader command-line alias set.
// Cross-field migration and local display/path interpretation belong to the host.
bool documentOption(const DocumentEntry&, DocumentAssignment& canonical);
// Same field catalog/validation for already decoded values, without file syntax
// or line limits. Unknown names leave output unchanged. Errors have line zero.
bool documentOptionValue(const DocumentAssignment&, DocumentAssignment& canonical);
}
#endif
