#!/usr/bin/env bash
# Executable behavior tests for the toolstack-update proposal helper.
# Only selected synthetic observations enter its stdin interface. An audit
# launcher rejects tool execution, network calls, and reads of the fixture home,
# even for a valid prepared proposal. No real installation/session is inspected.
# An optional installed-Pi pure skill-loader check validates metadata/scope;
# it never creates an agent/session, loads extensions, or makes a model call.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-toolstack-update)
HELPER="$ROOT/.agents/skills/toolstack-update/scripts/proposals.py"
PYTHON=$(command -v python3) || fail 'python3 required for proposal tests'

PYTHONDONTWRITEBYTECODE=1 PYTHONPYCACHEPREFIX="$TMP_ROOT/python-cache" PYTHONNOUSERSITE=1 PYTHONPATH='' \
  "$PYTHON" - "$HELPER" "$TMP_ROOT" <<'PY'
import copy
import json
import os
from pathlib import Path
import subprocess
import sys

helper = Path(sys.argv[1])
root = Path(sys.argv[2])
home = root / 'home'
home.mkdir()
secret = 'credential-canary-must-never-be-read-or-printed'
for name in ['.pi/agent/auth.json', '.no-mistakes/config.yaml', '.env']:
    path = home / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(secret)
launcher = root / 'audit.py'
launcher.write_text('''import os, runpy, sys
home = os.path.abspath(sys.argv[1])
script = sys.argv[2]
sys.argv = [script] + sys.argv[3:]
effects = []
def audit(event, args):
    blocked = event.startswith('socket.') or event in {
        'subprocess.Popen', 'os.system', 'os.posix_spawn', 'os.exec', 'os.fork',
        'os.forkpty', 'urllib.Request', 'os.mkdir', 'os.remove', 'os.rmdir',
        'os.rename', 'os.symlink', 'os.link', 'os.chmod', 'os.chown', 'os.utime'}
    if event in {'open', 'os.listdir', 'os.scandir'} and args and isinstance(args[0], (str, bytes)):
        path = os.path.abspath(os.fsdecode(args[0]))
        blocked = blocked or path == home or path.startswith(home + os.sep)
        if event == 'open':
            trusted = path == script or path.startswith(sys.base_prefix + os.sep) or '/python-cache/' in path
            flags = args[2] if len(args) > 2 else 0
            blocked = blocked or not trusted or bool(flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC))
    if blocked:
        effects.append(event + (':' + os.fsdecode(args[0]) if event == 'open' else ''))
        raise RuntimeError('forbidden helper effect: ' + event)
sys.addaudithook(audit)
try:
    runpy.run_path(script, run_name='__main__')
finally:
    if effects:
        print('Forbidden events: ' + ', '.join(effects), file=sys.stderr)
        raise SystemExit(91)
''')
env = dict(os.environ, HOME=str(home), PI_CODING_AGENT_DIR=str(home / '.pi/agent'),
           TYPESAFE_API_KEY=secret, OPENAI_API_KEY=secret, PYTHONDONTWRITEBYTECODE='1',
           PYTHONPYCACHEPREFIX=str(root / 'python-cache'), PYTHONNOUSERSITE='1', PYTHONPATH='')

def invoke(command=None, data=None, raw=None, extra=()):
    args = [sys.executable, '-B', str(launcher), str(home), str(helper)]
    if command is not None:
        args.append(command)
    args.extend(extra)
    result = subprocess.run(args, input=raw if raw is not None else json.dumps(data or {}),
                            text=True, capture_output=True, env=env, timeout=10)
    assert secret not in result.stdout + result.stderr, 'credential input leaked'
    assert result.returncode != 91, ('helper attempted execution, network, or protected reads', result.stderr)
    body = json.loads(result.stdout) if result.stdout else None
    return result.returncode, body


def refuse(command, data=None, raw=None, extra=()):
    code, body = invoke(command, data, raw, extra)
    assert code == 2, (code, body)
    if body:
        assert body['status'] == 'refused'
    return body


expected = ['pi', 'firstmate', 'herdr', 'wezterm', 'treehouse', 'git', 'gh-axi',
            'tasks-axi', 'quota-axi', 'lavish-axi', 'chrome-devtools-axi', 'no-mistakes']
