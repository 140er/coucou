// T3 Code (https://github.com/pingdotgg/t3code) as a live source.
//
// The web client does not scrape HTML. It opens the server's WebSocket at `/ws`
// and speaks Effect 4's JSON RPC (`RpcSerialization.layerJson`): one JSON object
// per frame, tagged `_tag`. The query `orchestrationProtocol=2` is required;
// without it the upgrade is rejected with 426. `orchestration.subscribeShell`
// streams orchestration protocol v2 (`snapshot`, `project.updated`,
// `thread.updated`, …). A thread waiting on an approval is opened with
// `orchestration.subscribeThread`, and Allow / Deny is
// `orchestration.dispatchCommand` of `runtime-request.respond`.
//
// A bearer session never sits in the socket URL. It is exchanged for a
// short-lived `wsTicket` (`POST /api/auth/websocket-ticket`), the same way the
// T3 client does it. Cloudflare Access service-token headers, when the user
// saved them, go on that request and on the upgrade. Nothing here is logged
// except a fixed reason.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

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
        .filter(|thread| !thread.archived && thread.pending_is_approval())
        .map(|thread| thread.id.clone())
        .collect();
    let current = session.subscribed.clone();
    for id in current.difference(&wanted) {
        send(write, &rpc_interrupt(&format!("thread:{id}"))).await?;
        session.subscribed.remove(id);
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
    // v2 servers reject a socket that does not name the protocol (HTTP 426).
    let mut url = format!("{scheme}://{}/ws?orchestrationProtocol=2", host_port(base));
    if let Some(ticket) = ticket {
        url.push_str("&wsTicket=");
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

fn approval_command(thread_id: &str, request_id: &str, accept: bool, command_id: &str) -> Value {
    // OrchestrationV2Command. `thread.approval.respond` is not a v2 command.
    json!({
        "type": "runtime-request.respond",
        "commandId": command_id,
        "threadId": thread_id,
        "requestId": request_id,
        "decision": if accept { "accept" } else { "decline" },
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
    /// Archived or deleted shells stay out of the list.
    archived: bool,
    /// `activityRunStatus` when the server sent one, otherwise `status`.
    run_status: String,
    pending_kind: String,
    pending_request_id: String,
    pending_created_at: String,
    /// Absent on older v2 servers, and true when the field is missing.
    pending_blocking: bool,
    last_error: String,
}

impl Thread {
    /// `user_input` is a question. `auth_refresh` is not an Allow / Deny: the
    /// run status shows through and the thread opens in the browser. Every
    /// other pending kind is an approval.
    fn pending_is_approval(&self) -> bool {
        !self.pending_request_id.is_empty()
            && !self.pending_kind.is_empty()
            && self.pending_kind != "user_input"
            && self.pending_kind != "auth_refresh"
    }

    fn pending_is_question(&self) -> bool {
        if self.pending_kind != "user_input" || self.pending_request_id.is_empty() {
            return false;
        }
        // A non-blocking question lets the run keep working.
        let live = matches!(
            self.run_status.as_str(),
            "preparing" | "starting" | "running"
        );
        self.pending_blocking || !live
    }

    fn status(&self) -> Status {
        if self.pending_is_approval() {
            return Status::Approval;
        }
        if self.pending_is_question() {
            return Status::Question;
        }
        if self.run_status == "failed" || self.stuck_error() {
            return Status::Error;
        }
        match self.run_status.as_str() {
            "preparing" | "queued" | "starting" | "running" | "waiting" => Status::Running,
            "completed" => Status::Done,
            _ => Status::Idle,
        }
    }

    fn stuck_error(&self) -> bool {
        !self.last_error.is_empty()
            && !matches!(
                self.run_status.as_str(),
                "preparing"
                    | "queued"
                    | "starting"
                    | "running"
                    | "waiting"
                    | "completed"
                    | "failed"
            )
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
    /// thread id → request id → prompt, from the thread projection.
    prompts: HashMap<String, HashMap<String, String>>,
    approvals: HashMap<String, Approval>,
    subscribed: HashSet<String>,
    previous: HashMap<String, Status>,
}

impl Session {
    fn apply_shell(&mut self, item: &Value) {
        match item.get("kind").and_then(Value::as_str) {
            Some("snapshot") => self.apply_snapshot(item),
            Some("synchronized") => {}
            Some("project.updated") => {
                if let Some(project) = item.get("project").and_then(parse_project) {
                    self.projects.insert(project.id.clone(), project);
                }
            }
            Some("project.removed") => {
                if let Some(id) = item.get("projectId").and_then(Value::as_str) {
                    self.projects.remove(id);
                    self.threads.retain(|_, thread| thread.project_id != id);
                }
            }
            Some("thread.updated") => {
                let location = item
                    .get("location")
                    .and_then(Value::as_str)
                    .unwrap_or("active");
                let id = item
                    .pointer("/thread/id")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                // Archive is the archived list. It leaves the live shell.
                if location == "archive" {
                    if !id.is_empty() {
                        self.threads.remove(id);
                    }
                } else if let Some(thread) = item.get("thread").and_then(parse_thread) {
                    if thread.archived {
                        self.threads.remove(&thread.id);
                    } else {
                        self.threads.insert(thread.id.clone(), thread);
                    }
                }
            }
            Some("thread.removed") => {
                if let Some(id) = item.get("threadId").and_then(Value::as_str) {
                    self.threads.remove(id);
                }
            }
            _ => {}
        }
        self.refresh_approvals();
    }

    /// A full snapshot replaces projects and threads. A project-metadata
    /// refresh (`resolvedRepositoryIdentityRoots`, or `threads: []` after we
    /// already have threads) must not wipe the thread list. The server sends
    /// that empty list within seconds of connect.
    fn apply_snapshot(&mut self, item: &Value) {
        let Some(snapshot) = item.get("snapshot") else {
            return;
        };
        let threads = snapshot.get("threads").and_then(Value::as_array);
        let archived = snapshot.get("archivedThreads").and_then(Value::as_array);
        let metadata = item.get("resolvedRepositoryIdentityRoots").is_some();
        let has_projects = snapshot
            .get("projects")
            .and_then(Value::as_array)
            .is_some_and(|projects| !projects.is_empty());
        let projects_only = metadata
            || (has_projects
                && threads.is_some_and(|threads| threads.is_empty())
                && archived.is_none_or(|archived| archived.is_empty())
                && !self.threads.is_empty());

        if metadata {
            for project in array_of(snapshot, "projects") {
                if let Some(project) = parse_project(project) {
                    self.projects.insert(project.id.clone(), project);
                }
            }
        } else {
            self.projects.clear();
            for project in array_of(snapshot, "projects") {
                if let Some(project) = parse_project(project) {
                    self.projects.insert(project.id.clone(), project);
                }
            }
        }
        if projects_only {
            return;
        }
        self.threads.clear();
        for thread in threads.into_iter().flatten() {
            if let Some(thread) = parse_thread(thread) {
                if !thread.archived {
                    self.threads.insert(thread.id.clone(), thread);
                }
            }
        }
    }

    fn apply_thread(&mut self, thread_id: &str, item: &Value) {
        match item.get("kind").and_then(Value::as_str) {
            Some("snapshot") => {
                let projection = item
                    .get("projection")
                    .or_else(|| item.pointer("/snapshot/projection"));
                if let Some(projection) = projection {
                    self.prompts
                        .insert(thread_id.to_string(), prompts_in(projection));
                }
            }
            Some("event") => {
                let Some(event) = item.get("event") else {
                    return;
                };
                let kind = event.get("type").and_then(Value::as_str).unwrap_or("");
                if kind == "turn-item.updated" || kind == "runtime-request.updated" {
                    if let Some(payload) = event.get("payload") {
                        let found = prompts_in(payload);
                        if !found.is_empty() {
                            self.prompts
                                .entry(thread_id.to_string())
                                .or_default()
                                .extend(found);
                        }
                    }
                }
            }
            _ => {}
        }
        self.refresh_approvals();
    }

    /// The shell's `pendingRuntimeRequest` decides that an approval is open.
    /// The thread projection only fills in the prompt.
    fn refresh_approvals(&mut self) {
        let mut next = HashMap::new();
        for thread in self.threads.values() {
            if thread.archived || !thread.pending_is_approval() {
                continue;
            }
            let prompt = self
                .prompts
                .get(&thread.id)
                .and_then(|prompts| prompts.get(&thread.pending_request_id))
                .cloned()
                .unwrap_or_default();
            next.insert(
                thread.id.clone(),
                Approval {
                    request_id: thread.pending_request_id.clone(),
                    thread_id: thread.id.clone(),
                    summary: kind_label(&thread.pending_kind),
                    detail: prompt,
                    created_at: thread.pending_created_at.clone(),
                },
            );
        }
        self.approvals = next;
        self.prompts.retain(|id, _| self.threads.contains_key(id));
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

fn array_of<'a>(value: &'a Value, key: &str) -> impl Iterator<Item = &'a Value> {
    value
        .get(key)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
}

fn timestamp_set(value: &Value, key: &str) -> bool {
    value
        .get(key)
        .and_then(Value::as_str)
        .is_some_and(|at| !at.is_empty())
}

fn parse_thread(value: &Value) -> Option<Thread> {
    let pending = value
        .get("pendingRuntimeRequest")
        .filter(|pending| !pending.is_null());
    let activity = value
        .get("activityRunStatus")
        .and_then(Value::as_str)
        .filter(|status| !status.is_empty());
    let run_status = activity
        .or_else(|| value.get("status").and_then(Value::as_str))
        .unwrap_or("")
        .to_string();
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
        archived: timestamp_set(value, "archivedAt") || timestamp_set(value, "deletedAt"),
        run_status,
        pending_kind: pending
            .and_then(|pending| pending.get("kind"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        pending_request_id: pending
            .and_then(|pending| pending.get("id"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        pending_created_at: pending
            .and_then(|pending| pending.get("createdAt"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        pending_blocking: pending
            .and_then(|pending| pending.get("blocking"))
            .and_then(Value::as_bool)
            .unwrap_or(true),
        last_error: value
            .get("lastError")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
    })
}

/// Prompts live on `approval_request` turn items. A runtime request can also
/// carry `prompt` or `detail` next to its id.
fn prompts_in(value: &Value) -> HashMap<String, String> {
    let mut found = HashMap::new();
    collect_prompts(value, &mut found);
    found
}

fn collect_prompts(value: &Value, found: &mut HashMap<String, String>) {
    let item = value.get("item").unwrap_or(value);
    if item.get("type").and_then(Value::as_str) == Some("approval_request") {
        if let Some(id) = item.get("requestId").and_then(Value::as_str) {
            if let Some(prompt) = text_field(item, &["prompt"]) {
                found.entry(id.to_string()).or_insert(prompt);
            }
        }
    }
    if value.get("kind").is_some() {
        if let Some(id) = value.get("id").and_then(Value::as_str) {
            if let Some(text) = text_field(value, &["prompt", "detail", "summary"]) {
                found.entry(id.to_string()).or_insert(text);
            }
        }
    }
    for key in ["turnItems", "visibleTurnItems", "runtimeRequests"] {
        for child in array_of(value, key) {
            collect_prompts(child, found);
        }
    }
}

fn text_field(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        value
            .get(*key)
            .and_then(Value::as_str)
            .filter(|text| !text.is_empty())
            .map(str::to_string)
    })
}

fn kind_label(kind: &str) -> String {
    match kind {
        "command" | "dynamic_tool_call" => "Command".into(),
        "file-read" => "File read".into(),
        "file-change" => "File change".into(),
        "mcp-elicitation" => "MCP".into(),
        "permission" => "Permission".into(),
        other => other.to_string(),
    }
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
        assert_eq!(
            socket_url(&base, None),
            "ws://t3code-home:3773/ws?orchestrationProtocol=2"
        );
        assert_eq!(
            socket_url(&base, Some("ticket value")),
            "ws://t3code-home:3773/ws?orchestrationProtocol=2&wsTicket=ticket%20value"
        );
        assert!(!socket_url(&base, Some("ticket")).contains("secret"));
    }

    #[test]
    fn https_and_wss_stay_on_the_public_host() {
        let base = url("wss://t3.hoerekind.nl/ws");
        assert_eq!(base.scheme(), "https");
        assert_eq!(
            socket_url(&base, Some("abc")),
            "wss://t3.hoerekind.nl/ws?orchestrationProtocol=2&wsTicket=abc"
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
        let command = approval_command("thread-1", "req-1", true, "cmd-1");
        assert_eq!(command["type"], "runtime-request.respond");
        assert_eq!(command["decision"], "accept");
        assert_eq!(command["threadId"], "thread-1");
        assert_eq!(command["requestId"], "req-1");
        assert!(command.get("createdAt").is_none());
        let denied = approval_command("thread-1", "req-1", false, "cmd-2");
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

    fn pending(id: &str, kind: &str) -> Value {
        json!({
            "id": id,
            "kind": kind,
            "createdAt": "2026-10-21T02:00:00.000Z"
        })
    }

    fn shell_snapshot() -> Value {
        json!({
            "kind": "snapshot",
            "snapshot": {
                "schemaVersion": 2,
                "snapshotSequence": 3,
                "projects": [
                    {"id": "p1", "title": "Coucou"},
                    {"id": "p2", "title": "Notes"}
                ],
                "threads": [
                    thread("t1", "p1", "Fix the build", "running", Value::Null, None, None, "2026-10-21T01:00:00.000Z"),
                    thread("t2", "p1", "Old", "completed", Value::Null, Some("2026-10-20T00:00:00.000Z"), None, "2026-10-20T00:00:00.000Z"),
                    thread("t3", "p2", "Wait", "running", pending("req-1", "command"), None, None, "2026-10-21T02:00:00.000Z"),
                    thread("t5", "p1", "Gone", "running", Value::Null, None, Some("2026-10-21T02:30:00.000Z"), "2026-10-21T02:30:00.000Z")
                ],
                "archivedThreads": []
            }
        })
    }

    /// One orchestration v2 thread shell. `pending` is the `pendingRuntimeRequest` object, or null.
    fn thread(
        id: &str,
        project: &str,
        title: &str,
        status: &str,
        pending: Value,
        archived: Option<&str>,
        deleted: Option<&str>,
        updated: &str,
    ) -> Value {
        json!({
            "id": id,
            "projectId": project,
            "title": title,
            "status": status,
            "updatedAt": updated,
            "archivedAt": archived,
            "deletedAt": deleted,
            "pendingRuntimeRequest": pending,
            "lastError": null
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
        // The request id is on the shell, so the first look rings once.
        assert_eq!(view.alerts.len(), 1);
        assert_eq!(view.alerts[0].kind, "approval");
        let coucou = view
            .projects
            .iter()
            .find(|project| project.title == "Coucou")
            .unwrap();
        assert_eq!(coucou.threads.len(), 1);
        assert_eq!(coucou.threads[0].status, "running");
        assert!(coucou.threads.iter().all(|thread| thread.title != "Old"));
        assert!(coucou.threads.iter().all(|thread| thread.title != "Gone"));
        let notes = view
            .projects
            .iter()
            .find(|project| project.title == "Notes")
            .unwrap();
        assert_eq!(notes.threads[0].url, "https://t3.hoerekind.nl/env%201/t3");
        // Already failed when it first appears: stay quiet.
        session.apply_shell(&json!({
            "kind": "thread.updated",
            "sequence": 4,
            "location": "active",
            "thread": thread("t4", "p1", "Broken", "failed", Value::Null, None, None, "2026-10-21T03:00:00.000Z")
        }));
        let again = session.view(&base, Some("env 1"), &mut seen);
        assert!(again.alerts.is_empty());
    }

    #[test]
    fn a_project_only_snapshot_keeps_the_threads() {
        let mut session = Session::default();
        session.apply_shell(&shell_snapshot());
        session.apply_shell(&json!({
            "kind": "snapshot",
            "resolvedRepositoryIdentityRoots": ["/work/coucou"],
            "snapshot": {
                "schemaVersion": 2,
                "snapshotSequence": 4,
                "projects": [{"id": "p1", "title": "Coucou renamed"}],
                "threads": [],
                "archivedThreads": []
            }
        }));
        assert_eq!(session.projects["p1"].title, "Coucou renamed");
        assert!(session.projects.contains_key("p2"));
        assert!(session.threads.contains_key("t1"));
        assert_eq!(session.threads["t3"].status(), Status::Approval);

        // The resume path can send the same empty thread list without the roots field.
        session.apply_shell(&json!({
            "kind": "snapshot",
            "snapshot": {
                "projects": [
                    {"id": "p1", "title": "Coucou"},
                    {"id": "p2", "title": "Notes"}
                ],
                "threads": [],
                "archivedThreads": []
            }
        }));
        assert!(session.threads.contains_key("t3"));
        assert_eq!(session.projects["p1"].title, "Coucou");
    }

    #[test]
    fn status_follows_the_v2_shell() {
        let running = parse_thread(&thread(
            "t",
            "p",
            "A",
            "running",
            Value::Null,
            None,
            None,
            "",
        ))
        .unwrap();
        assert_eq!(running.status(), Status::Running);
        for status in ["preparing", "queued", "starting", "waiting"] {
            let thread =
                parse_thread(&thread("t", "p", "A", status, Value::Null, None, None, "")).unwrap();
            assert_eq!(thread.status(), Status::Running, "{status}");
        }
        let waiting = parse_thread(&thread(
            "t",
            "p",
            "A",
            "running",
            pending("req-1", "file-read"),
            None,
            None,
            "",
        ))
        .unwrap();
        assert_eq!(waiting.status(), Status::Approval);
        let question = parse_thread(&thread(
            "t",
            "p",
            "A",
            "waiting",
            pending("req-2", "user_input"),
            None,
            None,
            "",
        ))
        .unwrap();
        assert_eq!(question.status(), Status::Question);
        let mut background = thread(
            "t",
            "p",
            "A",
            "running",
            pending("req-3", "user_input"),
            None,
            None,
            "",
        );
        background["pendingRuntimeRequest"]["blocking"] = json!(false);
        assert_eq!(parse_thread(&background).unwrap().status(), Status::Running);
        let auth = parse_thread(&thread(
            "t",
            "p",
            "A",
            "waiting",
            pending("req-4", "auth_refresh"),
            None,
            None,
            "",
        ))
        .unwrap();
        assert_eq!(auth.status(), Status::Running);
        let failed = parse_thread(&thread(
            "t",
            "p",
            "A",
            "failed",
            Value::Null,
            None,
            None,
            "",
        ))
        .unwrap();
        assert_eq!(failed.status(), Status::Error);
        let mut stuck = thread("t", "p", "A", "idle", Value::Null, None, None, "");
        stuck["lastError"] = json!("provider failed");
        assert_eq!(parse_thread(&stuck).unwrap().status(), Status::Error);
        let done = parse_thread(&thread(
            "t",
            "p",
            "A",
            "completed",
            Value::Null,
            None,
            None,
            "",
        ))
        .unwrap();
        assert_eq!(done.status(), Status::Done);
        let idle =
            parse_thread(&thread("t", "p", "A", "idle", Value::Null, None, None, "")).unwrap();
        assert_eq!(idle.status(), Status::Idle);
        for status in ["interrupted", "cancelled", "rolled_back"] {
            let thread =
                parse_thread(&thread("t", "p", "A", status, Value::Null, None, None, "")).unwrap();
            assert_eq!(thread.status(), Status::Idle, "{status}");
        }
        let mut active = thread("t", "p", "A", "completed", Value::Null, None, None, "");
        active["activityRunStatus"] = json!("running");
        assert_eq!(parse_thread(&active).unwrap().status(), Status::Running);
    }

    #[test]
    fn a_v1_shell_is_not_an_approval() {
        let legacy = json!({
            "id": "t",
            "projectId": "p",
            "title": "Wait",
            "updatedAt": "2026-10-21T02:00:00.000Z",
            "archivedAt": null,
            "session": {"status": "running"},
            "latestTurn": {"state": "running"},
            "hasPendingApprovals": true,
            "hasPendingUserInput": false
        });
        let thread = parse_thread(&legacy).unwrap();
        assert_eq!(thread.status(), Status::Idle);
        assert!(!thread.pending_is_approval());
    }

    #[test]
    fn v2_events_update_the_shell_and_v1_names_do_not() {
        let mut session = Session::default();
        session.apply_shell(&shell_snapshot());
        session.apply_shell(&json!({
            "kind": "thread-upserted",
            "thread": thread("t1", "p1", "Fix the build", "completed", Value::Null, None, None, "2026-10-21T03:00:00.000Z")
        }));
        assert_eq!(session.threads["t1"].status(), Status::Running);
        session.apply_shell(&json!({
            "kind": "thread.updated",
            "sequence": 5,
            "location": "active",
            "thread": thread("t1", "p1", "Fix the build", "completed", Value::Null, None, None, "2026-10-21T03:00:00.000Z")
        }));
        assert_eq!(session.threads["t1"].status(), Status::Done);
        session.apply_shell(&json!({
            "kind": "thread.updated",
            "sequence": 6,
            "location": "archive",
            "thread": thread("t1", "p1", "Fix the build", "completed", Value::Null, Some("2026-10-21T03:01:00.000Z"), None, "2026-10-21T03:01:00.000Z")
        }));
        assert!(!session.threads.contains_key("t1"));
        session.apply_shell(&json!({"kind": "thread.removed", "sequence": 7, "location": "active", "threadId": "t3"}));
        assert!(!session.threads.contains_key("t3"));
        session.apply_shell(&json!({
            "kind": "project.updated",
            "sequence": 8,
            "project": {"id": "p3", "title": "Extra"}
        }));
        assert_eq!(session.projects["p3"].title, "Extra");
        session.apply_shell(&json!({"kind": "project.removed", "sequence": 9, "projectId": "p1"}));
        assert!(!session.projects.contains_key("p1"));
        assert!(!session.threads.contains_key("t5"));
    }

    #[test]
    fn the_projection_fills_the_approval_prompt() {
        let mut session = Session::default();
        let mut seen = Seen::default();
        let base = url("http://t3code-home:3773");
        session.apply_shell(&shell_snapshot());
        let first = session.view(&base, None, &mut seen);
        assert_eq!(first.alerts.len(), 1);
        assert_eq!(first.approval.as_ref().unwrap().request_id, "req-1");
        assert_eq!(first.approval.as_ref().unwrap().summary, "Command");
        session.apply_thread(
            "t3",
            &json!({
                "kind": "snapshot",
                "snapshotSequence": 4,
                "projection": {
                    "runtimeRequests": [{
                        "id": "req-1",
                        "kind": "command",
                        "status": "pending",
                        "detail": "from the request"
                    }],
                    "turnItems": [{
                        "type": "approval_request",
                        "requestId": "req-1",
                        "requestKind": "command",
                        "prompt": "npm test"
                    }],
                    "visibleTurnItems": [{
                        "item": {
                            "type": "approval_request",
                            "requestId": "req-1",
                            "prompt": "ignored once the turn item was seen"
                        }
                    }]
                }
            }),
        );
        let second = session.view(&base, None, &mut seen);
        assert!(second.alerts.is_empty());
        assert_eq!(second.approval.as_ref().unwrap().detail, "npm test");
        // Clearing the pending request closes the card. A v1 activity stream does not.
        session.apply_thread(
            "t3",
            &json!({
                "kind": "snapshot",
                "snapshot": {"thread": {"activities": [{
                    "kind": "approval.resolved",
                    "payload": {"requestId": "req-1"}
                }]}}
            }),
        );
        assert!(session.approvals.contains_key("t3"));
        session.apply_shell(&json!({
            "kind": "thread.updated",
            "sequence": 10,
            "location": "active",
            "thread": thread("t3", "p2", "Wait", "running", Value::Null, None, None, "2026-10-21T02:05:00.000Z")
        }));
        assert!(session.approvals.get("t3").is_none());
    }

    #[test]
    fn a_new_approval_sounds_once_and_a_finish_sounds_after_the_first_look() {
        let mut session = Session::default();
        let mut seen = Seen::default();
        let base = url("http://t3code-home:3773");
        session.apply_shell(&shell_snapshot());
        let first = session.view(&base, None, &mut seen);
        assert_eq!(first.alerts.len(), 1);
        assert_eq!(first.pill.state, "approval");
        let second = session.view(&base, None, &mut seen);
        assert!(second.alerts.is_empty());
        session.apply_shell(&json!({
            "kind": "thread.updated",
            "sequence": 11,
            "location": "active",
            "thread": thread("t1", "p1", "Fix the build", "completed", Value::Null, None, None, "2026-10-21T04:00:00.000Z")
        }));
        let finished = session.view(&base, None, &mut seen);
        assert!(finished
            .alerts
            .iter()
            .any(|alert| alert.kind == "finished" && alert.label.contains("Fix the build")));
        session.apply_shell(&json!({
            "kind": "thread.updated",
            "sequence": 12,
            "location": "active",
            "thread": thread("t1", "p1", "Fix the build", "running", pending("req-9", "user_input"), None, None, "2026-10-21T04:01:00.000Z")
        }));
        let question = session.view(&base, None, &mut seen);
        assert!(question.alerts.iter().any(|alert| alert.kind == "question"));
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
