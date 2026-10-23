"""Keep earlier redirected output intact when querying the public selection export."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    home = Path(directory)
    tools = home/'bin'
    tools.mkdir()
    getent = tools/'getent'
    getent.write_text('#!/bin/bash\nprintf "%s:x:%s:%s::%s:/bin/bash\\n" "$USER" "$(id -u)" "$(id -g)" "$TEST_HOME"\n')
    getent.chmod(0o755)
    environment = dict(os.environ, HOME=str(home), TEST_HOME=str(home),
                       PATH=str(tools)+':'+os.environ['PATH'],
                       XDG_STATE_HOME=str(home/'state'), XDG_CACHE_HOME=str(home/'cache'))
    output = home/'combined-output'
    marker = b'previous stack output\n'
    with output.open('wb') as stream:
        stream.write(marker)
        stream.flush()
        result = subprocess.run(['bash', str(root/'install.sh'), '--export-selection'],
                                env=environment, stdout=stream, stderr=subprocess.PIPE, timeout=60)
    assert result.returncode == 0, result.stderr.decode(errors='replace')
    data = output.read_bytes()
    assert data.startswith(marker), ('selection export truncated prior output', data[:80])
    assert b'\0' not in data, 'selection export created holes in redirected output'
    document = json.loads(data[len(marker):])
    assert document['scope'] == 'standalone' and document['components'], document
print('PASS: selection export preserves earlier redirected output and emits valid JSON')
