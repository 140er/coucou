// T3 Code (https://github.com/pingdotgg/t3code) as a live source.
//
// The web client does not scrape HTML. It opens the server's WebSocket at `/ws`
// and speaks Effect 4's JSON RPC (`RpcSerialization.layerJson`): one JSON object
// per frame, tagged `_tag`. `orchestration.subscribeShell` streams the projects
// and the thread shells (running, waiting, done, error). A thread that is
// waiting is opened with `orchestration.subscribeThread`, and Allow / Deny is
// `orchestration.dispatchCommand` of `thread.approval.respond`.
//
// A bearer session never sits in the socket URL. It is exchanged for a
// short-lived `wsTicket` (`POST /api/auth/websocket-ticket`), the same way the
// T3 client does it. Cloudflare Access service-token headers, when the user
// saved them, go on that request and on the upgrade. Nothing here is logged
// except a fixed reason.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use futures_util::sink::Sink;
use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, Notify};
use tokio_rustls::rustls::pki_types::ServerName;
use tokio_rustls::rustls::version::{TLS12, TLS13};
use tokio_rustls::rustls::{crypto::ring as ring_provider, ClientConfig, RootCertStore};
use tokio_rustls::TlsConnector;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

use crate::integrations::PAUSED;
use crate::island::WINDOW_LABEL;
use crate::log;
use crate::secrets;

pub const PILL_ID: &str = "agent_t3";

const URL_KEY: &str = "t3-url";
const TOKEN_KEY: &str = "t3-token";
const CF_ID_KEY: &str = "t3-cf-client-id";
const CF_SECRET_KEY: &str = "t3-cf-client-secret";

const SHELL_METHOD: &str = "orchestration.subscribeShell";
const THREAD_METHOD: &str = "orchestration.subscribeThread";
const DISPATCH_METHOD: &str = "orchestration.dispatchCommand";
const SHELL_ID: &str = "shell";

static WAKE: Notify = Notify::const_new();
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static LIVE: Mutex<Option<Live>> = Mutex::new(None);

struct Live {
    tx: mpsc::UnboundedSender<Decision>,
    /// request id → thread id, only the approvals the server is still waiting on.
    pending: HashMap<String, String>,
}

struct Decision {
    thread_id: String,
    request_id: String,
    accept: bool,
}

pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        supervise(app).await;
    });
}

/// Settings or the saved address changed: drop the socket and look again.
pub fn wake() {
    WAKE.notify_waiters();
    WAKE.notify_one();
}

/// Allow / Deny from the island or the phone. True when this request is one T3
/// is waiting on, so the caller does not also answer a Claude Code hook.
/// A thread id, when the island has one, has to be that request's thread.
pub fn try_decide(thread_id: Option<&str>, request_id: &str, accept: bool) -> bool {
    let live = LIVE.lock().unwrap();
    let Some(live) = live.as_ref() else {
        return false;
    };
    let Some(known) = live.pending.get(request_id).cloned() else {
        return false;
    };
    if thread_id.is_some_and(|id| id != known) {
        return true;
    }
    let _ = live.tx.send(Decision {
        thread_id: known,
        request_id: request_id.to_string(),
        accept,
    });
    true
}

/// The server origin in the browser. The thread rows carry their own links.
pub fn open_server() {
    let Some(raw) = secrets::get(URL_KEY) else {
        return;
    };
    let Some(base) = parse_server_url(&raw) else {
        return;
    };
    crate::platform::open_url(&http_origin(&base));
}

fn enabled(app: &AppHandle) -> bool {
    app.try_state::<crate::Shared>()
        .map(|shared| {
            let settings = shared.settings.lock().unwrap();
            settings.main_pill == PILL_ID
                || settings.active_integrations.iter().any(|id| id == PILL_ID)
        })
        .unwrap_or(false)
}

async fn supervise(app: AppHandle) {
    let mut seen = Seen::default();
    let mut backoff = Duration::from_secs(1);
    loop {
        if PAUSED.load(Ordering::Relaxed) || !enabled(&app) {
            seen = Seen::default();
            publish(&app, &Update::quiet());
            WAKE.notified().await;
            continue;
        }
        let Some(cfg) = load_config() else {
            publish(&app, &Update::failed());
            WAKE.notified().await;
            continue;
        };
        let started = Instant::now();
        let result = tokio::select! {
            biased;
            _ = WAKE.notified() => Ok(()),
            result = connect_and_serve(&app, &cfg, &mut seen) => result,
        };
        if let Err(reason) = result {
            log::line(format!("t3: {reason}"));
            publish(&app, &Update::failed());
            let wait = if started.elapsed() > Duration::from_secs(20) {
                backoff = Duration::from_secs(1);
                Duration::from_secs(1)
            } else {
                let wait = backoff;
                backoff = (backoff * 2).min(Duration::from_secs(30));
                wait
            };
            tokio::select! {
                _ = WAKE.notified() => {}
                _ = tokio::time::sleep(wait) => {}
            }
        }
    }
}

async fn connect_and_serve(
    app: &AppHandle,
    cfg: &Server,
    seen: &mut Seen,
) -> Result<(), &'static str> {
    let http = http_client()?;
    let ticket = match &cfg.token {
        Some(token) => Some(issue_ticket(&http, cfg, token).await?),
        None => None,
    };
    let environment = fetch_environment(&http, cfg).await;
    let socket = connect_socket(cfg, ticket.as_deref()).await?;
    let (tx, rx) = mpsc::unbounded_channel();
    *LIVE.lock().unwrap() = Some(Live {
        tx,
        pending: HashMap::new(),
    });
    let result = serve(app, socket, cfg, environment, rx, seen).await;
    *LIVE.lock().unwrap() = None;
    result
}

fn http_client() -> Result<reqwest::Client, &'static str> {
    // No redirects: a login page must not receive the bearer.
    reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| "unreachable")
}

