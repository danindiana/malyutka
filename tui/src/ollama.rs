//! Minimal Ollama client: lists local models via GET /api/tags (plain HTTP, no extra deps).
use serde_json::Value;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq)]
pub struct Model {
    pub name: String,
    pub params: String,
    pub size_gb: f64,
}

pub fn default_base() -> String {
    match std::env::var("OLLAMA_HOST") {
        Ok(h) if h.starts_with("http") => h,
        Ok(h) if !h.is_empty() => format!("http://{h}"),
        _ => "http://127.0.0.1:11434".to_string(),
    }
}

pub fn parse_tags(body: &str) -> Result<Vec<Model>, String> {
    let v: Value = serde_json::from_str(body).map_err(|e| format!("bad response: {e}"))?;
    let arr = v
        .get("models")
        .and_then(Value::as_array)
        .ok_or("no 'models' in response")?;
    let mut out: Vec<Model> = arr
        .iter()
        .filter_map(|m| {
            let name = m.get("name")?.as_str()?.to_string();
            if name.contains("embed") {
                return None; // embedding models cannot chat
            }
            Some(Model {
                params: m["details"]["parameter_size"]
                    .as_str()
                    .unwrap_or("")
                    .to_string(),
                size_gb: m.get("size").and_then(Value::as_f64).unwrap_or(0.0) / 1e9,
                name,
            })
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

fn host_port(base: &str) -> Result<(String, u16), String> {
    let rest = base
        .strip_prefix("http://")
        .ok_or("only http:// base URLs are supported")?;
    let hp = rest.split('/').next().unwrap_or("");
    match hp.rsplit_once(':') {
        Some((h, p)) => Ok((h.to_string(), p.parse().map_err(|_| "bad port")?)),
        None => Ok((hp.to_string(), 80)),
    }
}

pub fn list_models(base: &str) -> Result<Vec<Model>, String> {
    let (host, port) = host_port(base)?;
    let addr = (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|e| e.to_string())?
        .next()
        .ok_or("cannot resolve host")?;
    let mut s = TcpStream::connect_timeout(&addr, Duration::from_secs(2))
        .map_err(|e| format!("cannot reach Ollama at {base}: {e}"))?;
    s.set_read_timeout(Some(Duration::from_secs(5))).ok();
    write!(
        s,
        "GET /api/tags HTTP/1.0\r\nHost: {host}\r\nAccept: application/json\r\n\r\n"
    )
    .map_err(|e| e.to_string())?;
    let mut raw = String::new();
    s.read_to_string(&mut raw).map_err(|e| e.to_string())?;
    let (head, body) = raw
        .split_once("\r\n\r\n")
        .ok_or("malformed HTTP response")?;
    if !head.starts_with("HTTP/1.0 200") && !head.starts_with("HTTP/1.1 200") {
        return Err(format!(
            "Ollama replied: {}",
            head.lines().next().unwrap_or("")
        ));
    }
    parse_tags(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_filters_embeddings() {
        let body = r#"{"models":[
          {"name":"b:1","size":2000000000,"details":{"parameter_size":"8B"}},
          {"name":"nomic-embed-text:latest","size":1,"details":{}},
          {"name":"a:2","size":5000000000,"details":{"parameter_size":"27B"}}]}"#;
        let m = parse_tags(body).unwrap();
        assert_eq!(
            m.iter().map(|m| m.name.as_str()).collect::<Vec<_>>(),
            ["a:2", "b:1"]
        );
        assert_eq!(m[0].params, "27B");
        assert!((m[1].size_gb - 2.0).abs() < 1e-9);
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_tags("nope").is_err());
        assert!(parse_tags("{}").is_err());
    }

    #[test]
    fn host_parsing() {
        assert_eq!(
            host_port("http://127.0.0.1:11434").unwrap(),
            ("127.0.0.1".into(), 11434)
        );
        assert!(host_port("https://x").is_err());
    }
}
