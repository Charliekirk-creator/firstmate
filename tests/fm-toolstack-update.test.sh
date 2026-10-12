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

def invoke(command=None, data=None, raw=None, extra=(), forbidden=()):
    args = [sys.executable, '-B', str(launcher), str(home), str(helper)]
    if command is not None:
        args.append(command)
    args.extend(extra)
    result = subprocess.run(args, input=raw if raw is not None else json.dumps(data or {}),
                            text=True, capture_output=True, env=env, timeout=30)
    assert secret not in result.stdout + result.stderr, 'credential input leaked'
    assert all(value not in result.stdout + result.stderr for value in forbidden), 'input credential leaked'
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
assert all(r['outcome']['category'] == 'unknown' for r in empty['targets'])
assert 'dispatch' not in json.dumps(empty) and empty['mode'] == 'inspection-only'
print('ok - exact default inventory, Pi resources, dependency-only exclusions, and inspection default')

for excluded in catalog['dependency_only'] + ['npm', 'brew', 'pi-typesafe']:
    refuse('propose', {'target': excluded})
    refuse('inspect', {'observations': {excluded: {}}})
print('ok - excluded applications, owners, and proposed packages cannot become default update targets')


def assessment(source, scope='system'):
    return dict(source=source, scope=scope, declarations=[source], pins=[],
                dependencies=['synthetic-runtime@1.0.0'], disruption='brief command replacement',
                maintenance='no affected work may be active', rollback='restore reviewed package artifact',
                verification=['installed version', 'effective version', 'health'],
                compatibility_evidence='synthetic compatibility review',
                owner_evidence='synthetic installation receipt', release_evidence='synthetic release record',
                installed_version_evidence='synthetic package receipt',
                effective_version_evidence='synthetic executable response',
                observed_at='2026-02-20T12:00:00Z', availability_status='verified')


def observation(target):
    row = dict(installed=True, used=True, loaded=True,
               installed_version='1.0.0', effective_version='1.0.0',
               available='1.1.0',
               owner=catalog['targets'][expected.index(target)]['owners'][0],
               compatible=True, owner_verified=True, available_verified=True,
               **assessment('synthetic:' + target))
    if target == 'firstmate':
        row.update(installed_version='0' * 40, effective_version='0' * 40,
                   available='1' * 40, relation='fast-forward')
    if target == 'wezterm':
        row.update(installed_version='20240203-110809-5046fc22',
                   effective_version='20240203-110809-5046fc22', available='20260203-110809-5046fc22')
    if target == 'git':
        row['update_label'] = 'Command Line Tools for Xcode-26.1'
    if target == 'pi':
        row.update(resources=[], resources_complete=True)
    return row


def request(target='gh-axi'):
    return {'observations': {target: observation(target)}, 'target': target}


def resource_selector(row):
    source = row['source']
    if source.startswith('npm:'):
        spec = source[4:]
        package = spec.split('@', 2)[0] if not spec.startswith('@') else '@' + '/'.join(spec[1:].split('/')[:1])
        if spec.startswith('@'):
            package = '@' + spec[1:].split('@', 1)[0]
        unit_type = 'npm'
    elif source.startswith(('git:', 'http://', 'https://', 'ssh://', 'git@')):
        value = source[4:] if source.startswith('git:') else source
        for prefix in ('https://', 'http://', 'git://', 'ssh://git@'):
            if value.startswith(prefix):
                value = value[len(prefix):]
        if value.startswith('git@'):
            value = value[4:].replace(':', '/', 1)
        tail = value[value.rfind('/') + 1:]
        if '@' in tail:
            value = value.rsplit('@', 1)[0]
        package = value[:-4] if value.endswith('.git') else value
        unit_type = 'git'
    else:
        package = source
        unit_type = 'source'
    return {'name': row['name'], 'kind': row['kind'], 'scope': row['scope'],
            'source': source, 'path': row['path'],
            'update_unit': {'type': unit_type, 'identity': package, 'scope': row['scope']}}


def strip_identity(rows):
    return [{key: value for key, value in row.items() if key != 'identity'} for row in rows]


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

for flag in ['installed', 'used', 'loaded', 'compatible', 'owner_verified', 'available_verified']:
    data = request()
    data['observations']['gh-axi'][flag] = None
    refuse('propose', data)
    data['observations']['gh-axi'][flag] = 'true'
    refuse('propose', data)
for field in ['installed_version', 'effective_version', 'installed_version_evidence',
              'effective_version_evidence', 'available']:
    data = request()
    del data['observations']['gh-axi'][field]
    refuse('propose', data)
data = request('pi')
del data['observations']['pi']['resources_complete']
refuse('propose', data)
data = request()
data['observations']['gh-axi'].update(used=False, loaded=False, effective_version=None,
                                      effective_version_evidence='not loaded in any affected process')
assert prepared(approved(data))['effective_version'] is None
print('ok - actual-use evidence differs from installation; unknown compatibility/resources block proposals')

