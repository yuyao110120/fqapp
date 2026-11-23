//! Exercise codec rejection through the real dispatcher, including the raw
//! response and download fallbacks that extractor-only tests cannot cover.

#![allow(clippy::await_holding_lock)]

mod common;

use common::{build_server, pool_json, query_map, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use fqapi_core::endpoints::Server;
use fqapi_core::upstream::reset_playback_route_state_for_tests;
use md5::{Digest, Md5};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

const ALLOWED_URL: &str = "https://example.invalid/h264.mp4";
const REJECTED_URL: &str = "https://example.invalid/bytevc2.mp4";
const SPADE_A: &str = "kbwf80+1N+V9nwHQSp431GWvLeBlqizTYJ0o5FOrHuZhqimysg==";
const KEY_HEX: &str = "4990a92de837e29e18031a370ab744e6";

static ROUTES: Mutex<()> = Mutex::new(());

fn exclusive() -> MutexGuard<'static, ()> {
    let guard = ROUTES.lock().unwrap_or_else(|error| error.into_inner());
    reset_playback_route_state_for_tests();
    guard
}

fn response_shapes(variants: Vec<Value>) -> Vec<(&'static str, Value)> {
    let video_map: serde_json::Map<String, Value> = variants
        .iter()
        .enumerate()
        .map(|(i, v)| (format!("video_{i}"), v.clone()))
        .collect();
    let shortplay = json!({"key_seed": "AAAA", "video_list": video_map});
    let array_model = json!({"key_seed": "AAAA", "video_list": variants});
    let decoy = json!({"key_seed": "AAAA", "video_list": {
        "video_0": {"main_url": ALLOWED_URL, "codec_type": "h264"}
    }});
    vec![
        (
            "shortplay object",
            json!({"data": {"video_model": shortplay}}),
        ),
        (
            "shortplay string",
            json!({"data": {"video_model": shortplay.to_string()}}),
        ),
        (
            "v5 grouped episode",
            json!({"data": {"1004": {
                "episode": {"video_model": shortplay},
                "other": {"video_model": decoy}
            }}}),
        ),
        (
            "array object",
            json!({"data": {"video_model": array_model}}),
        ),
        (
            "nested array string",
            json!({"data": {"episode": {"video_model": array_model.to_string()}}}),
        ),
        (
            "phoenix play info",
            json!({"data": {"video_info_list_map": {"episode": [
                {"play_info_list": variants}
            ]}}}),
        ),
    ]
}

async fn request_video(server: &Server, query: &str) -> (u16, Value) {
    let response = dispatch(
        server,
        &Request {
            method: "GET".to_string(),
            path: "/api/v1/videos/episode".to_string(),
            query: query.to_string(),
            ..Default::default()
        },
    )
    .await;
    let status = response.status;
    let body = response.into_bytes().await.expect("response body");
    (
        status,
        serde_json::from_slice(&body).expect("JSON response"),
    )
}

fn assert_rejected(status: u16, body: &Value, context: &str) {
    assert_eq!(status, 500, "{context}: {body}");
    assert_eq!(body["success"], false, "{context}: {body}");
    assert_eq!(body["error"], "该视频暂不支持播放", "{context}: {body}");
    assert!(!body.to_string().contains("https://"), "{context}: {body}");
}

#[tokio::test]
async fn bytevc2_only_is_terminal_across_response_shapes_and_modes() {
    let _guard = exclusive();
    for codec in [
        json!({"codec_type": "ByTeVc2"}),
        json!({"video_meta": {"codec_type": "BYTEVC2"}}),
        json!({"gear_des_key": "bytevc2_1080p"}),
    ] {
        let mut variant = codec;
        variant["main_url"] = json!(REJECTED_URL);
        for (name, payload) in response_shapes(vec![variant]) {
            let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
            let dir = TempDir::new("video-codec-reject");
            let server =
                build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
            for mode in ["mode=stream", ""] {
                let (status, body) = request_video(&server, mode).await;
                assert_rejected(status, &body, &format!("{name}, {mode}"));
            }
            assert!(upstream
                .requests()
                .iter()
                .all(|r| !r.path.ends_with(".mp4")));
        }
    }
}

