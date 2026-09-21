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

#include "MiddleButtonEmulator.h"

namespace viewer {
/*
 * Lets create a simple finite-state machine for 3 button emulation:
 *
 * We track buttons 1 and 3 (left and right).  There are 11 states:
 *   0 ground           - initial state
 *   1 delayed left     - left pressed, waiting for right
 *   2 delayed right    - right pressed, waiting for left
 *   3 pressed middle   - right and left pressed, emulated middle sent
 *   4 pressed left     - left pressed and sent
 *   5 pressed right    - right pressed and sent
 *   6 released left    - left released after emulated middle
 *   7 released right   - right released after emulated middle
 *   8 repressed left   - left pressed after released left
 *   9 repressed right  - right pressed after released right
 *  10 pressed both     - both pressed, not emulating middle
 *
 * At each state, we need handlers for the following events
 *   0: no buttons down
 *   1: left button down
 *   2: right button down
 *   3: both buttons down
 *   4: emulate3Timeout passed without a button change
 * Note that button events are not deltas, they are the set of buttons being
 * pressed now.  It's possible (ie, mouse hardware does it) to go from (eg)
 * left down to right down without anything in between, so all cases must be
 * handled.
 *
 * a handler consists of three values:
 *   0: action1
 *   1: action2
 *   2: new emulation state
 *
 * action > 0: ButtonPress
 * action = 0: nothing
 * action < 0: ButtonRelease
 *
 * The comment preceding each section is the current emulation state.
 * The comments to the right are of the form
 *      <button state> (<events>) -> <new emulation state>
 * which should be read as
 *      If the buttons are in <button state>, generate <events> then go to
 *      <new emulation state>.
 */
static const signed char stateTab[11][5][3] = {
/* 0 ground */
  {
    {  0,  0,  0 },   /* nothing -> ground (no change) */
    {  0,  0,  1 },   /* left -> delayed left */
    {  0,  0,  2 },   /* right -> delayed right */
    {  2,  0,  3 },   /* left & right (middle press) -> pressed middle */
    {  0,  0, -1 }    /* timeout N/A */
  },
/* 1 delayed left */
  {
    {  1, -1,  0 },   /* nothing (left event) -> ground */
    {  0,  0,  1 },   /* left -> delayed left (no change) */
    {  1, -1,  2 },   /* right (left event) -> delayed right */
    {  2,  0,  3 },   /* left & right (middle press) -> pressed middle */
    {  1,  0,  4 },   /* timeout (left press) -> pressed left */
  },
/* 2 delayed right */
  {
    {  3, -3,  0 },   /* nothing (right event) -> ground */
    {  3, -3,  1 },   /* left (right event) -> delayed left (no change) */
    {  0,  0,  2 },   /* right -> delayed right (no change) */
    {  2,  0,  3 },   /* left & right (middle press) -> pressed middle */
    {  3,  0,  5 },   /* timeout (right press) -> pressed right */
  },
/* 3 pressed middle */
  {
    { -2,  0,  0 },   /* nothing (middle release) -> ground */
    {  0,  0,  7 },   /* left -> released right */
    {  0,  0,  6 },   /* right -> released left */
    {  0,  0,  3 },   /* left & right -> pressed middle (no change) */
    {  0,  0, -1 },   /* timeout N/A */
  },
/* 4 pressed left */
  {
    { -1,  0,  0 },   /* nothing (left release) -> ground */
    {  0,  0,  4 },   /* left -> pressed left (no change) */
    { -1,  0,  2 },   /* right (left release) -> delayed right */
    {  3,  0, 10 },   /* left & right (right press) -> pressed both */
    {  0,  0, -1 },   /* timeout N/A */
  },
/* 5 pressed right */
  {
    { -3,  0,  0 },   /* nothing (right release) -> ground */
    { -3,  0,  1 },   /* left (right release) -> delayed left */
    {  0,  0,  5 },   /* right -> pressed right (no change) */
    {  1,  0, 10 },   /* left & right (left press) -> pressed both */
    {  0,  0, -1 },   /* timeout N/A */
  },
/* 6 released left */
  {
    { -2,  0,  0 },   /* nothing (middle release) -> ground */
    { -2,  0,  1 },   /* left (middle release) -> delayed left */
    {  0,  0,  6 },   /* right -> released left (no change) */
    {  1,  0,  8 },   /* left & right (left press) -> repressed left */
    {  0,  0, -1 },   /* timeout N/A */
  },
/* 7 released right */
  {
    { -2,  0,  0 },   /* nothing (middle release) -> ground */
    {  0,  0,  7 },   /* left -> released right (no change) */
    { -2,  0,  2 },   /* right (middle release) -> delayed right */
    {  3,  0,  9 },   /* left & right (right press) -> repressed right */
    {  0,  0, -1 },   /* timeout N/A */
  },
/* 8 repressed left */
  {
    { -2, -1,  0 },   /* nothing (middle release, left release) -> ground */
    { -2,  0,  4 },   /* left (middle release) -> pressed left */
    { -1,  0,  6 },   /* right (left release) -> released left */
    {  0,  0,  8 },   /* left & right -> repressed left (no change) */
    {  0,  0, -1 },   /* timeout N/A */
  },
/* 9 repressed right */
  {
    { -2, -3,  0 },   /* nothing (middle release, right release) -> ground */
    { -3,  0,  7 },   /* left (right release) -> released right */
    { -2,  0,  5 },   /* right (middle release) -> pressed right */
    {  0,  0,  9 },   /* left & right -> repressed right (no change) */
    {  0,  0, -1 },   /* timeout N/A */
  },
/* 10 pressed both */
  {
    { -1, -3,  0 },   /* nothing (left release, right release) -> ground */
    { -3,  0,  4 },   /* left (right release) -> pressed left */
    { -1,  0,  5 },   /* right (left release) -> pressed right */
    {  0,  0, 10 },   /* left & right -> pressed both (no change) */
    {  0,  0, -1 },   /* timeout N/A */
  },
};

MiddleButtonEmulator::Batch MiddleButtonEmulator::pointer(core::Point position, uint16_t buttons)
{
  Batch result;
  lastPosition = position; lastButtons = buttons;
  const unsigned event = (buttons & 1) | ((buttons & 4) >> 1);
  const auto* transition = stateTab[state][event];
  for (unsigned i = 0; i < 2; ++i)
    if (transition[i]) action(result, pending() && transition[i] > 0 ? original : position, buttons, transition[i]);
  if (!transition[0] && !transition[1] && !pending())
    result.events[result.count++] = {position, mask(buttons)};
  result.timerChanged = state != transition[2];
  state = transition[2];
  if (result.timerChanged && pending()) original = position;
  return result;
}
MiddleButtonEmulator::Batch MiddleButtonEmulator::expire()
{
  Batch result;
  if (!pending()) return result;
  const auto* transition = stateTab[state][4];
  for (unsigned i = 0; i < 2; ++i)
    if (transition[i]) action(result, original, lastButtons, transition[i]);
  if (original != lastPosition) result.events[result.count++] = {lastPosition, mask(lastButtons)};
  state = transition[2]; result.timerChanged = true;
  return result;
}
void MiddleButtonEmulator::action(Batch& batch, core::Point position, uint16_t buttons, int value)
{
  if (value < 0) emulated &= ~(1 << (-value - 1));
  else emulated |= 1 << (value - 1);
  batch.events[batch.count++] = {position, mask(buttons)};
}
}
