//! $12-challenge feed API on xitdb (Rust/Axum reference).
//!
//! Env: `XITDB_PATH` (fresh `feed.xitdb` copy), `JWT_SECRET`,
//! `HOST`/`PORT`. Writes are one xitdb txn each, fsync-on-commit.

use std::fs::OpenOptions;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use axum::Router;
use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use xitdb::core::FileCore;
use xitdb::cursor::{ReadOnly, Writeable};
use xitdb::database::{Database, InitOpts};
use xitdb::error::{Error, Result};
use xitdb::hasher::Sha1Hasher;
use xitdb::hashmap::HashMap;
use xitdb::hashset::HashSet;
use xitdb::sorted_map::SortedMap;

type Db = Database<FileCore, Sha1Hasher>;
type DbMap<'a> = HashMap<'a, FileCore, Sha1Hasher, xitdb::cursor::ReadWrite>;

struct AppState {
    db: Mutex<Db>,
    secret: String,
    boot: Instant,
}
type Shared = Arc<AppState>;

// ---------- pure helpers (unit-tested) ----------

pub fn feed_key(created_at: &str, id: u64) -> String {
    format!("{created_at}\x00{id:010}")
}

pub fn is_valid_post_id(s: &str) -> Option<u64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    match s.parse::<u64>() {
        Ok(n) if n >= 1 => Some(n),
        _ => None,
    }
}

pub fn trim_validate_body(
    v: &serde_json::Value,
) -> std::result::Result<String, &'static str> {
    let body = match v.get("body").and_then(serde_json::Value::as_str) {
        Some(s) => s,
        None => return Err("body is required"),
    };
    let trimmed = body.trim().to_string();
    if trimmed.is_empty() {
        return Err("body is required");
    }
    if trimmed.chars().count() > 500 {
        return Err("body must be at most 500 characters");
    }
    Ok(trimmed)
}

fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    use sha2::Digest;
    let mut key_block = [0u8; 64];
    if key.len() > 64 {
        let mut h = sha2::Sha256::new();
        h.update(key);
        key_block[..32].copy_from_slice(&h.finalize());
    } else {
        key_block[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for i in 0..64 {
        ipad[i] ^= key_block[i];
        opad[i] ^= key_block[i];
    }
    let mut inner = sha2::Sha256::new();
    inner.update(ipad);
    inner.update(msg);
    let inner_sum = inner.finalize();
    let mut outer = sha2::Sha256::new();
    outer.update(opad);
    outer.update(inner_sum);
    outer.finalize().into()
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

// Hand-rolled HS256: jsonwebtoken's `time` subtree outgrew our pinned
// toolchain, and std has no HMAC. Mirrors the Zig/Odin/Java servers.
pub fn verify_jwt(
    token: &str,
    secret: &str,
) -> std::result::Result<(u64, String), &'static str> {
    use base64::Engine;
    let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let mut parts = token.split('.');
    let (header_b64, payload_b64, sig_b64) = match (parts.next(), parts.next(), parts.next()) {
        (Some(h), Some(p), Some(s)) if parts.next().is_none() => (h, p, s),
        _ => return Err("invalid or expired token"),
    };
    let header_raw = b64.decode(header_b64).map_err(|_| "invalid or expired token")?;
    let header: serde_json::Value =
        serde_json::from_slice(&header_raw).map_err(|_| "invalid or expired token")?;
    if header.get("alg").and_then(serde_json::Value::as_str) != Some("HS256") {
        return Err("invalid or expired token");
    }
    let sig = b64.decode(sig_b64).map_err(|_| "invalid or expired token")?;
    let mut msg = Vec::with_capacity(header_b64.len() + 1 + payload_b64.len());
    msg.extend_from_slice(header_b64.as_bytes());
    msg.push(b'.');
    msg.extend_from_slice(payload_b64.as_bytes());
    let expected = hmac_sha256(secret.as_bytes(), &msg);
    if !constant_time_eq(&expected, &sig) {
        return Err("invalid or expired token");
    }
    let payload_raw = b64.decode(payload_b64).map_err(|_| "invalid or expired token")?;
    let payload: serde_json::Value =
        serde_json::from_slice(&payload_raw).map_err(|_| "invalid or expired token")?;
    let data = payload.as_object().ok_or("invalid or expired token")?;
    let sub = data.get("sub").and_then(serde_json::Value::as_str);
    let username = data.get("username").and_then(serde_json::Value::as_str);
    let user_id = match sub {
        Some(s) if !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) => match s.parse::<u64>() {
            Ok(n) if n >= 1 => n,
            _ => return Err("invalid token payload"),
        },
        _ => return Err("invalid token payload"),
    };
    let username = match username {
        Some(name) => name.to_string(),
        None => return Err("invalid token payload"),
    };
    let exp = data
        .get("exp")
        .and_then(serde_json::Value::as_u64)
        .ok_or("invalid or expired token")?;
    if exp + 60 < now_millis() / 1_000 {
        return Err("invalid or expired token");
    }
    Ok((user_id, username))
}

