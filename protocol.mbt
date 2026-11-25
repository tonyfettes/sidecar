///|
const PROTOCOL_VERSION : Byte = b'\x01'

///|
const ABI_VERSION : UInt = 1U

///|
const HEADER_LEN : Int = 12

///|
const TOKEN_LEN : Int = 32

///|
const DEFAULT_MAX_FRAME_SIZE : UInt = 16U * 1024U * 1024U

///|
#derive(Eq)
priv enum Op {
  Hello
  Load
  Loaded
  Unload
  Unloaded
  Find
  Found
  Call
  Called
  Cancel
  Error
}

///|
fn Op::to_byte(self : Op) -> Byte {
  match self {
    Hello => b'\x01'
    Load => b'\x02'
    Loaded => b'\x03'
    Unload => b'\x04'
    Unloaded => b'\x05'
    Find => b'\x06'
    Found => b'\x07'
    Call => b'\x08'
    Called => b'\x09'
    Cancel => b'\x0A'
    Error => b'\xFF'
  }
}

///|
fn Op::from_byte(b : Byte) -> Op? {
  match b {
    b'\x01' => Some(Hello)
    b'\x02' => Some(Load)
    b'\x03' => Some(Loaded)
    b'\x04' => Some(Unload)
    b'\x05' => Some(Unloaded)
    b'\x06' => Some(Find)
    b'\x07' => Some(Found)
    b'\x08' => Some(Call)
    b'\x09' => Some(Called)
    b'\x0A' => Some(Cancel)
    b'\xFF' => Some(Error)
    _ => None
  }
}

///|
#non_exhaustive
#derive(Eq, @debug.Debug)
pub(all) suberror SidecarError {
  /// Sidecar TCP connection was closed or the server exited unexpectedly.
  ConnectionClosed
  /// Attempted to use a `Library` handle after `Library::unload()`.
  LibraryUnloaded
  /// No embedded `sidecar-server` binary is available for `platform`.
  UnsupportedPlatform(platform~ : String)
  /// Handshake one-time authentication token did not match.
  AuthFailed
  /// Peer reported an unsupported wire protocol version.
  UnsupportedProtocolVersion(expected~ : Byte, actual~ : Byte)
  /// Peer reported an unsupported C plugin ABI version.
  UnsupportedAbiVersion(expected~ : UInt, actual~ : UInt)
  /// Received frame length exceeded the negotiated limit.
  FrameTooLarge(length~ : UInt, max~ : UInt)
  /// Received an unknown frame opcode byte.
  UnknownOpcode(Byte)
  /// Frame structure was truncated, corrupted, or unexpected for the request.
  MalformedFrame
  /// Error returned by the sidecar server (0x0001..0x0FFF) or plugin (0x1000..0xFFFF).
  RemoteError(code~ : UInt16, message~ : String)
}

///|
/// Platform and capability metadata reported by the sidecar server during
/// handshake.
#derive(Eq, @debug.Debug)
pub struct ServerInfo {
  abi_version : UInt
  max_frame_size : UInt
  os : String
  arch : String
  lib_ext : String
}

///|
priv struct HelloPayload {
  token : Bytes
  info : ServerInfo
}

///|
priv struct FrameHeader {
  op : Op
  req_id : UInt
  length : UInt
}

///|
priv struct Frame {
  header : FrameHeader
  payload : Bytes
}

///|
fn write_u16le(buf : @buffer.Buffer, v : UInt16) -> Unit {
  let u = v.to_uint()
  buf.write_byte((u & 0xFFU).to_byte())
  buf.write_byte(((u >> 8) & 0xFFU).to_byte())
}

///|
fn write_u32le(buf : @buffer.Buffer, v : UInt) -> Unit {
  buf.write_byte((v & 0xFFU).to_byte())
  buf.write_byte(((v >> 8) & 0xFFU).to_byte())
  buf.write_byte(((v >> 16) & 0xFFU).to_byte())
  buf.write_byte(((v >> 24) & 0xFFU).to_byte())
}

