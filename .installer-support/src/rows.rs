//! Ordered installer rows addressed by one-based indexes.

use serde_json::{json, Map, Value};

pub fn apply_script(raw: &str) -> Result<Value, String> {
    let script: Value = serde_json::from_str(raw.trim()).map_err(|error| format!("invalid command script: {error}"))?;
    let script = script.as_object().ok_or_else(|| "command script must be an object".to_string())?;
    let mut items = match script.get("items") {
        Some(Value::Array(rows)) => rows.iter().map(copy_row).collect::<Result<Vec<_>, _>>()?,
        Some(_) => return Err("items must be an array".into()),
        None => Vec::new(),
    };
    let commands = script.get("commands").and_then(Value::as_array).ok_or_else(|| "commands must be an array".to_string())?;
    let mut results = Vec::new();
    for command in commands {
        results.push(apply_command(&mut items, command)?);
    }
    Ok(json!({"results": results, "items": items}))
}

fn apply_command(items: &mut Vec<Map<String, Value>>, command: &Value) -> Result<Value, String> {
    let parts = command.as_array().ok_or_else(|| "command must be an array".to_string())?;
    let name = parts.first().and_then(Value::as_str).unwrap_or("");
    match name {
        "add" => {
            let values = parts.get(1).ok_or_else(|| "add requires a row".to_string())?;
            items.push(copy_row(values)?);
            Ok(json!(items.len()))
        }
        "set" => {
            let index = number_arg(parts, 1)?;
            let field = text_arg(parts, 2)?;
            let value = parts.get(3).cloned().unwrap_or(Value::Null);
            Ok(json!(set_value(items, index, &field, value)))
        }
        "toggle" => {
            let index = number_arg(parts, 1)?;
            let field = text_arg(parts, 2)?;
            Ok(json!(toggle(items, index, &field)))
        }
        "set-group" => {
            let index = number_arg(parts, 1)?;
            let group = number_arg(parts, 2)?;
            if group < 0 {
                return Err("group must be zero or greater".into());
            }
            Ok(json!(set_value(items, index, "group", json!(group))))
        }
        other => Err(format!("unknown command: {other}")),
    }
}

fn set_value(items: &mut [Map<String, Value>], index: i64, field: &str, value: Value) -> bool {
    let Some(row) = row_mut(items, index) else { return false };
    row.insert(field.to_string(), value);
    true
}

fn toggle(items: &mut [Map<String, Value>], index: i64, field: &str) -> bool {
    let Some(row) = row_mut(items, index) else { return false };
    let current = row.get(field).cloned().unwrap_or(Value::Null);
    row.insert(field.to_string(), json!(!truthy(&current)));
    true
}

fn row_mut(items: &mut [Map<String, Value>], index: i64) -> Option<&mut Map<String, Value>> {
    if index < 1 { return None; }
    items.get_mut((index as usize) - 1)
}

fn truthy(value: &Value) -> bool {
    match value {
        Value::Null | Value::Bool(false) => false,
        Value::Bool(true) => true,
        Value::Number(number) => number.as_f64().unwrap_or(0.0) != 0.0,
        Value::String(text) => !text.is_empty(),
        Value::Array(items) => !items.is_empty(),
        Value::Object(map) => !map.is_empty(),
    }
}

fn copy_row(value: &Value) -> Result<Map<String, Value>, String> {
    value.as_object().cloned().ok_or_else(|| "row must be an object".to_string())
}

fn number_arg(parts: &[Value], index: usize) -> Result<i64, String> {
    parts.get(index).and_then(Value::as_i64).ok_or_else(|| format!("argument {index} must be an integer"))
}

fn text_arg(parts: &[Value], index: usize) -> Result<String, String> {
    parts.get(index).and_then(Value::as_str).map(str::to_string).ok_or_else(|| format!("argument {index} must be a string"))
}

pub fn python_json(value: &Value) -> String {
    match value {
        Value::Null => "null".into(),
        Value::Bool(true) => "true".into(),
        Value::Bool(false) => "false".into(),
        Value::Number(number) => number.to_string(),
        Value::String(text) => json_string(text),
        Value::Array(items) => format!("[{}]", items.iter().map(python_json).collect::<Vec<_>>().join(", ")),
        Value::Object(map) => format!("{{{}}}", map.iter().map(|(key, item)| format!("{}: {}", json_string(key), python_json(item))).collect::<Vec<_>>().join(", ")),
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
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
