///|
/// A gzip-compressed native binary embedded internally for `sidecar-server`.
priv struct EmbeddedArtifact {
  filename : String
  sha256 : String
  gzip_bytes : Bytes
}

///|
fn EmbeddedArtifact::new(
  filename~ : String,
  sha256~ : String,
  gzip_bytes~ : Bytes,
) -> EmbeddedArtifact {
  { filename, sha256, gzip_bytes }
}

///|
let cached_host_platform : Ref[String?] = Ref(None)

///|
async fn host_platform() -> String {
  if cached_host_platform.val is Some(p) {
    return p
  }
  let os = if @async.platform is Linux {
    "linux"
  } else if @async.platform is MacOS {
    "macos"
  } else if @async.platform is Windows {
    "windows"
  } else {
    "unknown"
  }
  let arch = match @async.platform {
    Windows =>
      match @env.get_env_vars().get("PROCESSOR_ARCHITECTURE") {
        Some("ARM64") | Some("arm64") => "aarch64"
        _ => "x86_64"
      }
    _ => {
      let res = @process.run(
        "uname",
        ["-m"],
        stdout=Collect,
        accepted_exit_code=_ => true,
      )
      if res.exit_code != 0 {
        "unknown"
      } else {
        match res.stdout_text().trim().to_owned() {
          "arm64" | "aarch64" => "aarch64"
          "x86_64" | "amd64" => "x86_64"
          other => other
        }
      }
    }
  }
  let key = "\{os}-\{arch}"
  cached_host_platform.val = Some(key)
  key
}

///|
fn resolve_cache_root() -> String {
  let vars = @env.get_env_vars()
  if vars.get("SIDECAR_CACHE_DIR") is Some(dir) && !dir.is_empty() {
    return dir
  }
  match @async.platform {
    Windows => {
      if vars.get("LOCALAPPDATA") is Some(d) && !d.is_empty() {
        return "\{d}\\moonbit-sidecar"
      }
      if vars.get("TEMP") is Some(d) && !d.is_empty() {
        return "\{d}\\moonbit-sidecar"
      }
      if vars.get("TMP") is Some(d) && !d.is_empty() {
        return "\{d}\\moonbit-sidecar"
      }
      ".moonbit-sidecar"
    }
    _ => {
      if vars.get("XDG_CACHE_HOME") is Some(d) && !d.is_empty() {
        return "\{d}/moonbit-sidecar"
      }
      if vars.get("HOME") is Some(d) && !d.is_empty() {
        return "\{d}/.cache/moonbit-sidecar"
      }
      if vars.get("TMPDIR") is Some(d) && !d.is_empty() {
        return "\{d}/moonbit-sidecar"
      }
      "/tmp/moonbit-sidecar"
    }
  }
}

///|
fn join_path(a : String, b : String) -> String {
  let sep = if @async.platform is Windows { "\\" } else { "/" }
  if a.has_suffix("/") || a.has_suffix("\\") {
    "\{a}\{b}"
  } else {
    "\{a}\{sep}\{b}"
  }
}

///|
fn short_hash(sha256 : String) -> String {
  if sha256.length() > 16 {
    sha256[:16].to_owned()
  } else if sha256.is_empty() {
    "default"
  } else {
    sha256
  }
}

///|
fn rotr32(x : UInt, n : Int) -> UInt {
  (x >> n) | (x << (32 - n))
}