///|
fn encode_frame(
  op : Op,
  req_id : UInt,
  payload : BytesView,
  flags? : UInt16 = 0,
) -> Bytes {
  let buf = @buffer.Buffer(capacity=HEADER_LEN + payload.length())
  buf.write_byte(PROTOCOL_VERSION)
  buf.write_byte(op.to_byte())
  write_u16le(buf, flags)
  write_u32le(buf, req_id)
  write_u32le(buf, payload.length().reinterpret_as_uint())
  buf.write_bytesview(payload)
  buf.to_bytes()
}

///|
fn encode_frame_with_u32_prefix(
  op : Op,
  req_id : UInt,
  prefix : UInt,
  rest : BytesView,
) -> Bytes {
  let payload_len = 4 + rest.length()
  let buf = @buffer.Buffer(capacity=HEADER_LEN + payload_len)
  buf.write_byte(PROTOCOL_VERSION)
  buf.write_byte(op.to_byte())
  write_u16le(buf, 0)
  write_u32le(buf, req_id)
  write_u32le(buf, payload_len.reinterpret_as_uint())
  write_u32le(buf, prefix)
  buf.write_bytesview(rest)
  buf.to_bytes()
}

///|
fn decode_header(raw : BytesView) -> FrameHeader raise SidecarError {
  match raw {
    [ver, op_byte, u16le(_), u32le(req_id), u32le(length)] => {
      if ver != PROTOCOL_VERSION {
        raise UnsupportedProtocolVersion(expected=PROTOCOL_VERSION, actual=ver)
      }
      let op = match Op::from_byte(op_byte) {
        Some(op) => op
        None => raise UnknownOpcode(op_byte)
      }
      { op, req_id, length }
    }
    _ => raise MalformedFrame
  }
}

///|
fn read_len_prefixed_utf8(
  data : BytesView,
) -> (String, BytesView) raise SidecarError {
  match data {
    [u16le(len), .. rest] => {
      let n = len.reinterpret_as_int()
      if rest.length() < n {
        raise MalformedFrame
      }
      (@utf8.decode_lossy(rest[:n]), rest[n:])
    }
    _ => raise MalformedFrame
  }
}

///|
fn decode_hello(payload : BytesView) -> HelloPayload raise SidecarError {
  if payload.length() < TOKEN_LEN {
    raise MalformedFrame
  }
  let token = payload[:TOKEN_LEN].to_owned()
  match payload[TOKEN_LEN:] {
    [u32le(abi_version), u32le(max_frame_size), .. rest] => {
      let (os, rest) = read_len_prefixed_utf8(rest)
      let (arch, rest) = read_len_prefixed_utf8(rest)
      let (lib_ext, _) = read_len_prefixed_utf8(rest)
      { token, info: { abi_version, max_frame_size, os, arch, lib_ext } }
    }
    _ => raise MalformedFrame
  }
}

///|
fn decode_error(payload : BytesView) -> SidecarError {
  match payload {
    [u16le(code), .. msg] =>
      RemoteError(code=code.to_uint16(), message=@utf8.decode_lossy(msg))
    _ => MalformedFrame
  }
}

///|
let token_counter : Ref[UInt64] = Ref(0UL)

///|
fn generate_token() -> (Bytes, String) {
  token_counter.val = token_counter.val + 1UL
  let seed_buf = @buffer.Buffer(capacity=32)
  let t = @async.now().reinterpret_as_uint64()
  let c = token_counter.val
  for i in 0..<4 {
    let v = t ^ (c * 0x9E3779B97F4A7C15UL) ^ (i.to_uint64() << 32)
    seed_buf.write_int64_le(v.reinterpret_as_int64())
  }
  let rng = @random.Rand::chacha8(seed=seed_buf.to_bytes())
  let raw_buf = @buffer.Buffer(capacity=TOKEN_LEN)
  let hex_chars = "0123456789abcdef"
  let hex_buf = StringBuilder(capacity=TOKEN_LEN * 2)
  for _ in 0..<4 {
    let w = rng.uint64()
    for shift in 0..<8 {
      let b = ((w >> (shift * 8)) & 0xFFUL).to_byte()
      raw_buf.write_byte(b)
      let hi = (b.to_int() >> 4) & 0xF
      let lo = b.to_int() & 0xF
      hex_buf.write_char(hex_chars[hi].to_int().unsafe_to_char())
      hex_buf.write_char(hex_chars[lo].to_int().unsafe_to_char())
    }
  }
  (raw_buf.to_bytes(), hex_buf.to_string())
}
