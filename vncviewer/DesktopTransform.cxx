/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include "DesktopTransform.h"
#include <algorithm>
#include <cmath>
#include <cctype>
#include <limits>
#include <stdexcept>

namespace {
unsigned number(const std::string& s, bool percent)
{
  if (s.empty()) throw std::invalid_argument("Empty scaling value");
  unsigned result = 0, decimals = 0;
  bool dot = false;
  for (char c : s) {
    if (c == '.' && percent && !dot) {
      if (s.front() == '.') throw std::invalid_argument("Missing integer part");
      dot = true; continue;
    }
    if (c < '0' || c > '9' || (dot && ++decimals > 2))
      throw std::invalid_argument("Invalid scaling number");
    if (result > 1000000) throw std::invalid_argument("Scaling number too large");
    result = result * 10 + (c - '0');
  }
  if (dot && decimals == 0) throw std::invalid_argument("Missing fraction");
  if (percent) {
    while (decimals++ < 2) result *= 10;
    if (!result || result > 1000000) throw std::invalid_argument("Percentage outside 0.01..10000");
  } else if (!result || result > 65535) {
    throw std::invalid_argument("Dimension outside 1..65535");
  }
  return result;
}
std::string percentage(unsigned value)
{
  std::string s = std::to_string(value / 100);
  if (value % 100) {
    s += '.';
    s += char('0' + (value % 100) / 10);
    if (value % 10) s += char('0' + value % 10);
  }
  return s;
}
int dimension(double value, bool down = false)
{
  if (!std::isfinite(value) || value > 65535.0)
    throw std::overflow_error("Scaled desktop exceeds 65535 pixels");
  return std::max(1, int(down ? std::floor(value) : std::floor(value + 0.5)));
}
int origin(double value)
{
  if (!std::isfinite(value) || std::abs(value) > std::numeric_limits<int>::max() / 4)
    throw std::overflow_error("Desktop origin out of range");
  return int(std::floor(value + 0.5));
}
}

