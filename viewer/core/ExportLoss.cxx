/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "ExportLoss.h"

namespace viewer {
namespace {
constexpr uint32_t bit(ExportLoss loss) { return static_cast<uint32_t>(loss); }
}

uint32_t exportLosses(const ExportRequest& request)
{
  if (!request.tlsPriority.empty()) throw ExportError(ExportProblem::SecurityPolicy);
  uint32_t losses = bit(ExportLoss::FailureAlerts) | bit(ExportLoss::RemoteResize) | bit(ExportLoss::NetworkFamilies) |
                    bit(ExportLoss::PointerTiming) | bit(ExportLoss::ClipboardLimit) | bit(ExportLoss::WindowPlacement);
  if (request.selectedDisplays) losses |= bit(ExportLoss::DisplayIdentity);
  if (request.ignoredInput) losses |= bit(ExportLoss::IgnoredInput);
  if (request.sshGateway) losses |= bit(ExportLoss::SshGateway);
  return losses;
}

const std::vector<ExportLossInfo>& exportLossCatalog()
{
  static const std::vector<ExportLossInfo> catalog = {
    {ExportLoss::FailureAlerts, "failureAlerts", "AlertOnFatalError"},
    {ExportLoss::RemoteResize, "remoteResize", "RemoteResize"},
    {ExportLoss::NetworkFamilies, "networkFamilies", "UseIPv4,UseIPv6"},
    {ExportLoss::PointerTiming, "pointerTiming", "PointerEventInterval"},
    {ExportLoss::ClipboardLimit, "clipboardLimit", "MaxCutText"},
    {ExportLoss::WindowPlacement, "windowPlacement", "geometry,Maximize"},
    {ExportLoss::DisplayIdentity, "displayIdentity", "FullScreenSelectedMonitors"},
    {ExportLoss::IgnoredInput, "ignoredInput", ""},
    {ExportLoss::SshGateway, "sshGateway", "via"},
  };
  return catalog;
}
}