async fn issue_ticket(
    http: &reqwest::Client,
    cfg: &Server,
    token: &str,
) -> Result<String, &'static str> {
    if !header_safe(token) {
        return Err("auth");
    }
    let mut req = http
        .post(http_url(cfg, "/api/auth/websocket-ticket"))
        .header("Authorization", format!("Bearer {token}"))
        .header("Accept", "application/json");
    req = with_access(req, cfg);
    let response = req.send().await.map_err(|_| "unreachable")?;
    if response.status().as_u16() == 401 || response.status().as_u16() == 403 {
        return Err("auth");
    }
    if !response.status().is_success() {
        return Err("unreachable");
    }
    let body: Value = response.json().await.map_err(|_| "auth")?;
    ticket_of(&body).map(str::to_string).ok_or("auth")
}

async fn fetch_environment(http: &reqwest::Client, cfg: &Server) -> Option<String> {
    let req = with_access(
        http.get(http_url(cfg, "/.well-known/t3/environment"))
            .header("Accept", "application/json"),
        cfg,
    );
    let response = req.send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    environment_id(&response.json().await.ok()?)
}

fn with_access(mut req: reqwest::RequestBuilder, cfg: &Server) -> reqwest::RequestBuilder {
    if let Some(id) = &cfg.cf_id {
        req = req.header("CF-Access-Client-Id", id);
    }
    if let Some(secret) = &cfg.cf_secret {
        req = req.header("CF-Access-Client-Secret", secret);
    }
    req
}

trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}
type Socket = WebSocketStream<Box<dyn Io>>;

fn tls_config() -> std::sync::Arc<ClientConfig> {
    let roots = RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let config =
        ClientConfig::builder_with_provider(std::sync::Arc::new(ring_provider::default_provider()))
            .with_protocol_versions(&[&TLS13, &TLS12])
            .expect("the ring provider supports TLS 1.2 and 1.3")
            .with_root_certificates(roots)
            .with_no_client_auth();
    std::sync::Arc::new(config)
}

async fn connect_socket(cfg: &Server, ticket: Option<&str>) -> Result<Socket, &'static str> {
    let host = cfg.base.host_str().ok_or("unreachable")?.to_string();
    let port = cfg.base.port_or_known_default().ok_or("unreachable")?;
    let tls = cfg.base.scheme() == "https";
    let attempt = async {
        let tcp = TcpStream::connect((host.as_str(), port))
            .await
            .map_err(|_| "unreachable")?;
        let _ = tcp.set_nodelay(true);
        let stream: Box<dyn Io> = if tls {
            let name = ServerName::try_from(host.clone()).map_err(|_| "unreachable")?;
            Box::new(
                TlsConnector::from(tls_config())
                    .connect(name, tcp)
                    .await
                    .map_err(|_| "unreachable")?,
            )
        } else {
            Box::new(tcp)
        };
        let mut request = socket_url(&cfg.base, ticket)
            .into_client_request()
            .map_err(|_| "unreachable")?;
        let headers = request.headers_mut();
        if let Ok(origin) = HeaderValue::from_str(&http_origin(&cfg.base)) {
            headers.insert("Origin", origin);
        }
        insert_header(headers, "CF-Access-Client-Id", cfg.cf_id.as_deref());
        insert_header(headers, "CF-Access-Client-Secret", cfg.cf_secret.as_deref());
        let config = WebSocketConfig::default()
            .max_message_size(Some(16 * 1024 * 1024))
            .max_frame_size(Some(16 * 1024 * 1024));
        match tokio_tungstenite::client_async_with_config(request, stream, Some(config)).await {
            Ok((socket, _)) => Ok(socket),
            Err(tokio_tungstenite::tungstenite::Error::Http(response)) => {
                Err(if matches!(response.status().as_u16(), 401 | 403) {
                    "auth"
                } else {
                    "unreachable"
                })
            }
            Err(_) => Err("unreachable"),
        }
    };
    tokio::time::timeout(Duration::from_secs(15), attempt)
        .await
        .unwrap_or(Err("unreachable"))
}

fn insert_header(
    headers: &mut tokio_tungstenite::tungstenite::http::HeaderMap,
    name: &'static str,
    value: Option<&str>,
) {
    let Some(value) = value else { return };
    if let Ok(parsed) = HeaderValue::from_str(value) {
        headers.insert(name, parsed);
    }
}

async fn serve(
    app: &AppHandle,
    socket: Socket,
    cfg: &Server,
    environment: Option<String>,
    mut decisions: mpsc::UnboundedReceiver<Decision>,
    seen: &mut Seen,
) -> Result<(), &'static str> {
    let (mut write, mut read) = socket.split();
    send(&mut write, &rpc_request(SHELL_ID, SHELL_METHOD, json!({}))).await?;
    let mut session = Session::default();
    let mut ping = tokio::time::interval(Duration::from_secs(20));
    ping.tick().await;
    loop {
        let incoming = tokio::select! {
            message = read.next() => message,
            _ = ping.tick() => {
                send(&mut write, &rpc_ping()).await?;
                continue;
            }
            decision = decisions.recv() => {
                if let Some(decision) = decision {
                    let command = approval_command(
                        &decision.thread_id,
                        &decision.request_id,
                        decision.accept,
                        &rfc3339_now(),
                        &fresh_id("cmd"),
                    );
                    send(&mut write, &rpc_request(&fresh_id("rpc"), DISPATCH_METHOD, command)).await?;
                }
                continue;
            }
        };
        let Some(Ok(message)) = incoming else {
            return Err("unreachable");
        };
        let text = match message {
            Message::Text(text) => text.to_string(),
            Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => continue,
            Message::Close(_) => return Err("unreachable"),
            Message::Binary(_) => continue,
        };
        for frame in decode_messages(&text) {
            let tag = frame.get("_tag").and_then(Value::as_str).unwrap_or("");
            match tag {
                "Pong" => {}
                "Ping" => send(&mut write, &rpc_pong()).await?,
                "Chunk" => {
                    let id = message_id(&frame);
                    if !id.is_empty() {
                        send(&mut write, &rpc_ack(&id)).await?;
                    }
                    let values = chunk_values(&frame);
                    if id == SHELL_ID {
                        for value in values {
                            session.apply_shell(&value);
                        }
                    } else if let Some(thread_id) = id.strip_prefix("thread:") {
                        for value in values {
                            session.apply_thread(thread_id, &value);
                        }
                    }
                    sync_thread_subs(&mut write, &mut session).await?;
                    remember_pending(&session);
                    publish(app, &session.view(&cfg.base, environment.as_deref(), seen));
                }
                "Exit" => {
                    let id = message_id(&frame);
                    if id == SHELL_ID {
                        return Err("protocol");
                    }
                    session
                        .subscribed
                        .remove(&id.trim_start_matches("thread:").to_string());
                }
                "Defect" | "ClientProtocolError" => return Err("protocol"),
                _ => {}
            }
        }
    }
}