///|
fn sha256_hex(data : BytesView) -> String {
  let k : FixedArray[UInt] = [
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U,
    0x923f82a4U, 0xab1c5ed5U, 0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
    0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U, 0xe49b69c1U, 0xefbe4786U,
    0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
    0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U,
    0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
    0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U, 0xa2bfe8a1U, 0xa81a664bU,
    0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
    0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU,
    0x5b9cca4fU, 0x682e6ff3U, 0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
  ]
  let mut h0 = 0x6a09e667U
  let mut h1 = 0xbb67ae85U
  let mut h2 = 0x3c6ef372U
  let mut h3 = 0xa54ff53aU
  let mut h4 = 0x510e527fU
  let mut h5 = 0x9b05688cU
  let mut h6 = 0x1f83d9abU
  let mut h7 = 0x5be0cd19U

  let len = data.length()
  let bit_len = len.to_uint64() * 8UL
  let pad_len = {
    let rem = (len + 9) % 64
    if rem == 0 {
      len + 9
    } else {
      len + 9 + (64 - rem)
    }
  }
  let padded = FixedArray::make(pad_len, b'\x00')
  for i in 0..<len {
    padded[i] = data[i]
  }
  padded[len] = b'\x80'
  for i in 0..<8 {
    let shift = (7 - i) * 8
    padded[pad_len - 8 + i] = ((bit_len >> shift) & 0xFFUL).to_byte()
  }

  let w = FixedArray::make(64, 0U)
  let mut off = 0
  while off < pad_len {
    for i in 0..<16 {
      let j = off + i * 4
      w[i] = (padded[j].to_uint() << 24) |
        (padded[j + 1].to_uint() << 16) |
        (padded[j + 2].to_uint() << 8) |
        padded[j + 3].to_uint()
    }
    for i in 16..<64 {
      let s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3)
      let s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    }
    let mut a = h0
    let mut b = h1
    let mut c = h2
    let mut d = h3
    let mut e = h4
    let mut f = h5
    let mut g = h6
    let mut h = h7
    for i in 0..<64 {
      let s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
      let ch = (e & f) ^ (e.lnot() & g)
      let temp1 = h + s1 + ch + k[i] + w[i]
      let s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
      let maj = (a & b) ^ (a & c) ^ (b & c)
      let temp2 = s0 + maj
      h = g
      g = f
      f = e
      e = d + temp1
      d = c
      c = b
      b = a
      a = temp1 + temp2
    }
    h0 = h0 + a
    h1 = h1 + b
    h2 = h2 + c
    h3 = h3 + d
    h4 = h4 + e
    h5 = h5 + f
    h6 = h6 + g
    h7 = h7 + h
    off += 64
  }

  let hex_chars = "0123456789abcdef"
  let sb = StringBuilder(capacity=64)
  for word in [h0, h1, h2, h3, h4, h5, h6, h7] {
    for shift in [28, 24, 20, 16, 12, 8, 4, 0] {
      let nibble = ((word >> shift) & 0xFU).reinterpret_as_int()
      sb.write_char(hex_chars[nibble].to_int().unsafe_to_char())
    }
  }
  sb.to_string()
}

///|
async fn materialize_cached(
  name~ : String,
  filename~ : String,
  cache_key~ : String,
  bytes : BytesView,
  gzip~ : Bool,
  executable~ : Bool,
) -> String {
  let cache_root = resolve_cache_root()
  let target_dir = join_path(join_path(cache_root, name), short_hash(cache_key))
  let target_path = join_path(target_dir, filename)

  if @fs.exists(target_path) {
    return target_path
  }

  @fs.mkdir(target_dir, recursive=true, allow_existing=true)

  let raw : BytesView = if gzip { @gzip.decompress(bytes)[:] } else { bytes }
  let (_, suffix) = generate_token()
  let tmp_path = "\{target_path}.tmp.\{suffix[:12]}"
  let perm = if executable { 0o755 } else { 0o644 }

  {
    errdefer @fs.remove(tmp_path, allow_missing=true)
    @fs.write_binary(
      tmp_path,
      raw,
      create_mode=@fs.CreateOrTruncate,
      permission=perm,
    )
    if executable && !(@async.platform is Windows) {
      @fs.chmod(tmp_path, 0o755)
    }
    try @fs.rename(tmp_path, target_path, replace=true) catch {
      err =>
        if @fs.exists(target_path) {
          @fs.remove(tmp_path, allow_missing=true)
          return target_path
        } else {
          raise err
        }
    } noraise {
      _ => ()
    }
  }

  target_path
}

///|
async fn materialize_embedded_server() -> String {
  let key = host_platform()
  match embedded_servers.get(key) {
    Some(artifact) =>
      materialize_cached(
        name="sidecar-server",
        filename=artifact.filename,
        cache_key=artifact.sha256,
        artifact.gzip_bytes[:],
        gzip=true,
        executable=true,
      )
    None =>
      raise UnsupportedPlatform(
        "no embedded 'sidecar-server' binary for host platform '\{key}'",
      )
  }
}

///|
fn library_filename(name : String, lib_ext : String) -> String {
  let suffix = ".\{lib_ext}"
  if name.has_suffix(suffix) {
    name
  } else if lib_ext == "dll" {
    "\{name}.dll"
  } else {
    "lib\{name}.\{lib_ext}"
  }
}
