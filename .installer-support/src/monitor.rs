//! Display monitors numbered like GNOME Settings.

use serde_json::Value;
use std::collections::HashMap;
use std::process::Command;

const ROTATED: [i64; 4] = [1, 3, 5, 7];

pub struct Row {
    pub number: usize,
    pub connector: String,
    pub name: String,
    pub primary: i64,
    pub x: i64,
    pub y: i64,
    pub width: i64,
    pub height: i64,
}

pub fn format_rows(rows: &[Row]) -> String {
    rows.iter().map(|row| format!("{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}", row.number, row.connector, row.name, row.primary, row.x, row.y, row.width, row.height)).collect::<Vec<_>>().join("\n")
}

pub fn rows_from_simplified(document: &Value) -> Result<Vec<Row>, String> {
    let monitors = document.get("monitors").and_then(Value::as_array).ok_or_else(|| "monitors must be an array".to_string())?;
    let logical = document.get("logical").and_then(Value::as_array).unwrap_or(&Vec::new()).clone();
    let mut geometry = HashMap::new();
    let mut primary = Vec::new();
    for entry in &logical {
        let x = as_i64(entry.get("x"));
        let y = as_i64(entry.get("y"));
        let scale = as_f64(entry.get("scale"));
        let scale = if scale == 0.0 { 1.0 } else { scale };
        let transform = as_i64(entry.get("transform"));
        let is_primary = entry.get("primary").and_then(Value::as_bool).unwrap_or(false);
        let connectors = entry.get("connectors").and_then(Value::as_array).cloned().unwrap_or_default();
        for connector_value in connectors {
            let Some(connector) = connector_value.as_str() else { continue };
            if is_primary {
                primary.push(connector.to_string());
            }
            let (mut width, mut height) = current_mode(monitors, connector);
            width = (width as f64 / scale).round() as i64;
            height = (height as f64 / scale).round() as i64;
            if ROTATED.contains(&transform) {
                std::mem::swap(&mut width, &mut height);
            }
            geometry.insert(connector.to_string(), (x, y, width, height));
        }
    }
    Ok(materialize(monitors, &geometry, &primary))
}

pub fn rows_from_busctl(document: &Value) -> Result<Vec<Row>, String> {
    let data = document.get("data").and_then(Value::as_array).ok_or_else(|| "DisplayConfig JSON has no data".to_string())?;
    let monitors = data.get(1).and_then(Value::as_array).ok_or_else(|| "DisplayConfig monitors missing".to_string())?;
    let logical = data.get(2).and_then(Value::as_array).unwrap_or(&Vec::new()).clone();
    let mut geometry = HashMap::new();
    let mut primary = Vec::new();
    for entry in &logical {
        let parts = entry.as_array().ok_or_else(|| "logical monitor must be an array".to_string())?;
        let x = as_i64(parts.get(0));
        let y = as_i64(parts.get(1));
        let scale = as_f64(parts.get(2));
        let scale = if scale == 0.0 { 1.0 } else { scale };
        let transform = as_i64(parts.get(3));
        let is_primary = parts.get(4).and_then(Value::as_bool).unwrap_or(false);
        let assigned = parts.get(5).and_then(Value::as_array).cloned().unwrap_or_default();
        for item in assigned {
            let Some(connector) = item.as_array().and_then(|fields| fields.first()).and_then(Value::as_str) else { continue };
            if is_primary {
                primary.push(connector.to_string());
            }
            let (mut width, mut height) = current_mode_busctl(monitors, connector);
            width = (width as f64 / scale).round() as i64;
            height = (height as f64 / scale).round() as i64;
            if ROTATED.contains(&transform) {
                std::mem::swap(&mut width, &mut height);
            }
            geometry.insert(connector.to_string(), (x, y, width, height));
        }
    }
    let mut rows = Vec::new();
    for (index, monitor) in monitors.iter().enumerate() {
        let fields = monitor.as_array().ok_or_else(|| "monitor must be an array".to_string())?;
        let connector = fields.first().and_then(Value::as_array).and_then(|id| id.first()).and_then(Value::as_str).unwrap_or("").to_string();
        let name = fields.get(2).and_then(|props| props.get("display-name")).map(variant_string).filter(|name| !name.is_empty()).unwrap_or_else(|| connector.clone());
        let (x, y, width, height) = geometry.get(&connector).copied().unwrap_or((0, 0, 0, 0));
        rows.push(Row { number: index + 1, connector, name, primary: if primary.iter().any(|item| item == &rows_connector(monitor)) { 1 } else { 0 }, x, y, width, height });
    }
    fn rows_connector(monitor: &Value) -> String {
        monitor.as_array().and_then(|fields| fields.first()).and_then(Value::as_array).and_then(|id| id.first()).and_then(Value::as_str).unwrap_or("").to_string()
    }
    for row in &mut rows {
        row.primary = if primary.iter().any(|item| item == &row.connector) { 1 } else { 0 };
    }
    Ok(rows)
}

