/**
 * This file has no copyright assigned and is placed in the Public Domain.
 * This file is part of the mingw-w64 runtime package.
 * No warranty is given; refer to the file DISCLAIMER.PD within this package.
 */

#if defined(__aarch64__)
#include <math.h>
#endif

long double acosl (long double x);

long double acosl (long double x)
{
  long double res = 0.0L;

  /* acosl = atanl (sqrtl(1 - x^2) / x) */
#if defined(__x86_64__)
  asm volatile (
	"fld	%%st\n\t"
	"fmul	%%st(0)\n\t"		/* x^2 */
	"fld1\n\t"
	"fsubp\n\t"			/* 1 - x^2 */
	"fsqrt\n\t"			/* sqrtl (1 - x^2) */
	"fxch	%%st(1)\n\t"
	"fpatan"
	: "=t" (res) : "0" (x) : "st(1)");
#elif defined(__aarch64__)
  // TODO
  res = atanl (sqrtl(1 - x*x) / x);
#endif
  return res;
}
