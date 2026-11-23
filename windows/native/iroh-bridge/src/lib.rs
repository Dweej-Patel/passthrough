//! Passthrough's iroh endpoint for Windows: exactly what `IrohTransport/*.swift` does with iroh-ffi, as a C ABI the
//! .NET host calls (Passthrough.Windows/Iroh/IrohBridge.cs).
//!
//! Rules every export keeps:
//! * It never unwinds into the caller: a panic becomes `PT_ERR_PANIC`.
//! * Objects are named by handles: ids from a counter that never repeats, looked up in a table, so a stale or
//!   forged handle finds nothing (`PT_ERR_BAD_HANDLE`) instead of freed memory.
//! * Buffers belong to the caller. Text comes in as UTF-8 pointer + length; text goes out into a caller's buffer,
//!   and the call returns the length it needs, so a too-small buffer is retried.
//! * Calls that wait (accept, read, write, connect) block the calling thread and end with `PT_ERR_CANCELLED` once
//!   their object is closed or freed from another thread.
//! * The last error's text, for logs, is per thread (`pt_iroh_last_error`). It never holds key material.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use iroh::endpoint::{Connection, ConnectionError, Incoming, IncomingAddr, RecvStream, SendStream, presets};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMap, RelayMode, RelayUrl, SecretKey, TransportAddr};
use tokio::runtime::Runtime;
use tokio_util::sync::CancellationToken;

pub const PT_OK: i32 = 0;
/// A read reached the end of the peer's data; an accept found the endpoint closed.
pub const PT_END: i32 = 1;
pub const PT_ERR_ARGUMENT: i32 = -1;
pub const PT_ERR_BAD_HANDLE: i32 = -2;
pub const PT_ERR_CANCELLED: i32 = -3;
pub const PT_ERR_WRONG_ALPN: i32 = -4;
pub const PT_ERR_CONNECTION: i32 = -5;
pub const PT_ERR_BIND: i32 = -6;
pub const PT_ERR_TIMEOUT: i32 = -7;
/// The call is not possible in the object's state (an attempt already accepted, refused or retried).
pub const PT_ERR_STATE: i32 = -8;
pub const PT_ERR_PANIC: i32 = -99;

/// `pt_iroh_incoming_origin` / `pt_iroh_stream_path`.
pub const PT_PATH_UNKNOWN: i32 = 0;
pub const PT_PATH_DIRECT: i32 = 1;
pub const PT_PATH_RELAY: i32 = 2;

/// `pt_iroh_stream_wait_closed`: how the connection ended.
pub const PT_CLOSE_CLEAN: i32 = 0;
pub const PT_CLOSE_APPLICATION: i32 = 1;
pub const PT_CLOSE_LOST: i32 = 2;

/// `pt_iroh_endpoint_bind` relay modes.
pub const PT_RELAY_DISABLED: i32 = 0;
pub const PT_RELAY_N0: i32 = 1;
pub const PT_RELAY_CUSTOM: i32 = 2;

/// How long a stream's close waits for what was sent to be acknowledged (as `IrohByteStream.drainTimeout`).
const DRAIN_TIMEOUT: Duration = Duration::from_secs(2);

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("passthrough-iroh")
            .enable_all()
            .build()
            .expect("the iroh runtime")
    })
}

// MARK: Errors

thread_local! {
    static LAST_ERROR: std::cell::RefCell<String> = const { std::cell::RefCell::new(String::new()) };
}

struct Failure(i32, String);

impl Failure {
    fn new(code: i32, what: impl std::fmt::Display) -> Self {
        Failure(code, what.to_string())
    }
}

type Outcome<T> = Result<T, Failure>;

/// Runs an export: its failure's text is kept for `pt_iroh_last_error`, a panic is caught.
fn guard(body: impl FnOnce() -> Outcome<i32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(code)) => {
            LAST_ERROR.with(|e| e.borrow_mut().clear());
            code
        }
        Ok(Err(Failure(code, text))) => {
            LAST_ERROR.with(|e| *e.borrow_mut() = text);
            code
        }
        Err(_) => {
            LAST_ERROR.with(|e| *e.borrow_mut() = "panic in the iroh bridge".into());
            PT_ERR_PANIC
        }
    }
}

/// Waits for `future` on the bridge's runtime, ending early with `PT_ERR_CANCELLED` once `cancel` fires.
fn wait<T>(cancel: &CancellationToken, future: impl Future<Output = Outcome<T>>) -> Outcome<T> {
    runtime().block_on(async {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => Err(Failure::new(PT_ERR_CANCELLED, "cancelled")),
            result = future => result,
        }
    })
}

// MARK: Handles

enum Object {
    Endpoint(Arc<EndpointObject>),
    Incoming(Arc<IncomingObject>),
    Stream(Arc<StreamObject>),
}

struct EndpointObject {
    endpoint: Endpoint,
    cancel: CancellationToken,
}

enum IncomingState {
    Waiting(Incoming),
    Accepting,
    Connected(Connection),
    Done,
}

