mod support;

use codex_sessions_collector::price_history::{self, FetchConfig, History, Observation};
use serde_json::{Value, json};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use support::TempDir;

const TOKEN: &str = "synthetic-pricing-machine-token-123456789";
struct Hub {
    child: Child,
    url: String,
    _temp: TempDir,
}
impl Drop for Hub {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
fn hub() -> Hub {
    let temp = TempDir::new("price-history");
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    let config = temp.path().join("hub.json");
    std::fs::write(&config, json!({"owner_token":"synthetic-pricing-owner-token-123456789","machines":{"machine-a":TOKEN}}).to_string()).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_codex-sessions-hub"))
        .arg(address.to_string())
        .arg(temp.path().join("data"))
        .arg(config)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut hub = Hub {
        child,
        url: format!("http://{address}"),
        _temp: temp,
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    while ureq::get(format!("{}/v1/health", hub.url)).call().is_err() {
        assert!(hub.child.try_wait().unwrap().is_none());
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(20));
    }
    hub
}
fn sync(hub: &Hub, token: &str, observations: Vec<Value>) -> Result<Value, ureq::Error> {
    ureq::post(format!("{}/v1/prices/sync", hub.url))
        .header("Authorization", format!("Bearer {token}"))
        .send_json(json!({"protocol":1,"observations":observations}))?
        .body_mut()
        .read_json()
}

#[test]
fn price_history_endpoint_requires_machine_authentication() {
    let hub = hub();
    assert!(matches!(
        sync(&hub, "invalid-token", vec![]),
        Err(ureq::Error::StatusCode(401))
    ));
    let history = sync(&hub, TOKEN, vec![]).unwrap();
    assert_eq!(history["protocol"], 1);
    assert_eq!(history["observations"], json!([]));
}

fn observation(hour: u32, rate: &str, authority: &str) -> Value {
    json!({"origin":if authority=="hub" {"hub"}else{"machine-a"},"authority":authority,"observed_at_utc":format!("2026-09-01T{hour:02}:00:00.000000Z"),"provider":"provider","model_id":"provider/model","model":{"id":"provider/model","pricing":{"prompt":rate,"completion":"0.2"}}})
}

#[test]
fn opposite_orders_duplicates_revision_replay_preserve_gap_and_provenance() {
    let a = hub();
    let b = hub();
    let values = vec![
        observation(0, "0.1", "local"),
        observation(6, "0.2", "local"),
        observation(18, "0.3", "local"),
    ];
    let mut first = Value::Null;
    let mut second = Value::Null;
    for item in &values {
        first = sync(&a, TOKEN, vec![item.clone()]).unwrap();
    }
    for item in values.iter().rev() {
        second = sync(&b, TOKEN, vec![item.clone()]).unwrap();
    }
    assert_eq!(first, second);
    assert_eq!(sync(&a, TOKEN, values).unwrap(), first);
    assert_eq!(sync(&a, TOKEN, vec![]).unwrap(), first);
    assert_eq!(first["observations"].as_array().unwrap().len(), 3);
    let conn =
        rusqlite::Connection::open(a._temp.path().join("data/hub-pricing/history.sqlite")).unwrap();
    let preserved: String = conn
        .query_row(
            "select observations_json from price_history_revisions where revision=?",
            [first["revision"].as_str().unwrap()],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&preserved).unwrap()["through_rowid"],
        3
    );
}

#[test]
fn hub_wins_only_same_instant_and_same_model_preserving_intraslot_changes() {
    let values = [
        observation(0, "0.1", "local"),
        observation(6, "0.2", "local"),
        observation(12, "9", "local"),
        observation(12, "0.3", "hub"),
        observation(13, "0.4", "local"),
    ];
    let history = History::new(values.iter().map(|v| Observation::parse(v).unwrap()));
    assert_eq!(history.observations.len(), 5);
    let winners = history.winners();
    assert_eq!(winners.len(), 4);
    assert_eq!(
        winners
            .iter()
            .map(|o| o.value["model"]["pricing"]["prompt"].as_str().unwrap())
            .collect::<Vec<_>>(),
        vec!["0.1", "0.2", "0.3", "0.4"]
    );
    let reversed = History::new(values.iter().rev().map(|v| Observation::parse(v).unwrap()));
    assert_eq!(history.revision, reversed.revision);
}

