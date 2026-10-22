#!/usr/bin/env python3
"""JSON installation-config helpers for the shared installer framework.

Converts between the Bash selection arrays (CM_* / ISC menu state) and
``installation_configs/*.json`` documents. Invoked from installation_config.sh;
tests call these functions directly.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from logging_utils import get_logger, log_call

LOGGER = get_logger("installation_config", "installation_config.log")

SCHEMA_VERSION = 1


def _bool_int(value: str) -> int:
    """Parse a truthy flag from a state-file field."""
    return 1 if value.lower() in {"1", "true", "yes", "on"} else 0


@log_call(LOGGER)
def parse_state_file(path: Path) -> dict[str, Any]:
    """Read the intermediate state blob written by installation_config.sh."""
    scope = "standalone"
    repo = ""
    repos: dict[str, dict[str, Any]] = {}
    current_repo = ""

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("scope="):
            scope = line.split("=", 1)[1].strip()
            continue
        if line.startswith("repo_name="):
            repo = line.split("=", 1)[1].strip()
            continue
        if line.startswith("repo:"):
            _, name, enabled = line.split(":", 2)
            current_repo = name
            repos.setdefault(name, {"enabled": _bool_int(enabled), "components": {}})
            continue
        if line.startswith("comp\t"):
            parts = line.split("\t")
            if len(parts) < 9:
                continue
            _, comp_repo, comp_id, on_v, uninstall_v, favorite_v, startup_v, workspace_v, sticky_v = parts[:9]
            # Field 10 is the [m] monitor number and field 11 the component's
            # own config value. Trailing empty fields are stripped from the
            # line, so both are optional here; the state file is an ephemeral
            # exchange format, always written by this same module.
            monitor_v = parts[9] if len(parts) > 9 else ""
            config_value = parts[10] if len(parts) > 10 else ""
            entry: dict[str, Any] = {
                "on": _bool_int(on_v),
                "uninstall": _bool_int(uninstall_v),
                "favorite": _bool_int(favorite_v),
                "startup": _bool_int(startup_v),
                "workspace": int(workspace_v) if str(workspace_v).isdigit() else 0,
                "sticky": _bool_int(sticky_v),
                "config_value": config_value,
            }
            if str(monitor_v).isdigit():
                entry["monitor"] = int(monitor_v)
            repos.setdefault(comp_repo, {"enabled": 1, "components": {}})
            repos[comp_repo]["components"][comp_id] = entry

    if scope == "master":
        return {"schema_version": SCHEMA_VERSION, "scope": "master", "repos": repos}
    return {
        "schema_version": SCHEMA_VERSION,
        "scope": "standalone",
        "repo": repo or current_repo,
        "components": repos.get(repo or current_repo, {}).get("components", {}),
    }


@log_call(LOGGER)
def write_state_file(path: Path, document: dict[str, Any]) -> None:
    """Emit the intermediate state blob consumed by installation_config.sh."""
    lines: list[str] = []
    scope = document.get("scope", "standalone")
    lines.append(f"scope={scope}")
    if scope == "standalone":
        lines.append(f"repo_name={document.get('repo', '')}")
        components = document.get("components") or {}
        repo = document.get("repo", "")
        lines.append(f"repo:{repo}:1")
        for comp_id, entry in sorted(components.items()):
            lines.append(_comp_line(repo, comp_id, entry))
    else:
        repos = document.get("repos") or {}
        for repo_name in sorted(repos):
            repo_entry = repos[repo_name]
            enabled = 1 if repo_entry.get("enabled") else 0
            lines.append(f"repo:{repo_name}:{enabled}")
            for comp_id, entry in sorted((repo_entry.get("components") or {}).items()):
                lines.append(_comp_line(repo_name, comp_id, entry))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _comp_line(repo: str, comp_id: str, entry: dict[str, Any]) -> str:
    """Format one tab-separated component row for the intermediate state file."""
    workspace = entry.get("workspace", 0)
    # An absent "monitor" key (documents written before the [m] action) stays
    # empty so applying them keeps the repository's own default instead of
    # silently unpinning every application.
    monitor = entry.get("monitor", "")
    config_value = str(entry.get("config_value", ""))
    return "\t".join(
        (
            "comp",
            repo,
            comp_id,
            str(1 if entry.get("on") else 0),
            str(1 if entry.get("uninstall") else 0),
            str(1 if entry.get("favorite") else 0),
            str(1 if entry.get("startup") else 0),
            str(workspace),
            str(1 if entry.get("sticky") else 0),
            str(monitor),
            config_value,
        )
    )


@log_call(LOGGER)
def export_json(state_path: Path) -> dict[str, Any]:
    """Build a JSON document from a state-file path."""
    return parse_state_file(state_path)


@log_call(LOGGER)
def apply_json(document: dict[str, Any], state_path: Path) -> None:
    """Write a JSON document back to the intermediate state-file format."""
    write_state_file(state_path, document)


@log_call(LOGGER)
def diff_documents(baseline: dict[str, Any], current: dict[str, Any]) -> list[str]:
    """Return human-readable change lines between two config documents."""
    changes: list[str] = []

    if baseline.get("scope") != current.get("scope"):
        changes.append(
            f"scope: {baseline.get('scope')} -> {current.get('scope')}"
        )
        return changes

    if baseline.get("scope") == "standalone":
        changes.extend(_diff_component_maps(
            baseline.get("repo", ""),
            baseline.get("components") or {},
            current.get("components") or {},
        ))
        return changes

    base_repos = baseline.get("repos") or {}
    curr_repos = current.get("repos") or {}
    all_repos = sorted(set(base_repos) | set(curr_repos))
    for repo in all_repos:
        base_entry = base_repos.get(repo, {"enabled": 0, "components": {}})
        curr_entry = curr_repos.get(repo, {"enabled": 0, "components": {}})
        base_enabled = 1 if base_entry.get("enabled") else 0
        curr_enabled = 1 if curr_entry.get("enabled") else 0
        if base_enabled != curr_enabled:
            state = "enabled" if curr_enabled else "disabled"
            changes.append(f"repo {repo}: {state}")
        changes.extend(_diff_component_maps(
            repo,
            base_entry.get("components") or {},
            curr_entry.get("components") or {},
        ))
    return changes


def _diff_component_maps(
    repo: str, baseline: dict[str, Any], current: dict[str, Any]
) -> list[str]:
    """Diff component maps for one repository."""
    changes: list[str] = []
    all_ids = sorted(set(baseline) | set(current))
    for comp_id in all_ids:
        base = baseline.get(comp_id, {})
        curr = current.get(comp_id, {})
        prefix = f"{repo}/{comp_id}" if repo else comp_id
        for field, label in (
            ("on", "selected"),
            ("uninstall", "uninstall"),
            ("favorite", "favorite"),
            ("startup", "startup"),
            ("sticky", "sticky"),
        ):
            base_val = 1 if base.get(field) else 0
            curr_val = 1 if curr.get(field) else 0
            if base_val != curr_val:
                changes.append(f"{prefix} {label}: {base_val} -> {curr_val}")
        base_ws = int(base.get("workspace") or 0)
        curr_ws = int(curr.get("workspace") or 0)
        if base_ws != curr_ws:
            changes.append(f"{prefix} workspace: {base_ws} -> {curr_ws}")
        base_mon = int(base.get("monitor") or 0)
        curr_mon = int(curr.get("monitor") or 0)
        if base_mon != curr_mon:
            changes.append(f"{prefix} monitor: {base_mon} -> {curr_mon}")
        base_cfg = str(base.get("config_value", ""))
        curr_cfg = str(curr.get("config_value", ""))
        if base_cfg != curr_cfg:
            changes.append(f"{prefix} config_value: {base_cfg!r} -> {curr_cfg!r}")
    return changes


@log_call(LOGGER)
def load_json_file(path: Path) -> dict[str, Any]:
    """Load and validate a JSON installation config."""
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return {"schema_version": SCHEMA_VERSION, "scope": "standalone", "components": {}}
    document = json.loads(text)
    if not isinstance(document, dict):
        raise ValueError(f"config root must be an object: {path}")
    document.setdefault("schema_version", SCHEMA_VERSION)
    return document


@log_call(LOGGER)
def save_json_file(path: Path, document: dict[str, Any]) -> None:
    """Write a JSON installation config with stable formatting."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _cmd_export(args: argparse.Namespace) -> int:
    document = export_json(Path(args.state_file))
    if args.output:
        save_json_file(Path(args.output), document)
    else:
        sys.stdout.write(json.dumps(document, indent=2, sort_keys=True) + "\n")
    return 0