struct IncomingObject {
    state: Mutex<IncomingState>,
    alpn: Vec<u8>,
    cancel: CancellationToken,
}

struct StreamObject {
    connection: Connection,
    send: tokio::sync::Mutex<SendStream>,
    recv: tokio::sync::Mutex<RecvStream>,
    /// Ends waiting reads at once on close; sends already started still finish.
    cancel: CancellationToken,
    closing: std::sync::atomic::AtomicBool,
}

fn table() -> &'static Mutex<HashMap<u64, Object>> {
    static TABLE: OnceLock<Mutex<HashMap<u64, Object>>> = OnceLock::new();
    TABLE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn insert(object: Object) -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    table().lock().unwrap_or_else(|p| p.into_inner()).insert(id, object);
    id
}

fn endpoint(handle: u64) -> Outcome<Arc<EndpointObject>> {
    match table().lock().unwrap_or_else(|p| p.into_inner()).get(&handle) {
        Some(Object::Endpoint(e)) => Ok(e.clone()),
        _ => Err(Failure::new(PT_ERR_BAD_HANDLE, "not an endpoint")),
    }
}

fn incoming(handle: u64) -> Outcome<Arc<IncomingObject>> {
    match table().lock().unwrap_or_else(|p| p.into_inner()).get(&handle) {
        Some(Object::Incoming(i)) => Ok(i.clone()),
        _ => Err(Failure::new(PT_ERR_BAD_HANDLE, "not an incoming connection")),
    }
}

fn stream(handle: u64) -> Outcome<Arc<StreamObject>> {
    match table().lock().unwrap_or_else(|p| p.into_inner()).get(&handle) {
        Some(Object::Stream(s)) => Ok(s.clone()),
        _ => Err(Failure::new(PT_ERR_BAD_HANDLE, "not a stream")),
    }
}

// MARK: Text in and out

/// # Safety
/// `ptr` is null with `len` 0, or valid for `len` bytes.
unsafe fn bytes_in<'a>(ptr: *const u8, len: usize) -> Outcome<&'a [u8]> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(Failure::new(PT_ERR_ARGUMENT, "null buffer"));
    }
    Ok(unsafe { std::slice::from_raw_parts(ptr, len) })
}

unsafe fn text_in<'a>(ptr: *const u8, len: usize) -> Outcome<&'a str> {
    std::str::from_utf8(unsafe { bytes_in(ptr, len)? }).map_err(|_| Failure::new(PT_ERR_ARGUMENT, "not UTF-8"))
}

/// Copies `text` into the caller's buffer when it fits; returns its length either way (the caller retries when bigger).
unsafe fn text_out(text: &str, buffer: *mut u8, capacity: usize) -> i32 {
    let bytes = text.as_bytes();
    if !buffer.is_null() && bytes.len() <= capacity {
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, bytes.len()) };
    }
    i32::try_from(bytes.len()).unwrap_or(i32::MAX)
}

unsafe fn handle_out(out: *mut u64, value: u64) -> Outcome<()> {
    if out.is_null() {
        return Err(Failure::new(PT_ERR_ARGUMENT, "null out pointer"));
    }
    unsafe { *out = value };
    Ok(())
}

/// "0.0.0.0:p" and "1.2.3.4:5" as "1.2.3.4" for an IP, "[fe80::1%3]:5" as "fe80::1%3".
fn host_of(address: &SocketAddr) -> String {
    match address {
        SocketAddr::V4(v4) => v4.ip().to_string(),
        SocketAddr::V6(v6) if v6.scope_id() != 0 => format!("{}%{}", v6.ip(), v6.scope_id()),
        SocketAddr::V6(v6) => v6.ip().to_string(),
    }
}

// MARK: Keys

/// Fills `out` (32 bytes) with a fresh endpoint secret key, for the host to store.
///
/// # Safety
/// `out` is valid for 32 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_generate_secret_key(out: *mut u8) -> i32 {
    guard(|| {
        if out.is_null() {
            return Err(Failure::new(PT_ERR_ARGUMENT, "null out pointer"));
        }
        let key = SecretKey::generate().to_bytes();
        unsafe { std::ptr::copy_nonoverlapping(key.as_ptr(), out, key.len()) };
        Ok(PT_OK)
    })
}

/// The endpoint id a 32-byte secret key gives, as text.
///
/// # Safety
/// `key` is valid for 32 bytes; `buffer` for `capacity`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_endpoint_id_of_key(key: *const u8, buffer: *mut u8, capacity: usize) -> i32 {
    guard(|| {
        let key: [u8; 32] = unsafe { bytes_in(key, 32)? }.try_into().map_err(|_| Failure::new(PT_ERR_ARGUMENT, "not 32 bytes"))?;
        Ok(unsafe { text_out(&SecretKey::from_bytes(&key).public().to_string(), buffer, capacity) })
    })
}