code, catalog = invoke('catalog')
assert code == 0 and [r['id'] for r in catalog['targets']] == expected
assert catalog['resource_kinds'] == ['extension', 'skill', 'prompt-template']
assert set(catalog['dependency_only']) == {'chrome', 'excel', 'typora', 'node', 'package-managers'}
assert catalog['discovery_scope'] == 'firstmate-project-shared-not-main-only'
code, empty = invoke()
assert code == 0 and len(empty['targets']) == 12
assert all(r['comparison'] == 'unknown' for r in empty['targets'])
assert 'dispatch' not in json.dumps(empty) and empty['mode'] == 'inspection-only'
print('ok - exact default inventory, Pi resources, dependency-only exclusions, and inspection default')

for excluded in catalog['dependency_only'] + ['npm', 'brew', 'pi-typesafe']:
    refuse('propose', {'target': excluded})
    refuse('inspect', {'observations': {excluded: {}}})
print('ok - excluded applications, owners, and proposed packages cannot become default update targets')


def observation(target):
    row = dict(installed=True, used=True, current='1.0.0', available='1.1.0',
               owner=catalog['targets'][expected.index(target)]['owners'][0],
               compatible=True, owner_verified=True, available_verified=True)
    if target == 'firstmate':
        row.update(current='0' * 40, available='1' * 40, relation='fast-forward')
    if target == 'wezterm':
        row.update(current='20240203-110809-5046fc22', available='20260203-110809-5046fc22')
    if target == 'git':
        row['update_label'] = 'Command Line Tools for Xcode-26.1'
    if target == 'pi':
        row.update(resources=[], resources_complete=True)
    return row


def request(target='gh-axi'):
    return {'observations': {target: observation(target)}, 'target': target}


def checkpoint():
    return dict(actor='primary', active_sessions=False, active_workers=False,
                active_validation=False, pins_preserved=True, packages_preserved=True,
                credentials_untouched=True, local_state_preserved=True, rollback_reviewed=True)


def approved(data):
    data = copy.deepcopy(data)
    code, result = invoke('propose', data)
    assert code == 0 and result['status'] == 'needs-individual-captain-approval', result
    data['approval'] = result['proposal']
    data['checkpoint'] = checkpoint()
    return data


def prepared(data):
    code, result = invoke('prepare', data)
    assert code == 0 and result['status'] == 'prepared-not-executed', result
    assert result['execution_authorized_by_helper'] is False
    return result['proposal']


actions = {
    'pi': ['pi', 'update', '--no-approve'],
    'herdr': ['brew', 'upgrade', 'herdr'],
    'wezterm': ['brew', 'upgrade', '--cask', 'wezterm'],
    'treehouse': ['treehouse', 'update'],
    'git': ['softwareupdate', '--install', 'Command Line Tools for Xcode-26.1'],
    'gh-axi': ['gh-axi', 'update'],
    'tasks-axi': ['npm', 'install', '-g', 'tasks-axi@1.1.0'],
    'quota-axi': ['quota-axi', 'update'],
    'lavish-axi': ['lavish-axi', 'update'],
    'chrome-devtools-axi': ['chrome-devtools-axi', 'update'],
    'no-mistakes': ['no-mistakes', 'update'],
}
for target in expected:
    result = prepared(approved(request(target)))
    assert result['dispatch'] == ({'skill': 'updatefirstmate'} if target == 'firstmate' else {'argv': actions[target]})
assert actions['tasks-axi'][0] != 'tasks-axi'
print('ok - every supported owner dispatch is targeted; Firstmate delegates only to its existing skill')

for target in ['pi', 'herdr', 'gh-axi', 'quota-axi', 'lavish-axi', 'chrome-devtools-axi']:
    for owner in catalog['targets'][expected.index(target)]['owners']:
        data = request(target)
        data['observations'][target]['owner'] = owner
        result = prepared(approved(data))
        assert result['dispatch']['argv'][0] != 'firstmate'
        if target == 'herdr':
            assert result['dispatch']['argv'][0] == ('brew' if owner == 'brew-formula' else 'herdr')
for target in expected:
    data = request(target)
    data['observations'][target]['owner'] = 'unknown'
    refuse('propose', data)