data = request()
data['observations']['gh-axi'].update(installed_version='v1.0.0', available='1.0.0')
code, inspected = invoke('inspect', {'observations': data['observations']})
assert code == 0 and inspected['targets'][expected.index('gh-axi')]['outcome']['category'] == 'unchanged'
assert inspected['targets'][expected.index('gh-axi')]['outcome']['evidence'] == 'synthetic release record'
for category, changes in [
    ('unknown', {'availability_status': 'unknown', 'available': None, 'available_verified': None,
                 'release_evidence': None}),
    ('unavailable', {'availability_status': 'unavailable', 'available': None, 'available_verified': False,
                     'release_evidence': 'registry lookup failed after bounded attempt'}),
    ('unavailable', {'availability_status': 'unavailable', 'installed_version': None,
                     'available': None, 'available_verified': False,
                     'release_evidence': 'registry lookup failed with installed version unknown'}),
    ('deferred', {'available': '0.9.0'}),
    ('candidate', {}),
    ('deferred', {'compatible': False}),
    ('deferred', {'compatible': None}),
]:
    row = observation('gh-axi')
    row.update(changes)
    code, inspected = invoke('inspect', {'observations': {'gh-axi': row}})
    assert code == 0 and inspected['targets'][expected.index('gh-axi')]['outcome']['category'] == category
for available in ['1.0.0', '0.9.0']:
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
for installed_version, available, category in [
    ('1.0.0-beta.1', '1.0.0', 'candidate'),
    ('1.0.0-beta.1', '1.0.0-beta.2', 'candidate'),
    ('1.0.0+build.1', '1.0.0+build.2', 'unchanged'),
]:
    semver_data = request()
    semver_data['observations']['gh-axi'].update(
        installed_version=installed_version, effective_version=installed_version, available=available)
    code, semver_inspection = invoke('inspect', {'observations': semver_data['observations']})
    assert code == 0
    assert semver_inspection['targets'][expected.index('gh-axi')]['outcome']['category'] == category
    if category == 'candidate':
        assert prepared(approved(semver_data))['available'] == available
    else:
        refuse('propose', semver_data)
for malformed_version in ['1.0.0-01', '1.0.0-alpha..1', '01.0.0', '1.1١.0']:
    malformed_semver = request()
    malformed_semver['observations']['gh-axi']['installed_version'] = malformed_version
    refuse('inspect', {'observations': malformed_semver['observations']})
print('ok - semantic version precedence, divergence, and unrelated Apple updates are handled safely')

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
for field, value in [('installed_version', '1.0.1'), ('effective_version', '0.9.0'),
                     ('installed_version_evidence', 'different receipt'),
                     ('effective_version_evidence', 'different process response'),
                     ('available', '1.2.0'), ('owner', 'pnpm-global')]:
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

resource = dict(name='example-extension', kind='extension', path='extensions/example.ts', owner='pi-package',
                installed_version='1.0.0', effective_version='0.9.0', available='1.1.0',
                installed=True, discovered=True,
                loaded=True, used=True, compatible=True, owner_verified=True, available_verified=True,
                **assessment('npm:example-extension', 'user'))
data = request('pi')
data['observations']['pi']['resources'] = [resource]
data['resource'] = resource_selector(resource)
before = copy.deepcopy(data)
result = prepared(approved(data))
assert result['dispatch'] == {'argv': ['pi', 'update', 'npm:example-extension', '--no-approve']}
assert result['installed_version'] == '1.0.0' and result['effective_version'] == '0.9.0'
assert strip_identity(result['affected_resources']) == [resource] and data == before
assert result['affected_resources'][0]['identity'] == resource_selector(resource)
assert result['parent_pi']['owner'] == 'npm-global'
assert result['parent_pi']['loaded'] is True
whole_pi = copy.deepcopy(data)
whole_pi.pop('resource')
assert prepared(approved(whole_pi))['affected_resources'][0]['used'] is True
unknown_resource_usage = copy.deepcopy(whole_pi)
unknown_resource_usage['observations']['pi']['resources'][0].pop('used')
refuse('propose', unknown_resource_usage)
nonboolean_resource_usage = copy.deepcopy(whole_pi)
nonboolean_resource_usage['observations']['pi']['resources'][0]['used'] = 1
refuse('inspect', {'observations': nonboolean_resource_usage['observations']})
unused_resource = copy.deepcopy(whole_pi)
unused_resource['observations']['pi']['resources'][0]['used'] = False
assert prepared(approved(unused_resource))['affected_resources'][0]['used'] is False
tagged_update = copy.deepcopy(data)
tagged_update['observations']['pi']['resources'][0].update(
    source='npm:example-extension@next', declarations=['npm:example-extension@next'])
tagged_update['observations']['pi']['resources'][0].pop('pins')
tagged_peer = copy.deepcopy(tagged_update['observations']['pi']['resources'][0])
tagged_peer.update(name='ExamplePrompt', kind='prompt-template', path='prompts/example.md')
tagged_update['observations']['pi']['resources'].append(tagged_peer)
tagged_update['resource'] = resource_selector(tagged_update['observations']['pi']['resources'][0])
tagged_proposal = prepared(approved(tagged_update))
assert tagged_proposal['dispatch'] == {
    'argv': ['pi', 'update', 'npm:example-extension@next', '--no-approve']}
assert len(tagged_proposal['affected_resources']) == 2
assert all(row['pins'] == ['next'] for row in tagged_proposal['affected_resources'])
substituted_tag = approved(tagged_update)
substituted_tag['observations']['pi']['resources'][0].update(
    source='npm:example-extension@beta', declarations=['npm:example-extension@beta'])