pub fn query_busctl() -> Result<Vec<Row>, String> {
    let output = Command::new("busctl").args(["--user", "call", "org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig", "org.gnome.Mutter.DisplayConfig", "GetCurrentState", "--json=short"]).output().map_err(|error| format!("DisplayConfig call failed: {error}"))?;
    if !output.status.success() {
        return Err(format!("DisplayConfig call failed: {}", String::from_utf8_lossy(&output.stderr).trim()));
    }
    let document: Value = serde_json::from_slice(&output.stdout).map_err(|error| format!("DisplayConfig call failed: {error}"))?;
    let rows = rows_from_busctl(&document)?;
    if rows.is_empty() {
        return Err("DisplayConfig returned no monitors".into());
    }
    Ok(rows)
}

fn materialize(monitors: &[Value], geometry: &HashMap<String, (i64, i64, i64, i64)>, primary: &[String]) -> Vec<Row> {
    monitors.iter().enumerate().map(|(index, monitor)| {
        let connector = monitor.get("connector").and_then(Value::as_str).unwrap_or("").to_string();
        let name = monitor.get("name").and_then(Value::as_str).filter(|name| !name.is_empty()).unwrap_or(&connector).to_string();
        let (x, y, width, height) = geometry.get(&connector).copied().unwrap_or((0, 0, 0, 0));
        let is_primary = if primary.iter().any(|item| item == &connector) { 1 } else { 0 };
        Row { number: index + 1, connector, name, primary: is_primary, x, y, width, height }
    }).collect()
}

fn current_mode(monitors: &[Value], connector: &str) -> (i64, i64) {
    for monitor in monitors {
        if monitor.get("connector").and_then(Value::as_str) != Some(connector) {
            continue;
        }
        for mode in monitor.get("modes").and_then(Value::as_array).into_iter().flatten() {
            if mode.get("current").and_then(Value::as_bool).unwrap_or(false) {
                return (as_i64(mode.get("width")), as_i64(mode.get("height")));
            }
        }
    }
    (0, 0)
}

fn current_mode_busctl(monitors: &[Value], connector: &str) -> (i64, i64) {
    for monitor in monitors {
        let id = monitor.as_array().and_then(|fields| fields.first()).and_then(Value::as_array);
        if id.and_then(|fields| fields.first()).and_then(Value::as_str) != Some(connector) {
            continue;
        }
        let modes = monitor.as_array().and_then(|fields| fields.get(1)).and_then(Value::as_array);
        for mode in modes.into_iter().flatten() {
            let props = mode.as_array().and_then(|fields| fields.get(6));
            if props.and_then(|value| value.get("is-current")).map(variant_bool).unwrap_or(false) {
                let fields = mode.as_array().unwrap();
                return (as_i64(fields.get(1)), as_i64(fields.get(2)));
            }
        }
    }
    (0, 0)
}

fn variant_bool(value: &Value) -> bool {
    value.as_bool().or_else(|| value.get("data").and_then(Value::as_bool)).unwrap_or(false)
}

fn variant_string(value: &Value) -> String {
    value.as_str().map(str::to_string).or_else(|| value.get("data").and_then(Value::as_str).map(str::to_string)).unwrap_or_default()
}

fn as_i64(value: Option<&Value>) -> i64 {
    match value {
        Some(Value::Number(number)) => number.as_i64().unwrap_or_else(|| number.as_f64().unwrap_or(0.0).round() as i64),
        _ => 0,
    }
}

fn as_f64(value: Option<&Value>) -> f64 {
    match value {
        Some(Value::Number(number)) => number.as_f64().unwrap_or(0.0),
        _ => 0.0,
    }
}