async fn send(
    write: &mut (impl Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin),
    frame: &str,
) -> Result<(), &'static str> {
    write
        .send(Message::Text(frame.into()))
        .await
        .map_err(|_| "unreachable")
}

async fn sync_thread_subs(
    write: &mut (impl Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin),
    session: &mut Session,
) -> Result<(), &'static str> {
    let wanted: HashSet<String> = session
        .threads
        .values()
        .filter(|thread| !thread.archived && thread.pending_approval)
        .map(|thread| thread.id.clone())
        .collect();
    let current = session.subscribed.clone();
    for id in current.difference(&wanted) {
        send(write, &rpc_interrupt(&format!("thread:{id}"))).await?;
        session.subscribed.remove(id);
        session.activities.remove(id);
        session.approvals.remove(id);
    }
    for id in wanted.difference(&current) {
        send(
            write,
            &rpc_request(
                &format!("thread:{id}"),
                THREAD_METHOD,
                json!({ "threadId": id }),
            ),
        )
        .await?;
        session.subscribed.insert(id.clone());
    }
    Ok(())
}

fn remember_pending(session: &Session) {
    let pending: HashMap<String, String> = session
        .approvals
        .values()
        .map(|approval| (approval.request_id.clone(), approval.thread_id.clone()))
        .collect();
    if let Some(live) = LIVE.lock().unwrap().as_mut() {
        live.pending = pending;
    }
}

// ── Address ──────────────────────────────────────────────────────────────────

struct Server {
    base: reqwest::Url,
    token: Option<String>,
    cf_id: Option<String>,
    cf_secret: Option<String>,
}

fn load_config() -> Option<Server> {
    let raw = secrets::get(URL_KEY)?;
    let base = parse_server_url(&raw)?;
    let token = secrets::get(TOKEN_KEY).filter(|value| header_safe(value));
    let cf_id = secrets::get(CF_ID_KEY).filter(|value| header_safe(value));
    let cf_secret = secrets::get(CF_SECRET_KEY).filter(|value| header_safe(value));
    // Half a service token cannot pass the proxy, so send neither half.
    let (cf_id, cf_secret) = if cf_id.is_some() && cf_secret.is_some() {
        (cf_id, cf_secret)
    } else {
        (None, None)
    };
    Some(Server {
        base,
        token,
        cf_id,
        cf_secret,
    })
}

fn header_safe(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|byte| (32..127).contains(&byte))
}

fn parse_server_url(input: &str) -> Option<reqwest::Url> {
    let parsed = reqwest::Url::parse(input.trim()).ok()?;
    if !matches!(parsed.scheme(), "http" | "https" | "ws" | "wss") || parsed.host_str().is_none() {
        return None;
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return None;
    }
    let scheme = if matches!(parsed.scheme(), "https" | "wss") {
        "https"
    } else {
        "http"
    };
    reqwest::Url::parse(&format!("{scheme}://{}/", host_port(&parsed))).ok()
}

fn host_port(url: &reqwest::Url) -> String {
    let host = url.host_str().unwrap_or("");
    let host = if host.contains(':') {
        format!("[{host}]")
    } else {
        host.to_string()
    };
    match url.port() {
        Some(port) => format!("{host}:{port}"),
        None => host,
    }
}

fn http_origin(base: &reqwest::Url) -> String {
    format!("{}://{}", base.scheme(), host_port(base))
}

fn http_url(cfg: &Server, path: &str) -> String {
    format!("{}{path}", http_origin(&cfg.base))
}

fn socket_url(base: &reqwest::Url, ticket: Option<&str>) -> String {
    let scheme = if base.scheme() == "https" {
        "wss"
    } else {
        "ws"
    };
    let mut url = format!("{scheme}://{}/ws", host_port(base));
    if let Some(ticket) = ticket {
        url.push_str("?wsTicket=");
        url.push_str(&percent_encode(ticket));
    }
    url
}

fn thread_url(base: &reqwest::Url, environment: Option<&str>, thread_id: &str) -> Option<String> {
    let thread = path_segment(thread_id)?;
    let origin = http_origin(base);
    match environment.and_then(path_segment) {
        Some(environment) => Some(format!("{origin}/{environment}/{thread}")),
        None => Some(origin),
    }
}

fn path_segment(value: &str) -> Option<String> {
    if value.is_empty() {
        return None;
    }
    Some(percent_encode(value))
}

