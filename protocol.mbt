///|
pub const PROTOCOL_VERSION : Byte = b'\x01'

///|
pub const ABI_VERSION : UInt = 1U

///|
pub const HEADER_LEN : Int = 12

///|
pub const TOKEN_LEN : Int = 32

///|
pub const DEFAULT_MAX_FRAME_SIZE : UInt = 16U * 1024U * 1024U

///|
#derive(Eq, @debug.Debug)
pub(all) enum Op {
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
fn Op::name(self : Op) -> String {
  match self {
    Hello => "HELLO"
    Load => "LOAD"
    Loaded => "LOADED"
    Unload => "UNLOAD"
    Unloaded => "UNLOADED"
    Find => "FIND"
    Found => "FOUND"
    Call => "CALL"
    Called => "CALLED"
    Cancel => "CANCEL"
    Error => "ERROR"
  }
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
#derive(Eq, @debug.Debug)
pub(all) suberror SidecarError {
  ProtocolError(String)
  HandshakeFailed(String)
  ConnectionClosed
  UnsupportedPlatform(String)
  RemoteError(code~ : UInt16, message~ : String)
}

///|
#derive(Eq, @debug.Debug)
pub struct HelloInfo {
  token : Bytes
  abi_version : UInt
  max_frame_size : UInt
  os : String
  arch : String
  lib_ext : String
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
fn read_u16le(data : BytesView, offset : Int) -> UInt16 {
  let b0 = data[offset].to_uint()
  let b1 = data[offset + 1].to_uint()
  (b0 | (b1 << 8)).to_uint16()
}

///|
fn read_u32le(data : BytesView, offset : Int) -> UInt {
  let b0 = data[offset].to_uint()
  let b1 = data[offset + 1].to_uint()
  let b2 = data[offset + 2].to_uint()
  let b3 = data[offset + 3].to_uint()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
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
  if raw.length() != HEADER_LEN {
    raise ProtocolError("header length mismatch")
  }
  if raw[0] != PROTOCOL_VERSION {
    raise ProtocolError("unsupported protocol version: \{raw[0]}")
  }
  let op = match Op::from_byte(raw[1]) {
    Some(op) => op
    None => raise ProtocolError("unknown opcode: \{raw[1]}")
  }
  let _ = read_u16le(raw, 2)
  let req_id = read_u32le(raw, 4)
  let length = read_u32le(raw, 8)
  { op, req_id, length }
}

///|
fn decode_hello(payload : BytesView) -> HelloInfo raise SidecarError {
  // token(32) + abi_version(4) + max_frame_size(4) + 3 * len(2) = 46 min bytes
  if payload.length() < TOKEN_LEN + 14 {
    raise HandshakeFailed("HELLO payload too short")
  }
  let token = payload[0:TOKEN_LEN].to_owned()
  let abi_version = read_u32le(payload, TOKEN_LEN)
  let max_frame_size = read_u32le(payload, TOKEN_LEN + 4)
  let mut pos = TOKEN_LEN + 8

  fn read_str(p : BytesView, off : Int) -> (String, Int) raise SidecarError {
    if off + 2 > p.length() {
      raise HandshakeFailed("truncated HELLO string length")
    }
    let len = read_u16le(p, off).to_int()
    let start = off + 2
    if start + len > p.length() {
      raise HandshakeFailed("truncated HELLO string bytes")
    }
    let s = @utf8.decode_lossy(p[start:start + len])
    (s, start + len)
  }

  let (os, next1) = read_str(payload, pos)
  pos = next1
  let (arch, next2) = read_str(payload, pos)
  pos = next2
  let (lib_ext, _) = read_str(payload, pos)

  { token, abi_version, max_frame_size, os, arch, lib_ext }
}

///|
fn decode_error(payload : BytesView) -> SidecarError {
  if payload.length() < 2 {
    ProtocolError("malformed ERROR frame")
  } else {
    let code = read_u16le(payload, 0)
    let message = @utf8.decode_lossy(payload[2:])
    RemoteError(code~, message~)
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
