///|
priv enum WaitSignal {
  Frame(Frame)
  Failed(Error)
  TakeLeader
}

///|
priv enum ChildHandle {
  Managed(@process.Process)
  Orphan(@process.OrphanProcess)
}

///|
struct Sidecar {
  info : ServerInfo
  conn : @socket.Tcp
  child : ChildHandle
  write_mutex : @async.Mutex
  pending : Map[UInt, @async.Queue[WaitSignal]]
  mut next_req_id : UInt
  mut has_reader : Bool
  mut closed : Bool
  mut orphan_exit : Int?
}

///|
struct Library {
  sidecar : Sidecar
  id : UInt
  mut unloaded : Bool
}

///|
struct Function {
  sidecar : Sidecar
  id : UInt
}

///|
/// Return platform and capability metadata reported by the sidecar server.
pub fn Sidecar::info(self : Sidecar) -> ServerInfo {
  self.info
}

///|
/// Return the OS process ID of the sidecar server.
pub fn Sidecar::pid(self : Sidecar) -> Int {
  match self.child {
    Managed(proc) => proc.pid
    Orphan(proc) => proc.pid
  }
}

///|
async fn resolve_executable() -> String {
  match @env.get_env_vars().get("SIDECAR_SERVER") {
    Some(p) if !p.is_empty() => p
    _ => materialize_embedded_server()
  }
}

///|
fn build_env_map(
  extra_env : Map[String, String]?,
  token_hex : String,
) -> Map[String, String] {
  let env_map : Map[String, String] = Map([])
  if extra_env is Some(m) {
    for k, v in m {
      env_map[k] = v
    }
  }
  env_map["SIDECAR_TOKEN"] = token_hex
  env_map
}

///|
async fn accept_handshake(
  listener : @socket.TcpServer,
  expected_token : Bytes,
  startup_timeout_ms : Int,
) -> (@socket.Tcp, ServerInfo) {
  @async.with_timeout(startup_timeout_ms, () => {
    let (conn, _) = listener.accept()
    errdefer conn.close()
    let raw_hdr = conn.read_exactly(HEADER_LEN)
    let hdr = decode_header(raw_hdr[:])
    if hdr.op != Hello || hdr.req_id != 0U {
      raise MalformedFrame
    }
    if hdr.length > DEFAULT_MAX_FRAME_SIZE {
      raise FrameTooLarge(length=hdr.length, max=DEFAULT_MAX_FRAME_SIZE)
    }
    let payload = if hdr.length > 0U {
      conn.read_exactly(hdr.length.reinterpret_as_int())
    } else {
      b""
    }
    let hello = decode_hello(payload[:])
    if hello.token != expected_token {
      raise AuthFailed
    }
    if hello.info.abi_version != ABI_VERSION {
      raise UnsupportedAbiVersion(
        expected=ABI_VERSION,
        actual=hello.info.abi_version,
      )
    }
    (conn, hello.info)
  })
}

///|
/// Spawn a Zig sidecar server managed by `group`, establish a
/// token-authenticated loopback TCP connection, and verify the `HELLO`
/// handshake.
///
/// Closing the TCP connection (via `defer sidecar.close()`, or automatically
/// when `group` exits) triggers graceful server shutdown: the sidecar observes
/// TCP EOF, drains active calls, invokes `sidecar_lib_deinit` on all loaded
/// libraries, and exits with status 0. The task group waits up to
/// `shutdown_timeout_ms` for clean exit before falling back to a termination
/// signal.
pub async fn spawn(
  group : @async.TaskGroup,
  extra_env? : Map[String, String],
  startup_timeout_ms? : Int = 5000,
  shutdown_timeout_ms? : Int = 2000,
) -> Sidecar {
  let exe = resolve_executable()
  let (expected_token, token_hex) = generate_token()

  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = listener.addr.port
  let env_map = build_env_map(extra_env, token_hex)

  let close_on_cancel : Ref[(() -> Unit)?] = Ref(None)
  let fallback_cancel = @process.graceful_cancel(timeout=1000)
  let cancel_handler = @process.CancellationHandler(pid => {
    if close_on_cancel.val is Some(close_fn) {
      close_fn()
    }
    @async.sleep(shutdown_timeout_ms)
    (fallback_cancel.0)(pid)
  })

  let child = @process.spawn(
    group,
    exe,
    ["--port", port.to_string()],
    extra_env=env_map,
    inherit_env=true,
    cancel_handler~,
    no_wait=true,
  )

  let (conn, info) = {
    defer listener.close()
    errdefer child.cancel()
    accept_handshake(listener, expected_token, startup_timeout_ms)
  }

  let sidecar : Sidecar = {
    info,
    conn,
    child: Managed(child),
    write_mutex: @async.Mutex(),
    pending: Map([]),
    next_req_id: 1U,
    has_reader: false,
    closed: false,
    orphan_exit: None,
  }
  close_on_cancel.val = Some(() => sidecar.close())
  sidecar
}

