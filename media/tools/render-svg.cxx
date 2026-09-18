// Original TidyVNC work, 2026. SPDX-License-Identifier: GPL-2.0-or-later
// Optional regeneration tool; Qt 6 SVG/Gui, no display server required.
#include <QCoreApplication>
#include <QSvgRenderer>
#include <QPainter>
#include <QImage>
int main(int argc, char** argv) {
  QCoreApplication app(argc, argv);
  if (argc != 4) return 2;
  int size = QString(argv[2]).toInt();
  if (size < 1 || size > 4096) return 2;
  QSvgRenderer svg{QString(argv[1])};
  if (!svg.isValid()) return 3;
  QImage image(size, size, QImage::Format_ARGB32_Premultiplied);
  image.fill(Qt::transparent);
  QPainter painter(&image);
  svg.render(&painter);
  painter.end();
  return image.save(argv[3]) ? 0 : 4;
}