refuse('prepare', substituted_tag)
object_declaration = copy.deepcopy(data)
object_declaration['observations']['pi']['resources'][0]['declarations'] = [{
    'source': 'npm:example-extension', 'autoload': False,
    'extensions': ['extensions/*.ts'], 'skills': [], 'prompts': [], 'themes': []}]
object_proposal = prepared(approved(object_declaration))
assert object_proposal['affected_resources'][0]['declarations'][0]['skills'] == []
changed_filter = approved(object_declaration)
changed_filter['observations']['pi']['resources'][0]['declarations'][0]['skills'] = ['skills/review']
refuse('prepare', changed_filter)
unsupported_declaration = copy.deepcopy(object_declaration)
unsupported_declaration['observations']['pi']['resources'][0]['declarations'][0]['unknown'] = []
refuse('inspect', {'observations': unsupported_declaration['observations']})
parent_approved = approved(data)
for field, replacement in [
    ('owner', 'pi-managed'), ('source', 'synthetic:alternate-pi'),
    ('used', False), ('loaded', False),
    ('installed_version', '1.0.1'), ('effective_version', '0.9.0'),
    ('installed_version_evidence', 'different Pi receipt'),
    ('effective_version_evidence', 'different Pi process'),
    ('owner_evidence', 'different Pi owner evidence'),
    ('observed_at', '2026-02-20T12:00:01Z'),
]:
    changed_parent = copy.deepcopy(parent_approved)
    changed_parent['observations']['pi'][field] = replacement
    refuse('prepare', changed_parent)
for root_changes in [
    {'available': '1.0.0'},
    {'availability_status': 'unavailable', 'available': None, 'available_verified': False,
     'compatible': None, 'release_evidence': 'Pi release lookup unavailable'},
]:
    independent = copy.deepcopy(data)
    independent['observations']['pi'].update(root_changes)
    assert prepared(approved(independent))['resource'] == resource_selector(resource)
missing_effective = copy.deepcopy(data)
missing_effective['observations']['pi']['resources'][0]['effective_version'] = None
refuse('propose', missing_effective)
pinned = copy.deepcopy(data)
pinned['observations']['pi']['resources'][0].update(source='npm:example-extension@v1.1.0',
                                                    declarations=['npm:example-extension@v1.1.0'],
                                                    pins=['v1.1.0'])
pinned['resource'] = resource_selector(pinned['observations']['pi']['resources'][0])
code, pinned_inspection = invoke('inspect', {'observations': pinned['observations']})
assert code == 0
assert pinned_inspection['targets'][0]['observation']['resources'][0]['pins'] == ['v1.1.0']
refuse('propose', pinned)
bad = copy.deepcopy(data)
bad['observations']['pi']['resources'][0]['pin'] = '1.1.0'
refuse('propose', bad)
bad = copy.deepcopy(data)
bad['observations']['pi']['resources'][0]['pins'] = ['1.1.0']
refuse('propose', bad)
scoped = copy.deepcopy(data)
scoped['observations']['pi']['resources'][0].update(
    source='npm:@example/extension@1.1.0', declarations=['npm:@example/extension@1.1.0'], pins=['1.1.0'])
scoped['resource'] = resource_selector(scoped['observations']['pi']['resources'][0])
refuse('propose', scoped)
scoped_aliases = copy.deepcopy(data)
scoped_aliases['observations']['pi']['resources'][0].update(
    source='npm:@example/extension', declarations=['npm:@example/extension'])
scoped_sibling = copy.deepcopy(scoped_aliases['observations']['pi']['resources'][0])
scoped_sibling.update(name='scoped-skill', kind='skill', source='npm:@example/extension@latest',
                      declarations=['npm:@example/extension@latest'])
scoped_aliases['observations']['pi']['resources'].append(scoped_sibling)
scoped_aliases['resource'] = resource_selector(scoped_aliases['observations']['pi']['resources'][0])
scoped_proposal = prepared(approved(scoped_aliases))
assert len(scoped_proposal['affected_resources']) == 2
assert scoped_proposal['update_unit']['identity'] == '@example/extension'
bad = copy.deepcopy(data)
bad['observations']['pi']['resources'][0]['scope'] = 'project'
refuse('propose', bad)
for owner in ['firstmate', 'local']:
    bad = copy.deepcopy(data)
    bad['observations']['pi']['resources'][0]['owner'] = owner
    bad['observations']['pi']['resources'][0].pop('source')
    if owner == 'firstmate':
        bad['observations']['pi']['resources'][0].update(installed_version='0' * 40,
                                                         effective_version='0' * 40,
                                                         available='1' * 40)
    refuse('propose', bad)
bad = approved(data)
bad['observations']['pi']['resources'][0]['source'] += '@1.1.0'
refuse('prepare', bad)
bad = copy.deepcopy(data)
bad['observations']['pi']['resources'] *= 2
refuse('inspect', {'observations': bad['observations']})
print('ok - Pi resources retain declarations, filters, parent context, pins, owner, and scope')

