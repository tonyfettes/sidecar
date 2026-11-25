///|
/// A gzip-compressed native binary (executable or shared library) embedded in a
/// MoonBit package and materialized on demand into a content-addressed cache.
struct EmbeddedArtifact {
  filename : String
  sha256 : String
  gzip_bytes : Bytes
}

///|
pub fn EmbeddedArtifact::new(
  filename~ : String,
  sha256~ : String,
  gzip_bytes~ : Bytes,
) -> EmbeddedArtifact {
  { filename, sha256, gzip_bytes }
}

///|
let cached_host_platform : Ref[String?] = Ref(None)

///|
/// Detect and cache the current host `<os>-<arch>` platform key
/// (e.g. `"macos-aarch64"`, `"macos-x86_64"`, `"linux-x86_64"`,
/// `"linux-aarch64"`, `"windows-x86_64"`, `"windows-aarch64"`).
pub async fn host_platform() -> String {
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
/// Decompress `self` into a content-addressed cache path
/// (`<cache_root>/<name>/<sha256[:16]>/<filename>`) using atomic temp-file +
/// rename, and return its path.
///
/// Subsequent calls for the same `(name, sha256, filename)` reuse the cached
/// file directly without decompressing again.
pub async fn EmbeddedArtifact::materialize(
  self : EmbeddedArtifact,
  name~ : String,
  executable? : Bool = false,
) -> String {
  let cache_root = resolve_cache_root()
  let target_dir = join_path(
    join_path(cache_root, name),
    short_hash(self.sha256),
  )
  let target_path = join_path(target_dir, self.filename)

  if @fs.exists(target_path) {
    return target_path
  }

  @fs.mkdir(target_dir, recursive=true, allow_existing=true)

  let raw = @gzip.decompress(self.gzip_bytes[:])
  let (_, suffix) = generate_token()
  let tmp_path = "\{target_path}.tmp.\{suffix[:12]}"
  let perm = if executable { 0o755 } else { 0o644 }

  {
    errdefer @fs.remove(tmp_path, allow_missing=true)
    @fs.write_binary(
      tmp_path,
      raw[:],
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
async fn materialize_platform(
  name~ : String,
  artifacts : Map[String, EmbeddedArtifact],
  executable? : Bool = false,
) -> String {
  let key = host_platform()
  match artifacts.get(key) {
    Some(artifact) => artifact.materialize(name~, executable~)
    None =>
      raise UnsupportedPlatform(
        "no embedded '\{name}' artifact for host platform '\{key}'",
      )
  }
}
