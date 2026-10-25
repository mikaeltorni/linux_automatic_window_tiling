"""Check common owner CLI grammar and read-only metadata in an isolated home."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='public-owner-cli-') as directory:
    temporary = Path(directory)
    tools = temporary/'tools'
    tools.mkdir()
    home = temporary/'home'
    home.mkdir()
    marker = temporary/'effects'
    getent = tools/'getent'
    getent.write_text('#!/bin/bash\nprintf "%s:x:%s:%s::%s:/bin/bash\\n" "$USER" "$(id -u)" "$(id -g)" "$HOME"\n')
    getent.chmod(0o755)
    for name in ('curl','wget','cargo','sudo','apt','apt-get','gsettings','dconf','systemctl','gnome-extensions','xdotool','pkill','killall'):
        command = tools/name
        command.write_text('''#!/bin/bash
case "${0##*/}:$*" in
 gsettings:*get*|gsettings:*list-*|gnome-extensions:info*|gnome-extensions:list*|systemctl:*is-active*|systemctl:*status*) exit 1 ;;
esac
printf '%s %s\\n' "${0##*/}" "$*" >> "$EFFECTS"
exit 97
''')
        command.chmod(0o755)
    env = dict(PATH=str(tools)+':/usr/local/bin:/usr/bin:/bin', HOME=str(home), USER=os.environ.get('USER','mk'),
               XDG_CONFIG_HOME=str(home/'config'), XDG_CACHE_HOME=str(home/'cache'),
               XDG_STATE_HOME=str(home/'state'), XDG_SESSION_TYPE='unknown', EFFECTS=str(marker), TERM='xterm')
    public = ['bash',str(ROOT/'install.sh')]
    result = subprocess.run([*public,'--list-components'],env=env,text=True,capture_output=True,timeout=30)
    assert result.returncode == 0, (result.stdout,result.stderr)
    fields = [line.split('\t') for line in result.stdout.splitlines()]
    assert fields and all(len(row)>=3 and row[2] in ('on','off') for row in fields), result.stdout
    ids = tuple(row[0] for row in fields)
    assert len(set(ids)) == len(ids)
    result = subprocess.run([*public,'--detect'],env=env,text=True,capture_output=True,timeout=30)
    assert result.returncode == 0, (result.stdout,result.stderr)
    assert set(result.stdout.splitlines()) == {identifier+'\tabsent' for identifier in ids}, result.stdout
    assert not marker.exists(), marker.read_text() if marker.exists() else ''
    for arguments in (['--list-components','--unknown-mode'], ['--detect','--default'],
                      ['--default','--all'], ['--select'], ['--uninstall'], ['--reconfigure'],
                      ['--select','unknown'], ['--uninstall','unknown'],
                      ['--select',ids[0]+','+ids[0]], ['--uninstall',ids[0]+','+ids[0]]):
        result = subprocess.run([*public,*arguments],env=env,text=True,capture_output=True,timeout=30)
        assert result.returncode == 2, (arguments,result.returncode,result.stdout,result.stderr)
        assert not marker.exists(), (arguments,marker.read_text() if marker.exists() else '')
print('PASS: public owner CLI protocol and complete pre-effect rejection')
