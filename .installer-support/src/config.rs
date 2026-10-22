//! JSON installation-config export, apply, diff, and roundtrip.

use serde_json::{Map, Value};
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

pub fn export_state(path: &Path) -> Result<Value, String> {
    parse_state(&fs::read_to_string(path).map_err(|error| error.to_string())?)
}

pub fn apply_document(document: &Value, path: &Path) -> Result<(), String> {
    fs::write(path, write_state(document)?).map_err(|error| error.to_string())
}

pub fn load_document(path: &Path) -> Result<Value, String> {
    let text = fs::read_to_string(path).map_err(|error| error.to_string())?;
    if text.trim().is_empty() {
        return Ok(serde_json::json!({"schema_version": 1, "scope": "standalone", "components": {}}));
    }
    let mut document: Value = serde_json::from_str(&text).map_err(|error| error.to_string())?;
    let object = document.as_object_mut().ok_or_else(|| format!("config root must be an object: {}", path.display()))?;
    object.entry("schema_version".to_string()).or_insert(serde_json::json!(1));
    Ok(document)
}

pub fn diff_documents(baseline: &Value, current: &Value) -> Vec<String> {
    let mut changes = Vec::new();
    let base_scope = text_field(baseline, "scope");
    let curr_scope = text_field(current, "scope");
    if base_scope != curr_scope {
        changes.push(format!("scope: {base_scope} -> {curr_scope}"));
        return changes;
    }
    if base_scope == "standalone" {
        changes.extend(diff_components(&text_field(baseline, "repo"), object_field(baseline, "components"), object_field(current, "components")));
        return changes;
    }
    let base_repos = object_field(baseline, "repos");
    let curr_repos = object_field(current, "repos");
    let mut names: BTreeSet<String> = base_repos.keys().cloned().collect();
    names.extend(curr_repos.keys().cloned());
    for repo in names {
        let empty = serde_json::json!({"enabled": 0, "components": {}});
        let base_entry = base_repos.get(&repo).unwrap_or(&empty);
        let curr_entry = curr_repos.get(&repo).unwrap_or(&empty);
        let base_enabled = flag_int(base_entry.get("enabled"));
        let curr_enabled = flag_int(curr_entry.get("enabled"));
        if base_enabled != curr_enabled {
            let state = if curr_enabled == 1 { "enabled" } else { "disabled" };
            changes.push(format!("repo {repo}: {state}"));
        }
        changes.extend(diff_components(&repo, object_of(base_entry, "components"), object_of(curr_entry, "components")));
    }
    changes
}

pub fn is_explicit_empty(document: &Value) -> bool {
    let scope = scope_name(document);
    if scope == "master" { object_field(document, "repos").is_empty() } else { object_field(document, "components").is_empty() }
}

pub fn scope_name(document: &Value) -> String {
    let scope = text_field(document, "scope");
    if scope.is_empty() { "standalone".into() } else { scope }
}

pub fn repo_enabled(document: &Value, repo: &str) -> i64 {
    flag_int(document.get("repos").and_then(|repos| repos.get(repo)).and_then(|entry| entry.get("enabled")))
}

pub fn component_ids(document: &Value, repo: Option<&str>) -> Vec<String> {
    if scope_name(document) == "master" {
        let Some(repo) = repo else { return Vec::new() };
        return object_of(document.get("repos").and_then(|repos| repos.get(repo)).unwrap_or(&Value::Null), "components").keys().cloned().collect();
    }
    object_field(document, "components").keys().cloned().collect()
}

pub fn dumps(value: &Value) -> String {
    format!("{}\n", dump_value(value, 0))
}