/// The last failure's text on this thread, for logs (never key material).
///
/// # Safety
/// `buffer` is valid for `capacity` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_last_error(buffer: *mut u8, capacity: usize) -> i32 {
    LAST_ERROR.with(|e| unsafe { text_out(&e.borrow(), buffer, capacity) })
}

// MARK: Endpoints

/// Binds an endpoint with the minimal preset (no n0 DNS or pkarr publishing, no mDNS: peers are dialled by id plus
/// explicit addresses, as on the Mac). `secret_key` is 32 bytes for the host's stable id, or null for an ephemeral one
/// (a viewer dialling). `relay_mode`: `PT_RELAY_*`; a custom relay's URL and token (`Authorization: Bearer`) come with
/// it. `alpns` is newline-separated: the protocols it accepts (none for a dialler).
///
/// # Safety
/// Each pointer is valid for its length (or null with length 0); `out` for one handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_endpoint_bind(
    secret_key: *const u8,
    relay_mode: i32,
    relay_url: *const u8,
    relay_url_len: usize,
    relay_token: *const u8,
    relay_token_len: usize,
    alpns: *const u8,
    alpns_len: usize,
    out: *mut u64,
) -> i32 {
    guard(|| {
        let mode = match relay_mode {
            PT_RELAY_DISABLED => RelayMode::Disabled,
            PT_RELAY_N0 => RelayMode::Default,
            PT_RELAY_CUSTOM => {
                let url: RelayUrl = unsafe { text_in(relay_url, relay_url_len)? }
                    .parse()
                    .map_err(|e| Failure::new(PT_ERR_ARGUMENT, format!("relay URL: {e}")))?;
                let mut map = RelayMap::from_iter([url]);
                let token = unsafe { text_in(relay_token, relay_token_len)? };
                if !token.is_empty() {
                    map = map.with_auth_token(token);
                }
                RelayMode::Custom(map)
            }
            _ => return Err(Failure::new(PT_ERR_ARGUMENT, "relay mode")),
        };
        let alpns: Vec<Vec<u8>> = unsafe { text_in(alpns, alpns_len)? }
            .split('\n')
            .filter(|a| !a.is_empty())
            .map(|a| a.as_bytes().to_vec())
            .collect();
        let mut builder = Endpoint::builder(presets::Minimal).relay_mode(mode).alpns(alpns);
        if !secret_key.is_null() {
            let key: [u8; 32] = unsafe { bytes_in(secret_key, 32)? }.try_into().map_err(|_| Failure::new(PT_ERR_ARGUMENT, "secret key"))?;
            builder = builder.secret_key(SecretKey::from_bytes(&key));
        }
        let endpoint = runtime()
            .block_on(builder.bind())
            .map_err(|e| Failure::new(PT_ERR_BIND, format!("bind: {e}")))?;
        let id = insert(Object::Endpoint(Arc::new(EndpointObject { endpoint, cancel: CancellationToken::new() })));
        unsafe { handle_out(out, id)? };
        Ok(PT_OK)
    })
}

/// This endpoint's id (from its secret key), as text.
///
/// # Safety
/// `buffer` is valid for `capacity` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_endpoint_id(handle: u64, buffer: *mut u8, capacity: usize) -> i32 {
    guard(|| Ok(unsafe { text_out(&endpoint(handle)?.endpoint.id().to_string(), buffer, capacity) }))
}

/// The relay it is reachable through now, or empty.
///
/// # Safety
/// `buffer` is valid for `capacity` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_endpoint_home_relay(handle: u64, buffer: *mut u8, capacity: usize) -> i32 {
    guard(|| {
        let address = endpoint(handle)?.endpoint.addr();
        let relay = address.relay_urls().next().map(|u| u.to_string()).unwrap_or_default();
        Ok(unsafe { text_out(&relay, buffer, capacity) })
    })
}

/// The direct "ip:port" addresses it knows for itself, newline-separated.
///
/// # Safety
/// `buffer` is valid for `capacity` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_endpoint_direct_addresses(handle: u64, buffer: *mut u8, capacity: usize) -> i32 {
    guard(|| {
        let address = endpoint(handle)?.endpoint.addr();
        let list: Vec<String> = address.ip_addrs().map(|a| a.to_string()).collect();
        Ok(unsafe { text_out(&list.join("\n"), buffer, capacity) })
    })
}

/// Its bound sockets as loopback "ip:port", newline-separated (dialling on the same machine: tests).
///
/// # Safety
/// `buffer` is valid for `capacity` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_endpoint_loopback_addresses(handle: u64, buffer: *mut u8, capacity: usize) -> i32 {
    guard(|| {
        let list: Vec<String> = endpoint(handle)?
            .endpoint
            .bound_sockets()
            .iter()
            .map(|s| if s.is_ipv4() { format!("127.0.0.1:{}", s.port()) } else { format!("[::1]:{}", s.port()) })
            .collect();
        Ok(unsafe { text_out(&list.join("\n"), buffer, capacity) })
    })
}

