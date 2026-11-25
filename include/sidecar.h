#ifndef SIDECAR_H
#define SIDECAR_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SIDECAR_ABI_VERSION 1u

#if defined(_WIN32) || defined(__CYGWIN__)
#define SIDECAR_EXPORT __declspec(dllexport)
#elif defined(__GNUC__) || defined(__clang__)
#define SIDECAR_EXPORT __attribute__((visibility("default")))
#else
#define SIDECAR_EXPORT
#endif

/* Opaque per-call context owned by the sidecar server. */
typedef struct sidecar_ctx sidecar_ctx_t;

/*
 * Host API table passed to every plugin function call.
 *
 * Output and error buffers are owned by the sidecar server and reclaimed
 * automatically after the plugin function returns. Plugins do not need to
 * free buffers obtained from this table.
 */
typedef struct sidecar_api {
  /* Equals SIDECAR_ABI_VERSION (1). */
  uint32_t abi_version;

  /*
   * Append `len` bytes from `data` to the call's output buffer.
   * Returns 0 on success, non-zero on error (e.g., OOM or max_frame_size exceeded).
   */
  int (*write_out)(sidecar_ctx_t *ctx, const uint8_t *data, size_t len);

  /*
   * Zero-copy output API (pair with `commit_out`):
   * Reserve at least `cap` contiguous writable bytes at the end of the output buffer.
   * Returns NULL on error (OOM or max_frame_size exceeded).
   * The returned pointer is invalidated by any subsequent `write_out`,
   * `reserve_out`, or `commit_out` call.
   */
  uint8_t *(*reserve_out)(sidecar_ctx_t *ctx, size_t cap);

  /*
   * Commit `written_len` bytes previously written into the pointer returned by
   * `reserve_out`. `written_len` must be <= the reserved `cap`.
   * Returns 0 on success, non-zero on invalid length.
   */
  int (*commit_out)(sidecar_ctx_t *ctx, size_t written_len);

  /*
   * Append UTF-8 diagnostic bytes to the call's error message buffer.
   * Used when the plugin function returns a non-zero error code.
   * Returns 0 on success, non-zero on error.
   */
  int (*write_err)(sidecar_ctx_t *ctx, const uint8_t *data, size_t len);

  /*
   * Cooperative cancellation check.
   * Returns true if the call was cancelled or the sidecar server is shutting down.
   */
  bool (*is_cancelled)(sidecar_ctx_t *ctx);
} sidecar_api_t;

/*
 * Unified C ABI for plugin functions resolved via FIND and invoked via CALL.
 *
 * - `input` is valid for the duration of the call and is 16-byte aligned when
 *   `input_len > 0`.
 * - Return 0 on success (server sends CALLED with the output buffer).
 * - Return non-zero uint16_t on failure (server discards output and sends ERROR
 *   with `code = return_value` and UTF-8 message from the error buffer).
 *   Plugin-specific error codes should use 0x1000..0xFFFF.
 */
typedef uint16_t (*sidecar_fn_t)(
    const sidecar_api_t *api,
    sidecar_ctx_t *ctx,
    const uint8_t *input,
    size_t input_len
);

/*
 * Optional library-level lifecycle hooks.
 *
 * If exported by a shared library:
 * - `sidecar_lib_init` is called once during LOAD; returning non-zero fails LOAD.
 * - `sidecar_lib_deinit` is called once during UNLOAD or when the sidecar
 *   connection closes, after all in-flight calls into the library have finished.
 */
typedef int32_t (*sidecar_lib_init_fn_t)(void);
typedef void (*sidecar_lib_deinit_fn_t)(void);

#ifdef __cplusplus
}
#endif

#endif /* SIDECAR_H */