#[test]
fn full_conditional_rules_and_exact_decimal_dart_fixture_survive_http_roundtrip() {
    let fixture: Value =
        serde_json::from_str(include_str!("../../samples/pricing/hub-parity.json")).unwrap();
    let observation = Observation::parse(&fixture["observation"]).unwrap();
    assert_eq!(observation.fingerprint, fixture["expected_fingerprint"]);
    let hub = hub();
    let response = sync(&hub, TOKEN, vec![fixture["observation"].clone()]).unwrap();
    assert_eq!(response["revision"], fixture["expected_revision"]);
    assert_eq!(response["observations"][0], fixture["observation"]);
    // The retained Dart test evaluates this same file through the production
    // exact-decimal engine. Rust owns transport, not a second cost calculator.
    assert_eq!(fixture["expected_cost"], "2.9200002499999999999999");
    let rates = &response["observations"][0]["model"]["pricing"];
    assert_eq!(rates["input_cache_write"], "0.0000000833333333333333");
    assert_eq!(rates["overrides"][0]["min_prompt_tokens"], 9);
}

#[test]
fn spoofed_authority_origin_and_invalid_rates_cannot_partially_change_history() {
    let hub = hub();
    let original = sync(&hub, TOKEN, vec![observation(0, "0.1", "local")]).unwrap();
    let mut spoof = observation(6, "0.2", "local");
    spoof["origin"] = json!("another-machine");
    for invalid in [
        spoof,
        observation(6, "0.2", "hub"),
        observation(6, "-0.5", "local"),
    ] {
        assert!(sync(&hub, TOKEN, vec![observation(18, "0.9", "local"), invalid]).is_err());
        assert_eq!(sync(&hub, TOKEN, vec![]).unwrap(), original);
    }
    let mut unknown = observation(6, "-1", "local");
    unknown["model"]["pricing"]["completion"] = Value::Null;
    let response = sync(&hub, TOKEN, vec![unknown.clone()]).unwrap();
    assert!(
        response["observations"]
            .as_array()
            .unwrap()
            .contains(&unknown)
    );
}

fn provider(pages: Vec<Value>) -> (String, std::thread::JoinHandle<()>) {
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let url = format!("http://{}/models", server.server_addr());
    let thread = std::thread::spawn(move || {
        for page in pages {
            let request = server
                .recv_timeout(Duration::from_secs(10))
                .unwrap()
                .expect("provider request");
            assert_eq!(request.method(), &tiny_http::Method::Get);
            assert!(
                !request
                    .headers()
                    .iter()
                    .any(|h| h.field.equiv("Authorization"))
            );
            request
                .respond(tiny_http::Response::from_string(page.to_string()))
                .unwrap();
        }
    });
    (url, thread)
}