# Inspection must retain non-npm resources without inventing an updater for
# them, even when the main Pi binary itself has a supported proposal.
all_sources = request('pi')
all_sources['observations']['pi']['resources'] = [
    dict(name='git-skill', kind='skill', path='skills/git-skill/SKILL.md', owner='pi-package', scope='user',
         source='git:github.com/example/skills@main', declarations=['git:github.com/example/skills@main'],
         pins=['main'], installed=True, discovered=True, loaded=True, used=True, compatible=True,
         owner_verified=True, available_verified=False, version_status='inherently-unversioned',
         installed_version=None, effective_version=None, available=None, installed_version_evidence='git checkout revision main',
         effective_version_evidence='loaded resource inventory', owner_evidence='Pi package inventory',
         compatibility_evidence='reviewed against Pi 1.1.0', observed_at='2026-02-20T12:00:00Z',
         availability_status='unavailable',
         release_evidence='Git resource update intentionally deferred'),
    dict(name='local-template', kind='prompt-template', path='prompts/local-template.md', owner='local', scope='project',
         source='./templates/local-template', declarations=['./templates/local-template'], pins=[],
         installed=True, discovered=True, loaded=False, used=False, compatible=True,
         owner_verified=True, available_verified=None, version_status='inherently-unversioned',
         installed_version=None, effective_version=None, available=None, installed_version_evidence='inherently unversioned local source',
         effective_version_evidence='not loaded in affected process', owner_evidence='local source owner',
         compatibility_evidence='reviewed against Pi 1.1.0', observed_at='2026-02-20T12:00:00Z',
         availability_status='unknown'),
]
code, inspected = invoke('inspect', {'observations': all_sources['observations']})
assert code == 0, inspected
assert strip_identity(inspected['targets'][0]['observation']['resources']) == all_sources['observations']['pi']['resources']
assert strip_identity(prepared(approved(all_sources))['affected_resources']) == all_sources['observations']['pi']['resources']
unknown_resource_revision = copy.deepcopy(all_sources)
unknown_resource_revision['observations']['pi']['resources'][1]['version_status'] = 'unknown'
refuse('propose', unknown_resource_revision)
npm_unversioned = copy.deepcopy(data)
npm_unversioned['observations']['pi']['resources'][0].update(
    version_status='inherently-unversioned', installed_version=None, effective_version=None)
refuse('propose', npm_unversioned)
changed_unversioned_evidence = approved(all_sources)
changed_unversioned_evidence['observations']['pi']['resources'][1][
    'installed_version_evidence'] = 'changed local revision evidence'
refuse('prepare', changed_unversioned_evidence)
for name in ['git-skill', 'local-template']:
    bad = copy.deepcopy(all_sources)
    bad['resource'] = resource_selector(next(row for row in bad['observations']['pi']['resources']
                                             if row['name'] == name))
    refuse('propose', bad)
unknown_compatibility = copy.deepcopy(all_sources)
unknown_compatibility['observations']['pi']['resources'][1]['compatible'] = None
refuse('propose', unknown_compatibility)
print('ok - Pi updates bind Git/local compatibility without requiring resource releases')