///|
/// Open a standalone Zig sidecar server not tied to a `@async.TaskGroup`.
///
/// The caller is responsible for calling `sidecar.close()` and `sidecar.wait()`
/// to cleanly shut down and reap the child process.
pub async fn open(
  extra_env? : Map[String, String],
  startup_timeout_ms? : Int = 5000,
) -> Sidecar {
  let exe = resolve_executable()
  let (expected_token, token_hex) = generate_token()

  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = listener.addr.port
  let env_map = build_env_map(extra_env, token_hex)

  let proc = {
    errdefer listener.close()
    @process.spawn_orphan(
      exe,
      ["--port", port.to_string()],
      extra_env=env_map,
      inherit_env=true,
    )
  }

  let (conn, info) = {
    defer listener.close()
    errdefer @async.protect_from_cancel(() => {
      let _ = @async.with_timeout_opt(2000, () => proc.wait()) catch {
        _ => None
      }
      proc.close()
    })
    accept_handshake(listener, expected_token, startup_timeout_ms)
  }

  {
    info,
    conn,
    child: Orphan(proc),
    write_mutex: @async.Mutex(),
    pending: Map([]),
    next_req_id: 1U,
    has_reader: false,
    closed: false,
    orphan_exit: None,
  }
}

///|
async fn Sidecar::read_one_frame(self : Sidecar) -> Frame {
  let raw_hdr = self.conn.read_exactly(HEADER_LEN)
  let hdr = decode_header(raw_hdr[:])
  if hdr.length > self.info.max_frame_size {
    raise FrameTooLarge(length=hdr.length, max=self.info.max_frame_size)
  }
  let payload = if hdr.length > 0U {
    @async.protect_from_cancel(() => {
      self.conn.read_exactly(hdr.length.reinterpret_as_int())
    })
  } else {
    b""
  }
  { header: hdr, payload }
}

///|
fn Sidecar::hand_off_reader(self : Sidecar) -> Unit {
  if self.has_reader || self.closed {
    return
  }
  for _, q in self.pending {
    let _ = q.try_put(TakeLeader) catch { _ => false }
    return
  }
}

///|
fn Sidecar::fail_all_pending(self : Sidecar, err : Error) -> Unit {
  self.closed = true
  let queues : Array[@async.Queue[WaitSignal]] = []
  for _, q in self.pending {
    queues.push(q)
  }
  self.pending.clear()
  for q in queues {
    let _ = q.try_put(Failed(err)) catch { _ => false }
  }
}

///|
fn Sidecar::alloc_req_id(self : Sidecar) -> UInt {
  while true {
    let id = self.next_req_id
    self.next_req_id = self.next_req_id + 1U
    if self.next_req_id == 0U {
      self.next_req_id = 1U
    }
    if !self.pending.contains(id) {
      return id
    }
  }
  1U
}

///|
fn unwrap_frame(frame : Frame) -> Frame raise SidecarError {
  if frame.header.op == Error {
    raise decode_error(frame.payload[:])
  }
  frame
}

///|
#warnings("-fragile_catch_all")
async fn Sidecar::send_and_wait(
  self : Sidecar,
  req_id : UInt,
  wire : Bytes,
) -> Frame {
  let q : @async.Queue[WaitSignal] = @async.Queue(kind=@aqueue.Unbounded)
  self.pending[req_id] = q
  defer self.pending.remove(req_id)

  {
    self.write_mutex.acquire()
    defer self.write_mutex.release()
    self.conn.write(wire[:])
  }

  // Leader-Follower demultiplexing: no background coroutine is required.
  // One waiting caller acts as reader leader at a time, routing responses by
  // `req_id` and handing off leadership before returning or on cancellation.
  for ;; {
    if q.try_get() is Some(sig) {
      match sig {
        Frame(frame) => return unwrap_frame(frame)
        Failed(err) => raise err
        TakeLeader => ()
      }
    }
    if !self.has_reader {
      self.has_reader = true
      defer {
        self.has_reader = false
        self.hand_off_reader()
      }
      for ;; {
        if q.try_get() is Some(sig) {
          match sig {
            Frame(frame) => return unwrap_frame(frame)
            Failed(err) => raise err
            TakeLeader => ()
          }
        }
        let frame = self.read_one_frame() catch {
          err => {
            if @async.is_being_cancelled() {
              raise err
            }
            self.fail_all_pending(err)
            raise err
          }
        }
        if frame.header.req_id == req_id {
          self.pending.remove(req_id)
          return unwrap_frame(frame)
        }
        if self.pending.get(frame.header.req_id) is Some(other_q) {
          self.pending.remove(frame.header.req_id)
          let _ = other_q.try_put(Frame(frame))
        }
      }
    } else {
      match q.get() {
        Frame(frame) => return unwrap_frame(frame)
        Failed(err) => raise err
        TakeLeader => continue
      }
    }
  }
}