ScalingSettings ScalingSettings::parse(const std::string& value)
{
  std::string s = value;
  size_t begin = s.find_first_not_of(" \t\r\n"), end = s.find_last_not_of(" \t\r\n");
  if (begin == std::string::npos) throw std::invalid_argument("Empty scaling value");
  s = s.substr(begin, end - begin + 1);
  for (char& c : s) c = std::tolower(static_cast<unsigned char>(c));
  ScalingSettings out;
  if (s == "none") out.mode = Unscaled;
  else if (s == "auto") out.mode = Auto;
  else if (s == "fixedratio") out.mode = FixedRatio;
  else if (s == "fitwidth") out.mode = FitWidth;
  else if (s == "fitheight") out.mode = FitHeight;
  else {
    size_t split = s.find('x');
    if (split != std::string::npos) {
      std::string a = s.substr(0, split), b = s.substr(split + 1);
      bool independent = !a.empty() && !b.empty() && a.back() == '%' && b.back() == '%';
      if (independent) { a.pop_back(); b.pop_back(); }
      out.mode = independent ? Independent : Exact;
      out.x = number(a, independent); out.y = number(b, independent);
    } else {
      if (s.back() == '%') s.pop_back();
      out.x = out.y = number(s, true);
      out.mode = out.x == 10000 ? Unscaled : Percent;
    }
  }
  return out;
}
std::string ScalingSettings::serialize() const
{
  switch (mode) {
  case Unscaled: return "100";
  case Auto: return "Auto";
  case FixedRatio: return "FixedRatio";
  case FitWidth: return "FitWidth";
  case FitHeight: return "FitHeight";
  case Exact: return std::to_string(x) + "x" + std::to_string(y);
  case Independent: return percentage(x) + "%x" + percentage(y) + "%";
  case Percent: return percentage(x);
  }
  throw std::logic_error("Unknown scaling mode");
}
bool ScalingSettings::fits() const
{ return mode == Auto || mode == FixedRatio || mode == FitWidth || mode == FitHeight; }
bool DisplayMetrics::valid() const
{
  return std::isfinite(pixelsPerUnitX) && std::isfinite(pixelsPerUnitY) &&
         pixelsPerUnitX >= 1.0/16 && pixelsPerUnitY >= 1.0/16 &&
         pixelsPerUnitX <= 16 && pixelsPerUnitY <= 16;
}
DesktopTransform::DesktopTransform(int rw, int rh, double aw, double ah,
  const DisplayMetrics& m, const ScalingSettings& s, ScalingSettings::Units units,
  double ox, double oy)
  : remoteWidth(rw), remoteHeight(rh), backingWidth(0), backingHeight(0),
    logicalWidth(0), logicalHeight(0), originBX(0), originBY(0), metrics(m)
{
  if (!m.valid()) throw std::invalid_argument("Invalid display metrics");
  if (rw <= 0 || rh <= 0 || !std::isfinite(aw) || !std::isfinite(ah) || aw <= 0 || ah <= 0)
    return;
  double w = rw, h = rh;
  double qx = m.pixelsPerUnitX, qy = m.pixelsPerUnitY;
  if (s.fits()) {
    double scale;
    if (s.mode == ScalingSettings::Auto) { w = aw; h = ah; }
    else {
      if (s.mode == ScalingSettings::FitWidth) scale = aw / rw;
      else if (s.mode == ScalingSettings::FitHeight) scale = ah / rh;
      else scale = std::min(aw / rw, ah / rh);
      w = rw * scale; h = rh * scale;
    }
    backingWidth = dimension(w * qx, true);
    backingHeight = dimension(h * qy, true);
  } else {
    if (s.mode == ScalingSettings::Exact) { w = s.x; h = s.y; }
    else { w *= s.x / 10000.0; h *= s.y / 10000.0; }
    backingWidth = dimension(w * (units == ScalingSettings::Logical ? qx : 1));
    backingHeight = dimension(h * (units == ScalingSettings::Logical ? qy : 1));
  }
  logicalWidth = backingWidth / qx; logicalHeight = backingHeight / qy;
  originBX = origin(ox * qx); originBY = origin(oy * qy);
}
bool DesktopTransform::identity() const
{ return !empty() && backingWidth == remoteWidth && backingHeight == remoteHeight; }
void DesktopTransform::placeOnCanvas(int width,int height,const core::Rect& region,
                                    ScalingSettings::Units units,double panX,double panY)
{
  double ux=units==ScalingSettings::Device?metrics.pixelsPerUnitX:1;
  double uy=units==ScalingSettings::Device?metrics.pixelsPerUnitY:1;
  double imageW=logicalWidth*ux, imageH=logicalHeight*uy;
  double x=(std::max(0.,(width-imageW)/2)-region.tl.x-
            std::max(0.,std::min(panX,std::max(0.,imageW-width))))/ux;
  double y=(std::max(0.,(height-imageH)/2)-region.tl.y-
            std::max(0.,std::min(panY,std::max(0.,imageH-height))))/uy;
  originBX=origin(x*metrics.pixelsPerUnitX);
  originBY=origin(y*metrics.pixelsPerUnitY);
}
core::Point DesktopTransform::remotePoint(double lx, double ly) const
{
  if (empty() || !std::isfinite(lx) || !std::isfinite(ly)) return {0, 0};
  double rx = std::floor((lx * metrics.pixelsPerUnitX - originBX) * remoteWidth / backingWidth);
  double ry = std::floor((ly * metrics.pixelsPerUnitY - originBY) * remoteHeight / backingHeight);
  return {int(std::max(0.0, std::min(double(remoteWidth - 1), rx))),
          int(std::max(0.0, std::min(double(remoteHeight - 1), ry)))};
}
core::Rect DesktopTransform::logicalDamage(const core::Rect& r, ScalingSettings::Quality quality) const
{
  if (empty() || r.is_empty()) return {};
  int halo = quality == ScalingSettings::Nearest ? 0 : 1;
  double sx = double(backingWidth) / remoteWidth, sy = double(backingHeight) / remoteHeight;
  return {int(std::floor((originBX + std::max(0, r.tl.x - halo) * sx) / metrics.pixelsPerUnitX)),
          int(std::floor((originBY + std::max(0, r.tl.y - halo) * sy) / metrics.pixelsPerUnitY)),
          int(std::ceil((originBX + std::min(remoteWidth, r.br.x + halo) * sx) / metrics.pixelsPerUnitX)),
          int(std::ceil((originBY + std::min(remoteHeight, r.br.y + halo) * sy) / metrics.pixelsPerUnitY))};
}