source_forms = request('pi')
source_forms['observations']['pi']['resources'] = [
    dict(name='range-extension', kind='extension', path='extensions/range.ts', owner='pi-package',
         scope='user', source='npm:range-package@>=1.0.0 <2.0.0',
         declarations=['npm:range-package@>=1.0.0 <2.0.0'], pins=[]),
    dict(name='scoped-range-skill', kind='skill', path='skills/scoped/SKILL.md', owner='pi-package',
         scope='user', source='npm:@example/scoped@^1.0.0',
         declarations=['npm:@example/scoped@^1.0.0'], pins=[]),
    dict(name='url-skill', kind='skill', path='skills/url/SKILL.md', owner='pi-package',
         scope='user', source='https://github.com/example/pi-tools',
         declarations=['https://github.com/example/pi-tools'], pins=[]),
    dict(name='git-template', kind='prompt-template', path='prompts/git.md', owner='pi-package',
         scope='user', source='git:github.com/example/pi-tools@main',
         declarations=['git:github.com/example/pi-tools@main'], pins=['main']),
    dict(name='git-protocol-skill', kind='skill', path='skills/git-protocol/SKILL.md', owner='pi-package',
         scope='user', source='git://github.com/example/protocol-tools',
         declarations=['git://github.com/example/protocol-tools'], pins=[]),
    dict(name='git-ssh-template', kind='prompt-template', path='prompts/git-ssh.md', owner='pi-package',
         scope='user', source='ssh://deploy@example.com:2222/org/tools@release+1',
         declarations=['ssh://deploy@example.com:2222/org/tools@release+1']),
    dict(name='local-skill', kind='skill', path='skills/local/SKILL.md', owner='local',
         scope='project', source='../local tools', declarations=['../local tools'], pins=[]),
    dict(name='historical-git-skill', kind='skill', path='skills/historical/SKILL.md', owner='pi-package',
         scope='user', source='git:github:user/repo', declarations=['git:github:user/repo'], pins=[]),
    dict(name='hosted-ref-skill', kind='skill', path='skills/hosted-ref/SKILL.md', owner='pi-package',
         scope='user', source='git:https://github.com/user/repo#v1',
         declarations=['git:https://github.com/user/repo#v1']),
    dict(name='hosted-shorthand-skill', kind='skill', path='skills/hosted-shorthand/SKILL.md', owner='pi-package',
         scope='user', source='git:github.com/user/repo#v1',
         declarations=['git:github.com/user/repo#v1']),
    dict(name='gist-skill', kind='skill', path='skills/gist/SKILL.md', owner='pi-package',
         scope='user', source='git:gist:abc123', declarations=['git:gist:abc123'], pins=[]),
    dict(name='bare-local-skill', kind='skill', path='skills/bare-local/SKILL.md', owner='local',
         scope='project', source='packages/pi-tools', declarations=['packages/pi-tools'], pins=[]),
    dict(name='file-local-skill', kind='skill', path='skills/file-local/SKILL.md', owner='local',
         scope='project', source='file:../pi-tools', declarations=['file:../pi-tools'], pins=[]),
    dict(name='git-plus-https-skill', kind='skill', path='skills/git-plus-https/SKILL.md', owner='pi-package',
         scope='user', source='git:git+https://github.com/user/repo.git#v1',
         declarations=['git:git+https://github.com/user/repo.git#v1']),
    dict(name='git-plus-ssh-skill', kind='skill', path='skills/git-plus-ssh/SKILL.md', owner='pi-package',
         scope='user', source='git:git+ssh://git@github.com/user/repo.git#v1',
         declarations=['git:git+ssh://git@github.com/user/repo.git#v1']),
    dict(name='sourcehut-skill', kind='skill', path='skills/sourcehut/SKILL.md', owner='pi-package',
         scope='user', source='git:git+ssh://git@git.sr.ht/~alice/tools.git#v1',
         declarations=['git:git+ssh://git@git.sr.ht/~alice/tools.git#v1']),
    dict(name='sourcehut-alias-skill', kind='skill', path='skills/sourcehut-alias/SKILL.md', owner='pi-package',
         scope='user', source='git:sourcehut:~alice/tools#v2',
         declarations=['git:sourcehut:~alice/tools#v2']),
    dict(name='host-alias-skill', kind='skill', path='skills/host-alias/SKILL.md', owner='pi-package',
         scope='user', source='git:https://www.github.com/user/repo.git#v1',
         declarations=['git:https://www.github.com/user/repo.git#v1']),
    dict(name='decoded-ref-skill', kind='skill', path='skills/decoded-ref/SKILL.md', owner='pi-package',
         scope='user', source='git:github:user/repo#release%2F1',
         declarations=['git:github:user/repo#release%2F1']),
    dict(name='browser-url-skill', kind='skill', path='skills/browser-url/SKILL.md', owner='pi-package',
         scope='user', source='https://github.com/user/repo/tree/v1#readme',
         declarations=['https://github.com/user/repo/tree/v1#readme']),
    dict(name='bitbucket-browser-skill', kind='skill', path='skills/bitbucket-browser/SKILL.md', owner='pi-package',
         scope='user', source='https://bitbucket.org/user/repo/src/v1',
         declarations=['https://bitbucket.org/user/repo/src/v1']),
    dict(name='gist-raw-skill', kind='skill', path='skills/gist-raw/SKILL.md', owner='pi-package',
         scope='user', source='https://gist.github.com/user/abc123/raw/file',
         declarations=['https://gist.github.com/user/abc123/raw/file'], pins=[]),
    dict(name='generic-encoded-skill', kind='skill', path='skills/generic-encoded/SKILL.md', owner='pi-package',
         scope='user', source='https://example.com/org%2Fteam/repo',
         declarations=['https://example.com/org%2Fteam/repo'], pins=[]),
    dict(name='hosted-encoded-skill', kind='skill', path='skills/hosted-encoded/SKILL.md', owner='pi-package',
         scope='user', source='https://github.com/org%2Fteam/repo',
         declarations=['https://github.com/org%2Fteam/repo'], pins=[]),
    dict(name='unsupported-host-protocol-skill', kind='skill', path='skills/host-protocol/SKILL.md', owner='pi-package',
         scope='user', source='http://bitbucket.org/user/repo#v1',
         declarations=['http://bitbucket.org/user/repo#v1'], pins=[]),
    dict(name='ported-generic-skill', kind='skill', path='skills/ported-generic/SKILL.md', owner='pi-package',
         scope='user', source='https://example.com:8443/org/repo',
         declarations=['https://example.com:8443/org/repo'], pins=[]),
    dict(name='generic-raw-ref-skill', kind='skill', path='skills/generic-raw-ref/SKILL.md', owner='pi-package',
         scope='user', source='git:https://example.com/org/repo@release%2F1',
         declarations=['git:https://example.com/org/repo@release%2F1']),
    dict(name='combined-hosted-ref-skill', kind='skill', path='skills/combined-hosted-ref/SKILL.md', owner='pi-package',
         scope='user', source='git:https://github.com/user/repo@release#readme',
         declarations=['git:https://github.com/user/repo@release#readme']),
]
code, source_inspection = invoke('inspect', {'observations': source_forms['observations']})
assert code == 0 and len(source_inspection['targets'][0]['observation']['resources']) == 28
inspected_resources = source_inspection['targets'][0]['observation']['resources']
assert inspected_resources[5]['pins'] == ['release+1']
assert inspected_resources[8]['pins'] == ['v1']
assert inspected_resources[9]['pins'] == ['v1']
assert inspected_resources[9]['identity']['update_unit']['identity'] == 'github.com/user/repo'
assert inspected_resources[9]['source'] == 'git:github.com/user/repo#v1'
assert inspected_resources[9]['declarations'] == ['git:github.com/user/repo#v1']
for index in (13, 14):
    assert inspected_resources[index]['pins'] == ['v1']
    assert inspected_resources[index]['identity']['update_unit']['identity'] == 'github.com/user/repo'