#[test]
fn provider_fetch_publishes_complete_rules_at_completion_time_and_retries_partial_pages() {
    let temp = TempDir::new("price-fetch");
    let first = observation(0, "0.1", "local")["model"].clone();
    let second = json!({"id":"provider/second","pricing":{"prompt":"-1","completion":null,"overrides":[{"utc_start":1000,"utc_end":1200,"utc_days":["monday"],"completion":"0.0000000000000000001"}]}});
    let (url, server) = provider(vec![
        json!({"data":[first],"total_count":2,"links":{"next":"/page2"}}),
        json!({"data":[second.clone()],"total_count":2}),
    ]);
    let config = FetchConfig {
        enabled: true,
        endpoint: url,
        interval_hours: 6,
    };
    let before = chrono::Utc::now();
    assert_eq!(price_history::fetch_once(temp.path(), &config).unwrap(), 2);
    server.join().unwrap();
    let history = price_history::synchronize(
        temp.path(),
        "machine-a",
        json!({"protocol":1,"observations":[]}),
    )
    .unwrap();
    let observations = history["observations"].as_array().unwrap();
    assert!(
        observations
            .iter()
            .any(|o| o["model"]["pricing"] == second["pricing"]
                && serde_json::from_str::<Value>(o["model"]["raw_pricing_json"].as_str().unwrap())
                    .unwrap()
                    == second)
    );
    for o in observations {
        assert_eq!(o["authority"], "hub");
        let at =
            chrono::DateTime::parse_from_rfc3339(o["observed_at_utc"].as_str().unwrap()).unwrap();
        assert!(at >= before);
    }
    assert!(!price_history::fetch_due(temp.path(), &config, chrono::Utc::now()).unwrap());
    let (url, server) = provider(vec![
        json!({"data":[first],"total_count":2,"links":{"next":"/page2"}}),
        json!({"data":[],"total_count":3}),
    ]);
    let failed = FetchConfig {
        endpoint: url,
        ..config
    };
    assert_eq!(price_history::fetch_once(temp.path(), &failed).unwrap(), 0);
    server.join().unwrap();
    assert_eq!(
        price_history::synchronize(
            temp.path(),
            "machine-a",
            json!({"protocol":1,"observations":[]})
        )
        .unwrap(),
        history
    );
    let conn = rusqlite::Connection::open(temp.path().join("hub-pricing/history.sqlite")).unwrap();
    let error: String = conn
        .query_row(
            "select value from app_metadata where key='hub_prices.error'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(!error.is_empty());
}

#[test]
fn utc_schedule_boundaries_restart_catchup_and_disabled_default() {
    let temp = TempDir::new("price-schedule");
    let at = |text: &str| {
        chrono::DateTime::parse_from_rfc3339(text)
            .unwrap()
            .with_timezone(&chrono::Utc)
    };
    let config = FetchConfig {
        enabled: true,
        ..FetchConfig::default()
    };
    assert!(
        !price_history::fetch_due(
            temp.path(),
            &FetchConfig::default(),
            at("2026-09-01T00:00:00Z")
        )
        .unwrap()
    );
    assert!(!temp.path().join("hub-pricing").exists());
    assert!(price_history::fetch_due(temp.path(), &config, at("2026-09-01T00:00:00Z")).unwrap());
    let conn = rusqlite::Connection::open(temp.path().join("hub-pricing/history.sqlite")).unwrap();
    let slot = price_history::slot_at(at("2026-09-01T00:00:00Z"), 6);
    conn.execute("insert into app_metadata(key,value,updated_at_utc) values ('hub_prices.last_success_utc',?,'now')",["2026-09-01T00:00:00Z"]).unwrap();
    assert!(!price_history::fetch_due(temp.path(), &config, at("2026-09-01T05:59:59Z")).unwrap());
    for hour in [6, 12, 18] {
        assert!(
            price_history::fetch_due(
                temp.path(),
                &config,
                at(&format!("2026-09-01T{hour:02}:00:00Z"))
            )
            .unwrap()
        );
    }
    assert!(price_history::fetch_due(temp.path(), &config, at("2026-09-05T13:00:00Z")).unwrap());
    let daily = FetchConfig {
        interval_hours: 24,
        ..config.clone()
    };
    assert!(!price_history::fetch_due(temp.path(), &daily, at("2026-09-01T18:00:00Z")).unwrap());
    assert!(price_history::fetch_due(temp.path(), &daily, at("2026-09-02T00:00:00Z")).unwrap());
    // Offset/DST representation cannot move the underlying UTC boundary.
    assert_eq!(
        price_history::slot_at(at("2026-09-01T08:00:00+02:00"), 6),
        slot + 1
    );
}

#[test]
fn canonical_json_uses_dart_utf16_key_order_and_fixed_microsecond_instants() {
    let value = json!({"\u{e000}":2,"\u{1f600}":1});
    assert_eq!(
        price_history::canonical_json(&value),
        "{\"😀\":1,\"\u{e000}\":2}"
    );
    let mut a = observation(0, "0.1", "local");
    let mut b = a.clone();
    a["observed_at_utc"] = json!("2026-09-01T00:00:00.123456789Z");
    b["observed_at_utc"] = json!("2026-09-01T02:00:00.123456+02:00");
    assert_eq!(
        Observation::parse(&a).unwrap().fingerprint,
        Observation::parse(&b).unwrap().fingerprint
    );
}

#[test]
fn enabled_worker_catches_up_once_and_stops_without_waiting_for_next_slot() {
    let temp = TempDir::new("price-worker");
    let model = observation(0, "0.1", "local")["model"].clone();
    let (url, server) = provider(vec![json!({"data":[model]})]);
    let worker = price_history::Worker::start(
        temp.path(),
        FetchConfig {
            enabled: true,
            endpoint: url,
            interval_hours: 6,
        },
    )
    .unwrap()
    .unwrap();
    server.join().unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let history = price_history::synchronize(
            temp.path(),
            "machine-a",
            json!({"protocol":1,"observations":[]}),
        )
        .unwrap();
        if history["observations"].as_array().unwrap().len() == 1 {
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    let start = Instant::now();
    drop(worker);
    assert!(start.elapsed() < Duration::from_secs(2));
    assert!(
        price_history::Worker::start(temp.path(), FetchConfig::default())
            .unwrap()
            .is_none()
    );
}

#[test]
fn failed_provider_honors_retry_after_and_never_publishes_error_body() {
    let temp = TempDir::new("price-retry");
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let url = format!("http://{}/models", server.server_addr());
    let thread = std::thread::spawn(move || {
        let request = server
            .recv_timeout(Duration::from_secs(10))
            .unwrap()
            .unwrap();
        request
            .respond(
                tiny_http::Response::from_string("private-provider-error-body")
                    .with_status_code(429)
                    .with_header(tiny_http::Header::from_bytes("Retry-After", "3600").unwrap()),
            )
            .unwrap();
    });
    let config = FetchConfig {
        enabled: true,
        endpoint: url,
        interval_hours: 6,
    };
    let before = chrono::Utc::now();
    assert_eq!(price_history::fetch_once(temp.path(), &config).unwrap(), 0);
    thread.join().unwrap();
    let conn = rusqlite::Connection::open(temp.path().join("hub-pricing/history.sqlite")).unwrap();
    let next: String = conn
        .query_row(
            "select value from app_metadata where key='hub_prices.retry_at'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let next = chrono::DateTime::parse_from_rfc3339(&next).unwrap();
    assert!(next >= before + chrono::Duration::hours(1));
    assert!(
        !price_history::fetch_due(temp.path(), &config, before + chrono::Duration::minutes(59))
            .unwrap()
    );
    let error: String = conn
        .query_row(
            "select value from app_metadata where key='hub_prices.error'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(!error.contains("private-provider-error-body"));
    assert_eq!(
        conn.query_row::<i64, _, _>("select count(*) from price_observations", [], |r| r.get(0))
            .unwrap(),
        0
    );
}

#[test]
fn complete_catalog_removal_emits_tombstone_without_erasing_local_gap_evidence() {
    let temp = TempDir::new("price-removal");
    let a = observation(0, "0.1", "local")["model"].clone();
    let b = json!({"id":"provider/removed","pricing":{"prompt":"0.2"}});
    let (url, server) = provider(vec![json!({"data":[a.clone(),b],"total_count":2})]);
    let config = FetchConfig {
        enabled: true,
        endpoint: url,
        interval_hours: 6,
    };
    assert_eq!(price_history::fetch_once(temp.path(), &config).unwrap(), 2);
    server.join().unwrap();
    let mut local = observation(6, "0.3", "local");
    local["model_id"] = json!("provider/local-only");
    local["model"]["id"] = json!("provider/local-only");
    price_history::synchronize(
        temp.path(),
        "machine-a",
        json!({"protocol":1,"observations":[local.clone()]}),
    )
    .unwrap();
    let (url, server) = provider(vec![json!({"data":[a],"total_count":1})]);
    assert_eq!(
        price_history::fetch_once(
            temp.path(),
            &FetchConfig {
                endpoint: url,
                ..config
            }
        )
        .unwrap(),
        2
    );
    server.join().unwrap();
    let response = price_history::synchronize(
        temp.path(),
        "machine-a",
        json!({"protocol":1,"observations":[]}),
    )
    .unwrap();
    let values = response["observations"].as_array().unwrap();
    let tombstones: Vec<_> = values
        .iter()
        .filter(|v| v["model"]["removed"] == true)
        .collect();
    assert_eq!(tombstones.len(), 1);
    assert_eq!(tombstones[0]["model_id"], "provider/removed");
    assert!(values.contains(&local));
}

#[test]
fn malformed_conditions_and_provider_identity_cannot_poison_immutable_history() {
    let hub = hub();
    let original = sync(&hub, TOKEN, vec![observation(0, "0.1", "local")]).unwrap();
    let mut bad_provider = observation(6, "0.1", "local");
    bad_provider["provider"] = json!("wrong-provider");
    assert!(sync(&hub, TOKEN, vec![bad_provider]).is_err());
    let mut floating_metadata = observation(6, "0.1", "local");
    floating_metadata["model"]["numeric_metadata"] = json!(1.5);
    assert!(sync(&hub, TOKEN, vec![floating_metadata]).is_err());
    let invalid_rules = [
        json!({"min_prompt_tokens":-1,"prompt":"1"}),
        json!({"utc_start":2460,"utc_end":100,"prompt":"1"}),
        json!({"utc_start":1000,"prompt":"1"}),
        json!({"utc_start":1000,"utc_end":1000,"prompt":"1"}),
        json!({"utc_days":["mon"],"prompt":"1"}),
        json!({"utc_days":[],"prompt":"1"}),
        json!({"utc_days":["monday"]}),
        json!({"unsupported_condition":true,"prompt":"1"}),
        json!({"prompt":"-1"}),
        json!({"prompt":null}),
    ];
    for rule in invalid_rules {
        let mut item = observation(6, "0.1", "local");
        item["model"]["pricing"]["overrides"] = json!([rule]);
        assert!(sync(&hub, TOKEN, vec![observation(18, "0.9", "local"), item]).is_err());
        assert_eq!(sync(&hub, TOKEN, vec![]).unwrap(), original);
    }
    assert!(sync(&hub, TOKEN, vec![observation(6, "0.2", "local")]).is_ok());
}

fn request(hub: &Hub, body: Value) -> Result<Value, ureq::Error> {
    ureq::post(format!("{}/v1/prices/sync", hub.url))
        .header("Authorization", format!("Bearer {TOKEN}"))
        .send_json(body)?
        .body_mut()
        .read_json()
}

#[test]
fn paged_history_snapshot_and_delta_survive_concurrent_append_and_duplicate_uploads() {
    let hub = hub();
    let observations: Vec<_> = (0..520)
        .map(|index| {
            let mut item = observation(0, "0.1", "local");
            let id = format!("provider/model-{index}");
            item["model_id"] = json!(id);
            item["model"]["id"] = json!(id);
            item
        })
        .collect();
    for chunk in observations.chunks(512) {
        let ack = request(
            &hub,
            json!({"protocol":1,"observations":chunk,"download":false}),
        )
        .unwrap();
        assert!(ack.get("observations").is_none());
        assert_eq!(ack["accepted"], chunk.len());
    }
    let first = request(
        &hub,
        json!({"protocol":1,"observations":[],"download":true,"after":0}),
    )
    .unwrap();
    assert_eq!(first["observations"].as_array().unwrap().len(), 512);
    assert_eq!(first["complete"], false);
    let extra = observation(6, "0.2", "local");
    request(
        &hub,
        json!({"protocol":1,"observations":[extra.clone()],"download":false}),
    )
    .unwrap();
    let second=request(&hub,json!({"protocol":1,"observations":[],"download":true,"after":first["after"],"through":first["through"]})).unwrap();
    assert_eq!(second["complete"], true);
    assert_eq!(second["observations"].as_array().unwrap().len(), 8);
    assert_eq!(second["revision"], first["revision"]);
    let aggregate = History::new(observations.iter().map(|v| Observation::parse(v).unwrap()));
    assert_eq!(aggregate.revision, first["revision"]);
    let delta = request(
        &hub,
        json!({"protocol":1,"observations":[],"download":true,"after":second["through"]}),
    )
    .unwrap();
    assert_eq!(delta["observations"], json!([extra]));
    assert_eq!(delta["complete"], true);
    request(
        &hub,
        json!({"protocol":1,"observations":&observations[..512],"download":false}),
    )
    .unwrap();
    let unchanged = request(
        &hub,
        json!({"protocol":1,"observations":[],"download":true,"after":delta["through"]}),
    )
    .unwrap();
    assert_eq!(unchanged["observations"], json!([]));
    assert_eq!(unchanged["revision"], delta["revision"]);
    assert!(matches!(
        request(
            &hub,
            json!({"protocol":1,"observations":[],"download":true,"after":999999})
        ),
        Err(ureq::Error::StatusCode(409))
    ));
    assert!(
        request(
            &hub,
            json!({"protocol":1,"observations":observations,"download":false})
        )
        .is_err()
    );
}
