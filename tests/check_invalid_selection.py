"""Reject unknown public installer selections before changing files or settings."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    home = Path(directory)
    tools = home/'bin'
    tools.mkdir()
    effects = home/'effects'
    effects.touch()
    scripts = {
        'getent': 'printf "%s:x:%s:%s::%s:/bin/bash\\n" "$USER" "$(id -u)" "$(id -g)" "$TEST_HOME"',
        'gsettings': 'printf "%s\\n" "$*" >> "$TEST_EFFECTS"; printf "[\x27existing@local\x27]\\n"',
        'glib-compile-schemas': 'printf "compile\\n" >> "$TEST_EFFECTS"',
        'gnome-extensions': 'printf "extension\\n" >> "$TEST_EFFECTS"',
        'awt-helper': 'printf "[\x27existing@local\x27]\\n"',
    }
    for name, body in scripts.items():
        path = tools/name
        path.write_text('#!/bin/bash\n'+body+'\n')
        path.chmod(0o755)
    target = home/'.local/share/gnome-shell/extensions/automatic-window-tiling@local'
    target.mkdir(parents=True)
    sentinel = target/'extension.js'
    sentinel.write_text('existing user extension\n')
    environment = dict(os.environ, HOME=str(home), TEST_HOME=str(home),
                       TEST_EFFECTS=str(effects), PATH=str(tools)+':'+os.environ['PATH'],
                       AWT_BIN=str(tools/'awt-helper'), ISC_FUNCTIONS_DIR=str(root/'.installer-support'),
                       XDG_STATE_HOME=str(home/'state'), XDG_CACHE_HOME=str(home/'cache'))
    for arguments in (['--select', '__invalid_vm_component__'],
                      ['--select=keybinding,__invalid_vm_component__'],
                      ['--reconfigure', 'portrait_stacking,__invalid_vm_component__']):
        result = subprocess.run(['bash', str(root/'install.sh'), *arguments],
                                env=environment, capture_output=True, text=True, timeout=20)
        assert result.returncode != 0, (arguments, result.stdout, result.stderr)
        assert 'Unknown component' in result.stderr, (arguments, result.stderr)
        assert effects.read_text() == '', (arguments, effects.read_text())
        assert sentinel.read_text() == 'existing user extension\n', arguments
        assert sorted(path.name for path in target.iterdir()) == ['extension.js'], arguments
        assert not (home/'state/isc/receipts').exists(), arguments
print('PASS: invalid single/mixed selections preserve installed files, settings and receipts')