/// Waits up to `timeout_ms` for the endpoint to reach its home relay. `PT_ERR_TIMEOUT` if it didn't.
#[unsafe(no_mangle)]
pub extern "C" fn pt_iroh_endpoint_wait_online(handle: u64, timeout_ms: u32) -> i32 {
    guard(|| {
        let object = endpoint(handle)?;
        wait(&object.cancel, async {
            tokio::time::timeout(Duration::from_millis(timeout_ms.into()), object.endpoint.online())
                .await
                .map_err(|_| Failure::new(PT_ERR_TIMEOUT, "not online yet"))
        })?;
        Ok(PT_OK)
    })
}

/// Waits for the next incoming connection attempt; returns before the handshake (finish it with
/// `pt_iroh_incoming_accept`), so one slow peer can't hold up the accept loop. `PT_END` once the endpoint is closed.
///
/// # Safety
/// `out` is valid for one handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_endpoint_accept(handle: u64, alpn: *const u8, alpn_len: usize, out: *mut u64) -> i32 {
    guard(|| {
        let object = endpoint(handle)?;
        let alpn = unsafe { bytes_in(alpn, alpn_len)? }.to_vec();
        let next = match wait(&object.cancel, async { Ok(object.endpoint.accept().await) }) {
            Err(Failure(PT_ERR_CANCELLED, _)) => return Ok(PT_END),
            other => other?,
        };
        let Some(next) = next else { return Ok(PT_END) };
        let id = insert(Object::Incoming(Arc::new(IncomingObject {
            state: Mutex::new(IncomingState::Waiting(next)),
            alpn,
            cancel: object.cancel.child_token(),
        })));
        unsafe { handle_out(out, id)? };
        Ok(PT_OK)
    })
}

/// Dials endpoint `id` at `relay_url` and/or `addresses` ("ip:port", newline-separated) and opens a bidirectional
/// stream; the peer sees the stream once this side writes to it.
///
/// # Safety
/// Each pointer is valid for its length (or null with length 0); `out` for one handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_endpoint_connect(
    handle: u64,
    id: *const u8,
    id_len: usize,
    relay_url: *const u8,
    relay_url_len: usize,
    addresses: *const u8,
    addresses_len: usize,
    alpn: *const u8,
    alpn_len: usize,
    out: *mut u64,
) -> i32 {
    guard(|| {
        let object = endpoint(handle)?;
        let id: EndpointId = unsafe { text_in(id, id_len)? }.parse().map_err(|e| Failure::new(PT_ERR_ARGUMENT, format!("endpoint id: {e}")))?;
        let mut address = EndpointAddr::new(id);
        let relay = unsafe { text_in(relay_url, relay_url_len)? };
        if !relay.is_empty() {
            address = address.with_relay_url(relay.parse().map_err(|e| Failure::new(PT_ERR_ARGUMENT, format!("relay URL: {e}")))?);
        }
        for socket in unsafe { text_in(addresses, addresses_len)? }.split('\n').filter(|a| !a.is_empty()) {
            let socket: SocketAddr = socket.parse().map_err(|e| Failure::new(PT_ERR_ARGUMENT, format!("address: {e}")))?;
            address = address.with_ip_addr(socket);
        }
        let alpn = unsafe { bytes_in(alpn, alpn_len)? }.to_vec();
        let cancel = object.cancel.child_token();
        let stream_object = wait(&cancel, async {
            let connection = object.endpoint.connect(address, &alpn).await.map_err(|e| Failure::new(PT_ERR_CONNECTION, format!("connect: {e}")))?;
            match connection.open_bi().await {
                Ok((send, recv)) => Ok(StreamObject::new(connection, send, recv, cancel.clone())),
                Err(e) => {
                    connection.close(0u32.into(), b"");
                    Err(Failure::new(PT_ERR_CONNECTION, format!("open stream: {e}")))
                }
            }
        })?;
        let id = insert(Object::Stream(Arc::new(stream_object)));
        unsafe { handle_out(out, id)? };
        Ok(PT_OK)
    })
}

/// Closes the endpoint: everything waiting on it (accepts, handshakes, dials) ends, and so do its connections.
#[unsafe(no_mangle)]
pub extern "C" fn pt_iroh_endpoint_close(handle: u64) -> i32 {
    guard(|| {
        let object = endpoint(handle)?;
        object.cancel.cancel();
        runtime().block_on(async {
            let _ = tokio::time::timeout(Duration::from_secs(3), object.endpoint.close()).await;
        });
        Ok(PT_OK)
    })
}

// MARK: Incoming attempts

