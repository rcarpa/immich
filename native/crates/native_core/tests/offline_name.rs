#![cfg(feature = "offline_name")]

use native_core::offline_name::{bucket, file_name, name_hash, token, video_token};

/// Every case the naming has to get right, with the names stored files already have.
const FIXTURE: &str = include_str!("fixtures/offline_names.tsv");

#[test]
fn names_every_fixture_url_as_written() {
    let mut checked = 0;
    for line in FIXTURE.lines().filter(|line| !line.is_empty()) {
        let (url, name) = line.split_once('\t').expect("url<TAB>name");
        assert_eq!(file_name(url).as_deref(), Some(name), "{url}");
        checked += 1;
    }
    assert!(checked > 20);
}

#[test]
fn refuses_a_malformed_escape() {
    assert_eq!(file_name("https://e.com/api/assets/x%2/thumbnail"), None);
    assert_eq!(
        file_name("https://e.com/api/assets/x/thumbnail?c=%ZZ"),
        None
    );
    assert_eq!(file_name("https://e.com/api/assets/%FF/thumbnail"), None);
}

#[test]
fn ignores_the_fragment() {
    assert_eq!(
        file_name("https://e.com/api/assets/x/thumbnail?size=preview#top"),
        file_name("https://e.com/api/assets/x/thumbnail?size=preview")
    );
}

#[test]
fn buckets_by_the_name_hash() {
    // Values stored files already sit under.
    assert_eq!(
        bucket("assets_abc123_thumbnail_preview_eb9fc1d4"),
        fnv_low_byte("assets_abc123_thumbnail_preview_eb9fc1d4")
    );
    assert_eq!(bucket(""), 0xc5);
}

#[test]
fn reads_the_token_back() {
    assert_eq!(
        token("assets_abc123_thumbnail_preview_eb9fc1d4"),
        Some(0xeb9f_c1d4)
    );
    assert_eq!(
        token("assets_abc123_original_f83372e3.mp4"),
        Some(0xf833_72e3)
    );
    assert_eq!(token("people_p1"), None);
}

#[test]
fn hashes_names_as_stored_rows_and_indexes_expect() {
    // FNV-1a: the offset bases for an empty name, and values held rows already carry.
    assert_eq!(name_hash(""), 0xcbf2_9ce4_8422_2325);
    assert_eq!(video_token(""), 0x811c_9dc5);
    assert_eq!(
        u32::from(fnv_low_byte("assets_abc123_video_playback_811c9dc5.mp4")),
        video_token("assets_abc123_video_playback_811c9dc5.mp4") & 0xFF
    );
    assert_ne!(
        name_hash("assets_abc123_thumbnail_preview_eb9fc1d4"),
        name_hash("assets_abc123")
    );
}

fn fnv_low_byte(value: &str) -> u8 {
    let mut hash: u32 = 0x811c_9dc5;
    for byte in value.bytes() {
        hash = (hash ^ u32::from(byte)).wrapping_mul(0x0100_0193);
    }
    (hash & 0xFF) as u8
}