fn percent_encode(value: &str) -> String {
    let mut out = String::new();
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn ticket_of(body: &Value) -> Option<&str> {
    body.get("ticket")
        .and_then(Value::as_str)
        .filter(|ticket| !ticket.is_empty())
}

fn environment_id(body: &Value) -> Option<String> {
    let direct = body
        .get("environmentId")
        .and_then(Value::as_str)
        .or_else(|| body.get("id").and_then(Value::as_str));
    if let Some(id) = direct.filter(|id| !id.is_empty()) {
        return Some(id.to_string());
    }
    body.get("environment")
        .and_then(|environment| environment.get("environmentId"))
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(str::to_string)
}

// ── Effect JSON RPC ──────────────────────────────────────────────────────────

fn fresh_id(prefix: &str) -> String {
    format!("{prefix}-{}", NEXT_ID.fetch_add(1, Ordering::Relaxed))
}

fn rpc_request(id: &str, tag: &str, payload: Value) -> String {
    json!({ "_tag": "Request", "id": id, "tag": tag, "payload": payload, "headers": [] })
        .to_string()
}

fn rpc_ack(id: &str) -> String {
    json!({ "_tag": "Ack", "requestId": id }).to_string()
}

fn rpc_ping() -> String {
    json!({ "_tag": "Ping" }).to_string()
}

fn rpc_pong() -> String {
    json!({ "_tag": "Pong" }).to_string()
}

fn rpc_interrupt(id: &str) -> String {
    json!({ "_tag": "Interrupt", "requestId": id }).to_string()
}

fn approval_command(
    thread_id: &str,
    request_id: &str,
    accept: bool,
    now: &str,
    command_id: &str,
) -> Value {
    json!({
        "type": "thread.approval.respond",
        "commandId": command_id,
        "threadId": thread_id,
        "requestId": request_id,
        "decision": if accept { "accept" } else { "decline" },
        "createdAt": now,
    })
}

fn decode_messages(text: &str) -> Vec<Value> {
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Array(items)) => items,
        Ok(value) => vec![value],
        Err(_) => Vec::new(),
    }
}

fn message_id(frame: &Value) -> String {
    match frame.get("requestId") {
        Some(Value::String(id)) => id.clone(),
        Some(Value::Number(id)) => id.to_string(),
        _ => String::new(),
    }
}

fn chunk_values(frame: &Value) -> Vec<Value> {
    match frame.get("values") {
        Some(Value::Array(values)) => values.clone(),
        Some(value) => vec![value.clone()],
        None => Vec::new(),
    }
}

fn rfc3339_now() -> String {
    let dur = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    rfc3339(dur.as_secs(), dur.subsec_millis())
}

fn rfc3339(secs: u64, millis: u32) -> String {
    let (year, month, day) = civil_from_days((secs / 86_400) as i64);
    let tod = secs % 86_400;
    format!(
        "{year:04}-{month:02}-{day:02}T{hh:02}:{mm:02}:{ss:02}.{millis:03}Z",
        hh = tod / 3600,
        mm = (tod % 3600) / 60,
        ss = tod % 60,
    )
}

/// Howard Hinnant's `civil_from_days`. `days` is the count since 1970-01-01.
fn civil_from_days(days: i64) -> (i32, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { y + 1 } else { y };
    (year as i32, month as u32, day as u32)
}

// ── Shell ────────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Status {
    Idle,
    Running,
    Approval,
    Question,
    Done,
    Error,
}

impl Status {
    fn rank(self) -> u8 {
        match self {
            Status::Approval => 0,
            Status::Question => 1,
            Status::Error => 2,
            Status::Running => 3,
            Status::Done => 4,
            Status::Idle => 5,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Status::Idle => "idle",
            Status::Running => "running",
            Status::Approval => "approval",
            Status::Question => "question",
            Status::Done => "done",
            Status::Error => "error",
        }
    }

    fn pill(self) -> &'static str {
        match self {
            Status::Approval => "approval",
            Status::Question => "question",
            Status::Error => "error",
            Status::Running => "working",
            Status::Done | Status::Idle => "idle",
        }
    }
}

#[derive(Clone, Debug)]
struct Project {
    id: String,
    title: String,
}

#[derive(Clone, Debug)]
struct Thread {
    id: String,
    project_id: String,
    title: String,
    updated_at: String,
    archived: bool,
    session_status: String,
    turn_state: String,
    pending_approval: bool,
    pending_input: bool,
}