/// Where an attempt comes from, before any handshake: `PT_PATH_*`, and for a direct one the peer's IP.
///
/// # Safety
/// `path` is valid for one int; `buffer` for `capacity` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_incoming_origin(handle: u64, path: *mut i32, buffer: *mut u8, capacity: usize) -> i32 {
    guard(|| {
        let object = incoming(handle)?;
        let state = object.state.lock().unwrap_or_else(|p| p.into_inner());
        let IncomingState::Waiting(attempt) = &*state else { return Err(Failure::new(PT_ERR_STATE, "already handled")) };
        let (kind, ip) = match attempt.remote_addr() {
            IncomingAddr::Ip(address) => (PT_PATH_DIRECT, host_of(&address)),
            IncomingAddr::Relay { .. } => (PT_PATH_RELAY, String::new()),
            _ => (PT_PATH_UNKNOWN, String::new()),
        };
        if path.is_null() {
            return Err(Failure::new(PT_ERR_ARGUMENT, "null out pointer"));
        }
        unsafe { *path = kind };
        Ok(unsafe { text_out(&ip, buffer, capacity) })
    })
}

/// 1 when the peer has shown it receives packets at the address it came from (it echoed a retry token), else 0.
#[unsafe(no_mangle)]
pub extern "C" fn pt_iroh_incoming_is_validated(handle: u64) -> i32 {
    guard(|| {
        let object = incoming(handle)?;
        let state = object.state.lock().unwrap_or_else(|p| p.into_inner());
        let IncomingState::Waiting(attempt) = &*state else { return Err(Failure::new(PT_ERR_STATE, "already handled")) };
        Ok(i32::from(attempt.remote_addr_validated()))
    })
}

/// Ends the attempt with a QUIC retry, keeping no state: a peer that really is at its address comes again with a
/// token. `PT_ERR_STATE` if it can't be asked (it already came with one, or the attempt was handled).
#[unsafe(no_mangle)]
pub extern "C" fn pt_iroh_incoming_retry(handle: u64) -> i32 {
    guard(|| {
        let object = incoming(handle)?;
        let mut state = object.state.lock().unwrap_or_else(|p| p.into_inner());
        match std::mem::replace(&mut *state, IncomingState::Done) {
            IncomingState::Waiting(attempt) => match attempt.retry() {
                Ok(()) => Ok(PT_OK),
                Err(e) => {
                    e.into_incoming().refuse();
                    Err(Failure::new(PT_ERR_STATE, "it already came with a token"))
                }
            },
            other => {
                *state = other;
                Err(Failure::new(PT_ERR_STATE, "already handled"))
            }
        }
    })
}

/// Turns the attempt away without a handshake; if its handshake already started or finished, abandons it.
#[unsafe(no_mangle)]
pub extern "C" fn pt_iroh_incoming_cancel(handle: u64) -> i32 {
    guard(|| {
        let object = incoming(handle)?;
        object.cancel.cancel();
        let mut state = object.state.lock().unwrap_or_else(|p| p.into_inner());
        match std::mem::replace(&mut *state, IncomingState::Done) {
            IncomingState::Waiting(attempt) => attempt.refuse(),
            IncomingState::Connected(connection) => connection.close(0u32.into(), b""),
            IncomingState::Accepting | IncomingState::Done => {}
        }
        Ok(PT_OK)
    })
}

/// Completes the handshake and waits for the peer's first bidirectional stream (it arrives once the peer has written
/// to it). `PT_ERR_WRONG_ALPN` when the peer negotiated another protocol; `PT_ERR_CANCELLED` once cancelled.
///
/// # Safety
/// `out` is valid for one handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_incoming_accept(handle: u64, out: *mut u64) -> i32 {
    guard(|| {
        let object = incoming(handle)?;
        let attempt = {
            let mut state = object.state.lock().unwrap_or_else(|p| p.into_inner());
            match std::mem::replace(&mut *state, IncomingState::Accepting) {
                IncomingState::Waiting(attempt) => attempt,
                other => {
                    *state = other;
                    return Err(Failure::new(PT_ERR_STATE, "already handled"));
                }
            }
        };
        let connection = wait(&object.cancel, async {
            let accepting = attempt.accept().map_err(|e| Failure::new(PT_ERR_CONNECTION, format!("accept: {e}")))?;
            accepting.await.map_err(|e| Failure::new(PT_ERR_CONNECTION, format!("handshake: {e}")))
        });
        let connection = match connection {
            Ok(c) => c,
            Err(f) => {
                *object.state.lock().unwrap_or_else(|p| p.into_inner()) = IncomingState::Done;
                return Err(f);
            }
        };
        {
            let mut state = object.state.lock().unwrap_or_else(|p| p.into_inner());
            if matches!(*state, IncomingState::Done) || object.cancel.is_cancelled() {
                connection.close(0u32.into(), b"");
                return Err(Failure::new(PT_ERR_CANCELLED, "cancelled"));
            }
            *state = IncomingState::Connected(connection.clone());
        }
        let result = (|| {
            if connection.alpn() != object.alpn.as_slice() {
                return Err(Failure::new(PT_ERR_WRONG_ALPN, "the peer asked for another protocol"));
            }
            wait(&object.cancel, async {
                connection.accept_bi().await.map_err(|e| Failure::new(PT_ERR_CONNECTION, format!("accept stream: {e}")))
            })
        })();
        *object.state.lock().unwrap_or_else(|p| p.into_inner()) = IncomingState::Done;
        match result {
            Ok((send, recv)) => {
                let id = insert(Object::Stream(Arc::new(StreamObject::new(connection, send, recv, CancellationToken::new()))));
                unsafe { handle_out(out, id)? };
                Ok(PT_OK)
            }
            Err(f) => {
                connection.close(0u32.into(), b"");
                Err(f)
            }
        }
    })
}

