//! Friendly and GTK accelerator conversion for installer hotkeys.

use std::fs;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

const ORDER: [&str; 4] = ["Control", "Alt", "Super", "Shift"];

pub fn to_gnome_accelerator(spec: &str) -> Result<String, String> {
    let raw = spec.trim();
    if raw.is_empty() {
        return Err("empty hotkey specification".into());
    }
    let tokens: Vec<&str> = raw.split('+').map(str::trim).collect();
    if tokens.iter().any(|token| token.is_empty()) {
        return Err(format!("malformed hotkey {}: empty modifier or key", py_repr(spec)));
    }
    let key = tokens[tokens.len() - 1];
    let mut seen = Vec::new();
    for token in &tokens[..tokens.len() - 1] {
        let canonical = alias(token).ok_or_else(|| format!("unknown modifier {} in hotkey {}", py_repr(token), py_repr(spec)))?;
        if !seen.contains(&canonical) {
            seen.push(canonical);
        }
    }
    Ok(format!("{}{key}", prefix(&seen)))
}

pub fn normalize_accelerator(text: &str) -> Result<(Vec<&'static str>, String), String> {
    let value = text.trim();
    if value.is_empty() {
        return Err("empty accelerator".into());
    }
    let mut modifiers = Vec::new();
    let key = if value.contains('<') {
        for token in gtk_modifiers(value) {
            let canonical = alias(token).ok_or_else(|| format!("unknown modifier {} in accelerator {}", py_repr(token), py_repr(text)))?;
            if !modifiers.contains(&canonical) {
                modifiers.push(canonical);
            }
        }
        gtk_key(value)
    } else {
        let parts: Vec<&str> = value.split('+').map(str::trim).filter(|part| !part.is_empty()).collect();
        if parts.is_empty() {
            return Err(format!("accelerator {} has no key", py_repr(text)));
        }
        for token in &parts[..parts.len() - 1] {
            let canonical = alias(token).ok_or_else(|| format!("unknown modifier {} in accelerator {}", py_repr(token), py_repr(text)))?;
            if !modifiers.contains(&canonical) {
                modifiers.push(canonical);
            }
        }
        parts[parts.len() - 1].to_string()
    };
    if key.is_empty() {
        return Err(format!("accelerator {} has no key", py_repr(text)));
    }
    Ok((modifiers, key.to_lowercase()))
}

pub fn display_accelerator(text: &str) -> Result<String, String> {
    let (modifiers, key) = normalize_accelerator(text)?;
    let mut parts: Vec<String> = ORDER.iter().filter(|name| modifiers.contains(name)).map(|name| display_name(name).to_string()).collect();
    parts.push(if key.chars().count() == 1 { key.to_uppercase() } else { key });
    Ok(parts.join("+"))
}

pub fn normalize_modifier(text: &str) -> Result<&'static str, String> {
    let raw = text.trim();
    if raw.is_empty() || raw.contains('+') || raw.contains('<') || raw.contains('>') {
        return Err("enter exactly one modifier: Shift, Ctrl, Alt, or Super".into());
    }
    alias(raw).ok_or_else(|| format!("unknown modifier {}", py_repr(text)))
}

pub fn add_modifier(accelerator: &str, modifier: &str) -> Result<String, String> {
    let (mut modifiers, key) = normalize_accelerator(accelerator)?;
    let canonical = normalize_modifier(modifier)?;
    if modifiers.contains(&canonical) {
        return Err(format!("{} is already part of {}", display_name(canonical), display_accelerator(accelerator)?));
    }
    modifiers.push(canonical);
    Ok(format!("{}{key}", prefix(&modifiers)))
}

pub fn config_get(path: &Path, key: &str, default_value: &str) -> String {
    let Ok(text) = fs::read_to_string(path) else { return default_value.to_string() };
    for line in text.lines() {
        let (name, separator, value) = partition(line);
        if separator && name == key {
            return value.to_string();
        }
    }
    default_value.to_string()
}

pub fn config_set(path: &Path, key: &str, value: &str) -> Result<(), String> {
    if !valid_key(key) {
        return Err(format!("invalid config key {}", py_repr(key)));
    }
    if value.contains('\n') || value.contains('\r') {
        return Err("config values cannot contain newlines".into());
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let existing = fs::read_to_string(path).unwrap_or_default();
    let mut updated = Vec::new();
    let mut replaced = false;
    if path.is_file() {
        for line in existing.lines() {
            let (name, separator, _) = partition(line);
            if separator && name == key {
                updated.push(format!("{key}={value}"));
                replaced = true;
            } else {
                updated.push(line.to_string());
            }
        }
    }
    if !replaced {
        updated.push(format!("{key}={value}"));
    }
    let temporary = path.with_extension(format!("{}.tmp", path.extension().and_then(|ext| ext.to_str()).unwrap_or("field")));
    {
        let mut file = fs::OpenOptions::new().create(true).write(true).truncate(true).mode(0o600).open(&temporary).map_err(|error| error.to_string())?;
        file.write_all(format!("{}\n", updated.join("\n")).as_bytes()).map_err(|error| error.to_string())?;
    }
    fs::rename(&temporary, path).map_err(|error| error.to_string())?;
    Ok(())
}

fn alias(token: &str) -> Option<&'static str> {
    match token.to_ascii_lowercase().as_str() {
        "ctrl" | "control" => Some("Control"),
        "alt" | "meta" => Some("Alt"),
        "super" | "win" | "windows" | "cmd" => Some("Super"),
        "shift" => Some("Shift"),
        _ => None,
    }
}

fn display_name(name: &str) -> &'static str {
    match name {
        "Control" => "Ctrl",
        "Alt" => "Alt",
        "Super" => "Super",
        "Shift" => "Shift",
        _ => name_static(name),
    }
}

fn name_static(name: &str) -> &'static str {
    match name {
        "Control" => "Control",
        "Alt" => "Alt",
        "Super" => "Super",
        "Shift" => "Shift",
        _ => "",
    }
}

fn prefix(modifiers: &[&str]) -> String {
    ORDER.iter().filter(|name| modifiers.contains(name)).map(|name| format!("<{name}>")).collect()
}

fn gtk_modifiers(value: &str) -> Vec<&str> {
    let mut tokens = Vec::new();
    let mut rest = value;
    while let Some(start) = rest.find('<') {
        let after = &rest[start + 1..];
        let Some(end) = after.find('>') else { break };
        tokens.push(&after[..end]);
        rest = &after[end + 1..];
    }
    tokens
}

fn gtk_key(value: &str) -> String {
    let mut out = String::new();
    let mut rest = value;
    while let Some(start) = rest.find('<') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        let Some(end) = after.find('>') else {
            out.push_str(rest);
            return out;
        };
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    out
}

fn partition(line: &str) -> (&str, bool, &str) {
    match line.split_once('=') {
        Some((name, value)) => (name, true, value),
        None => (line, false, ""),
    }
}

fn valid_key(key: &str) -> bool {
    let mut chars = key.chars();
    match chars.next() {
        Some(first) if first.is_ascii_uppercase() => chars.all(|ch| ch.is_ascii_uppercase() || ch.is_ascii_digit() || ch == '_'),
        _ => false,
    }
}

fn py_repr(text: &str) -> String {
    if text.contains('\'') {
        format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
    } else {
        format!("'{text}'")
    }
}
