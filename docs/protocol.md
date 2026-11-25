# Sidecar RPC Protocol v1 & C ABI Specification

## 1. Overview

`sidecar` provides a cross-platform dynamic-library RPC bridge between a MoonBit client (supporting `wasm` and `native` targets via `moonbitlang/async`) and a lightweight native server implemented in Zig.

Downstream library authors compile a small native shared library (`.dylib` / `.so` / `.dll`) exporting functions that conform to `include/sidecar.h`, and MoonBit code loads and calls those functions over a multiplexed binary RPC channel.

---

## 2. Transport & Handshake

### 2.1 Loopback TCP with One-Time Auth Token

To keep `stdin`/`stdout`/`stderr` completely free (preventing `printf` in loaded C libraries from corrupting the binary framing, and allowing inherited TTY file descriptors when desired), client and server communicate over **loopback TCP (`127.0.0.1`)**:

1. **Client binds** a TCP listener on `127.0.0.1:0` (OS assigns an ephemeral port `P`).
2. **Client generates** a cryptographically or pseudo-randomly generated 32-byte one-time authentication token `T` (hex-encoded as 64 lowercase ASCII characters).
3. **Client spawns** the sidecar executable with:
   - Command-line argument: `--port <P>`
   - Environment variable: `SIDECAR_TOKEN=<64-hex-chars>` (passing via env avoids exposing the token in process argument listings; `--token <hex>` is also accepted as a fallback for manual debugging).
4. **Server connects** to `127.0.0.1:<P>`, enables `TCP_NODELAY`, and immediately sends a `HELLO` frame (`req_id = 0`) containing the raw 32-byte token and server metadata.
5. **Client accepts** a single connection, immediately closes the listener socket, reads the first frame, verifies that it is a valid `HELLO` frame matching `T`, and enters the multiplexed RPC session. If token validation fails, the client closes the connection and terminates the sidecar process.

If the TCP connection drops (EOF or reset), the sidecar immediately initiates clean shutdown (`sidecar_lib_deinit` on loaded libraries) and exits to avoid orphan processes.

---

## 3. Binary Frame Format

Every message in both directions is a framed binary packet with a **12-byte little-endian header**:

```text
 0      1      2        4            8             12
+------+------+--------+------------+-------------+--------------------+
| ver  |  op  | flags  |   req_id   |   length    | payload (length B) |
+------+------+--------+------------+-------------+--------------------+
  u8     u8     u16le      u32le         u32le          [length]u8
```

| Field | Type | Description |
|---|---|---|
| `version` | `u8` | Protocol version. Must be `1`. |
| `op` | `u8` | Operation code (see §4). |
| `flags` | `u16le` | Reserved bitflags. Must be `0` in v1. |
| `req_id` | `u32le` | Request correlation ID. `0` for `HELLO`; non-zero client-assigned ID unique among all currently in-flight requests. Responses echo the same `req_id`. |
| `length` | `u32le` | Byte length of `payload`. Must not exceed `max_frame_size` (default `16 MiB` = `16,777,216` bytes). |
| `payload` | `[length]u8` | Operation-specific payload bytes. |

> **Alignment note**: For `CALL`, the payload begins with `func_id:u32le` (4 bytes). Because `12 + 4 = 16`, the `input` slice inside a contiguous frame buffer starts at a 16-byte aligned offset (`max_align_t`).

---

## 4. Operations

| Op | Code | Direction | `req_id` | Payload |
|---|---|---|---|---|
| `HELLO` | `0x01` | server → client | `0` | Handshake & platform metadata (see §4.1) |
| `LOAD` | `0x02` | client → server | non-zero | UTF-8 path to dynamic library |
| `LOADED` | `0x03` | server → client | echo | `lib_id:u32le` |
| `UNLOAD` | `0x04` | client → server | non-zero | `lib_id:u32le` |
| `UNLOADED` | `0x05` | server → client | echo | Empty |
| `FIND` | `0x06` | client → server | non-zero | `lib_id:u32le` + UTF-8 symbol name |
| `FOUND` | `0x07` | server → client | echo | `func_id:u32le` |
| `CALL` | `0x08` | client → server | non-zero | `func_id:u32le` + input bytes (may be empty) |
| `CALLED` | `0x09` | server → client | echo | Output bytes (may be empty) |
| `CANCEL` | `0x0A` | client → server | non-zero | `target_req_id:u32le` *(reserved in v1)* |
| `ERROR` | `0xFF` | server → client | echo | `code:u16le` + UTF-8 diagnostic message |

### 4.1 `HELLO` Payload Layout

All multi-byte integers are little-endian:

```text
token:          [32]u8   // Raw 32-byte auth token
abi_version:    u32le    // C plugin ABI version (1)
max_frame_size: u32le    // Maximum payload size accepted by server (default 16 MiB)
os_len:         u16le    // Byte length of os string
os:             [os_len]u8       // e.g. "macos", "linux", "windows"
arch_len:       u16le    // Byte length of arch string
arch:           [arch_len]u8     // e.g. "aarch64", "x86_64"
lib_ext_len:    u16le    // Byte length of shared library extension
lib_ext:        [lib_ext_len]u8  // e.g. "dylib", "so", "dll"
```