// MARK: Streams

impl StreamObject {
    fn new(connection: Connection, send: SendStream, recv: RecvStream, cancel: CancellationToken) -> Self {
        StreamObject {
            connection,
            send: tokio::sync::Mutex::new(send),
            recv: tokio::sync::Mutex::new(recv),
            cancel,
            closing: std::sync::atomic::AtomicBool::new(false),
        }
    }
}

/// Reads up to `capacity` bytes into `buffer`; `*read` is how many. `PT_END` (with 0) once the peer has finished.
///
/// # Safety
/// `buffer` is valid for `capacity` bytes; `read` for one size.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_stream_read(handle: u64, buffer: *mut u8, capacity: usize, read: *mut usize) -> i32 {
    guard(|| {
        if buffer.is_null() || read.is_null() || capacity == 0 {
            return Err(Failure::new(PT_ERR_ARGUMENT, "buffer"));
        }
        let object = stream(handle)?;
        let target = unsafe { std::slice::from_raw_parts_mut(buffer, capacity) };
        let count = wait(&object.cancel, async {
            let mut recv = object.recv.lock().await;
            recv.read(target).await.map_err(|e| Failure::new(PT_ERR_CONNECTION, format!("read: {e}")))
        })?;
        match count {
            Some(n) => {
                unsafe { *read = n };
                Ok(PT_OK)
            }
            None => {
                unsafe { *read = 0 };
                Ok(PT_END)
            }
        }
    })
}

/// Writes all of `data`, in order with earlier writes. `finish` 1 ends this side's data after it.
///
/// # Safety
/// `data` is valid for `len` bytes (or null with 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_stream_write(handle: u64, data: *const u8, len: usize, finish: i32) -> i32 {
    guard(|| {
        let object = stream(handle)?;
        let data = unsafe { bytes_in(data, len)? };
        if object.closing.load(Ordering::Acquire) {
            return Err(Failure::new(PT_ERR_CANCELLED, "closed"));
        }
        runtime().block_on(async {
            let mut send = object.send.lock().await;
            if !data.is_empty() {
                send.write_all(data).await.map_err(|e| Failure::new(PT_ERR_CONNECTION, format!("write: {e}")))?;
            }
            if finish != 0 {
                send.finish().map_err(|e| Failure::new(PT_ERR_CONNECTION, format!("finish: {e}")))?;
            }
            Ok(PT_OK)
        })
    })
}

/// Stops reads at once, then finishes the send half and closes the connection (code 0) once the peer has
/// acknowledged what was already written, or after 2 s: `write(x); close()` delivers x, as over TCP. Returns at once.
#[unsafe(no_mangle)]
pub extern "C" fn pt_iroh_stream_close(handle: u64) -> i32 {
    guard(|| {
        let object = stream(handle)?;
        if object.closing.swap(true, Ordering::AcqRel) {
            return Ok(PT_OK);
        }
        object.cancel.cancel();
        runtime().spawn(async move {
            let _ = tokio::time::timeout(DRAIN_TIMEOUT, async {
                let mut send = object.send.lock().await;
                let _ = send.finish();
                let _ = send.stopped().await;
            })
            .await;
            object.connection.close(0u32.into(), b"");
        });
        Ok(PT_OK)
    })
}

/// Waits until the connection under the stream ends: `PT_CLOSE_CLEAN` (closed with code 0, by either side),
/// `PT_CLOSE_APPLICATION` (another code, in `*code`), or `PT_CLOSE_LOST` (timed out, reset, a transport error).
///
/// # Safety
/// `kind` and `code` are valid for one value each.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_stream_wait_closed(handle: u64, kind: *mut i32, code: *mut u64) -> i32 {
    guard(|| {
        if kind.is_null() || code.is_null() {
            return Err(Failure::new(PT_ERR_ARGUMENT, "null out pointer"));
        }
        let object = stream(handle)?;
        let reason = runtime().block_on(object.connection.closed());
        let (k, c) = match &reason {
            ConnectionError::LocallyClosed => (PT_CLOSE_CLEAN, 0),
            ConnectionError::ApplicationClosed(close) => {
                let value = close.error_code.into_inner();
                (if value == 0 { PT_CLOSE_CLEAN } else { PT_CLOSE_APPLICATION }, value)
            }
            _ => (PT_CLOSE_LOST, 0),
        };
        unsafe {
            *kind = k;
            *code = c;
        }
        LAST_ERROR.with(|e| *e.borrow_mut() = reason.to_string());
        Ok(PT_OK)
    })
}