#[tokio::test]
async fn missing_or_invalid_seed_cannot_hide_codec_rejection() {
    let _guard = exclusive();
    for seed in [Value::Null, json!(""), json!("invalid!")] {
        let payload = json!({"data": {"video_model": {
            "key_seed": seed,
            "video_list": {"video_1": {
                "codec_type": "bytevc2", "main_url": REJECTED_URL
            }}
        }}});
        let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
        let dir = TempDir::new("video-codec-seed");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        let (status, body) = request_video(&server, "mode=stream").await;
        assert_rejected(status, &body, "invalid seed");
    }
}

#[tokio::test]
async fn mixed_variants_keep_h264_preference_across_response_shapes() {
    let _guard = exclusive();
    // Put H.264 first: blindly taking the last array entry would pick bytevc2,
    // and filtering without ranking would pick H.265 at the same quality.
    let variants = vec![
        json!({"main_url": ALLOWED_URL, "codec_type": "h264", "vwidth": 720, "vheight": 1280}),
        json!({"main_url": "https://example.invalid/h265.mp4", "codec_type": "h265", "vwidth": 720, "vheight": 1280}),
        json!({"main_url": REJECTED_URL, "codec_type": "bytevc2", "vwidth": 1080, "vheight": 1920}),
    ];
    for (name, payload) in response_shapes(variants) {
        let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
        let dir = TempDir::new("video-codec-mixed");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        let (status, body) = request_video(&server, "mode=stream").await;
        assert_eq!(status, 200, "{name}: {body}");
        assert_eq!(body["video_url"], ALLOWED_URL, "{name}: {body}");
        assert!(!body.to_string().contains(REJECTED_URL), "{name}: {body}");
    }
}

#[tokio::test]
async fn unrecognized_payload_keeps_legacy_raw_response_compatibility() {
    let _guard = exclusive();
    let payload = json!({"code": 0, "data": {"legacy": {"main_url": ALLOWED_URL}}});
    let expected = payload.clone();
    let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
    let dir = TempDir::new("video-codec-legacy");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    for mode in ["mode=stream", ""] {
        let (status, body) = request_video(&server, mode).await;
        assert_eq!(status, 200);
        assert_eq!(body, expected);
    }

    let payload = json!({"code": 0, "data": {"1004": {
        "other": {"main_url": "https://example.invalid/other.mp4"}
    }}});
    let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
    let dir = TempDir::new("video-v5-target-missing");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    for mode in ["mode=stream", ""] {
        let (status, body) = request_video(&server, mode).await;
        assert_eq!(status, 500, "{mode}: {body}");
        assert_eq!(body["error"], "视频取流失败，请稍后重试", "{mode}: {body}");
        assert!(!body.to_string().contains("other.mp4"), "{mode}: {body}");
    }
}

