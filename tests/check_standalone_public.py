"""Exercise public standalone installer discovery with network unavailable."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    home=Path(directory)
    tools=home/'bin'
    tools.mkdir()
    for name,body in {'getent':'printf "%s:x:%s:%s::%s:/bin/bash\\n" "$USER" "$(id -u)" "$(id -g)" "$TEST_HOME"', 'curl':'exit 67', 'wget':'exit 67'}.items():
        p=tools/name
        p.write_text('#!/bin/sh\n'+body+'\n')
        p.chmod(0o755)
    env=dict(os.environ,HOME=str(home),TEST_HOME=str(home),PATH=str(tools)+':'+os.environ['PATH'],XDG_STATE_HOME=str(home/'state'),XDG_CACHE_HOME=str(home/'cache'))
    for args in (['--list-components'],['--export-selection']):
        result=subprocess.run(['bash',str(root/'install.sh'),*args],env=env,text=True,capture_output=True,timeout=30)
        assert result.returncode==0,(args,result.stdout,result.stderr)
        if args==['--export-selection']:
            assert isinstance(json.loads(result.stdout),dict)
        else:
            assert '\t' in result.stdout,result.stdout
print('PASS: standalone public discovery and selection export with downloads blocked')