// ---------- JSON + DB helpers ----------

fn json_str(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}

struct Post {
    id: u64,
    body: String,
    created_at: String,
    author: String,
    like_count: u64,
}

fn post_json(p: &Post) -> String {
    format!(
        "{{\"id\":{},\"body\":{},\"created_at\":{},\"author\":{},\"like_count\":{}}}",
        p.id,
        json_str(&p.body),
        json_str(&p.created_at),
        json_str(&p.author),
        p.like_count
    )
}

fn json_resp(status: StatusCode, body: String) -> Response {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(axum::body::Body::from(body))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

fn err(status: StatusCode, msg: &str) -> Response {
    json_resp(status, format!("{{\"error\":\"{msg}\"}}"))
}

fn get_text(map: &HashMap<'_, FileCore, Sha1Hasher, ReadOnly>, key: &str) -> Result<Vec<u8>> {
    match map.get(key)? {
        Some(c) => Ok(c.read_bytes_alloc()?),
        None => Err(Error::Corrupted),
    }
}

fn read_post<M>(map: &HashMap<'_, FileCore, Sha1Hasher, M>, id_str: &str) -> Result<Option<Post>> {
    let Some(pc) = map.get(id_str)? else {
        return Ok(None);
    };
    let pm = HashMap::new(pc)?;
    let id = match pm.get("id")? {
        Some(c) => c.read_uint()?,
        None => return Err(Error::Corrupted),
    };
    let body = String::from_utf8(get_text(&pm, "body")?).map_err(|_| Error::Corrupted)?;
    let created_at =
        String::from_utf8(get_text(&pm, "created_at")?).map_err(|_| Error::Corrupted)?;
    let author =
        String::from_utf8(get_text(&pm, "author")?).map_err(|_| Error::Corrupted)?;
    let like_count = match pm.get("like_count")? {
        Some(c) => c.read_uint()?,
        None => return Err(Error::Corrupted),
    };
    Ok(Some(Post {
        id,
        body,
        created_at,
        author,
        like_count,
    }))
}

fn read_feed_posts(db: &Db) -> Result<Vec<Post>> {
    let root_c = db.root_cursor();
    let root = HashMap::new_write(&root_c)?;
    let Some(feed_c) = root.get("feed")? else {
        return Ok(Vec::new());
    };
    let feed = SortedMap::new(feed_c)?;
    let count = feed.count()?;
    let start = count.saturating_sub(20);
    let mut ids: Vec<String> = Vec::new();
    let mut idx = start;
    while idx < count {
        let i64_idx =
            i64::try_from(idx).map_err(|_| Error::Corrupted)?;
        if let Some(kv) = feed.get_index_key_value_pair(i64_idx)? {
            let raw = kv.value.read_bytes_alloc()?;
            ids.push(String::from_utf8(raw).map_err(|_| Error::Corrupted)?);
        }
        idx = idx.saturating_add(1);
    }
    let Some(posts_c) = root.get("posts")? else {
        return Ok(Vec::new());
    };
    let posts = HashMap::new(posts_c)?;
    let mut out = Vec::new();
    for id in &ids {
        if let Some(p) = read_post(&posts, id)? {
            out.push(p);
        }
    }
    out.reverse();
    Ok(out)
}

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis().min(u128::from(u64::MAX)) as u64)
        .unwrap_or(0)
}