///|
async fn Sidecar::request(
  self : Sidecar,
  op : Op,
  payload : BytesView,
) -> Frame {
  if self.closed {
    raise ConnectionClosed
  }
  let req_id = self.alloc_req_id()
  let wire = encode_frame(op, req_id, payload)
  self.send_and_wait(req_id, wire)
}

///|
async fn Sidecar::request_with_u32_prefix(
  self : Sidecar,
  op : Op,
  prefix : UInt,
  rest : BytesView,
) -> Frame {
  if self.closed {
    raise ConnectionClosed
  }
  let req_id = self.alloc_req_id()
  let wire = encode_frame_with_u32_prefix(op, req_id, prefix, rest)
  self.send_and_wait(req_id, wire)
}

///|
/// Load a shared library at `library_path` into the sidecar process.
pub async fn Sidecar::load_path(
  self : Sidecar,
  library_path : String,
) -> Library {
  let path_bytes = @utf8.encode(library_path)
  let resp = self.request(Load, path_bytes[:])
  guard resp.header.op == Loaded && resp.payload[:] is [u32le(id)] else {
    raise MalformedFrame
  }
  { sidecar: self, id, unloaded: false }
}

///|
/// Load a shared library from raw bytes (or gzip-compressed bytes when
/// `gzip=true`). The bytes are content-addressed by SHA-256 and cached on disk
/// using the server's native shared-library extension (`dylib` / `so` / `dll`).
pub async fn Sidecar::load_bytes(
  self : Sidecar,
  bytes : BytesView,
  gzip? : Bool = false,
) -> Library {
  let hash = sha256_hex(bytes)
  let cache_key = if gzip { "gz-\{hash}" } else { hash }
  let filename = "\{short_hash(cache_key)}.\{self.info.lib_ext}"
  let path = materialize_cached(
    name="libs",
    filename~,
    cache_key~,
    bytes,
    gzip~,
    executable=false,
  )
  self.load_path(path)
}

///|
/// Synchronously close the TCP transport, signaling EOF to the sidecar server.
/// Safe to use with `defer sidecar.close()`. Upon observing EOF, the sidecar
/// drains active calls, invokes `sidecar_lib_deinit` on all loaded libraries,
/// and exits cleanly.
pub fn Sidecar::close(self : Sidecar) -> Unit {
  if !self.closed {
    self.fail_all_pending(ConnectionClosed)
    self.conn.close()
  }
}

///|
/// Wait for the sidecar child process to exit and return its exit code.
/// Idempotent for both `spawn` and `open` handles.
pub async fn Sidecar::wait(self : Sidecar) -> Int {
  match self.child {
    Managed(proc) => proc.wait()
    Orphan(proc) =>
      match self.orphan_exit {
        Some(code) => code
        None => {
          let code = proc.wait()
          proc.close()
          self.orphan_exit = Some(code)
          code
        }
      }
  }
}

///|
/// Resolve an exported symbol matching `sidecar_fn_t` from this library.
pub async fn Library::find(self : Library, symbol : String) -> Function {
  if self.unloaded {
    raise LibraryUnloaded
  }
  let sym_bytes = @utf8.encode(symbol)
  let resp = self.sidecar.request_with_u32_prefix(Find, self.id, sym_bytes[:])
  guard resp.header.op == Found && resp.payload[:] is [u32le(id)] else {
    raise MalformedFrame
  }
  { sidecar: self.sidecar, id }
}

///|
/// Unload this library from the sidecar process, waiting for active calls into
/// this library to drain and invoking `sidecar_lib_deinit` if present.
pub async fn Library::unload(self : Library) -> Unit {
  if self.unloaded {
    return
  }
  let buf = @buffer.Buffer(capacity=4)
  write_u32le(buf, self.id)
  let resp = self.sidecar.request(Unload, buf.to_bytes()[:])
  if resp.header.op != Unloaded {
    raise MalformedFrame
  }
  self.unloaded = true
}

///|
/// Invoke this resolved plugin function with `input` bytes and return the
/// output bytes produced by the plugin.
pub async fn Function::call(self : Function, input : BytesView) -> Bytes {
  let resp = self.sidecar.request_with_u32_prefix(Call, self.id, input)
  if resp.header.op != Called {
    raise MalformedFrame
  }
  resp.payload
}