print('ok - alternate known receipts retain their owner; unknown owners cannot silently fall back')

for flag in ['installed', 'used', 'compatible', 'owner_verified', 'available_verified']:
    data = request()
    data['observations']['gh-axi'][flag] = None
    refuse('propose', data)
    data['observations']['gh-axi'][flag] = 'true'
    refuse('propose', data)
for field in ['current', 'available']:
    data = request()
    del data['observations']['gh-axi'][field]
    refuse('propose', data)
data = request('pi')
del data['observations']['pi']['resources_complete']
refuse('propose', data)
data = request()
data['observations']['gh-axi']['used'] = False
assert prepared(approved(data))['target'] == 'gh-axi'
print('ok - actual-use evidence differs from installation; unknown compatibility/resources block proposals')

data = request()
data['observations']['gh-axi'].update(current='v1.0.0', available='1.0.0')
code, inspected = invoke('inspect', {'observations': data['observations']})
assert code == 0 and inspected['targets'][expected.index('gh-axi')]['comparison'] == 'current'
for available in ['1.0.0', '0.9.0', '1.1.0-beta.1']:
    data = request()
    data['observations']['gh-axi']['available'] = available
    refuse('propose', data)
for relation in ['unknown', 'diverged']:
    data = request('firstmate')
    data['observations']['firstmate']['relation'] = relation
    refuse('propose', data)
for label in ['macOS Tahoe-26.1', '--all', 'Command Line Tools for Xcode; echo unsafe']:
    data = request('git')
    data['observations']['git']['update_label'] = label
    refuse('propose', data)
print('ok - unchanged releases, downgrades, prereleases, diverged histories, and unrelated Apple updates are refused')

data = approved(request())
refuse('prepare', request())
for approval in [True, [data['approval']], {'approved': True}, {**data['approval'], 'target': 'quota-axi'}]:
    bad = copy.deepcopy(data)
    bad['approval'] = approval
    refuse('prepare', bad)
for command in [['brew', 'upgrade'], ['npm', 'update', '-g'], ['pi', 'update', '--all'], ['pi', 'update', '--extensions']]:
    bad = copy.deepcopy(data)
    bad['approval']['dispatch'] = {'argv': command}
    refuse('prepare', bad)
    refuse('inspect', {'command': command})
for field, value in [('current', '1.0.1'), ('available', '1.2.0'), ('owner', 'pnpm-global')]:
    bad = copy.deepcopy(data)
    bad['observations']['gh-axi'][field] = value
    refuse('prepare', bad)
print('ok - approvals are individual and bound to current evidence; broad commands and stale approvals are refused')

for field in ['active_sessions', 'active_workers', 'active_validation']:
    for value in [True, None, 0]:
        bad = copy.deepcopy(data)
        bad['checkpoint'][field] = value
        refuse('prepare', bad)
for field in ['pins_preserved', 'packages_preserved', 'credentials_untouched', 'local_state_preserved', 'rollback_reviewed']:
    bad = copy.deepcopy(data)
    bad['checkpoint'][field] = False
    refuse('prepare', bad)
for actor in ['worker', 'secondmate', None]:
    bad = copy.deepcopy(data)
    bad['checkpoint']['actor'] = actor
    refuse('prepare', bad)
bad = copy.deepcopy(data)
del bad['checkpoint']['active_validation']
refuse('prepare', bad)
print('ok - active/unknown work and incomplete/non-primary checkpoints cannot be prepared')

resource = dict(name='example-extension', kind='extension', owner='pi-package', source='npm:example-extension',
                scope='user', current='1.0.0', available='1.1.0')
data = request('pi')
data['observations']['pi']['resources'] = [resource]
data['resource'] = resource['name']
before = copy.deepcopy(data)
result = prepared(approved(data))
assert result['dispatch'] == {'argv': ['pi', 'update', 'npm:example-extension', '--no-approve']}
assert result['resources'] == [resource] and data == before
pinned = copy.deepcopy(data)
pinned['observations']['pi']['resources'][0].update(source='npm:example-extension@v1.1.0', pin='1.1.0')
assert prepared(approved(pinned))['dispatch']['argv'][2] == 'npm:example-extension@v1.1.0'
for pin_kind in ['source', 'field']:
    bad = copy.deepcopy(data)
    if pin_kind == 'source':
        bad['observations']['pi']['resources'][0]['source'] += '@1.0.0'
    else:
        bad['observations']['pi']['resources'][0]['pin'] = '1.0.0'
    refuse('propose', bad)