/// The peer's endpoint id.
///
/// # Safety
/// `buffer` is valid for `capacity` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_stream_remote_id(handle: u64, buffer: *mut u8, capacity: usize) -> i32 {
    guard(|| Ok(unsafe { text_out(&stream(handle)?.connection.remote_id().to_string(), buffer, capacity) }))
}

/// The path the connection uses now: `*path` is `PT_PATH_*`; for a direct one the peer's IP goes in `buffer`.
///
/// # Safety
/// `path` is valid for one int; `buffer` for `capacity` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_stream_path(handle: u64, path: *mut i32, buffer: *mut u8, capacity: usize) -> i32 {
    guard(|| {
        if path.is_null() {
            return Err(Failure::new(PT_ERR_ARGUMENT, "null out pointer"));
        }
        let object = stream(handle)?;
        let paths = object.connection.paths();
        let selected = paths.iter().find(|p| p.is_selected());
        let (kind, ip) = match selected {
            Some(p) if p.is_relay() => (PT_PATH_RELAY, String::new()),
            Some(p) if p.is_ip() => match p.remote_addr() {
                TransportAddr::Ip(address) => (PT_PATH_DIRECT, host_of(address)),
                _ => (PT_PATH_DIRECT, String::new()),
            },
            _ => (PT_PATH_UNKNOWN, String::new()),
        };
        unsafe { *path = kind };
        Ok(unsafe { text_out(&ip, buffer, capacity) })
    })
}

/// Diagnostics: every path of the connection, one per line, as "relay <url> rtt N ms" or "ip <addr:port> rtt N ms",
/// the selected one ending in " *". Unlike the other exports this names the peer's addresses: the host logs it only
/// when an administrator turned diagnostics on.
///
/// # Safety
/// `buffer` is valid for `capacity` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_stream_paths(handle: u64, buffer: *mut u8, capacity: usize) -> i32 {
    guard(|| {
        let object = stream(handle)?;
        let paths = object.connection.paths();
        let lines: Vec<String> = paths
            .iter()
            .map(|p| {
                let address = match p.remote_addr() {
                    TransportAddr::Relay(url) => format!("relay {url}"),
                    TransportAddr::Ip(address) => format!("ip {address}"),
                    other => format!("{other:?}"),
                };
                format!("{address} rtt {} ms{}", p.rtt().as_millis(), if p.is_selected() { " *" } else { "" })
            })
            .collect();
        Ok(unsafe { text_out(&lines.join("\n"), buffer, capacity) })
    })
}

/// Diagnostics: what the endpoint knows of itself, as one line: its direct addresses (with the public one once the
/// relay's address discovery answered), its home relay, and the socket's counters for hole punching, paths and bytes
/// per transport.
///
/// # Safety
/// `buffer` is valid for `capacity` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_endpoint_report(handle: u64, buffer: *mut u8, capacity: usize) -> i32 {
    guard(|| {
        let object = endpoint(handle)?;
        let address = object.endpoint.addr();
        let direct: Vec<String> = address.ip_addrs().map(|a| a.to_string()).collect();
        let bound: Vec<String> = object.endpoint.bound_sockets().iter().map(|a| a.to_string()).collect();
        let metrics = object.endpoint.metrics();
        let (s, n) = (&metrics.socket, &metrics.net_report);
        let text = format!(
            "mine: [{}]; bound [{}]; relay {}; holepunch attempts {}, paths direct {} relay {}, conns opened {} direct {} closed {}, \
             ip paths added {} removed {}, sent ipv4 {} ipv6 {} relay {} B, received ipv4 {} ipv6 {} relay {} B, \
             net reports {} (full {}), portmap attempts {}, link changes {}",
            direct.join(", "),
            bound.join(", "),
            address.relay_urls().next().map(|u| u.to_string()).unwrap_or_else(|| "none".into()),
            s.holepunch_attempts.get(),
            s.paths_direct.get(),
            s.paths_relay.get(),
            s.num_conns_opened.get(),
            s.num_conns_direct.get(),
            s.num_conns_closed.get(),
            s.transport_ip_paths_added.get(),
            s.transport_ip_paths_removed.get(),
            s.send_ipv4.get(),
            s.send_ipv6.get(),
            s.send_relay.get(),
            s.recv_data_ipv4.get(),
            s.recv_data_ipv6.get(),
            s.recv_data_relay.get(),
            n.reports.get(),
            n.reports_full.get(),
            n.portmap_attempts.get(),
            s.actor_link_change.get(),
        );
        Ok(unsafe { text_out(&text, buffer, capacity) })
    })
}