def _cmd_apply(args: argparse.Namespace) -> int:
    document = load_json_file(Path(args.config))
    apply_json(document, Path(args.state_file))
    return 0


def _cmd_diff(args: argparse.Namespace) -> int:
    baseline = load_json_file(Path(args.baseline))
    current = load_json_file(Path(args.current))
    for line in diff_documents(baseline, current):
        sys.stdout.write(line + "\n")
    return 0


def _cmd_roundtrip(args: argparse.Namespace) -> int:
    document = export_json(Path(args.state_file))
    tmp = Path(args.state_file).with_suffix(".applied")
    apply_json(document, tmp)
    roundtrip = export_json(tmp)
    if document != roundtrip:
        LOGGER.error("roundtrip mismatch: %s vs %s", document, roundtrip)
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    """CLI entry for installation_config.sh subprocess calls."""
    parser = argparse.ArgumentParser(description="Installation config JSON helpers")
    sub = parser.add_subparsers(dest="command", required=True)

    export_p = sub.add_parser("export", help="state-file -> JSON")
    export_p.add_argument("--state-file", required=True)
    export_p.add_argument("--output")
    export_p.set_defaults(func=_cmd_export)

    apply_p = sub.add_parser("apply", help="JSON -> state-file")
    apply_p.add_argument("--config", required=True)
    apply_p.add_argument("--state-file", required=True)
    apply_p.set_defaults(func=_cmd_apply)

    diff_p = sub.add_parser("diff", help="diff two JSON configs")
    diff_p.add_argument("--baseline", required=True)
    diff_p.add_argument("--current", required=True)
    diff_p.set_defaults(func=_cmd_diff)

    rt_p = sub.add_parser("roundtrip", help="verify state-file round-trip")
    rt_p.add_argument("--state-file", required=True)
    rt_p.set_defaults(func=_cmd_roundtrip)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())