assert inspected_resources[15]['pins'] == ['v1']
assert inspected_resources[16]['pins'] == ['v2']
for index in (15, 16):
    assert inspected_resources[index]['identity']['update_unit']['identity'] == 'git.sr.ht/~alice/tools'
assert inspected_resources[17]['pins'] == ['v1']
assert inspected_resources[17]['identity']['update_unit']['identity'] == 'github.com/user/repo'
assert inspected_resources[18]['pins'] == ['release/1']
assert inspected_resources[18]['declarations'] == ['git:github:user/repo#release%2F1']
assert inspected_resources[19]['pins'] == ['v1']
assert inspected_resources[19]['identity']['update_unit']['identity'] == 'github.com/user/repo'
assert inspected_resources[19]['declarations'] == ['https://github.com/user/repo/tree/v1#readme']
assert inspected_resources[20]['pins'] == []
assert inspected_resources[20]['identity']['update_unit']['identity'] == 'bitbucket.org/user/repo'
assert inspected_resources[21]['identity']['update_unit']['identity'] == 'gist.github.com/user/abc123/raw/file'
assert inspected_resources[22]['identity']['update_unit']['identity'] == 'example.com/org%2Fteam/repo'
assert inspected_resources[23]['identity']['update_unit']['identity'] == 'github.com/org/team/repo'
assert inspected_resources[24]['pins'] == []
assert inspected_resources[24]['identity']['update_unit']['identity'] == 'bitbucket.org/user/repo'
assert inspected_resources[25]['identity']['update_unit']['identity'] == 'example.com/org/repo'
assert inspected_resources[25]['source'] == 'https://example.com:8443/org/repo'
assert inspected_resources[26]['pins'] == ['release%2F1']
assert inspected_resources[26]['identity']['update_unit']['identity'] == 'example.com/org/repo'
assert inspected_resources[27]['pins'] == ['readme#release']
assert inspected_resources[27]['identity']['update_unit']['identity'] == 'github.com/user/repo'
matching_git_pin = copy.deepcopy(source_forms)
matching_git_pin['observations']['pi']['resources'][5]['pins'] = ['release+1']
matching_git_pin['observations']['pi']['resources'][9]['pins'] = ['v1']
matching_git_pin['observations']['pi']['resources'][18]['pins'] = ['release/1']
assert invoke('inspect', {'observations': matching_git_pin['observations']})[0] == 0
mismatched_git_pin = copy.deepcopy(source_forms)
mismatched_git_pin['observations']['pi']['resources'][5]['pins'] = ['other-ref']
refuse('inspect', {'observations': mismatched_git_pin['observations']})
mismatched_shorthand_pin = copy.deepcopy(source_forms)
mismatched_shorthand_pin['observations']['pi']['resources'][9]['pins'] = ['other-ref']
refuse('inspect', {'observations': mismatched_shorthand_pin['observations']})
raw_encoded_pin = copy.deepcopy(source_forms)
raw_encoded_pin['observations']['pi']['resources'][18]['pins'] = ['release%2F1']
refuse('inspect', {'observations': raw_encoded_pin['observations']})
malformed_encoded_ref = copy.deepcopy(source_forms)
malformed_encoded_ref['observations']['pi']['resources'][18].update(
    source='git:github:user/repo#release%FF',
    declarations=['git:github:user/repo#release%FF'])
refuse('inspect', {'observations': malformed_encoded_ref['observations']})
credentialed_git = copy.deepcopy(source_forms)
credentialed_git['observations']['pi']['resources'][5].update(
    source='ssh://deploy:embedded-secret@example.com:2222/org/tools@release+1',
    declarations=['ssh://deploy:embedded-secret@example.com:2222/org/tools@release+1'])
code, credential_refusal = invoke('inspect', {'observations': credentialed_git['observations']})
assert code == 2 and 'embedded-secret' not in json.dumps(credential_refusal)
uppercase_url_credential = 'uppercase-url-canary'
uppercase_credentialed_url = copy.deepcopy(source_forms)
for protocol in ('HTTPS', 'HtTpS'):
    url = f'{protocol}://user:{uppercase_url_credential}@example.com/pkg?token={uppercase_url_credential}'
    uppercase_credentialed_url['observations']['pi']['resources'][5].update(
        source=url, declarations=[url])
    code, uppercase_url_refusal = invoke(
        'inspect', {'observations': uppercase_credentialed_url['observations']},
        forbidden=(uppercase_url_credential,))
    assert code == 2 and uppercase_url_credential not in json.dumps(uppercase_url_refusal)
npm_credential = 'npm-url-credential-canary'
credentialed_npm = copy.deepcopy(source_forms)
credentialed_npm['observations']['pi']['resources'][0].update(
    source=f'npm:example@https://user:{npm_credential}@example.com/package.tgz',
    declarations=[f'npm:example@https://user:{npm_credential}@example.com/package.tgz'])
code, npm_credential_refusal = invoke(
    'inspect', {'observations': credentialed_npm['observations']}, forbidden=(npm_credential,))