#[tokio::test]
async fn fallback_rejection_requires_a_conclusive_codec_decision() {
    let _guard = exclusive();
    let model = json!({
        "fallback_api": "https://example.invalid/fallback",
        "video_list": [{
            "main_url": "https://example.invalid/original.mp4",
            "encrypt_info": {"encrypt": true}
        }]
    });
    for data in [
        json!({"video_model": model}),
        json!({"episode": {"video_model": model.to_string()}}),
    ] {
        let upstream = MockUpstream::start(move |req| {
            if req.path == "/fallback" {
                return MockReply::json(json!({"video_info": {"data": {
                    "key_seed": "AAAA", "video_list": {"video_1": {
                        "main_url": REJECTED_URL, "codec_type": "bytevc2"
                    }}
                }}}));
            }
            MockReply::json(json!({"data": data}))
        })
        .await;
        let dir = TempDir::new("video-codec-fallback");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        for mode in ["mode=stream", ""] {
            let (status, body) = request_video(&server, mode).await;
            assert_rejected(status, &body, "fallback rejected");
        }
        let requests = upstream.requests();
        assert!(requests.iter().any(|r| r.path == "/fallback"));
        assert!(requests.iter().all(|r| !r.path.ends_with(".mp4")));
    }

    let model = json!({
        "fallback_api": "https://example.invalid/fallback",
        "video_list": [{
            "main_url": "https://example.invalid/original.mp4",
            "encrypt_info": {"encrypt": true}
        }]
    });
    let upstream = MockUpstream::start(move |req| {
        if req.path == "/fallback" {
            return MockReply::status(503);
        }
        MockReply::json(json!({"data": {"video_model": model}}))
    })
    .await;
    let dir = TempDir::new("video-codec-fallback-unknown");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    for mode in ["mode=stream", ""] {
        let (status, body) = request_video(&server, mode).await;
        assert_eq!(status, 500, "{mode}: {body}");
        assert_eq!(body["error"], "视频取流失败，请稍后重试", "{mode}: {body}");
    }
}

#[tokio::test]
async fn download_failure_returns_only_the_selected_url_and_its_key() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|req| {
        if req.path.ends_with(".mp4") {
            return MockReply::status(500);
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA", "video_list": {
                "video_1": {"main_url": ALLOWED_URL, "codec_type": "h264", "spade_a": SPADE_A},
                "video_2": {"main_url": REJECTED_URL, "codec_type": "bytevc2"}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-codec-download");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "").await;
    assert_eq!(status, 200);
    assert_eq!(body["video_url"], ALLOWED_URL);
    assert_eq!(body["key_hex"], KEY_HEX);
    assert!(!body.to_string().contains(REJECTED_URL));
    let requests = upstream.requests();
    assert!(requests.iter().any(|r| r.path == "/h264.mp4"));
    assert!(requests.iter().all(|r| r.path != "/bytevc2.mp4"));
}

#[tokio::test]
async fn successful_download_keeps_the_local_source_contract() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|req| {
        if req.path == "/h264.mp4" {
            return MockReply {
                status: 200,
                headers: vec![],
                body: b"video fixture".to_vec(),
            };
        }
        MockReply::json(json!({"data": {"episode": {"video_model": {
            "video_list": [{"main_url": ALLOWED_URL, "codec_type": "h264"}]
        }}}}))
    })
    .await;
    let dir = TempDir::new("video-codec-local");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "").await;
    assert_eq!(status, 200);
    assert_eq!(body["video_url"], "/src/episode.mp4");
    assert_eq!(
        body["video_info"]["data"]["video_list"]["video_1"]["main_url"],
        "/src/episode.mp4"
    );
    assert_eq!(
        std::fs::read(dir.join("src/episode.mp4")).unwrap(),
        b"video fixture"
    );
}