/// Diagnostics: from now on iroh's own events matching `filter` (tracing directives, as
/// "iroh::_events=debug,iroh::socket::remote_map=debug") are appended to the file at `path`. Once per process; a
/// second call fails with `PT_ERR_ARGUMENT`. The file names addresses, so the host calls this only when an
/// administrator turned diagnostics on.
///
/// # Safety
/// Each pointer is valid for its length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_trace_start(path: *const u8, path_len: usize, filter: *const u8, filter_len: usize) -> i32 {
    guard(|| {
        use tracing_subscriber::layer::SubscriberExt;
        use tracing_subscriber::util::SubscriberInitExt;
        let path = unsafe { text_in(path, path_len)? };
        let filter: tracing_subscriber::EnvFilter = unsafe { text_in(filter, filter_len)? }
            .parse()
            .map_err(|e| Failure::new(PT_ERR_ARGUMENT, format!("trace filter: {e}")))?;
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .map_err(|e| Failure::new(PT_ERR_ARGUMENT, format!("trace file: {e}")))?;
        tracing_subscriber::registry()
            .with(filter)
            .with(tracing_subscriber::fmt::layer().with_ansi(false).with_writer(Mutex::new(file)))
            .try_init()
            .map_err(|e| Failure::new(PT_ERR_ARGUMENT, format!("trace: {e}")))?;
        Ok(PT_OK)
    })
}

/// The selected path's round trip in milliseconds and whether it is a relay (`*relayed` 1 or 0); `*rtt_ms` is
/// `u32::MAX` when no path is selected yet.
///
/// # Safety
/// `rtt_ms` and `relayed` are each valid for one value.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_stream_rtt(handle: u64, rtt_ms: *mut u32, relayed: *mut i32) -> i32 {
    guard(|| {
        if rtt_ms.is_null() || relayed.is_null() {
            return Err(Failure::new(PT_ERR_ARGUMENT, "null out pointer"));
        }
        let object = stream(handle)?;
        let paths = object.connection.paths();
        let (rtt, relay) = match paths.iter().find(|p| p.is_selected()) {
            Some(p) => (p.rtt().as_millis().min(u32::MAX as u128 - 1) as u32, p.is_relay() as i32),
            None => (u32::MAX, 0),
        };
        unsafe {
            *rtt_ms = rtt;
            *relayed = relay;
        }
        Ok(0)
    })
}

/// The selected path's QUIC numbers, as text for a log line: round trip, congestion window, the controller's
/// bandwidth estimate, packets sent and lost, congestion events, MTU. No addresses.
///
/// # Safety
/// `buffer` is valid for `capacity` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_iroh_stream_stats(handle: u64, buffer: *mut u8, capacity: usize) -> i32 {
    guard(|| {
        let object = stream(handle)?;
        let paths = object.connection.paths();
        let text = match paths.iter().find(|p| p.is_selected()) {
            Some(p) => {
                let s = p.stats();
                format!(
                    "rtt {} ms, cwnd {} B, est {} kbit/s, sent {} pkts, lost {} pkts, {} congestion events, mtu {}",
                    s.rtt.as_millis(),
                    s.cwnd,
                    s.bandwidth_estimate.map(|b| (b / 1000).to_string()).unwrap_or_else(|| "?".into()),
                    s.sent_packets,
                    s.lost_packets,
                    s.congestion_events,
                    s.current_mtu
                )
            }
            None => String::new(),
        };
        Ok(unsafe { text_out(&text, buffer, capacity) })
    })
}

// MARK: Freeing

/// Forgets a handle. An endpoint is closed, an attempt not yet handled is refused, a stream is closed as by
/// `pt_iroh_stream_close`. Freeing twice, or a handle that never was, is `PT_ERR_BAD_HANDLE`.
#[unsafe(no_mangle)]
pub extern "C" fn pt_iroh_free(handle: u64) -> i32 {
    guard(|| {
        let removed = table().lock().unwrap_or_else(|p| p.into_inner()).remove(&handle);
        match removed {
            None => Err(Failure::new(PT_ERR_BAD_HANDLE, "no such handle")),
            Some(Object::Endpoint(object)) => {
                object.cancel.cancel();
                let endpoint = object.endpoint.clone();
                runtime().spawn(async move { endpoint.close().await });
                Ok(PT_OK)
            }
            Some(Object::Incoming(object)) => {
                object.cancel.cancel();
                let mut state = object.state.lock().unwrap_or_else(|p| p.into_inner());
                match std::mem::replace(&mut *state, IncomingState::Done) {
                    IncomingState::Waiting(attempt) => attempt.refuse(),
                    IncomingState::Connected(connection) => connection.close(0u32.into(), b""),
                    _ => {}
                }
                Ok(PT_OK)
            }
            Some(Object::Stream(object)) => {
                if !object.closing.swap(true, Ordering::AcqRel) {
                    object.cancel.cancel();
                    runtime().spawn(async move {
                        let _ = tokio::time::timeout(DRAIN_TIMEOUT, async {
                            let mut send = object.send.lock().await;
                            let _ = send.finish();
                            let _ = send.stopped().await;
                        })
                        .await;
                        object.connection.close(0u32.into(), b"");
                    });
                }
                Ok(PT_OK)
            }
        }
    })
}