// Millis -> `YYYY-MM-DDTHH:MM:SS.mmmZ` UTC (civil-date algorithm).
// Domain is ms >= 0 (seed + wall clock); identical output to chrono's
// `%Y-%m-%dT%H:%M:%S%.3fZ` on that domain (no chrono dep on purpose:
// its `time` subtree keeps outgrowing our pinned toolchain).
fn format_millis_z(ms: u64) -> String {
    let days = ms / 86_400_000;
    let rem = ms % 86_400_000;
    let z = days + 719_468;
    let era = z / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let mut y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    if m <= 2 {
        y += 1;
    }
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        y,
        m,
        d,
        rem / 3_600_000,
        (rem % 3_600_000) / 60_000,
        (rem % 60_000) / 1_000,
        rem % 1_000
    )
}

fn now_millis_z() -> String {
    format_millis_z(now_millis())
}

// ---------- HTTP layer ----------

fn bearer(headers: &HeaderMap) -> Option<String> {
    let v = headers.get("authorization")?.to_str().ok()?;
    v.strip_prefix("Bearer ").map(str::to_string)
}

fn auth(headers: &HeaderMap, secret: &str) -> std::result::Result<(u64, String), Response> {
    match bearer(headers) {
        Some(t) => verify_jwt(&t, secret)
            .map_err(|m| err(StatusCode::UNAUTHORIZED, m)),
        None => Err(err(StatusCode::UNAUTHORIZED, "missing bearer token")),
    }
}

async fn health(State(state): State<Shared>) -> Response {
    let moved = Arc::clone(&state);
    let outcome = tokio::task::spawn_blocking(move || {
        let guard = moved.db.lock().unwrap_or_else(|e| e.into_inner());
        let size: Result<u64> = guard.committed_size();
        drop(guard);
        size
    })
    .await;
    match outcome {
        Ok(Ok(_)) => {
            let uptime = state.boot.elapsed().as_secs();
            json_resp(
                StatusCode::OK,
                format!("{{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":{uptime}}}"),
            )
        }
        _ => json_resp(
            StatusCode::SERVICE_UNAVAILABLE,
            "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"read failed\"}".to_string(),
        ),
    }
}

async fn feed(State(state): State<Shared>) -> Response {
    let moved = Arc::clone(&state);
    let outcome = tokio::task::spawn_blocking(move || {
        let guard = moved.db.lock().unwrap_or_else(|e| e.into_inner());
        let posts = read_feed_posts(&guard);
        drop(guard);
        posts
    })
    .await;
    match outcome {
        Ok(Ok(posts)) => {
            let mut body = String::from("{\"posts\":[");
            for (i, p) in posts.iter().enumerate() {
                if i > 0 {
                    body.push(',');
                }
                body.push_str(&post_json(p));
            }
            body.push_str("]}");
            json_resp(StatusCode::OK, body)
        }
        _ => err(StatusCode::INTERNAL_SERVER_ERROR, "internal server error"),
    }
}

async fn get_post(State(state): State<Shared>, Path(id_raw): Path<String>) -> Response {
    let Some(id) = is_valid_post_id(&id_raw) else {
        return err(StatusCode::BAD_REQUEST, "invalid post id");
    };
    let id_str = id.to_string();
    let outcome = tokio::task::spawn_blocking(move || {
        let guard = state.db.lock().unwrap_or_else(|e| e.into_inner());
        let found = (|| {
            let root = HashMap::new_write(&guard.root_cursor())?;
            let Some(posts_c) = root.get("posts")? else {
                return Ok(None);
            };
            let posts = HashMap::new(posts_c)?;
            read_post(&posts, &id_str)
        })();
        drop(guard);
        found
    })
    .await;
    match outcome {
        Ok(Ok(Some(p))) => json_resp(
            StatusCode::OK,
            format!("{{\"post\":{}}}", post_json(&p)),
        ),
        Ok(Ok(None)) => err(StatusCode::NOT_FOUND, "post not found"),
        _ => err(StatusCode::INTERNAL_SERVER_ERROR, "internal server error"),
    }
}