assert code == 2 and npm_credential not in json.dumps(npm_credential_refusal)
npm_query = 'npm-query-canary'
query_npm = copy.deepcopy(source_forms)
query_npm['observations']['pi']['resources'][0].update(
    source=f'npm:example@https://example.com/package.tgz?token={npm_query}',
    declarations=[f'npm:example@https://example.com/package.tgz?token={npm_query}'])
code, npm_query_refusal = invoke(
    'inspect', {'observations': query_npm['observations']}, forbidden=(npm_query,))
assert code == 2 and npm_query not in json.dumps(npm_query_refusal)
for row in source_forms['observations']['pi']['resources']:
    assert row['source'] in json.dumps(source_inspection)
range_update = copy.deepcopy(data)
range_update['observations']['pi']['resources'][0].update(
    source='npm:example-extension@>=1.0.0 <2.0.0',
    declarations=['npm:example-extension@>=1.0.0 <2.0.0'], pins=[])
range_update['resource'] = resource_selector(range_update['observations']['pi']['resources'][0])
refuse('propose', range_update)
url_update = copy.deepcopy(data)
url_update['observations']['pi']['resources'][0].update(
    source='https://github.com/example/pi-tools', declarations=['https://github.com/example/pi-tools'])
url_update['resource'] = resource_selector(url_update['observations']['pi']['resources'][0])
refuse('propose', url_update)
ssh_update = copy.deepcopy(data)
ssh_update['observations']['pi']['resources'][0].update(
    source='ssh://deploy@example.com:2222/org/tools@release+1',
    declarations=['ssh://deploy@example.com:2222/org/tools@release+1'])
ssh_update['observations']['pi']['resources'][0].pop('pins')
code, ssh_update_inspection = invoke('inspect', {'observations': ssh_update['observations']})
assert code == 0
ssh_update['resource'] = ssh_update_inspection['targets'][0]['observation']['resources'][0]['identity']
refuse('propose', ssh_update)
hosted_shorthand_update = copy.deepcopy(data)
hosted_shorthand_update['observations']['pi']['resources'][0].update(
    source='git:github.com/user/repo#v1', declarations=['git:github.com/user/repo#v1'])
hosted_shorthand_update['observations']['pi']['resources'][0].pop('pins')
code, shorthand_update_inspection = invoke(
    'inspect', {'observations': hosted_shorthand_update['observations']})
assert code == 0
hosted_shorthand_update['resource'] = shorthand_update_inspection[
    'targets'][0]['observation']['resources'][0]['identity']
refuse('propose', hosted_shorthand_update)
git_plus_update = copy.deepcopy(data)
git_plus_update['observations']['pi']['resources'][0].update(
    source='git:git+https://github.com/user/repo.git#v1',
    declarations=['git:git+https://github.com/user/repo.git#v1'])
git_plus_update['observations']['pi']['resources'][0].pop('pins')
code, git_plus_inspection = invoke('inspect', {'observations': git_plus_update['observations']})
assert code == 0
git_plus_update['resource'] = git_plus_inspection[
    'targets'][0]['observation']['resources'][0]['identity']
refuse('propose', git_plus_update)
sourcehut_update = copy.deepcopy(data)
sourcehut_update['observations']['pi']['resources'][0].update(
    source='git:git+ssh://git@git.sr.ht/~alice/tools.git#v1',
    declarations=['git:git+ssh://git@git.sr.ht/~alice/tools.git#v1'])
sourcehut_update['observations']['pi']['resources'][0].pop('pins')
code, sourcehut_inspection = invoke('inspect', {'observations': sourcehut_update['observations']})
assert code == 0
sourcehut_update['resource'] = sourcehut_inspection[
    'targets'][0]['observation']['resources'][0]['identity']
refuse('propose', sourcehut_update)
print('ok - supported npm ranges, Git URLs, shorthand, and local sources remain inspectable and deferred')

collision_data = request('pi')
collision_a = copy.deepcopy(resource)
collision_a.update(name='Review', kind='prompt-template', path='prompts/a/review.md',
                   source='npm:collision-package', declarations=['npm:collision-package'])
collision_b = copy.deepcopy(collision_a)
collision_b['path'] = 'prompts/b/review.md'
collision_other = copy.deepcopy(collision_a)
collision_other.update(path='prompts/review.md', scope='project', source='npm:other-package',
                       declarations=['npm:other-package'])
non_command_a = copy.deepcopy(resource)
non_command_a.update(name='shared-name', kind='skill', path='skills/shared-name/SKILL.md')
non_command_b = copy.deepcopy(resource)
non_command_b.update(name='shared-name', kind='skill', path='skills/other-shared-name/SKILL.md')
collision_data['observations']['pi']['resources'] = [
    collision_a, collision_b, collision_other, non_command_a, non_command_b]
code, collision_inspection = invoke('inspect', {'observations': collision_data['observations']})
assert code == 0
collision_report = collision_inspection['targets'][0]['resource_collisions']
assert len(collision_report) == 1 and len(collision_report[0]['resources']) == 3
collision_data['resource'] = resource_selector(collision_a)
collision_proposal = prepared(approved(collision_data))
assert {row['path'] for row in collision_proposal['affected_resources']} == {
    'prompts/a/review.md', 'prompts/b/review.md'}