/// The shortplay list stops at 720P; the model's `fallback_api` list carries
/// the top tier. The stream response must merge both, or the quality panel
/// silently loses a row (measured 2026-10-12 on the live upstream).
#[tokio::test]
async fn stream_variants_merge_the_fallback_list_so_the_top_tier_survives() {
    let _guard = exclusive();
    let v5_calls = Arc::new(AtomicUsize::new(0));
    let v5_calls_for_mock = Arc::clone(&v5_calls);
    let upstream = MockUpstream::start(move |req| {
        if req.path == "/novel/player/multi_video_model/player/v1"
            && v5_calls_for_mock.fetch_add(1, Ordering::SeqCst) == 0
        {
            return MockReply::status(503);
        }
        if req.path == "/fallback" {
            return MockReply::json(json!({"video_info": {"data": {
                "key_seed": "AAAA",
                "video_list": {
                    "video_1": {"main_url": "https://example.invalid/360.mp4",
                        "vwidth": 360, "vheight": 640, "codec_type": "bytevc1", "spade_a": SPADE_A},
                    "video_2": {"main_url": "https://example.invalid/720.mp4",
                        "vwidth": 720, "vheight": 1280, "codec_type": "bytevc1", "spade_a": SPADE_A},
                    "video_3": {"main_url": "https://example.invalid/1080.mp4",
                        "vwidth": 1080, "vheight": 1920, "codec_type": "bytevc1", "spade_a": SPADE_A}
                }
            }}}));
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA",
            "fallback_api": "https://example.invalid/fallback",
            "video_list": {
                "video_1": {"main_url": "https://example.invalid/360.mp4",
                    "vwidth": 360, "vheight": 640, "codec_type": "bytevc1", "spade_a": SPADE_A},
                "video_2": {"main_url": "https://example.invalid/720.mp4",
                    "vwidth": 720, "vheight": 1280, "codec_type": "bytevc1", "spade_a": SPADE_A}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-variant-merge");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "mode=stream&_playback_purpose=prefetch").await;
    assert_eq!(status, 200, "{body}");
    let names: Vec<&str> = body["variants"]
        .as_array()
        .expect("variants array")
        .iter()
        .map(|v| v["name"].as_str().expect("variant name"))
        .collect();
    assert_eq!(names, ["1080P", "720P", "360P"], "{body}");
    assert_eq!(
        body["variants"][0]["url"],
        "https://example.invalid/1080.mp4"
    );
    assert_eq!(
        body["variants"][0]["key_hex"].as_str().expect("key").len(),
        32,
        "{body}"
    );
    let requests = upstream.requests();
    assert!(requests.iter().any(|r| r.path == "/fallback"));
    let v5_requests: Vec<_> = requests
        .iter()
        .filter(|r| r.path == "/novel/player/multi_video_model/player/v1")
        .collect();
    assert_eq!(v5_requests.len(), 2);
    assert!(v5_requests
        .iter()
        .all(|request| !query_map(&request.query).contains_key("_playback_purpose")));
    assert_ne!(v5_requests[0].query, v5_requests[1].query);
    let v5 = v5_requests[1];
    assert_eq!(v5.method, "POST");
    assert_eq!(
        query_map(&v5.query).get("aid").map(String::as_str),
        Some("8662")
    );
    assert_eq!(v5.header("content-encoding"), Some("gzip"));
    assert_eq!(
        v5.header("content-type"),
        Some("application/json; charset=utf-8")
    );
    assert!(v5.header("x-medusa").is_some());
    assert!(v5.header("x-argus").is_none());
    let expected_stub = hex::encode_upper(Md5::digest(&v5.body));
    assert_eq!(v5.header("x-ss-stub"), Some(expected_stub.as_str()));
    let plain = fqapi_core::crypto::gunzip(&v5.body).expect("gzip V5 body");
    let wire: Value = serde_json::from_slice(&plain).expect("V5 JSON body");
    assert!(wire.get("_playback_purpose").is_none());
    assert_eq!(wire["mixed_video_id_map"]["1004"], json!(["episode"]));
    assert_eq!(wire["dr_scene"], "player");
}

/// The fallback list's low tiers are often bytevc2. Merging must not smuggle
/// them past the codec gate.
#[tokio::test]
async fn stream_variants_do_not_merge_bytevc2_tiers() {
    let _guard = exclusive();
    let upstream = MockUpstream::start(|req| {
        if req.path == "/fallback" {
            return MockReply::json(json!({"video_info": {"data": {
                "key_seed": "AAAA",
                "video_list": {
                    "video_1": {"main_url": "https://example.invalid/1080.mp4",
                        "vwidth": 1080, "vheight": 1920, "codec_type": "bytevc1", "spade_a": SPADE_A},
                    "video_2": {"main_url": REJECTED_URL,
                        "vwidth": 720, "vheight": 1280, "codec_type": "bytevc2", "spade_a": SPADE_A}
                }
            }}}));
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA",
            "fallback_api": "https://example.invalid/fallback",
            "video_list": {
                "video_1": {"main_url": ALLOWED_URL,
                    "vwidth": 360, "vheight": 640, "codec_type": "bytevc1", "spade_a": SPADE_A}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-variant-gate");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "mode=stream").await;
    assert_eq!(status, 200, "{body}");
    let names: Vec<&str> = body["variants"]
        .as_array()
        .expect("variants array")
        .iter()
        .map(|v| v["name"].as_str().expect("variant name"))
        .collect();
    assert_eq!(names, ["1080P", "360P"], "{body}");
    assert!(!body.to_string().contains(REJECTED_URL), "{body}");
}

/// The official single-episode door (`/novel/player/video_model/v1/`) answers
/// `data.video_model` in both the object and the string form; both must reach
/// the shared parser, and the request must carry that door's own HAR params.
#[tokio::test]
async fn the_single_episode_model_door_parses_both_video_model_shapes() {
    let _guard = exclusive();
    let model = json!({
        "key_seed": "AAAA",
        "video_list": {"video_0": {
            "main_url": ALLOWED_URL, "codec_type": "h264",
            "vwidth": 1080, "vheight": 1920
        }}
    });
    let object = json!({"code": 0, "data": {"video_model": model.clone()}});
    let string = json!({"code": 0, "data": {"video_model": model.to_string()}});
    for (name, payload) in [("object", object), ("string", string)] {
        reset_playback_route_state_for_tests();
        let reply = payload.clone();
        let upstream = MockUpstream::start(move |req| {
            if req.path == "/novel/player/multi_video_model/player/v1" {
                MockReply::status(200)
            } else {
                MockReply::json(reply.clone())
            }
        })
        .await;
        let dir = TempDir::new("video-model-door");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

        let (status, body) = request_video(&server, "mode=stream").await;
        assert_eq!(status, 200, "{name}: {body}");
        assert_eq!(body["video_url"], ALLOWED_URL, "{name}: {body}");

        let requests = upstream.requests();
        let model_request = requests
            .iter()
            .find(|request| request.path == "/novel/player/video_model/v1/")
            .unwrap_or_else(|| panic!("{name}: the single-episode door must be asked"));
        assert_eq!(model_request.method, "POST", "{name}");
        assert_eq!(
            model_request.header("content-encoding"),
            Some("gzip"),
            "{name}"
        );
        let expected_stub = hex::encode_upper(Md5::digest(&model_request.body));
        assert_eq!(
            model_request.header("x-ss-stub"),
            Some(expected_stub.as_str()),
            "{name}"
        );
        let plain = fqapi_core::crypto::gunzip(&model_request.body).expect("gzip model body");
        let wire: Value = serde_json::from_slice(&plain).expect("model JSON body");
        assert_eq!(wire["content_type"], json!(1004), "{name}");
        assert_eq!(wire["video_id"], json!("episode"), "{name}");
        assert_eq!(
            wire["biz_param"],
            json!({
                "detail_page_version": 0,
                "device_level": 3,
                "disable_digg_stat": false,
                "from_video_id": "",
                "need_all_video_definition": true,
                "need_mp4_align": false,
                "source": 9,
                "use_os_player": false,
                "use_server_dns": false,
                "video_platform": 3,
            }),
            "{name}"
        );
        let first = requests.first().expect("initial door");
        assert_eq!(
            query_map(&first.query).get("device_id"),
            query_map(&model_request.query).get("device_id"),
            "the single-episode door must reuse the initial identity"
        );
        for header in ["x-medusa", "x-helios", "x-khronos"] {
            assert!(model_request.header(header).is_some(), "{header}");
        }
        upstream.shutdown();
    }
}