async fn create_post(
    State(state): State<Shared>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let (_user_id, username) = match auth(&headers, &state.secret) {
        Ok(a) => a,
        Err(r) => return r,
    };
    let value: serde_json::Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => return err(StatusCode::BAD_REQUEST, "malformed JSON body"),
    };
    let trimmed = match trim_validate_body(&value) {
        Ok(s) => s,
        Err(m) => return err(StatusCode::BAD_REQUEST, m),
    };
    let moved = Arc::clone(&state);
    let outcome = tokio::task::spawn_blocking(move || {
        let guard = moved.db.lock().unwrap_or_else(|e| e.into_inner());
        let created: Result<Post> = (|| {
            let mut out: Option<Post> = None;
            guard.run_context(|w| {
                let root = HashMap::new_write(w)?;
                let meta_c = root.put_cursor("meta")?;
                let meta = HashMap::new_write(&meta_c)?;
                let next: u64 = match meta.get("next_post_id")? {
                    Some(c) => c.read_uint()?,
                    None => 1,
                };
                let created_at = now_millis_z();
                let posts_c = root.put_cursor("posts")?;
                let posts = HashMap::new_write(&posts_c)?;
                let id_str = next.to_string();
                let pc = posts.put_cursor(&id_str)?;
                let pm = HashMap::new_write(&pc)?;
                pm.put("id", Writeable::Uint(next))?;
                pm.put("body", Writeable::Bytes(trimmed.as_bytes().to_vec()))?;
                pm.put(
                    "created_at",
                    Writeable::Bytes(created_at.as_bytes().to_vec()),
                )?;
                pm.put(
                    "author",
                    Writeable::Bytes(username.as_bytes().to_vec()),
                )?;
                pm.put("like_count", Writeable::Uint(0))?;
                let feed_c = root.put_cursor("feed")?;
                let feed = SortedMap::new_write(&feed_c)?;
                feed.put(
                    &feed_key(&created_at, next),
                    Writeable::Bytes(id_str.as_bytes().to_vec()),
                )?;
                let likes_c = root.put_cursor("likes")?;
                let likes = HashMap::new_write(&likes_c)?;
                let set_c = likes.put_cursor(&id_str)?;
                let _set = HashSet::new_write(&set_c)?;
                meta.put("next_post_id", Writeable::Uint(next.saturating_add(1)))?;
                out = Some(Post {
                    id: next,
                    body: trimmed.clone(),
                    created_at,
                    author: username.clone(),
                    like_count: 0,
                });
                Ok(())
            })?;
            out.ok_or(Error::Corrupted)
        })();
        drop(guard);
        created
    })
    .await;
    match outcome {
        Ok(Ok(p)) => json_resp(
            StatusCode::CREATED,
            format!("{{\"post\":{}}}", post_json(&p)),
        ),
        _ => err(StatusCode::INTERNAL_SERVER_ERROR, "internal server error"),
    }
}