### 4.2 Concurrency & Multiplexing

- Multiple requests (especially `CALL`) may be in flight concurrently with distinct `req_id` values.
- Server dispatches `CALL` requests on worker threads so blocking calls (e.g., `poll`-style event waits) do not stall other concurrent `CALL`, `LOAD`, `FIND`, `UNLOAD`, or `CLOSE` operations.
- Responses may arrive out of order; the client correlates responses strictly by `req_id`.
- On `UNLOAD(lib_id)`:
  1. The library is marked unloading and all `func_id` handles belonging to it are immediately invalidated for new `FIND`/`CALL` requests.
  2. The server waits until all in-flight `CALL` invocations into that library complete.
  3. If the library exported `sidecar_lib_deinit`, it is invoked once.
  4. The shared library handle is closed (`dlclose` / `FreeLibrary`), and `UNLOADED` is sent.
- **Session Teardown (Transport Close / TCP EOF)**:
  There is no separate application-level `CLOSE` frame; closing the underlying TCP connection (normal `sidecar.close()` or client exit/crash) is the single teardown trigger:
  1. Client closes the TCP connection (sending TCP FIN) and waits for the sidecar process to exit (falling back to termination signal only on timeout).
  2. Server observes TCP EOF, stops reading new requests, sets its closing/cancellation flag, waits for in-flight worker calls to finish, invokes `sidecar_lib_deinit` and closes all remaining loaded libraries, and exits with status `0`.
  3. Process exit serves as the synchronization barrier guaranteeing that all library `deinit` hooks have completed before the client's task group returns.

### 4.3 `CANCEL` (Reserved in v1)

Opcode `0x0A` (`CANCEL`) is reserved for cooperative cancellation of an in-flight request (`target_req_id:u32le`). In v1:
- `sidecar_api_t` already exposes `is_cancelled(ctx)` so plugin authors can write forward-compatible cancellation checks (it returns `true` when the server is shutting down on EOF).
- Sending `CANCEL` in v1 returns `ERROR(UNSUPPORTED)`.

---

## 5. Error Codes (`ERROR.code: u16le`)

| Range | Owner |
|---|---|
| `0x0000` | Success (only used as C ABI return value, never sent in `ERROR` frame) |
| `0x0001` – `0x0FFF` | Sidecar framework errors |
| `0x1000` – `0xFFFF` | Recommended range for plugin-defined error codes |

Framework error codes:

| Code | Name | Meaning |
|---|---|---|
| `0x0001` | `INVALID_FRAME` | Unsupported protocol version, unknown opcode, or malformed payload |
| `0x0002` | `LIB_LOAD_FAILED` | Failed to open shared library or `sidecar_lib_init` returned non-zero |
| `0x0003` | `INVALID_LIB_ID` | Unknown or already unloaded `lib_id` |
| `0x0004` | `LIB_BUSY` | Library cannot be unloaded because it is busy |
| `0x0005` | `SYMBOL_NOT_FOUND` | Symbol not found in library |
| `0x0006` | `INVALID_FUNC_ID` | Unknown or invalidated `func_id` |
| `0x0007` | `FRAME_TOO_LARGE` | Payload or output exceeds `max_frame_size` or server ran out of memory |
| `0x0008` | `CANCELLED` | Request was cancelled |
| `0x0009` | `UNSUPPORTED` | Reserved / unimplemented operation in this server version |

---

## 6. Plugin C ABI (`include/sidecar.h`)

Shared libraries loaded via `LOAD` export callable entrypoints with signature:

```c
uint16_t my_func(
    const sidecar_api_t *api,
    sidecar_ctx_t *ctx,
    const uint8_t *input,
    size_t input_len
);
```

- **Memory ownership**:
  - `input` is read-only and valid for the duration of the call (16-byte aligned).
  - Output and error bytes are written through `api->write_out`, `api->reserve_out`/`api->commit_out`, or `api->write_err`. The underlying buffers are owned and reclaimed by the Zig sidecar after the call returns—**no `free` callback is required**, avoiding cross-DLL heap mismatches (especially on Windows).
  - Plugins manage any internal temporary allocations using their own stack/heap.
- **Return value**:
  - `0`: Success. Sidecar sends `CALLED` with the bytes written to `out`.
  - Non-zero `uint16_t`: Failure. Sidecar discards `out` and sends `ERROR` with `code = return_value` and UTF-8 diagnostic bytes written to `err`.
- **Optional library lifecycle hooks**:
  - `int32_t sidecar_lib_init(void)`: If exported, called once during `LOAD`. Returning non-zero aborts `LOAD` and unloads the library.
  - `void sidecar_lib_deinit(void)`: If exported, called once during `UNLOAD` or on transport close (TCP EOF) after all in-flight calls drain and before `dlclose`/`FreeLibrary`.
- **Thread safety**:
  - Because `CALL` requests run concurrently on worker threads, plugins that share mutable global state across calls must synchronize access internally.
