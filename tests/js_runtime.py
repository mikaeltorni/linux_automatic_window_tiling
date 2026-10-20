"""Load the extension's real local module graph with caller-supplied GNOME fakes."""

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
IMPORT = re.compile(r"^import[\s\S]*?;\n", re.MULTILINE)
LOCAL_IMPORT = re.compile(r"^import[\s\S]*?from\s*['\"](\./[^'\"]+)['\"]\s*;", re.MULTILINE)


def collect_modules(path, visited):
    """Read local imports in dependency order without executing native modules.

    Parameters: path - JavaScript module path; visited - paths already collected.
    Returns: source fragments with import/export syntax removed for Node fakes.
    """
    print(f"path={path}, visited={visited}")
    path = path.resolve()
    if path in visited:
        print([])
        return []
    visited.add(path)
    source = path.read_text()
    fragments = []
    for relative in LOCAL_IMPORT.findall(source):
        fragments.extend(collect_modules(path.parent / relative, visited))
    body = IMPORT.sub("", source)
    fragments.append(re.sub(r"^export (?:default )?", "", body, flags=re.MULTILINE))
    print(fragments)
    return fragments


def run_extension(stubs, invocation):
    """Execute the real extension graph through its lifecycle and public callbacks.

    Parameters: stubs - GNOME boundary fakes; invocation - public callback calls and final JSON output.
    Returns: the decoded final JSON result.
    """
    print(f"stubs={stubs}, invocation={invocation}")
    node = shutil.which("node")
    if node is None:
        pytest.skip("node is required for the public extension harness")
    source = "\n".join(collect_modules(ROOT / "extension.js", set()))
    completed = subprocess.run([node, "-e", stubs + "\n" + source + "\n" + invocation],
                               text=True, capture_output=True, check=True)
    result = json.loads(completed.stdout.strip().splitlines()[-1])
    print(result)
    return result