async fn like_post(
    State(state): State<Shared>,
    Path(id_raw): Path<String>,
    headers: HeaderMap,
) -> Response {
    // Auth first, then id (spec order).
    let (user_id, _username) = match auth(&headers, &state.secret) {
        Ok(a) => a,
        Err(r) => return r,
    };
    let Some(id) = is_valid_post_id(&id_raw) else {
        return err(StatusCode::BAD_REQUEST, "invalid post id");
    };
    let id_str = id.to_string();
    let user_str = user_id.to_string();
    let moved = Arc::clone(&state);
    let outcome = tokio::task::spawn_blocking(move || {
        let guard = moved.db.lock().unwrap_or_else(|e| e.into_inner());
        let done: Result<Option<bool>> = (|| {
            let mut already: Option<bool> = None;
            guard.run_context(|w| {
                let root = HashMap::new_write(w)?;
                let posts_c = root.put_cursor("posts")?;
                let posts = HashMap::new_write(&posts_c)?;
                if read_post(&posts, &id_str)?.is_none() {
                    return Ok(());
                }
                let likes_c = root.put_cursor("likes")?;
                let likes = HashMap::new_write(&likes_c)?;
                let set_c = likes.put_cursor(&id_str)?;
                let set = HashSet::new_write(&set_c)?;
                if set.contains(&user_str)? {
                    already = Some(true);
                } else {
                    set.put(&user_str)?;
                    let pc = posts.put_cursor(&id_str)?;
                    let pm = HashMap::new_write(&pc)?;
                    let current = match pm.get("like_count")? {
                        Some(c) => c.read_uint()?,
                        None => return Err(Error::Corrupted),
                    };
                    pm.put(
                        "like_count",
                        Writeable::Uint(current.saturating_add(1)),
                    )?;
                    already = Some(false);
                }
                Ok(())
            })?;
            Ok(already)
        })();
        drop(guard);
        done
    })
    .await;
    match outcome {
        Ok(Ok(Some(true))) => json_resp(
            StatusCode::OK,
            format!("{{\"liked\":true,\"already_liked\":true,\"post_id\":{id}}}"),
        ),
        Ok(Ok(Some(false))) => json_resp(
            StatusCode::CREATED,
            format!("{{\"liked\":true,\"already_liked\":false,\"post_id\":{id}}}"),
        ),
        Ok(Ok(None)) => err(StatusCode::NOT_FOUND, "post not found"),
        _ => err(StatusCode::INTERNAL_SERVER_ERROR, "internal server error"),
    }
}

async fn not_found() -> Response {
    err(StatusCode::NOT_FOUND, "not found")
}

