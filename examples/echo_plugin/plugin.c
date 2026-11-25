#include "sidecar.h"

#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
static void sleep_ms(uint32_t ms) { Sleep(ms); }
#else
#include <time.h>
static void sleep_ms(uint32_t ms) {
  struct timespec ts;
  ts.tv_sec = ms / 1000;
  ts.tv_nsec = (long)(ms % 1000) * 1000000L;
  nanosleep(&ts, NULL);
}
#endif

static atomic_int g_init_count = 0;

SIDECAR_EXPORT int32_t sidecar_lib_init(void) {
  atomic_fetch_add(&g_init_count, 1);
  return 0;
}

SIDECAR_EXPORT void sidecar_lib_deinit(void) {
  atomic_fetch_sub(&g_init_count, 1);
}

/* Echoes input bytes back using write_out. */
SIDECAR_EXPORT uint16_t echo(
    const sidecar_api_t *api,
    sidecar_ctx_t *ctx,
    const uint8_t *input,
    size_t input_len
) {
  if (input_len > 0 && api->write_out(ctx, input, input_len) != 0) {
    const char *msg = "failed to write output";
    api->write_err(ctx, (const uint8_t *)msg, strlen(msg));
    return 0x1001;
  }
  return 0;
}

/* Adds two little-endian u32 integers using reserve_out/commit_out (zero-copy). */
SIDECAR_EXPORT uint16_t add_u32(
    const sidecar_api_t *api,
    sidecar_ctx_t *ctx,
    const uint8_t *input,
    size_t input_len
) {
  if (input_len != 8) {
    const char *msg = "add_u32 expects exactly 8 bytes (two u32le integers)";
    api->write_err(ctx, (const uint8_t *)msg, strlen(msg));
    return 0x1002;
  }
  uint32_t a = 0, b = 0;
  memcpy(&a, input, 4);
  memcpy(&b, input + 4, 4);
  uint32_t sum = a + b;

  uint8_t *dst = api->reserve_out(ctx, 4);
  if (dst == NULL) {
    return 0x1003;
  }
  memcpy(dst, &sum, 4);
  if (api->commit_out(ctx, 4) != 0) {
    return 0x1004;
  }
  return 0;
}

/* Sleeps for `delay_ms` (first 4 bytes u32le) and echoes the remaining bytes.
 * Used to verify concurrent out-of-order CALL execution. */
SIDECAR_EXPORT uint16_t slow_echo(
    const sidecar_api_t *api,
    sidecar_ctx_t *ctx,
    const uint8_t *input,
    size_t input_len
) {
  if (input_len < 4) {
    const char *msg = "slow_echo expects at least 4 bytes (u32le delay_ms)";
    api->write_err(ctx, (const uint8_t *)msg, strlen(msg));
    return 0x1005;
  }
  uint32_t delay_ms = 0;
  memcpy(&delay_ms, input, 4);
  uint32_t elapsed = 0;
  while (elapsed < delay_ms) {
    if (api->is_cancelled(ctx)) {
      const char *msg = "slow_echo cancelled";
      api->write_err(ctx, (const uint8_t *)msg, strlen(msg));
      return 0x0008;
    }
    uint32_t step = (delay_ms - elapsed > 10) ? 10 : (delay_ms - elapsed);
    sleep_ms(step);
    elapsed += step;
  }
  if (input_len > 4) {
    if (api->write_out(ctx, input + 4, input_len - 4) != 0) {
      return 0x1006;
    }
  }
  return 0;
}

/* Always returns plugin error 0x1234 with a custom diagnostic message. */
SIDECAR_EXPORT uint16_t fail_always(
    const sidecar_api_t *api,
    sidecar_ctx_t *ctx,
    const uint8_t *input,
    size_t input_len
) {
  const char *prefix = "plugin failure: ";
  api->write_err(ctx, (const uint8_t *)prefix, strlen(prefix));
  if (input_len > 0) {
    api->write_err(ctx, input, input_len);
  }
  return 0x1234;
}