impl Thread {
    fn status(&self) -> Status {
        if self.pending_approval {
            Status::Approval
        } else if self.pending_input {
            Status::Question
        } else if self.session_status == "error" || self.turn_state == "error" {
            Status::Error
        } else if self.session_status == "running"
            || self.session_status == "starting"
            || self.turn_state == "running"
        {
            Status::Running
        } else if self.turn_state == "completed" {
            Status::Done
        } else {
            Status::Idle
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Approval {
    request_id: String,
    thread_id: String,
    summary: String,
    detail: String,
    created_at: String,
}

#[derive(Default)]
struct Seen {
    approvals: HashSet<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum AlertKind {
    Approval,
    Question,
    Error,
    Finished,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Alert {
    kind: AlertKind,
    label: String,
}

#[derive(Default)]
struct Session {
    projects: HashMap<String, Project>,
    threads: HashMap<String, Thread>,
    activities: HashMap<String, Vec<Value>>,
    approvals: HashMap<String, Approval>,
    subscribed: HashSet<String>,
    previous: HashMap<String, Status>,
}

impl Session {
    fn apply_shell(&mut self, item: &Value) {
        match item.get("kind").and_then(Value::as_str) {
            Some("snapshot") => {
                self.projects.clear();
                self.threads.clear();
                let Some(snapshot) = item.get("snapshot") else {
                    return;
                };
                for project in snapshot
                    .get("projects")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                {
                    if let Some(project) = parse_project(project) {
                        self.projects.insert(project.id.clone(), project);
                    }
                }
                for thread in snapshot
                    .get("threads")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                {
                    if let Some(thread) = parse_thread(thread) {
                        self.threads.insert(thread.id.clone(), thread);
                    }
                }
            }
            Some("project-upserted") => {
                if let Some(project) = item.get("project").and_then(parse_project) {
                    self.projects.insert(project.id.clone(), project);
                }
            }
            Some("project-removed") => {
                if let Some(id) = item.get("projectId").and_then(Value::as_str) {
                    self.projects.remove(id);
                    self.threads.retain(|_, thread| thread.project_id != id);
                }
            }
            Some("thread-upserted") => {
                if let Some(thread) = item.get("thread").and_then(parse_thread) {
                    self.threads.insert(thread.id.clone(), thread);
                }
            }
            Some("thread-removed") => {
                if let Some(id) = item.get("threadId").and_then(Value::as_str) {
                    self.threads.remove(id);
                    self.activities.remove(id);
                    self.approvals.remove(id);
                }
            }
            _ => {}
        }
        self.drop_settled_approvals();
    }

    fn apply_thread(&mut self, thread_id: &str, item: &Value) {
        match item.get("kind").and_then(Value::as_str) {
            Some("snapshot") => {
                let activities = item
                    .pointer("/snapshot/thread/activities")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                self.activities.insert(thread_id.to_string(), activities);
            }
            Some("event") => {
                let event = item.get("event");
                if event
                    .and_then(|event| event.get("type"))
                    .and_then(Value::as_str)
                    == Some("thread.activity-appended")
                {
                    if let Some(activity) = event
                        .and_then(|event| event.pointer("/payload/activity"))
                        .cloned()
                    {
                        let list = self.activities.entry(thread_id.to_string()).or_default();
                        list.push(activity);
                        if list.len() > 300 {
                            let extra = list.len() - 300;
                            list.drain(0..extra);
                        }
                    }
                }
            }
            _ => {}
        }
        if let Some(activities) = self.activities.get(thread_id) {
            if let Some(approval) = derive_approval(thread_id, activities) {
                self.approvals.insert(thread_id.to_string(), approval);
            } else {
                self.approvals.remove(thread_id);
            }
        }
    }

    fn drop_settled_approvals(&mut self) {
        self.approvals.retain(|id, _| {
            self.threads
                .get(id)
                .is_some_and(|thread| !thread.archived && thread.pending_approval)
        });
    }

    fn view(&mut self, base: &reqwest::Url, environment: Option<&str>, seen: &mut Seen) -> Update {
        let alerts = self.take_alerts(seen);
        let mut projects: Vec<ProjectOut> = self
            .projects
            .values()
            .map(|project| {
                let mut threads: Vec<&Thread> = self
                    .threads
                    .values()
                    .filter(|thread| thread.project_id == project.id && !thread.archived)
                    .collect();
                threads.sort_by(|a, b| {
                    a.status()
                        .rank()
                        .cmp(&b.status().rank())
                        .then(b.updated_at.cmp(&a.updated_at))
                        .then(a.title.cmp(&b.title))
                });
                ProjectOut {
                    id: project.id.clone(),
                    title: project.title.clone(),
                    threads: threads
                        .into_iter()
                        .map(|thread| ThreadOut {
                            id: thread.id.clone(),
                            title: thread.title.clone(),
                            status: thread.status().as_str(),
                            url: thread_url(base, environment, &thread.id).unwrap_or_default(),
                        })
                        .collect(),
                }
            })
            .filter(|project| !project.threads.is_empty())
            .collect();
        projects.sort_by(|a, b| {
            a.title
                .to_lowercase()
                .cmp(&b.title.to_lowercase())
                .then(a.id.cmp(&b.id))
        });

        let urgent = projects
            .iter()
            .flat_map(|project| project.threads.iter().map(move |thread| (project, thread)))
            .min_by_key(|(_, thread)| status_rank(thread.status));
        let (pill_state, label) = match urgent {
            Some((project, thread)) => {
                let state = match thread.status {
                    "approval" => Status::Approval,
                    "question" => Status::Question,
                    "error" => Status::Error,
                    "running" => Status::Running,
                    "done" => Status::Done,
                    _ => Status::Idle,
                };
                (
                    state.pill(),
                    format!("{} · {}", project.title, thread.title),
                )
            }
            None => ("idle", String::new()),
        };
        let approval = self
            .approvals
            .values()
            .min_by(|a, b| a.created_at.cmp(&b.created_at))
            .map(|approval| ApprovalOut {
                request_id: approval.request_id.clone(),
                thread_id: approval.thread_id.clone(),
                summary: approval.summary.clone(),
                detail: if approval.detail.is_empty() {
                    approval.summary.clone()
                } else {
                    approval.detail.clone()
                },
            });
        Update {
            connected: true,
            error: None,
            base_url: http_origin(base),
            projects,
            pill: PillOut {
                state: pill_state,
                label,
            },
            alerts: alerts
                .into_iter()
                .map(|alert| AlertOut {
                    kind: match alert.kind {
                        AlertKind::Approval => "approval",
                        AlertKind::Question => "question",
                        AlertKind::Error => "error",
                        AlertKind::Finished => "finished",
                    },
                    label: alert.label,
                })
                .collect(),
            approval,
        }
    }

    fn take_alerts(&mut self, seen: &mut Seen) -> Vec<Alert> {
        let mut alerts = Vec::new();
        let mut next = HashMap::new();
        for thread in self.threads.values().filter(|thread| !thread.archived) {
            let status = thread.status();
            let before = self.previous.get(&thread.id).copied();
            next.insert(thread.id.clone(), status);
            let label = self.label_of(thread);
            if let Some(approval) = self.approvals.get(&thread.id) {
                if seen.approvals.insert(approval.request_id.clone()) {
                    alerts.push(Alert {
                        kind: AlertKind::Approval,
                        label: label.clone(),
                    });
                }
            }
            // The first time a thread is seen is the baseline. A finish, an error
            // or a question only rings when it changes after that.
            if before == Some(Status::Running) && status == Status::Done {
                alerts.push(Alert {
                    kind: AlertKind::Finished,
                    label: label.clone(),
                });
            } else if before.is_some() && before != Some(Status::Error) && status == Status::Error {
                alerts.push(Alert {
                    kind: AlertKind::Error,
                    label: label.clone(),
                });
            } else if before.is_some()
                && before != Some(Status::Question)
                && status == Status::Question
            {
                alerts.push(Alert {
                    kind: AlertKind::Question,
                    label,
                });
            }
        }
        // A request that is no longer waiting may be asked again later.
        let open: HashSet<&str> = self
            .approvals
            .values()
            .map(|approval| approval.request_id.as_str())
            .collect();
        seen.approvals.retain(|id| open.contains(id.as_str()));
        self.previous = next;
        alerts
    }

    fn label_of(&self, thread: &Thread) -> String {
        let project = self
            .projects
            .get(&thread.project_id)
            .map(|project| project.title.as_str())
            .unwrap_or("");
        if project.is_empty() {
            thread.title.clone()
        } else {
            format!("{project} · {}", thread.title)
        }
    }
}

fn status_rank(status: &str) -> u8 {
    match status {
        "approval" => 0,
        "question" => 1,
        "error" => 2,
        "running" => 3,
        "done" => 4,
        _ => 5,
    }
}

fn parse_project(value: &Value) -> Option<Project> {
    Some(Project {
        id: value.get("id")?.as_str()?.to_string(),
        title: value
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
    })
}

fn parse_thread(value: &Value) -> Option<Thread> {
    Some(Thread {
        id: value.get("id")?.as_str()?.to_string(),
        project_id: value
            .get("projectId")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        title: value
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        updated_at: value
            .get("updatedAt")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        archived: value
            .get("archivedAt")
            .and_then(Value::as_str)
            .is_some_and(|at| !at.is_empty()),
        session_status: value
            .pointer("/session/status")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        turn_state: value
            .pointer("/latestTurn/state")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        pending_approval: value
            .get("hasPendingApprovals")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        pending_input: value
            .get("hasPendingUserInput")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

fn derive_approval(thread_id: &str, activities: &[Value]) -> Option<Approval> {
    let mut ordered: Vec<&Value> = activities.iter().collect();
    ordered.sort_by(|a, b| {
        let seq = |value: &Value| value.get("sequence").and_then(Value::as_u64).unwrap_or(0);
        seq(a).cmp(&seq(b)).then_with(|| {
            let left = a.get("createdAt").and_then(Value::as_str).unwrap_or("");
            let right = b.get("createdAt").and_then(Value::as_str).unwrap_or("");
            left.cmp(right)
        })
    });
    let mut open: Vec<Approval> = Vec::new();
    for activity in ordered {
        let kind = activity.get("kind").and_then(Value::as_str).unwrap_or("");
        let payload = activity.get("payload").filter(|value| value.is_object());
        let request_id = payload
            .and_then(|payload| payload.get("requestId"))
            .and_then(Value::as_str)
            .unwrap_or("");
        if request_id.is_empty() {
            continue;
        }
        if kind == "approval.requested" {
            let detail = payload
                .and_then(|payload| payload.get("detail"))
                .and_then(Value::as_str)
                .unwrap_or("");
            let summary = activity
                .get("summary")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            open.retain(|approval| approval.request_id != request_id);
            open.push(Approval {
                request_id: request_id.to_string(),
                thread_id: thread_id.to_string(),
                summary: if summary.is_empty() {
                    request_kind_label(payload)
                } else {
                    summary
                },
                detail: detail.to_string(),
                created_at: activity
                    .get("createdAt")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string(),
            });
        } else if kind == "approval.resolved"
            || (kind == "provider.approval.respond.failed" && stale_approval(payload))
        {
            open.retain(|approval| approval.request_id != request_id);
        }
    }
    open.into_iter()
        .min_by(|a, b| a.created_at.cmp(&b.created_at))
}

fn request_kind_label(payload: Option<&Value>) -> String {
    let kind = payload
        .and_then(|payload| payload.get("requestKind"))
        .and_then(Value::as_str);
    let request_type = payload
        .and_then(|payload| payload.get("requestType"))
        .and_then(Value::as_str);
    match kind.or(request_type).unwrap_or("") {
        "command"
        | "command_execution_approval"
        | "exec_command_approval"
        | "dynamic_tool_call" => "Command".into(),
        "file-read" | "file_read_approval" => "File read".into(),
        "file-change" | "file_change_approval" | "apply_patch_approval" => "File change".into(),
        other => other.to_string(),
    }
}

fn stale_approval(payload: Option<&Value>) -> bool {
    let detail = payload
        .and_then(|payload| payload.get("detail"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let detail = detail.to_lowercase();
    detail.contains("stale pending approval")
        || detail.contains("unknown pending approval")
        || detail.contains("unknown pending permission")
}

// ── What the island receives ─────────────────────────────────────────────────

#[derive(Serialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Update {
    connected: bool,
    error: Option<String>,
    base_url: String,
    projects: Vec<ProjectOut>,
    pill: PillOut,
    alerts: Vec<AlertOut>,
    approval: Option<ApprovalOut>,
}

#[derive(Serialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
struct ProjectOut {
    id: String,
    title: String,
    threads: Vec<ThreadOut>,
}

#[derive(Serialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
struct ThreadOut {
    id: String,
    title: String,
    status: &'static str,
    url: String,
}

#[derive(Serialize, Clone, PartialEq)]
struct PillOut {
    state: &'static str,
    label: String,
}

#[derive(Serialize, Clone, PartialEq)]
struct AlertOut {
    kind: &'static str,
    label: String,
}

#[derive(Serialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
struct ApprovalOut {
    request_id: String,
    thread_id: String,
    summary: String,
    detail: String,
}

impl Update {
    fn quiet() -> Self {
        Self {
            connected: false,
            error: None,
            base_url: String::new(),
            projects: Vec::new(),
            pill: PillOut {
                state: "idle",
                label: String::new(),
            },
            alerts: Vec::new(),
            approval: None,
        }
    }

    fn failed() -> Self {
        let mut update = Self::quiet();
        update.error = Some(crate::i18n::t("Not connected"));
        update
    }
}

fn publish(app: &AppHandle, update: &Update) {
    let _ = app.emit_to(WINDOW_LABEL, "t3", update);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn url(input: &str) -> reqwest::Url {
        parse_server_url(input).unwrap()
    }

    #[test]
    fn an_http_address_becomes_the_socket_and_drops_the_path() {
        let base = url("http://t3code-home:3773/ignored?token=secret");
        assert_eq!(http_origin(&base), "http://t3code-home:3773");
        assert_eq!(socket_url(&base, None), "ws://t3code-home:3773/ws");
        assert_eq!(
            socket_url(&base, Some("ticket value")),
            "ws://t3code-home:3773/ws?wsTicket=ticket%20value"
        );
        assert!(!socket_url(&base, Some("ticket")).contains("secret"));
    }

    #[test]
    fn https_and_wss_stay_on_the_public_host() {
        let base = url("wss://t3.hoerekind.nl/ws");
        assert_eq!(base.scheme(), "https");
        assert_eq!(
            socket_url(&base, Some("abc")),
            "wss://t3.hoerekind.nl/ws?wsTicket=abc"
        );
        assert_eq!(
            http_url(
                &Server {
                    base: base.clone(),
                    token: None,
                    cf_id: None,
                    cf_secret: None
                },
                "/api/auth/websocket-ticket"
            ),
            "https://t3.hoerekind.nl/api/auth/websocket-ticket"
        );
    }

    #[test]
    fn a_userinfo_or_other_scheme_is_refused() {
        assert!(parse_server_url("http://user:pw@host:3773").is_none());
        assert!(parse_server_url("ftp://host").is_none());
        assert!(parse_server_url("not a url").is_none());
        assert!(parse_server_url("").is_none());
    }

    #[test]
    fn the_request_envelope_is_effect_json() {
        let frame = rpc_request("shell", SHELL_METHOD, json!({}));
        let value: Value = serde_json::from_str(&frame).unwrap();
        assert_eq!(value["_tag"], "Request");
        assert_eq!(value["id"], "shell");
        assert_eq!(value["tag"], SHELL_METHOD);
        assert_eq!(value["payload"], json!({}));
        assert_eq!(value["headers"], json!([]));
        assert_eq!(rpc_ping(), r#"{"_tag":"Ping"}"#);
        assert_eq!(rpc_ack("shell"), r#"{"_tag":"Ack","requestId":"shell"}"#);
    }

    #[test]
    fn approval_is_accept_or_decline() {
        let command = approval_command(
            "thread-1",
            "req-1",
            true,
            "2026-10-21T00:00:00.000Z",
            "cmd-1",
        );
        assert_eq!(command["type"], "thread.approval.respond");
        assert_eq!(command["decision"], "accept");
        assert_eq!(command["threadId"], "thread-1");
        let denied = approval_command(
            "thread-1",
            "req-1",
            false,
            "2026-10-21T00:00:00.000Z",
            "cmd-2",
        );
        assert_eq!(denied["decision"], "decline");
    }

    #[test]
    fn frames_are_one_object_or_a_batch() {
        assert_eq!(decode_messages(r#"{"_tag":"Pong"}"#).len(), 1);
        assert_eq!(
            decode_messages(r#"[{"_tag":"Pong"},{"_tag":"Ping"}]"#).len(),
            2
        );
        assert!(decode_messages("nope").is_empty());
        let chunk = json!({"_tag":"Chunk","requestId":7,"values":[{"kind":"snapshot"}]});
        assert_eq!(message_id(&chunk), "7");
        assert_eq!(chunk_values(&chunk).len(), 1);
    }

    #[test]
    fn the_calendar_knows_leap_days() {
        assert_eq!(rfc3339(0, 0), "1970-01-01T00:00:00.000Z");
        assert_eq!(rfc3339(86_400, 0), "1970-01-02T00:00:00.000Z");
        assert_eq!(rfc3339(946_684_800, 0), "2000-01-01T00:00:00.000Z");
        assert_eq!(rfc3339(1_582_934_400, 0), "2020-02-29T00:00:00.000Z");
    }

    fn shell_snapshot() -> Value {
        json!({
            "kind": "snapshot",
            "snapshot": {
                "projects": [
                    {"id": "p1", "title": "Coucou"},
                    {"id": "p2", "title": "Notes"}
                ],
                "threads": [
                    thread("t1", "p1", "Fix the build", "running", "running", false, false, None, "2026-10-21T01:00:00.000Z"),
                    thread("t2", "p1", "Old", "ready", "completed", false, false, Some("2026-10-20T00:00:00.000Z"), "2026-10-20T00:00:00.000Z"),
                    thread("t3", "p2", "Wait", "running", "running", true, false, None, "2026-10-21T02:00:00.000Z")
                ]
            }
        })
    }

    fn thread(
        id: &str,
        project: &str,
        title: &str,
        session: &str,
        turn: &str,
        approval: bool,
        input: bool,
        archived: Option<&str>,
        updated: &str,
    ) -> Value {
        json!({
            "id": id,
            "projectId": project,
            "title": title,
            "updatedAt": updated,
            "archivedAt": archived,
            "session": {"status": session},
            "latestTurn": {"state": turn},
            "hasPendingApprovals": approval,
            "hasPendingUserInput": input
        })
    }

    #[test]
    fn a_snapshot_groups_threads_and_hides_archived_ones() {
        let mut session = Session::default();
        let mut seen = Seen::default();
        session.apply_shell(&shell_snapshot());
        let base = url("https://t3.hoerekind.nl");
        let view = session.view(&base, Some("env 1"), &mut seen);
        assert!(view.connected);
        assert_eq!(view.projects.len(), 2);
        // Approval outranks a running thread, so the pill waits.
        assert_eq!(view.pill.state, "approval");
        assert!(view.alerts.is_empty());
        let coucou = view
            .projects
            .iter()
            .find(|project| project.title == "Coucou")
            .unwrap();
        assert_eq!(coucou.threads.len(), 1);
        assert_eq!(coucou.threads[0].status, "running");
        assert!(coucou.threads.iter().all(|thread| thread.title != "Old"));
        let notes = view
            .projects
            .iter()
            .find(|project| project.title == "Notes")
            .unwrap();
        assert_eq!(notes.threads[0].url, "https://t3.hoerekind.nl/env%201/t3");
        // Already finished, already in error: the first look stays quiet.
        session.apply_shell(&json!({
            "kind": "thread-upserted",
            "thread": thread("t4", "p1", "Broken", "error", "error", false, false, None, "2026-10-21T03:00:00.000Z")
        }));
        let again = session.view(&base, Some("env 1"), &mut seen);
        assert!(again.alerts.is_empty());
    }

    #[test]
    fn status_follows_the_shell_flags() {
        let running = parse_thread(&thread(
            "t", "p", "A", "running", "running", false, false, None, "",
        ))
        .unwrap();
        assert_eq!(running.status(), Status::Running);
        let waiting = parse_thread(&thread(
            "t", "p", "A", "running", "running", true, false, None, "",
        ))
        .unwrap();
        assert_eq!(waiting.status(), Status::Approval);
        let question = parse_thread(&thread(
            "t",
            "p",
            "A",
            "ready",
            "completed",
            false,
            true,
            None,
            "",
        ))
        .unwrap();
        assert_eq!(question.status(), Status::Question);
        let failed = parse_thread(&thread(
            "t", "p", "A", "error", "error", false, false, None, "",
        ))
        .unwrap();
        assert_eq!(failed.status(), Status::Error);
        let done = parse_thread(&thread(
            "t",
            "p",
            "A",
            "ready",
            "completed",
            false,
            false,
            None,
            "",
        ))
        .unwrap();
        assert_eq!(done.status(), Status::Done);
        let idle =
            parse_thread(&thread("t", "p", "A", "idle", "", false, false, None, "")).unwrap();
        assert_eq!(idle.status(), Status::Idle);
    }

    #[test]
    fn upsert_and_remove_keep_the_shell() {
        let mut session = Session::default();
        session.apply_shell(&shell_snapshot());
        session.apply_shell(&json!({
            "kind": "thread-upserted",
            "thread": thread("t1", "p1", "Fix the build", "ready", "completed", false, false, None, "2026-10-21T03:00:00.000Z")
        }));
        assert_eq!(session.threads["t1"].status(), Status::Done);
        session.apply_shell(&json!({"kind": "thread-removed", "threadId": "t3"}));
        assert!(!session.threads.contains_key("t3"));
        session.apply_shell(&json!({"kind": "project-removed", "projectId": "p1"}));
        assert!(!session.projects.contains_key("p1"));
        assert!(!session.threads.contains_key("t1"));
    }

    #[test]
    fn activities_open_and_close_an_approval() {
        let activities = vec![
            json!({"kind": "approval.requested", "summary": "Run tests", "createdAt": "2026-10-21T00:00:00.000Z", "sequence": 2,
                "payload": {"requestId": "req-1", "requestKind": "command", "detail": "npm test"}}),
            json!({"kind": "approval.requested", "summary": "Earlier", "createdAt": "2026-10-21T00:00:01.000Z", "sequence": 1,
                "payload": {"requestId": "req-0", "detail": "rm -rf /"}}),
            json!({"kind": "approval.resolved", "summary": "Resolved", "createdAt": "2026-10-21T00:00:02.000Z", "sequence": 3,
                "payload": {"requestId": "req-0"}}),
        ];
        let approval = derive_approval("t3", &activities).unwrap();
        assert_eq!(approval.request_id, "req-1");
        assert_eq!(approval.detail, "npm test");
        assert_eq!(approval.summary, "Run tests");
        let stale = vec![
            activities[0].clone(),
            json!({"kind": "provider.approval.respond.failed", "sequence": 4, "payload": {"requestId": "req-1", "detail": "unknown pending approval request"}}),
        ];
        assert!(derive_approval("t3", &stale).is_none());
    }

    #[test]
    fn a_new_approval_sounds_once_and_a_finish_sounds_after_the_first_look() {
        let mut session = Session::default();
        let mut seen = Seen::default();
        let base = url("http://t3code-home:3773");
        session.apply_shell(&shell_snapshot());
        // No request id yet: the pill waits, and nothing rings.
        let first = session.view(&base, None, &mut seen);
        assert!(first.alerts.is_empty());
        assert_eq!(first.pill.state, "approval");
        session.apply_thread("t3", &json!({
            "kind": "snapshot",
            "snapshot": {"thread": {"activities": [{
                "kind": "approval.requested", "summary": "Run tests", "createdAt": "2026-10-21T02:00:00.000Z",
                "payload": {"requestId": "req-1", "detail": "npm test"}
            }]}}
        }));
        let second = session.view(&base, None, &mut seen);
        assert_eq!(second.alerts.len(), 1);
        assert_eq!(second.alerts[0].kind, "approval");
        assert_eq!(second.approval.as_ref().unwrap().request_id, "req-1");
        assert_eq!(second.approval.as_ref().unwrap().detail, "npm test");
        // The same request does not ring again.
        let third = session.view(&base, None, &mut seen);
        assert!(third.alerts.is_empty());
        // The running thread finishes.
        session.apply_shell(&json!({
            "kind": "thread-upserted",
            "thread": thread("t1", "p1", "Fix the build", "ready", "completed", false, false, None, "2026-10-21T04:00:00.000Z")
        }));
        let finished = session.view(&base, None, &mut seen);
        assert!(finished
            .alerts
            .iter()
            .any(|alert| alert.kind == "finished" && alert.label.contains("Fix the build")));
    }

    #[test]
    fn a_thread_link_cannot_leave_the_server() {
        let base = url("https://t3.hoerekind.nl");
        assert_eq!(
            thread_url(&base, Some("env"), "thread"),
            Some("https://t3.hoerekind.nl/env/thread".into())
        );
        assert_eq!(
            thread_url(&base, Some("env"), "https://evil.example"),
            Some("https://t3.hoerekind.nl/env/https%3A%2F%2Fevil.example".into())
        );
        assert_eq!(
            thread_url(&base, None, "thread"),
            Some("https://t3.hoerekind.nl".into())
        );
    }

    #[test]
    fn the_ticket_is_the_field_the_client_reads() {
        assert_eq!(ticket_of(&json!({"ticket": "abc"})), Some("abc"));
        assert_eq!(ticket_of(&json!({"token": "nope"})), None);
        assert_eq!(
            environment_id(&json!({"environmentId": "env-1"})).as_deref(),
            Some("env-1")
        );
        assert_eq!(
            environment_id(&json!({"environment": {"environmentId": "env-2"}})).as_deref(),
            Some("env-2")
        );
    }
}
