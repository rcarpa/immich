//! immich-sync fork: where the offline mirror stores a remote file. The one implementation of the naming, called from
//! Dart, Swift and Kotlin, which read and write the same files: names that disagreed would make every read miss
//! silently.
//!
//! A name is the decoded path after the last `api` segment, the `size` query value, and a token over the rest of the
//! query, so an edit (a new thumbhash in `c`) gives a new name while the LAN and external addresses of one server give
//! the same one. Decoding follows Dart's `Uri`: path segments are percent-decoded and keep `+`, query keys and values
//! also read `+` as a space, a repeated key takes its last value, and a pair with an empty key is dropped.

/// The file name for a remote URL, or `None` for a URL with a malformed escape.
pub fn file_name(url: &str) -> Option<String> {
    let url = url.split('#').next().unwrap_or_default();
    let (path, query) = match url.split_once('?') {
        Some((path, query)) => (path, Some(query)),
        None => (url, None),
    };
    // Scheme and authority are the server's address, like everything up to the API root.
    let path = match path.split_once("://") {
        Some((_, rest)) => rest.find('/').map_or("", |slash| &rest[slash..]),
        None => path,
    };

    let mut segments = Vec::new();
    for raw in path.split('/').filter(|segment| !segment.is_empty()) {
        segments.push(decode(raw, false)?);
    }
    if let Some(root) = segments.iter().rposition(|segment| segment == "api") {
        segments.drain(..=root);
    }

    let mut size = None;
    let mut params: Vec<(String, String)> = Vec::new();
    for pair in query
        .unwrap_or_default()
        .split('&')
        .filter(|pair| !pair.is_empty())
    {
        let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
        if key.is_empty() {
            continue;
        }
        let (key, value) = (decode(key, true)?, decode(value, true)?);
        if key == "size" {
            size = Some(value);
        } else if let Some(existing) = params.iter_mut().find(|(known, _)| *known == key) {
            existing.1 = value;
        } else {
            params.push((key, value));
        }
    }
    // Byte order, which is what `String`'s `Ord` is.
    let mut joined: Vec<String> = params
        .into_iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect();
    joined.sort();

    let mut name = segments
        .iter()
        .map(|segment| sanitize(segment))
        .collect::<Vec<_>>()
        .join("_");
    if let Some(size) = size {
        name.push('_');
        name.push_str(&sanitize(&size));
    }
    name.push_str(&format!("_{:08x}", fnv1a32(joined.join("&").as_bytes())));

    let playable = segments.iter().any(|segment| segment == "video")
        || segments.last().is_some_and(|s| s == "original");
    if playable {
        name.push_str(".mp4");
    }
    Some(name)
}

/// The directory a name is stored in, out of 256, so names sharing a prefix spread out.
pub fn bucket(name: &str) -> u8 {
    (fnv1a32(name.as_bytes()) & 0xFF) as u8
}

/// The token a name ends in: the hash of its query, which tells versions of one file apart.
pub fn token(name: &str) -> Option<u32> {
    let stem = name.strip_suffix(".mp4").unwrap_or(name);
    let (_, hex) = stem.rsplit_once('_')?;
    if hex.len() != 8 {
        return None;
    }
    u32::from_str_radix(hex, 16).ok()
}

/// The token of a stored video, whose name carries no version: a hash of the whole name.
pub fn video_token(name: &str) -> u32 {
    fnv1a32(name.as_bytes())
}

/// A 64-bit hash of a stored name, for the sets each side answers lookups from without touching the filesystem.
pub fn name_hash(name: &str) -> u64 {
    name.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

fn fnv1a32(bytes: &[u8]) -> u32 {
    bytes.iter().fold(0x811c_9dc5, |hash, &byte| {
        (hash ^ u32::from(byte)).wrapping_mul(0x0100_0193)
    })
}

/// Every byte outside `[0-9A-Za-z._-]` becomes `-`, so a multi-byte character becomes several.
fn sanitize(value: &str) -> String {
    value
        .bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-') {
                byte as char
            } else {
                '-'
            }
        })
        .collect()
}

/// Percent-decoding to UTF-8, with `+` as a space in a query. `None` for a malformed escape or invalid UTF-8.
fn decode(value: &str, query: bool) -> Option<String> {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' => {
                let hex = bytes.get(i + 1..i + 3)?;
                out.push(u8::from_str_radix(std::str::from_utf8(hex).ok()?, 16).ok()?);
                i += 3;
            }
            b'+' if query => {
                out.push(b' ');
                i += 1;
            }
            byte => {
                out.push(byte);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}
