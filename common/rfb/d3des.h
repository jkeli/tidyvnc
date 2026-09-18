/*
 * This is D3DES (V5.09) by Richard Outerbridge with the double and
 * triple-length support removed for use in VNC.
 *
 * These changes are:
 *  Copyright (C) 1999 AT&T Laboratories Cambridge.  All Rights Reserved.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 */

/* d3des.h -
 *
 *	Headers and defines for d3des.c
 *	Graven Imagery, 1992.
 *
 * Copyright (c) 1988,1989,1990,1991,1992 by Richard Outerbridge
 *	(GEnie : OUTER; CIS : [71755,204])
 */

#ifndef RFB_D3DES_H
#define RFB_D3DES_H

#ifdef __cplusplus
extern "C" {
#endif

#define EN0 0 /* encrypt */
#define DE1 1 /* decrypt */

/* One caller-owned key schedule. Initialize before transforming blocks.
 * Independent contexts can be used concurrently. An initialized context can
 * also be read concurrently, provided it is not being re-keyed or destroyed.
 * The key uses VNC's reversed per-byte bit order, as in the original D3DES.
 * This is a private RFB helper, not part of the native viewer's public C ABI.
 */
typedef struct {
  unsigned long keys[32];
} d3des_ctx;

void d3des_set_key(d3des_ctx* ctx, const unsigned char key[8], int mode);

/* Transform exactly eight bytes. Input and output may be the same buffer. */
void d3des_transform(const d3des_ctx* ctx, const unsigned char input[8],
                     unsigned char output[8]);

#ifdef __cplusplus
}
#endif

/* d3des.h V5.09 rwo 9208.04 15:06 Graven Imagery
 ********************************************************************/

#endif /* RFB_D3DES_H */