fn parse_state(text: &str) -> Result<Value, String> {
    let mut scope = "standalone".to_string();
    let mut repo = String::new();
    let mut repos: Map<String, Value> = Map::new();
    let mut current_repo = String::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(value) = line.strip_prefix("scope=") {
            scope = value.trim().to_string();
            continue;
        }
        if let Some(value) = line.strip_prefix("repo_name=") {
            repo = value.trim().to_string();
            continue;
        }
        if let Some(rest) = line.strip_prefix("repo:") {
            let mut parts = rest.splitn(2, ':');
            let name = parts.next().unwrap_or("").to_string();
            let enabled = parts.next().unwrap_or("0");
            current_repo = name.clone();
            let entry = repos.entry(name).or_insert_with(|| serde_json::json!({"enabled": 0, "components": {}}));
            if let Some(object) = entry.as_object_mut() {
                object.insert("enabled".into(), serde_json::json!(bool_int(enabled)));
                object.entry("components".to_string()).or_insert_with(|| serde_json::json!({}));
            }
            continue;
        }
        if let Some(rest) = line.strip_prefix("comp\t") {
            let mut parts = vec!["comp".to_string()];
            parts.extend(rest.split('\t').map(str::to_string));
            if parts.len() < 9 {
                continue;
            }
            let comp_repo = parts[1].clone();
            let comp_id = parts[2].clone();
            let mut entry = Map::new();
            entry.insert("on".into(), serde_json::json!(bool_int(&parts[3])));
            entry.insert("uninstall".into(), serde_json::json!(bool_int(&parts[4])));
            entry.insert("favorite".into(), serde_json::json!(bool_int(&parts[5])));
            entry.insert("startup".into(), serde_json::json!(bool_int(&parts[6])));
            entry.insert("workspace".into(), serde_json::json!(if parts[7].chars().all(|ch| ch.is_ascii_digit()) && !parts[7].is_empty() { parts[7].parse::<i64>().unwrap_or(0) } else { 0 }));
            entry.insert("sticky".into(), serde_json::json!(bool_int(&parts[8])));
            entry.insert("config_value".into(), serde_json::json!(parts.get(10).cloned().unwrap_or_default()));
            if parts.get(9).map(|value| !value.is_empty() && value.chars().all(|ch| ch.is_ascii_digit())).unwrap_or(false) {
                entry.insert("monitor".into(), serde_json::json!(parts[9].parse::<i64>().unwrap_or(0)));
            }
            let repo_entry = repos.entry(comp_repo).or_insert_with(|| serde_json::json!({"enabled": 1, "components": {}}));
            if let Some(components) = repo_entry.get_mut("components").and_then(Value::as_object_mut) {
                components.insert(comp_id, Value::Object(entry));
            }
        }
    }
    if scope == "master" {
        return Ok(serde_json::json!({"schema_version": 1, "scope": "master", "repos": repos}));
    }
    let selected = if !repo.is_empty() { repo } else { current_repo };
    let components = repos.get(&selected).and_then(|entry| entry.get("components")).cloned().unwrap_or_else(|| serde_json::json!({}));
    Ok(serde_json::json!({"schema_version": 1, "scope": "standalone", "repo": selected, "components": components}))
}

fn write_state(document: &Value) -> Result<String, String> {
    let scope = text_field(document, "scope");
    let scope = if scope.is_empty() { "standalone".to_string() } else { scope };
    let mut lines = vec![format!("scope={scope}")];
    if scope == "standalone" {
        let repo = text_field(document, "repo");
        lines.push(format!("repo_name={repo}"));
        lines.push(format!("repo:{repo}:1"));
        let components = object_field(document, "components");
        let mut ids: Vec<_> = components.keys().cloned().collect();
        ids.sort();
        for id in ids {
            lines.push(component_line(&repo, &id, &components[&id]));
        }
    } else {
        let repos = object_field(document, "repos");
        let mut names: Vec<_> = repos.keys().cloned().collect();
        names.sort();
        for name in names {
            let entry = &repos[&name];
            lines.push(format!("repo:{name}:{}", flag_int(entry.get("enabled"))));
            let components = object_of(entry, "components");
            let mut ids: Vec<_> = components.keys().cloned().collect();
            ids.sort();
            for id in ids {
                lines.push(component_line(&name, &id, &components[&id]));
            }
        }
    }
    Ok(format!("{}\n", lines.join("\n")))
}

fn component_line(repo: &str, id: &str, entry: &Value) -> String {
    let monitor = match entry.get("monitor") {
        Some(Value::Number(number)) => number.to_string(),
        Some(Value::String(text)) => text.clone(),
        _ => String::new(),
    };
    let config_value = match entry.get("config_value") {
        Some(Value::String(text)) => text.clone(),
        Some(other) => other.to_string(),
        None => String::new(),
    };
    [
        "comp",
        repo,
        id,
        &flag_int(entry.get("on")).to_string(),
        &flag_int(entry.get("uninstall")).to_string(),
        &flag_int(entry.get("favorite")).to_string(),
        &flag_int(entry.get("startup")).to_string(),
        &int_field(entry, "workspace").to_string(),
        &flag_int(entry.get("sticky")).to_string(),
        &monitor,
        &config_value,
    ].join("\t")
}

