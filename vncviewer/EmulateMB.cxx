/* Copyright 2020 Alex Tanskanen for Cendio AB
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

/*
 * Based on xf86-input-evdev
 *
 * Copyright 1990,91 by Thomas Roell, Dinkelscherben, Germany.
 * Copyright 1993 by David Dawes <dawes@xfree86.org>
 * Copyright 2002 by SuSE Linux AG, Author: Egbert Eich
 * Copyright 1994-2002 by The XFree86 Project, Inc.
 * Copyright 2002 by Paul Elliott
 * (Ported from xf86-input-mouse, above copyrights taken from there)
 * Copyright © 2008 University of South Australia
 *
 * Permission to use, copy, modify, distribute, and sell this software
 * and its documentation for any purpose is hereby granted without
 * fee, provided that the above copyright notice appear in all copies
 * and that both that copyright notice and this permission notice
 * appear in supporting documentation, and that the name of the authors
 * not be used in advertising or publicity pertaining to distribution of the
 * software without specific, written prior permission.  The authors make no
 * representations about the suitability of this software for any
 * purpose.  It is provided "as is" without express or implied
 * warranty.
 *
 * THE AUTHORS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
 * INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS, IN
 * NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY SPECIAL, INDIRECT OR
 * CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
 * OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
 * NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
 * CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 */

#include "parameters.h"
#include "EmulateMB.h"

EmulateMB::EmulateMB() : timer(this) {}
void EmulateMB::send(const viewer::MiddleButtonEmulator::Batch& batch)
{
  for (size_t i = 0; i < batch.count; ++i)
    sendPointerEvent(batch.events[i].position, batch.events[i].buttons);
}
void EmulateMB::filterPointerEvent(const core::Point& pos, uint16_t buttons)
{
  if (!emulateMiddleButton) {
    timer.stop(); emulator.reset(); sendPointerEvent(pos, buttons); return;
  }
  const auto batch = emulator.pointer(pos, buttons);
  send(batch);
  if (batch.timerChanged) {
    timer.stop();
    if (emulator.pending()) timer.start(50);
  }
}
void EmulateMB::handleTimeout(core::Timer* source)
{
  if (source != &timer) return;
  if (!emulateMiddleButton) { emulator.reset(); return; }
  send(emulator.expire());
}