ambiguous = copy.deepcopy(collision_data)
ambiguous['resource']['path'] = 'prompts/missing/review.md'
refuse('propose', ambiguous)
print('ok - source/path identities preserve collisions and bind only the selected package unit')

shared = request('pi')
shared_a = copy.deepcopy(resource)
shared_b = copy.deepcopy(resource)
shared_b.update(kind='skill', source='npm:example-extension@latest',
                declarations=['npm:example-extension@latest'])
shared['observations']['pi']['resources'] = [shared_a, shared_b]
shared['resource'] = resource_selector(shared_a)
proposal = prepared(approved(shared))
assert {(r['name'], r['kind']) for r in proposal['affected_resources']} == {
    ('example-extension', 'extension'), ('example-extension', 'skill')}
assert proposal['update_unit'] == {'type': 'npm', 'identity': 'example-extension', 'scope': 'user'}
selected_alias = copy.deepcopy(shared)
selected_alias['resource'] = resource_selector(selected_alias['observations']['pi']['resources'][1])
alias_proposal = prepared(approved(selected_alias))
assert alias_proposal['dispatch']['argv'][2] == 'npm:example-extension@latest'
assert len(alias_proposal['affected_resources']) == 2
filter_delta_data = copy.deepcopy(data)
filter_delta = copy.deepcopy(resource)
filter_delta.update(name='project-filter', kind='skill', path='skills/project-filter/SKILL.md',
                    scope='project', declarations=[{
                        'source': 'npm:example-extension', 'autoload': False,
                        'extensions': [], 'skills': ['+skills/project-filter/SKILL.md'],
                        'prompts': [], 'themes': []}])
filter_delta_data['observations']['pi']['resources'].append(filter_delta)
filter_delta_proposal = prepared(approved(filter_delta_data))
assert {(row['scope'], row['path']) for row in filter_delta_proposal['affected_resources']} == {
    ('user', 'extensions/example.ts'), ('project', 'skills/project-filter/SKILL.md')}
missing_delta_evidence = copy.deepcopy(filter_delta_data)
del missing_delta_evidence['observations']['pi']['resources'][1]['compatibility_evidence']
refuse('propose', missing_delta_evidence)
changed_delta = approved(filter_delta_data)
changed_delta['observations']['pi']['resources'][1]['declarations'][0]['skills'] = []
refuse('prepare', changed_delta)
independent_scope = copy.deepcopy(data)
independent_project = copy.deepcopy(filter_delta)
independent_project['declarations'] = [{'source': 'npm:example-extension', 'skills': []}]
independent_scope['observations']['pi']['resources'].append(independent_project)
assert len(prepared(approved(independent_scope))['affected_resources']) == 1
for changed in ['installed', 'discovered', 'compatible', 'owner_verified', 'available_verified']:
    bad = copy.deepcopy(shared)
    bad['observations']['pi']['resources'][1][changed] = False
    refuse('propose', bad)
missing = copy.deepcopy(shared)
del missing['observations']['pi']['resources'][1]['compatibility_evidence']
refuse('propose', missing)
conflicting = copy.deepcopy(shared)
conflicting['observations']['pi']['resources'][1].update(
    source='npm:example-extension@1.1.0', declarations=['npm:example-extension@1.1.0'], pins=['1.1.0'])
refuse('propose', conflicting)
pinned_package = copy.deepcopy(shared)
for sibling in pinned_package['observations']['pi']['resources']:
    sibling.update(source='npm:example-extension@1.1.0',
                   declarations=['npm:example-extension@1.1.0'], pins=['1.1.0'])
pinned_package['resource'] = resource_selector(pinned_package['observations']['pi']['resources'][0])
code, pinned_siblings = invoke('inspect', {'observations': pinned_package['observations']})
assert code == 0 and len(pinned_siblings['targets'][0]['observation']['resources']) == 2
refuse('propose', pinned_package)
changed_effective = approved(shared)
changed_effective['observations']['pi']['resources'][1].update(
    effective_version='0.8.0', effective_version_evidence='different loaded process')
refuse('prepare', changed_effective)
print('ok - shared package proposals bind every resource and require resource-specific evidence')

for field in ['scope', 'declarations', 'pins', 'dependencies']:
    incomplete = request()
    incomplete['observations']['gh-axi'][field] = None
    refuse('propose', incomplete)
for field in ['declarations', 'pins', 'dependencies']:
    malformed = request()
    malformed['observations']['gh-axi'][field] = 'none'
    refuse('propose', malformed)

bound = approved(request())
for field, replacement in [
    ('source', 'synthetic:other-owner'), ('scope', 'shared'), ('declarations', ['changed']),
    ('pins', ['1.1.0']), ('dependencies', ['runtime@2']), ('disruption', 'restart required'),
    ('maintenance', 'different interval'), ('rollback', 'no rollback'),
    ('verification', ['different check']), ('compatibility_evidence', 'different compatibility'),
    ('owner_evidence', 'different receipt'), ('release_evidence', 'different release source'),
    ('observed_at', '2026-02-20T12:00:01Z'),
]:
    bad = copy.deepcopy(bound)
    bad['observations']['gh-axi'][field] = replacement
    refuse('prepare', bad)
print('ok - approval equality binds source, scope, declarations, pins, dependencies, consequences, and evidence')

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