fn diff_components(repo: &str, baseline: Map<String, Value>, current: Map<String, Value>) -> Vec<String> {
    let mut changes = Vec::new();
    let mut ids: BTreeSet<String> = baseline.keys().cloned().collect();
    ids.extend(current.keys().cloned());
    for id in ids {
        let empty = Value::Object(Map::new());
        let base = baseline.get(&id).unwrap_or(&empty);
        let curr = current.get(&id).unwrap_or(&empty);
        let prefix = if repo.is_empty() { id.clone() } else { format!("{repo}/{id}") };
        for (field, label) in [("on", "selected"), ("uninstall", "uninstall"), ("favorite", "favorite"), ("startup", "startup"), ("sticky", "sticky")] {
            let base_val = flag_int(base.get(field));
            let curr_val = flag_int(curr.get(field));
            if base_val != curr_val {
                changes.push(format!("{prefix} {label}: {base_val} -> {curr_val}"));
            }
        }
        for (field, label) in [("workspace", "workspace"), ("monitor", "monitor")] {
            let base_val = int_field(base, field);
            let curr_val = int_field(curr, field);
            if base_val != curr_val {
                changes.push(format!("{prefix} {label}: {base_val} -> {curr_val}"));
            }
        }
        let base_cfg = string_field(base, "config_value");
        let curr_cfg = string_field(curr, "config_value");
        if base_cfg != curr_cfg {
            changes.push(format!("{prefix} config_value: {} -> {}", py_repr(&base_cfg), py_repr(&curr_cfg)));
        }
    }
    changes
}

fn bool_int(value: &str) -> i64 {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => 1,
        _ => 0,
    }
}

fn flag_int(value: Option<&Value>) -> i64 {
    match value {
        Some(Value::Bool(true)) | Some(Value::Number(_)) if truthy(value) => 1,
        Some(Value::String(text)) if bool_int(text) == 1 => 1,
        _ => 0,
    }
}

fn truthy(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(flag)) => *flag,
        Some(Value::Number(number)) => number.as_f64().unwrap_or(0.0) != 0.0,
        Some(Value::String(text)) => !text.is_empty() && text != "0",
        Some(Value::Array(items)) => !items.is_empty(),
        Some(Value::Object(map)) => !map.is_empty(),
        _ => false,
    }
}

fn int_field(value: &Value, field: &str) -> i64 {
    match value.get(field) {
        Some(Value::Number(number)) => number.as_i64().unwrap_or(0),
        Some(Value::String(text)) if !text.is_empty() && text.chars().all(|ch| ch.is_ascii_digit()) => text.parse().unwrap_or(0),
        _ => 0,
    }
}

fn string_field(value: &Value, field: &str) -> String {
    match value.get(field) {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string().trim_matches('"').to_string(),
    }
}

fn text_field(value: &Value, field: &str) -> String {
    value.get(field).and_then(Value::as_str).unwrap_or("").to_string()
}

fn object_field(value: &Value, field: &str) -> Map<String, Value> {
    object_of(value, field)
}

fn object_of(value: &Value, field: &str) -> Map<String, Value> {
    value.get(field).and_then(Value::as_object).cloned().unwrap_or_default()
}

fn py_repr(text: &str) -> String {
    if text.contains('\'') {
        format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
    } else {
        format!("'{}'", text.replace('\\', "\\\\"))
    }
}

fn dump_value(value: &Value, indent: usize) -> String {
    match value {
        Value::Null => "null".into(),
        Value::Bool(true) => "true".into(),
        Value::Bool(false) => "false".into(),
        Value::Number(number) => number.to_string(),
        Value::String(text) => json_string(text),
        Value::Array(items) => {
            if items.is_empty() { return "[]".into(); }
            let pad = " ".repeat(indent + 2);
            let inner = items.iter().map(|item| format!("{pad}{}", dump_value(item, indent + 2))).collect::<Vec<_>>().join(",\n");
            format!("[\n{inner}\n{}]", " ".repeat(indent))
        }
        Value::Object(map) => {
            if map.is_empty() { return "{}".into(); }
            let mut keys: Vec<_> = map.keys().cloned().collect();
            keys.sort();
            let pad = " ".repeat(indent + 2);
            let inner = keys.iter().map(|key| format!("{pad}{}: {}", json_string(key), dump_value(&map[key], indent + 2))).collect::<Vec<_>>().join(",\n");
            format!("{{\n{inner}\n{}}}", " ".repeat(indent))
        }
    }
}

fn json_string(text: &str) -> String {
    let mut out = String::from("\"");
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 || (c as u32) > 0x7f => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
