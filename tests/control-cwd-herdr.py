#!/usr/bin/env python3
"""Executable Herdr fixture for the public fm-control cwd-repair tests."""
import json
import os
from pathlib import Path
import sys
import time

root = Path(os.environ['FM_FAKE_DIR'])
args = sys.argv[1:]
with (root / 'herdr-log').open('a') as log:
    log.write(json.dumps(args) + '\n')
if '--session' in args:
    pos = args.index('--session')
    if args[pos + 1] != 'fm-lab-control':
        sys.exit(3)
    del args[pos:pos + 2]
state_path = root / 'herdr-state'
s = json.loads(state_path.read_text())
mode = s.get('mode', '')

def save():
    state_path.write_text(json.dumps(s))

def result(kind, **kwargs):
    print(json.dumps({'result': {'type': kind, **kwargs}}))

def error(code):
    print(json.dumps({'error': {'code': code}}))
    sys.exit(1)

def pane(pid):
    return {'pane_id': pid, 'workspace_id': 'w1', 'tab_id': 'w1:t1',
            'foreground_cwd': s['panes'][pid]['cwd'], 'cwd': s['primary'],
            'focused': False}

if args[:2] == ['status', '--json']:
    print(json.dumps({'client': {'version': '0.9.3', 'protocol': 22},
                      'server': {'status': 'running', 'running': True, 'protocol': 22}}))
elif args[:2] == ['session', 'list']:
    print(json.dumps({'sessions': [{'name': 'fm-lab-control', 'running': True, 'socket_path': str(root/'herdr.sock')}]}))
elif args[:2] == ['workspace', 'list']:
    result('workspace_list', workspaces=[
        {'workspace_id': 'w0', 'label': 'firstmate', 'focused': s.get('focus', 'w0:t1') == 'w0:t1', 'active_tab_id': 'w0:t1'},
        {'workspace_id': 'w1', 'label': s.get('label', 'task'), 'focused': s.get('focus') == 'w1:t1', 'active_tab_id': 'w1:t1'}])
elif args[:2] == ['tab', 'list']:
    ws = args[args.index('--workspace') + 1]
    tab = ws + ':t1'
    result('tab_list', tabs=[{'tab_id': tab, 'workspace_id': ws, 'label': 'fm-rcwd', 'focused': s.get('focus', 'w0:t1') == tab}])
elif args[:2] == ['tab', 'get']:
    result('tab_info', tab={'tab_id': args[2], 'workspace_id': args[2].split(':')[0]})
elif args[:2] == ['tab', 'focus']:
    if mode == 'focus-fail':
        sys.exit(1)
    s['focus'] = args[2]
    save()
elif args[:2] == ['pane', 'list']:
    result('pane_list', panes=[pane(pid) for pid in s['panes']])
elif args[:2] == ['pane', 'get']:
    pid = args[2]
    if pid not in s['panes']:
        error('pane_not_found')
    p = pane(pid)
    if pid == 'w1:p2':
        s['reads'] = s.get('reads', 0) + 1
        if mode in ('wrong-cwd', 'rollback-close-fail'):
            p['foreground_cwd'] = s['primary']
        if mode == 'nonconsecutive':
            p['foreground_cwd'] = s['target'] if s['reads'] % 3 == 1 else s['primary']
        if mode == 'read-fail':
            sys.exit(1)
        if mode == 'control-cwd':
            p['foreground_cwd'] = s['target'] + '\n'
        if mode == 'wrong-new-binding':
            p['tab_id'] = 'w1:t9'
        if mode == 'guard-race' and 'window=fm-lab-control:w1:p2\n' in (root / 'home-state' / 'rcwd.meta').read_text():
            p['foreground_cwd'] = s['primary']
        save()
    if mode == 'wrong-old-binding' and pid == 'w1:p1':
        p['workspace_id'] = 'w9'
    result('pane_info', pane=p)
elif args[:2] == ['agent', 'get']:
    pid = args[2]
    if mode == 'ambiguous' and pid == 'w1:p1':
        print('ambiguous')
    elif s['panes'][pid].get('agent') or (mode == 'live' and pid == 'w1:p1'):
        result('agent_info', agent={'agent_status': 'idle'})
    elif mode == 'new-live' and pid == 'w1:p2':
        result('agent_info', agent={'agent_status': 'idle'})
    else:
        error('agent_not_found')
elif args[:2] == ['pane', 'process-info']:
    pid = args[args.index('--pane') + 1]
    num = 44101 if pid == 'w1:p1' else 44102
    name = 'bash'
    processes = [{'pid': num, 'name': name, 'argv0': name, 'argv': [name, '-i']}]
    if mode == 'foreground' and pid == 'w1:p1':
        processes[0]['name'] = 'vim'
    if mode == 'shell-script' and pid == 'w1:p1':
        processes[0]['argv'] = ['bash', '-c', 'read value']
    if mode == 'new-process':
        processes.append({'pid': 44103, 'name': 'sleep', 'argv0': 'sleep'})
    result('pane_process_info', process_info={'pane_id': pid, 'shell_pid': num,
        'foreground_process_group_id': num, 'foreground_processes': processes})
elif args[:2] == ['pane', 'split']:
    if mode == 'split-wait':
        (root/'split-ready').touch()
        deadline = time.monotonic() + 30
        while not (root/'split-release').exists():
            if time.monotonic() > deadline:
                sys.exit(1)
            time.sleep(0.02)
    if mode == 'split-fail':
        sys.exit(1)
    assert args[args.index('--pane') + 1] == 'w1:p1'
    cwd = args[args.index('--cwd') + 1]
    assert cwd == s['target']
    assert '--no-focus' in args
    s['panes']['w1:p2'] = {'cwd': cwd}
    if mode == 'old-agent-race':
        s['panes']['w1:p1']['agent'] = True
    if mode in ('focus-steal', 'focus-fail'):
        s['focus'] = 'w1:t1'
    save()
    p = pane('w1:p2')
    if mode == 'bad-split':
        p['pane_id'] = 'w1:p1'
    result('pane_info', pane=p)
elif args[:2] == ['pane', 'close']:
    pid = args[2]
    if pid == 'w1:p1':
        journal = (root / 'home-state' / 'rcwd.control-relaunch').read_text()
        phase = next(line.split('=', 1)[1] for line in journal.splitlines() if line.startswith('phase='))
        (root / 'close-journal-phase').write_text(phase)
        if phase != 'retiring':
            sys.exit(1)
    if mode == 'cleanup-fail' or (mode == 'rollback-close-fail' and pid == 'w1:p2'):
        sys.exit(1)
    del s['panes'][pid]
    save()
elif args[:2] in (['pane', 'run'], ['pane', 'send-text'], ['pane', 'send-keys']):
    pid = args[2]
    if pid == 'w1:p1':
        (root / 'old-input').write_text(json.dumps(args))
    if any('encode launch-brief' in arg for arg in args):
        if mode == 'launch-fail':
            sys.exit(1)
        s['panes'][pid]['agent'] = True
        save()
elif args[:2] == ['pane', 'read']:
    print('$ ')
else:
    print('unsupported fixture call: ' + repr(args), file=sys.stderr)
    sys.exit(3)
