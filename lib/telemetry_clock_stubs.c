#include <time.h>
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/fail.h>

CAMLprim value asko_monotonic_seconds(value unit) {
  (void)unit;
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    caml_failwith("monotonic clock unavailable");
  return caml_copy_double((double)now.tv_sec + (double)now.tv_nsec / 1e9);
}