#[tokio::main]
async fn main() -> std::result::Result<(), Box<dyn std::error::Error>> {
    let db_path = std::env::var("XITDB_PATH").unwrap_or_else(|_| {
        std::env::args()
            .nth(1)
            .unwrap_or_else(|| "feed.xitdb".to_string())
    });
    let secret =
        std::env::var("JWT_SECRET").unwrap_or_else(|_| "twelve-dollar-challenge".to_string());
    let host = std::env::var("HOST").unwrap_or_else(|_| "127.0.0.1".to_string());
    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(3000);
    let file = OpenOptions::new().read(true).write(true).open(&db_path)?;
    let db: Db = Database::open(
        FileCore::new(file, true),
        Sha1Hasher,
        InitOpts {
            hash_id: None,
            file_id: None,
            fsync: true,
        },
    )?;
    let state: Shared = Arc::new(AppState {
        db: Mutex::new(db),
        secret,
        boot: Instant::now(),
    });
    let app: Router = Router::new()
        .route("/health", get(health))
        .route("/feed", get(feed))
        .route("/posts/{id}", get(get_post))
        .route("/posts", post(create_post))
        .route("/posts/{id}/like", post(like_post))
        .fallback(not_found)
        .with_state(state);
    let addr = format!("{host}:{port}");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    println!("serving {db_path} on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn feed_key_format_and_order() {
        assert_eq!(
            feed_key("2025-01-01T00:00:00.000Z", 7),
            "2025-01-01T00:00:00.000Z\x000000000007"
        );
        assert!(
            feed_key("2025-01-01T00:00:00.000Z", 7)
                < feed_key("2025-01-01T00:00:00.000Z", 8)
        );
    }

    #[test]
    fn post_id_table() {
        assert_eq!(is_valid_post_id("1"), Some(1));
        assert_eq!(is_valid_post_id("0"), None);
        assert_eq!(is_valid_post_id("-1"), None);
        assert_eq!(is_valid_post_id("abc"), None);
        assert_eq!(is_valid_post_id("1.5"), None);
        assert_eq!(is_valid_post_id(""), None);
        assert_eq!(is_valid_post_id("999999999"), Some(999999999));
    }

    #[test]
    fn body_trim_table() {
        assert_eq!(
            trim_validate_body(&json!({"body": "  hi "})),
            Ok("hi".to_string())
        );
        assert_eq!(
            trim_validate_body(&json!({"body": "   "})),
            Err("body is required")
        );
        assert_eq!(
            trim_validate_body(&json!({"body": 123})),
            Err("body is required")
        );
        assert_eq!(trim_validate_body(&json!({})), Err("body is required"));
        assert_eq!(
            trim_validate_body(&json!({"body": "a".repeat(501)})),
            Err("body must be at most 500 characters")
        );
        assert_eq!(
            trim_validate_body(&json!({"body": "b".repeat(500)})),
            Ok("b".repeat(500))
        );
    }

    fn sign(secret: &str, claims: serde_json::Value) -> String {
        use base64::Engine;
        let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let header = b64.encode(b"{\"alg\":\"HS256\",\"typ\":\"JWT\"}");
        let payload = b64.encode(serde_json::to_vec(&claims).expect("test json failed"));
        let mac = super::hmac_sha256(secret.as_bytes(), format!("{header}.{payload}").as_bytes());
        format!("{header}.{payload}.{}", b64.encode(mac))
    }

    #[test]
    fn format_millis_vectors() {
        assert_eq!(format_millis_z(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(format_millis_z(1_704_067_200_000), "2024-01-01T00:00:00.000Z");
        assert_eq!(format_millis_z(1_709_251_200_000), "2024-03-01T00:00:00.000Z");
        assert_eq!(format_millis_z(1_735_689_634_152), "2025-01-01T00:00:34.152Z");
    }

    #[test]
    fn jwt_vectors() {
        let secret = "twelve-dollar-challenge";
        let now = now_millis() / 1_000;
        let good = sign(
            secret,
            json!({"sub": "1", "username": "alice", "iat": now, "exp": now + 3600}),
        );
        assert_eq!(verify_jwt(&good, secret), Ok((1, "alice".to_string())));
        let bad_sig = sign(
            "wrong-secret",
            json!({"sub": "1", "username": "alice", "iat": now, "exp": now + 3600}),
        );
        assert_eq!(
            verify_jwt(&bad_sig, secret),
            Err("invalid or expired token")
        );
        let expired = sign(
            secret,
            json!({"sub": "1", "username": "alice", "iat": now - 7200, "exp": now - 3600}),
        );
        assert_eq!(
            verify_jwt(&expired, secret),
            Err("invalid or expired token")
        );
        assert_eq!(
            verify_jwt("abc", secret),
            Err("invalid or expired token")
        );
        let none_token = {
            let h = base64_url(b"{\"alg\":\"none\",\"typ\":\"JWT\"}");
            let p = base64_url(
                format!("{{\"sub\":\"1\",\"username\":\"alice\",\"iat\":{now},\"exp\":{}}}",
                    now + 3600)
                .as_bytes(),
            );
            format!("{h}.{p}.")
        };
        assert_eq!(
            verify_jwt(&none_token, secret),
            Err("invalid or expired token")
        );
        let bad_sub = sign(
            secret,
            json!({"sub": "abc", "username": "alice", "iat": now, "exp": now + 3600}),
        );
        assert_eq!(
            verify_jwt(&bad_sub, secret),
            Err("invalid token payload")
        );
        let no_name = sign(
            secret,
            json!({"sub": "1", "iat": now, "exp": now + 3600}),
        );
        assert_eq!(
            verify_jwt(&no_name, secret),
            Err("invalid token payload")
        );
    }

    fn base64_url(bytes: &[u8]) -> String {
        const ALPHABET: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let mut out = String::new();
        for chunk in bytes.chunks(3) {
            let mut n: u32 = 0;
            for (i, b) in chunk.iter().enumerate() {
                n |= (*b as u32) << (16 - 8 * i);
            }
            let chars = (chunk.len() * 8 + 5) / 6;
            for i in 0..chars {
                let shift = 18 - 6 * i;
                out.push(ALPHABET[((n >> shift) & 63) as usize] as char);
            }
        }
        out
    }
}
