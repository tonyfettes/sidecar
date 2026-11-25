///|
fn example_plugin_path(hello : @sidecar.HelloInfo) -> String {
  match hello.os {
    "windows" => "server/zig-out/lib/echo_plugin.dll"
    "macos" => "server/zig-out/lib/libecho_plugin.dylib"
    _ => "server/zig-out/lib/libecho_plugin.so"
  }
}

///|
fn u32le_bytes(v : UInt) -> Bytes {
  let b = @buffer.Buffer(capacity=4)
  b.write_byte((v & 0xFFU).to_byte())
  b.write_byte(((v >> 8) & 0xFFU).to_byte())
  b.write_byte(((v >> 16) & 0xFFU).to_byte())
  b.write_byte(((v >> 24) & 0xFFU).to_byte())
  b.to_bytes()
}

///|
fn parse_u32le(b : Bytes) -> UInt {
  b[0].to_uint() |
  (b[1].to_uint() << 8) |
  (b[2].to_uint() << 16) |
  (b[3].to_uint() << 24)
}

///|
async test "sidecar echo, add_u32, error, unload, and EOF close" {
  @async.with_task_group(group => {
    let sidecar = @sidecar.spawn(group)
    defer sidecar.close()

    inspect(sidecar.hello().abi_version, content="1")
    let lib_path = example_plugin_path(sidecar.hello())
    let library = sidecar.load(lib_path)

    // 1. echo (write_out)
    let echo_fn = library.find("echo")
    let out = echo_fn.call(b"hello sidecar"[:])
    inspect(@utf8.decode_lossy(out[:]), content="hello sidecar")

    // Empty input / empty output
    let empty_out = echo_fn.call(b""[:])
    inspect(empty_out.length(), content="0")

    // 2. add_u32 (reserve_out + commit_out zero-copy)
    let add_fn = library.find("add_u32")
    let arg_buf = @buffer.Buffer(capacity=8)
    arg_buf.write_bytes(u32le_bytes(17U))
    arg_buf.write_bytes(u32le_bytes(25U))
    let sum_bytes = add_fn.call(arg_buf.to_bytes()[:])
    inspect(parse_u32le(sum_bytes), content="42")

    // 3. Plugin error forwarding (ERROR frame)
    let fail_fn = library.find("fail_always")
    let err_seen = try {
      let _ = fail_fn.call(b"boom"[:])
      "unexpected ok"
    } catch {
      @sidecar.RemoteError(code~, message~) => "\{code}:\{message}"
      other => "other: \{other}"
    }
    inspect(err_seen, content="4660:plugin failure: boom")

    // 4. Unload invalidates existing function handles
    library.unload()
    let after_unload = try {
      let _ = echo_fn.call(b"x"[:])
      "unexpected ok"
    } catch {
      @sidecar.RemoteError(code~, ..) => "code=\{code}"
      other => "other: \{other}"
    }
    inspect(after_unload, content="code=6")

    // 5. Closing the TCP transport triggers clean exit (code 0)
    sidecar.close()
    inspect(sidecar.wait(), content="0")
  })
}

///|
async test "sidecar concurrent out-of-order calls" {
  @async.with_task_group(group => {
    let sidecar = @sidecar.spawn(group)
    defer sidecar.close()

    let library = sidecar.load(example_plugin_path(sidecar.hello()))
    let slow_fn = library.find("slow_echo")
    let completion_order : Array[String] = []

    let slow_input = {
      let b = @buffer.Buffer(capacity=16)
      b.write_bytes(u32le_bytes(120U))
      b.write_bytes(b"slow")
      b.to_bytes()
    }
    let fast_input = {
      let b = @buffer.Buffer(capacity=16)
      b.write_bytes(u32le_bytes(10U))
      b.write_bytes(b"fast")
      b.to_bytes()
    }

    @async.with_task_group(inner => {
      inner.spawn_bg(() => {
        let res = slow_fn.call(slow_input[:])
        completion_order.push(@utf8.decode_lossy(res[:]))
      })
      inner.spawn_bg(() => {
        let res = slow_fn.call(fast_input[:])
        completion_order.push(@utf8.decode_lossy(res[:]))
      })
    })

    // Fast call finishes before slow call, proving concurrent worker dispatch & req_id multiplexing
    debug_inspect(
      completion_order,
      content=(
        #|["fast", "slow"]
      ),
    )
  })
}

///|
async test "sidecar standalone open without TaskGroup and timeout cancellation" {
  let sidecar = @sidecar.open()
  defer sidecar.close()

  let library = sidecar.load(example_plugin_path(sidecar.hello()))
  let echo_fn = library.find("echo")
  let slow_fn = library.find("slow_echo")

  let res = echo_fn.call(b"standalone"[:])
  inspect(@utf8.decode_lossy(res[:]), content="standalone")

  // Cancelling a slow call via timeout must NOT corrupt the TCP stream for later calls
  let slow_input = {
    let b = @buffer.Buffer(capacity=16)
    b.write_bytes(u32le_bytes(150U))
    b.write_bytes(b"late")
    b.to_bytes()
  }
  let timed_out = @async.with_timeout_opt(20, () => slow_fn.call(slow_input[:]))
  inspect(timed_out is None, content="true")

  // Subsequent call on the same connection still works cleanly
  let res2 = echo_fn.call(b"after-timeout"[:])
  inspect(@utf8.decode_lossy(res2[:]), content="after-timeout")

  sidecar.close()
  inspect(sidecar.wait(), content="0")
}