bad = copy.deepcopy(data)
bad['observations']['pi']['resources'][0]['scope'] = 'project'
refuse('propose', bad)
for owner in ['firstmate', 'local']:
    bad = copy.deepcopy(data)
    bad['observations']['pi']['resources'][0]['owner'] = owner
    bad['observations']['pi']['resources'][0].pop('source')
    if owner == 'firstmate':
        bad['observations']['pi']['resources'][0].update(current='0' * 40, available='1' * 40)
    refuse('propose', bad)
bad = approved(data)
bad['observations']['pi']['resources'][0]['source'] += '@1.1.0'
refuse('prepare', bad)
bad = copy.deepcopy(data)
bad['observations']['pi']['resources'] *= 2
refuse('inspect', {'observations': bad['observations']})
print('ok - Pi resources retain exact declarations, pins, owner, scope, and single-resource selection')

# Inspection must retain non-npm resources without inventing an updater for
# them, even when the main Pi binary itself has a supported proposal.
all_sources = request('pi')
all_sources['observations']['pi']['resources'] = [
    dict(name='git-skill', kind='skill', owner='pi-package', scope='user',
         source='git:github.com/example/skills@main', current=None, available=None),
    dict(name='local-template', kind='prompt-template', owner='local', scope='project',
         source='./templates/local-template', current=None, available=None),
]
code, inspected = invoke('inspect', {'observations': all_sources['observations']})
assert code == 0, inspected
assert inspected['targets'][0]['observation']['resources'] == all_sources['observations']['pi']['resources']
assert prepared(approved(all_sources))['resources'] == all_sources['observations']['pi']['resources']
for name in ['git-skill', 'local-template']:
    bad = copy.deepcopy(all_sources)
    bad['resource'] = name
    refuse('propose', bad)
print('ok - complete Git/local resource inspection preserves sources without inventing package updates')

for field in ['credentials', 'apiKey', 'environment', 'auth_file', 'command']:
    refuse('inspect', {field: secret})
    bad = request()
    bad['observations']['gh-axi'][field] = secret
    refuse('propose', bad)
refuse('inspect', raw='{"observations":{}, "observations": {}}')
refuse('inspect', raw='{"credentials":"' + secret + '"')
refuse('inspect', raw='x' * (128 * 1024 + 1))
refuse('apply', extra=['--api-key', secret])
for path in home.rglob('*'):
    if path.is_file():
        assert path.read_text() == secret
print('ok - no credentials, configuration changes, execution, or network in inspection/proposal/preparation paths')
PY

# Use only the installed pure discovery module, never an agent factory or a
# resource-loader reload (which could reconcile packages or activate code).
PI_LOADER=/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/skills.js
if [ -f "$PI_LOADER" ] && command -v node >/dev/null 2>&1; then
  cp -R "$ROOT/.agents/skills/toolstack-update" "$TMP_ROOT/skill"
  HOME="$TMP_ROOT/home" PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 node --input-type=module - "$PI_LOADER" "$TMP_ROOT/skill" <<'JS'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { loadSkillsFromDir, formatSkillsForPrompt } = await import(pathToFileURL(process.argv[2]).href);
for (const source of ['project', 'user']) {
  const result = loadSkillsFromDir({ dir: process.argv[3], source });
  assert.equal(result.diagnostics.length, 0);
  assert.equal(result.skills.length, 1);
  assert.equal(result.skills[0].name, 'toolstack-update');
  assert.equal(result.skills[0].sourceInfo.scope, source);
  assert.equal(result.skills[0].disableModelInvocation, true);
  assert.equal(formatSkillsForPrompt(result.skills), '');
}
console.log('ok - installed Pi discovers the skill with accurate shared/personal scope and explicit invocation');
JS
else
  printf 'skip: installed Pi pure skill-loader check unavailable; portable helper behavior passed\n'
fi
pass 'toolstack update behavior suite'
