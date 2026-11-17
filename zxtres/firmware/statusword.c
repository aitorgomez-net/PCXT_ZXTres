/* The 128-bit status word of PCXT on the ZXTRES+ and ZXTRES++, in place of
   DeMiSTify's firmware/statusword.c (32 or 64 bits): build_firmware.sh
   stages this file and overrides.mk compiles it instead.

   statusword and statusword_high are bits 0-31 and 32-63, under the names
   the rest of DeMiSTify uses; statusword_ext[0] and [1] are bits 64-95 and
   96-127. sendstatus() sends all sixteen bytes with user_io's command 1Eh:
   user_io keeps the first eight, zxtres/rtl/zxtres_status_ext.sv the rest.
   The menu reaches bits 64-127 through the characters 80h-BFh of the
   configuration string (configstring_getdigit() in overrides.c). */

#include <stdio.h>
#include "statusword.h"
#include "spi.h"
#include "user_io.h"
#include "config.h"

unsigned int statusword;          /* bits 0-31 */
unsigned int statusword_high;     /* bits 32-63 */
unsigned int statusword_ext[2];   /* bits 64-127 */

static unsigned int *status_part(unsigned int i)
{
	return(i == 0 ? &statusword : i == 1 ? &statusword_high : &statusword_ext[i - 2]);
}

void sendstatus()
{
	unsigned int i, w;

	SPI(0xff);
	EnableIO();
	SPI(UIO_SET_STATUS2);
	for(i = 0; i < 4; ++i)
	{
		w = *status_part(i);
		SPI(w);
		SPI(w >> 8);
		SPI(w >> 16);
		SPI(w >> 24);
	}
	DisableIO();
}

/* The field of mask's width at bit shift (a field is at most 8 bits wide,
   so it spans two words at most). */
unsigned int statusword_get(unsigned int shift, unsigned int mask)
{
	unsigned int i = shift >> 5, s = shift & 31;
	unsigned int v = *status_part(i) >> s;

	if(s && i < 3)
		v |= *status_part(i + 1) << (32 - s);
	return(v & mask);
}

void statusword_set(unsigned int shift, unsigned int mask, unsigned int v)
{
	unsigned int i = shift >> 5, s = shift & 31;
	unsigned int *w = status_part(i);

	*w = (*w & ~(mask << s)) | ((v & mask) << s);
	if(s && i < 3)
	{
		w = status_part(i + 1);
		*w = (*w & ~(mask >> (32 - s))) | ((v & mask) >> (32 - s));
	}
}

void statusword_cycle(unsigned int shift, unsigned int mask, unsigned int limit)
{
	unsigned int v = statusword_get(shift, mask) + 1;

	if(v >= limit)
		v = 0;
	statusword_set(shift, mask, v);
	sendstatus();
}
