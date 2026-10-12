#!/usr/bin/env python3
"""Non-executing update proposal helper for the toolstack-update skill.

The skill owns the workflow; this module owns the catalog, input schema,
outcome classification, and supported dispatch descriptions. It only reads bounded JSON
from stdin and writes JSON to stdout. It never probes tools, reads configuration
or credentials, downloads, installs, executes a dispatch, or records approvals.
A supplied approval is a caller's assertion, not proof of captain authority.

Commands: catalog; inspect (default); propose; prepare.
Resource source records can retain credential-free npm, Git, and local sources;
only unpinned or latest npm user packages have a preparable resource action.
inspect takes {observations: {target: observation}} and always returns the full
catalog. propose adds target and optionally resource (a Pi resource identity object).
prepare additionally needs approval equal to the current proposal and checkpoint.
Use --help for the observation/checkpoint fields. No apply command exists.
"""

import argparse
import copy
import json
import re
import sys
from urllib.parse import unquote, urlsplit

TARGETS = {
    "pi": "Pi and its extensions, skills, and prompt templates",
    "firstmate": "Firstmate",
    "herdr": "Herdr",
    "wezterm": "WezTerm",
    "treehouse": "Treehouse",
    "git": "Git",
    "gh-axi": "gh-axi",
    "tasks-axi": "tasks-axi",
    "quota-axi": "quota-axi",
    "lavish-axi": "lavish-axi",
    "chrome-devtools-axi": "chrome-devtools-axi",
    "no-mistakes": "No Mistakes",
}
DEPENDENCY_ONLY = ["chrome", "excel", "typora", "node", "package-managers"]
OWNERS = {
    "pi": ["npm-global", "pi-managed"], "firstmate": ["firstmate"],
    "herdr": ["brew-formula", "herdr-native"], "wezterm": ["brew-cask"],
    "treehouse": ["treehouse-native"], "git": ["apple-clt"],
    "gh-axi": ["npm-global", "pnpm-global"], "tasks-axi": ["npm-global"],
    "quota-axi": ["npm-global", "pnpm-global"],
    "lavish-axi": ["npm-global", "pnpm-global"],
    "chrome-devtools-axi": ["npm-global", "pnpm-global"],
    "no-mistakes": ["no-mistakes-native"],
}
KINDS = ["extension", "skill", "prompt-template"]
AXI_NATIVE = {"gh-axi", "quota-axi", "lavish-axi", "chrome-devtools-axi"}
VERSION = re.compile(r"v?(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:(?:0|[1-9][0-9]*)|(?:[a-zA-Z-][a-zA-Z0-9-]*))(?:\.(?:(?:0|[1-9][0-9]*)|(?:[a-zA-Z-][a-zA-Z0-9-]*)))*)?(?:\+[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*)?\Z")
WEZ_VERSION = re.compile(r"[0-9]{8}-[0-9]{6}-[a-f0-9]{8}\Z")
COMMIT = re.compile(r"[a-f0-9]{40}\Z")
PACKAGE = re.compile(r"npm:((?:@[a-z0-9_-]+/)?[a-z0-9][a-z0-9._-]*)(?:@(.+))?\Z")
HOSTED_GIT = {"github": "github.com", "gitlab": "gitlab.com", "bitbucket": "bitbucket.org",
              "gist": "gist.github.com", "sourcehut": "git.sr.ht"}
NPM_SELECTOR = re.compile(r"[\x20-\x7e]{1,128}\Z")
DIST_TAG = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\Z")
ASSESSMENT_FIELDS = {"source", "scope", "declarations", "pins", "dependencies", "disruption",
                     "maintenance", "rollback", "verification", "compatibility_evidence",
                     "owner_evidence", "release_evidence", "availability_status", "observed_at"}
VERSION_FIELDS = {"installed_version", "effective_version", "installed_version_evidence",
                  "effective_version_evidence"}
OBS_FIELDS = {"installed", "used", "loaded", "available", "owner", "compatible", "owner_verified",
              "available_verified", "relation", "update_label", "resources", "resources_complete"} \
             | ASSESSMENT_FIELDS | VERSION_FIELDS
RESOURCE_FIELDS = {"name", "kind", "path", "owner", "available", "installed", "discovered",
                   "loaded", "used", "compatible", "owner_verified", "available_verified"} \
                  | ASSESSMENT_FIELDS | VERSION_FIELDS
CHECKPOINT_FIELDS = {"actor", "active_sessions", "active_workers", "active_validation",
                     "pins_preserved", "packages_preserved", "credentials_untouched",
                     "local_state_preserved", "rollback_reviewed"}
LIMIT = 128 * 1024


class Invalid(ValueError):
    pass


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, "Invalid helper arguments; use --help. No apply or credential options exist.\n")


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise Invalid("Duplicate JSON fields are refused.")
        value[key] = item
    return value


def object_fields(value, allowed):
    if not isinstance(value, dict) or set(value) - allowed:
        raise Invalid("Unexpected fields or non-object input; credentials and arbitrary commands are not accepted.")


def version(value, target):
    if value is None:
        return
    pattern = COMMIT if target == "firstmate" else WEZ_VERSION if target == "wezterm" else VERSION
    if not isinstance(value, str) or len(value) > 64 or not pattern.fullmatch(value):
        raise Invalid("Versions must be canonical release versions (or a full Firstmate commit).")


def declaration_record(value):
    if isinstance(value, str):
        if not value or len(value) > 300:
            raise Invalid("Package declarations must be bounded non-empty values.")
        return copy.deepcopy(value)
    fields = {"source", "autoload", "extensions", "skills", "prompts", "themes"}
    object_fields(value, fields)
    if not isinstance(value.get("source"), str) or not value["source"] or len(value["source"]) > 500:
        raise Invalid("An object package declaration requires its complete source.")
    if "autoload" in value and type(value["autoload"]) is not bool:
        raise Invalid("Package declaration autoload must be boolean.")
    for field in fields - {"source", "autoload"}:
        patterns = value.get(field)
        if patterns is not None and (not isinstance(patterns, list) or len(patterns) > 100 or
                                     any(not isinstance(pattern, str) or not pattern or len(pattern) > 300
                                         for pattern in patterns)):
            raise Invalid("Package resource filters must be bounded string lists.")
    return copy.deepcopy(value)


def assessment_record(row):
    status = row.get("availability_status")
    if status is not None and status not in {"unknown", "unavailable", "verified"}:
        raise Invalid("Availability status must distinguish unknown, unavailable, and verified evidence.")
    if row.get("scope") is not None and row["scope"] not in {"user", "project", "system", "shared"}:
        raise Invalid("Scope must identify the concrete update boundary.")
    declarations = row.get("declarations")
    if declarations is not None:
        if not isinstance(declarations, list) or len(declarations) > 100:
            raise Invalid("Declarations must be a bounded list.")
        row["declarations"] = [declaration_record(value) for value in declarations]
    for field in ("pins", "dependencies", "verification"):
        values = row.get(field)
        if values is not None and (not isinstance(values, list) or len(values) > 100 or
                                   any(not isinstance(value, str) or not value or len(value) > 300 for value in values)):
            raise Invalid("Pins, dependencies, and verification facts must be bounded non-empty strings.")
    for field in ("disruption", "maintenance", "rollback", "compatibility_evidence",
                  "owner_evidence", "release_evidence", "installed_version_evidence",
                  "effective_version_evidence"):
        value = row.get(field)
        if value is not None and (not isinstance(value, str) or not value or len(value) > 500):
            raise Invalid("Assessment evidence must be a bounded non-empty string.")
    source = row.get("source")
    if source is not None and (not isinstance(source, str) or not source or len(source) > 500):
        raise Invalid("Source must be a bounded non-secret identifier.")
    observed_at = row.get("observed_at")
    if observed_at is not None and (not isinstance(observed_at, str) or
                                    not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", observed_at)):
        raise Invalid("Evidence freshness requires a canonical UTC observation time.")


def availability_evidence(row):
    status = row.get("availability_status")
    verified = row.get("available_verified")
    available = row.get("available")
    evidence = row.get("release_evidence")
    if status == "verified" and (verified is not True or not available or not evidence):
        raise Invalid("Verified availability requires a release, verification flag, and evidence.")
    if status == "unavailable" and (verified is not False or available is not None or not evidence):
        raise Invalid("Unavailable releases require explicit failed-lookup evidence and no release version.")
    if status in {None, "unknown"} and verified is True:
        raise Invalid("Unknown availability cannot claim verified release evidence.")


def npm_declaration(source):
    match = PACKAGE.fullmatch(source) if isinstance(source, str) else None
    return (match.group(1), match.group(2)) if match else None


def git_declaration(source):
    if not isinstance(source, str) or not source or len(source) > 500:
        return None
    value = source.strip()
    prefixed = value.startswith("git:") and not value.startswith("git://")
    if prefixed:
        value = value[4:].strip()
    explicit_protocol = re.match(r"^((?:git\+)?(?:https?|ssh)|git)://", value, re.IGNORECASE)
    if explicit_protocol and explicit_protocol.group(1).lower().startswith("git+") and not prefixed:
        return None
    host = path = ref = None
    port = None
    hosted = None
    preserve_encoded_path = False
    if prefixed:
        shortcut = re.fullmatch(r"(github|gitlab|bitbucket|gist|sourcehut):(.+)", value, re.IGNORECASE)
        if shortcut:
            hosted, value = shortcut.group(1).lower(), shortcut.group(2)
        elif (not explicit_protocol and not value.startswith("git@") and
              value.split("#", 1)[0].count("/") == 1):
            hosted = "github"
    if hosted:
        host, path = HOSTED_GIT[hosted], value
        if "#" in path:
            path, ref = path.split("#", 1)
        if hosted == "gist" and "/" not in path:
            path = "null/" + path
    elif value.startswith("git@"):
        if not prefixed:
            return None
        match = re.fullmatch(r"git@([^:]+):(.+)", value)
        if not match:
            return None
        host, path = match.groups()
    elif explicit_protocol:
        try:
            parsed = urlsplit(value)
            if parsed.password is not None or (parsed.username is not None and parsed.scheme.lower() not in {"ssh", "git+ssh"}):
                return None
            host, port = parsed.hostname, parsed.port
            unaliased_host = host[4:] if host and host.lower().startswith("www.") else host
            if unaliased_host and unaliased_host.lower() in HOSTED_GIT.values():
                host = unaliased_host.lower()
        except ValueError:
            return None
        if parsed.query:
            return None
        path = parsed.path.lstrip("/")
        fragment = parsed.fragment or None
        segments = path.split("/")
        preserve_encoded_path = True
        if host == "github.com":
            if len(segments) >= 3 and segments[2] == "tree":
                path = "/".join(segments[:2])
                ref = segments[3] if len(segments) >= 4 else None
                preserve_encoded_path = False
            elif len(segments) == 2:
                ref = fragment
                preserve_encoded_path = False
        elif host == "bitbucket.org" and len(segments) >= 2 and \
                (len(segments) == 2 or segments[2] != "get"):
            path = "/".join(segments[:2])
            ref = fragment
            preserve_encoded_path = False
        elif host == "git.sr.ht" and len(segments) >= 2 and \
                (len(segments) == 2 or segments[2] != "archive"):
            path = "/".join(segments[:2])
            ref = fragment
            preserve_encoded_path = False
        elif host == "gist.github.com" and (len(segments) < 3 or segments[2] != "raw"):
            path = "null/" + path if len(segments) == 1 else "/".join(segments[:2])
            ref = fragment
            preserve_encoded_path = False
        elif host == "gitlab.com" and "/-/" not in "/" + path + "/":
            ref = fragment
            preserve_encoded_path = False
    elif prefixed and "/" in value:
        host, path = value.split("/", 1)
    else:
        return None
    if not host or not path or len(host) > 253 or not re.fullmatch(r"[a-zA-Z0-9.:-]+", host):
        return None
    if ref is None and host.lower() in HOSTED_GIT.values() and "#" in path:
        path, ref = path.split("#", 1)
    if ref is None and "@" in path:
        path, ref = path.split("@", 1)
    if re.search(r"%(?![0-9a-fA-F]{2})", path) or (ref is not None and re.search(r"%(?![0-9a-fA-F]{2})", ref)):
        return None
    try:
        decoded_path = unquote(path, errors="strict")
        decoded_ref = unquote(ref, errors="strict") if ref is not None else None
    except (UnicodeError, ValueError):
        return None
    if (not decoded_path or len(decoded_path) > 300 or decoded_path.startswith("/") or "\\" in decoded_path or
            "\x00" in decoded_path or ".." in decoded_path.split("/") or len(decoded_path.split("/")) < 2):
        return None
    if decoded_ref is not None and (not decoded_ref or len(decoded_ref) > 200 or
                                    re.search(r"[\x00-\x1f\\]", decoded_ref)):
        return None
    identity_path = path if preserve_encoded_path else decoded_path
    identity = host.lower() + ((":" + str(port)) if port is not None else "") + "/" + identity_path.removesuffix(".git")
    return (identity, decoded_ref)


def selector_has_credentials(selector):
    match = re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]*)", selector)
    if not match:
        return False
    try:
        parsed = urlsplit(selector)
    except ValueError:
        return True
    return "@" in match.group(1) or "?" in selector.split("#", 1)[0]


def is_dist_tag(selector):
    return isinstance(selector, str) and bool(DIST_TAG.fullmatch(selector)) and not VERSION.fullmatch(selector)


def local_declaration(source):
    if not isinstance(source, str) or not source or len(source) > 500:
        return False
    value = source.strip()
    if not value or re.search(r"[\x00-\x1f]", value):
        return False
    scheme = re.match(r"^([a-zA-Z][a-zA-Z0-9+.-]*):", value)
    if scheme and len(scheme.group(1)) == 1 and len(value) > 2 and value[2] in {"/", "\\"}:
        return True
    if scheme and scheme.group(1).lower() != "file":
        return False
    if scheme:
        try:
            parsed = urlsplit(value)
        except ValueError:
            return False
        return (parsed.username is None and parsed.password is None and
                parsed.netloc in {"", "localhost"} and bool(parsed.path) and
                not parsed.query and not parsed.fragment)
    return True


def update_identity(source):
    declaration = npm_declaration(source)
    if declaration:
        return ("npm", declaration[0])
    declaration = git_declaration(source)
    return ("git", declaration[0]) if declaration else ("source", source)


def selector_identity(selector):
    if selector in {None, "latest"}:
        return "latest"
    if VERSION.fullmatch(selector):
        return "exact:" + selector.lstrip("v")
    if is_dist_tag(selector):
        return "tag:" + selector
    return "constraint:" + selector


def resource_identity(row):
    unit = update_identity(row["source"])
    return {"scope": row["scope"], "kind": row["kind"], "name": row["name"],
            "source": row["source"], "path": row["path"],
            "update_unit": {"type": unit[0], "identity": unit[1], "scope": row["scope"]}}


def is_project_filter_delta(row):
    declarations = row.get("declarations")
    return (row.get("scope") == "project" and isinstance(declarations, list) and len(declarations) == 1 and
            isinstance(declarations[0], dict) and declarations[0].get("autoload") is False)


def declaration_source(row):
    declarations = row.get("declarations")
    if not isinstance(declarations, list) or len(declarations) != 1:
        raise Invalid("A Pi resource must retain exactly one complete package declaration.")
    declaration = declarations[0]
    return declaration if isinstance(declaration, str) else declaration["source"]


def resource_record(row):
    object_fields(row, RESOURCE_FIELDS)
    assessment_record(row)
    if (not isinstance(row.get("name"), str) or not row["name"] or len(row["name"]) > 200 or
            re.search(r"[\x00-\x1f]", row["name"])):
        raise Invalid("A resource needs a bounded display or command name.")
    if row.get("kind") not in KINDS or row.get("owner") not in {"pi-package", "firstmate", "local"}:
        raise Invalid("Unknown resource kind or owner.")
    if row.get("scope") not in {"user", "project"}:
        raise Invalid("A resource needs its actual user or project scope.")
    path = row.get("path")
    if not isinstance(path, str) or not path or len(path) > 500 or re.search(r"[\x00-\x1f]", path):
        raise Invalid("A resource needs its bounded discovered source path.")
    for field in ("installed", "discovered", "loaded", "used", "compatible", "owner_verified", "available_verified"):
        if row.get(field) is not None and type(row[field]) is not bool:
            raise Invalid("Resource inventory and assessment flags must be booleans or unknown.")
    for field in ("installed_version", "effective_version", "available"):
        value = row.get(field)
        version(value, "firstmate" if row["owner"] == "firstmate" or (isinstance(value, str) and COMMIT.fullmatch(value)) else "pi")
    availability_evidence(row)
    source = row.get("source")
    if source is None:
        raise Invalid("A resource needs its exact source-backed identity.")
    if source is not None:
        if not isinstance(source, str) or len(source) > 500:
            raise Invalid("Resource sources must be bounded non-secret declarations.")
        match = PACKAGE.fullmatch(source)
        if match:
            if (match[2] is not None and
                    (not NPM_SELECTOR.fullmatch(match[2]) or selector_has_credentials(match[2]))):
                raise Invalid("Unsupported npm declaration; never include credentials or command text.")
        elif git_declaration(source) is None and not local_declaration(source):
            raise Invalid("Only credential-free npm, Git, or local resource declarations are accepted.")
        if row.get("declarations") is not None and declaration_source(row) != source:
            raise Invalid("A resource declaration must exactly identify its update unit without flattening filters.")
        selector = match[2] if match else None
        git_ref = git_declaration(source)[1] if git_declaration(source) else None
        expected_pins = [selector] if selector and (VERSION.fullmatch(selector) or
                                                      (is_dist_tag(selector) and selector != "latest")) else [git_ref] if git_ref else []
        if row.get("pins") is not None and row["pins"] != expected_pins:
            raise Invalid("Resource pin evidence must match its unchanged declaration.")
        row["pins"] = expected_pins
    result = copy.deepcopy(row)
    result["identity"] = resource_identity(result)
    return result


def observations(data):
    rows = data.get("observations", {})
    object_fields(rows, set(TARGETS))
    result = {}
    for target, raw in rows.items():
        object_fields(raw, OBS_FIELDS)
        row = copy.deepcopy(raw)
        assessment_record(row)
        for field in ("installed", "used", "loaded", "compatible", "owner_verified", "available_verified", "resources_complete"):
            if row.get(field) is not None and type(row[field]) is not bool:
                raise Invalid("Observation flags must be booleans or unknown.")
        for field in ("installed_version", "effective_version", "available"):
            version(row.get(field), target)
        availability_evidence(row)
        if row.get("owner") is not None and not re.fullmatch(r"[a-z][a-z-]{0,40}", row["owner"]):
            raise Invalid("Owner must be a canonical owner identifier, never a command.")
        if row.get("relation") is not None and row["relation"] not in {"same", "fast-forward", "diverged", "unknown"}:
            raise Invalid("Unknown commit relationship.")
        label = row.get("update_label")
        if label is not None and (target != "git" or not isinstance(label, str) or not re.fullmatch(r"Command Line Tools for Xcode[- A-Za-z0-9.]{1,80}", label)):
            raise Invalid("Only a reviewed Command Line Tools label is accepted.")
        resources = row.get("resources", [])
        if not isinstance(resources, list) or len(resources) > 1000 or (resources and target != "pi"):
            raise Invalid("Resources belong only to Pi.")
        row["resources"] = [resource_record(r) for r in resources]
        keys = [json.dumps(resource["identity"], sort_keys=True) for resource in row["resources"]]
        if len(keys) != len(set(keys)):
            raise Invalid("Duplicate source/path-backed resource identities must be reconciled.")
        result[target] = row
    return result


def resource_collisions(resources):
    groups = {}
    for resource in resources:
        if resource["kind"] != "prompt-template":
            continue
        key = (resource["kind"], resource["name"])
        groups.setdefault(key, []).append(copy.deepcopy(resource["identity"]))
    return [{"kind": key[0], "name": key[1], "resources": identities}
            for key, identities in groups.items() if len(identities) > 1]


def semver_parts(value):
    value = value.lstrip("v").split("+", 1)[0]
    core, separator, prerelease = value.partition("-")
    return tuple(map(int, core.split("."))), prerelease.split(".") if separator else None


def semver_compare(left, right):
    left_core, left_pre = semver_parts(left)
    right_core, right_pre = semver_parts(right)
    if left_core != right_core:
        return (left_core > right_core) - (left_core < right_core)
    if left_pre is None or right_pre is None:
        return (left_pre is None) - (right_pre is None)
    for left_part, right_part in zip(left_pre, right_pre):
        if left_part == right_part:
            continue
        left_numeric, right_numeric = left_part.isdigit(), right_part.isdigit()
        if left_numeric and right_numeric:
            return (int(left_part) > int(right_part)) - (int(left_part) < int(right_part))
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return (left_part > right_part) - (left_part < right_part)
    return (len(left_pre) > len(right_pre)) - (len(left_pre) < len(right_pre))


def outcome(target, row):
    installed_version, available = row.get("installed_version"), row.get("available")
    status = row.get("availability_status")
    evidence = row.get("release_evidence")
    if row.get("installed") is False:
        category = "not-installed"
    elif row.get("installed") is True and status == "unavailable":
        category = "unavailable"
    elif row.get("installed") is not True or not installed_version or status in {None, "unknown"}:
        category = "unknown"
    elif status != "verified" or not available or row.get("available_verified") is not True:
        category = "unknown"
    elif (target not in {"firstmate", "wezterm"} and semver_compare(installed_version, available) == 0) or \
            installed_version.lstrip("v") == available.lstrip("v"):
        category = "unchanged"
    elif row.get("compatible") is not True:
        category = "deferred"
    elif target == "firstmate":
        category = "candidate" if row.get("relation") == "fast-forward" else "deferred"
    elif target == "wezterm":
        category = "candidate" if available[:15] > installed_version[:15] else "deferred"
    else:
        category = "candidate" if semver_compare(available, installed_version) > 0 else "deferred"
    return {"category": category, "evidence": evidence}


def require_version_evidence(row, loaded_field):
    if not row.get("installed_version") or not row.get("installed_version_evidence") or \
            not row.get("effective_version_evidence"):
        raise Invalid("Installed and effective versions require separate provenance.")
    if row.get(loaded_field) is True and not row.get("effective_version"):
        raise Invalid("A loaded or used item requires its independently observed effective version.")


def require_assessment(row, loaded_field):
    required = ("source", "scope", "declarations", "pins", "dependencies", "disruption",
                "maintenance", "rollback", "verification", "compatibility_evidence",
                "owner_evidence", "release_evidence", "observed_at")
    if any(field not in row for field in required) or not isinstance(row.get("scope"), str) or \
            any(not isinstance(row.get(field), list) for field in
                ("declarations", "pins", "dependencies", "verification")):
        raise Invalid("A proposal requires concrete typed source, scope, declarations, pins, dependencies, and verification facts.")
    if any(not row[field] for field in ("source", "scope", "disruption", "maintenance", "rollback", "verification",
                                        "compatibility_evidence", "owner_evidence", "release_evidence", "observed_at")):
        raise Invalid("A proposal requires concrete non-empty assessment and verification facts.")
    if row.get("availability_status") != "verified":
        raise Invalid("A proposal requires a verified available release.")
    require_version_evidence(row, loaded_field)


def require_pi_resource_compatibility(row):
    required = ("source", "scope", "declarations", "pins", "compatibility_evidence",
                "owner_evidence", "installed_version_evidence", "effective_version_evidence", "observed_at")
    if any(field not in row for field in required) or not isinstance(row.get("scope"), str) or \
            any(not isinstance(row.get(field), list) for field in ("declarations", "pins")) or \
            any(not row[field] for field in
                ("source", "scope", "compatibility_evidence", "owner_evidence", "installed_version_evidence",
                 "effective_version_evidence", "observed_at")):
        raise Invalid("A Pi update requires complete resource presence, owner, source, version, and compatibility evidence.")
    if any(row.get(field) is not True for field in
           ("installed", "discovered", "compatible", "owner_verified")) or \
            any(type(row.get(field)) is not bool for field in ("used", "loaded")):
        raise Invalid("A Pi update requires verified resource presence, owner, loading, and compatibility.")
    require_version_evidence(row, "loaded")


def parent_pi_context(row):
    fields = ("installed", "used", "loaded", "owner", "owner_verified", "source", "scope",
              "declarations", "pins", "installed_version", "effective_version",
              "installed_version_evidence", "effective_version_evidence", "owner_evidence", "observed_at")
    if any(field not in row for field in fields) or row.get("installed") is not True or \
            row.get("owner_verified") is not True or row.get("owner") not in OWNERS["pi"] or \
            any(type(row.get(field)) is not bool for field in ("used", "loaded")) or \
            not isinstance(row.get("declarations"), list) or not isinstance(row.get("pins"), list) or \
            any(not row.get(field) for field in ("source", "scope", "owner_evidence", "observed_at")):
        raise Invalid("Pi installation, channel, loading, version, provenance, and freshness evidence must be established first.")
    require_version_evidence(row, "loaded")
    return {field: copy.deepcopy(row[field]) for field in fields}


def dispatch(target, row, selected):
    owner = row.get("owner")
    if selected is None and owner not in OWNERS[target]:
        raise Invalid("Unsupported installation owner; never infer or substitute another owner.")
    if selected is not None:
        if selected["owner"] != "pi-package":
            raise Invalid("Use /updatefirstmate for Firstmate resources; local resources need their source owner's reviewed edit.")
        source = declaration_source(selected)
        if not source:
            raise Invalid("A managed resource needs its unchanged package declaration.")
        match = PACKAGE.fullmatch(source)
        if not match or (match[2] is not None and not is_dist_tag(match[2])):
            raise Invalid("Pinned, Git, local, and range sources need their existing owner's separately reviewed proposal.")
        if selected["scope"] != "user":
            raise Invalid("Project package scope needs separately verified owner isolation; never assume a personal update is project-only.")
        return {"argv": ["pi", "update", source, "--no-approve"]}
    if target == "firstmate" and owner == "firstmate":
        return {"skill": "updatefirstmate"}
    if target == "pi" and owner in {"npm-global", "pi-managed"}:
        return {"argv": ["pi", "update", "--no-approve"]}
    if target == "herdr" and owner == "brew-formula":
        return {"argv": ["brew", "upgrade", "herdr"]}
    if target == "herdr" and owner == "herdr-native":
        return {"argv": ["herdr", "update"]}
    if target == "wezterm" and owner == "brew-cask":
        return {"argv": ["brew", "upgrade", "--cask", "wezterm"]}
    if target == "treehouse" and owner == "treehouse-native":
        return {"argv": ["treehouse", "update"]}
    if target == "git" and owner == "apple-clt" and row.get("update_label"):
        return {"argv": ["softwareupdate", "--install", row["update_label"]]}
    if target in AXI_NATIVE and owner in {"npm-global", "pnpm-global"}:
        return {"argv": [target, "update"]}
    if target == "tasks-axi" and owner == "npm-global":
        return {"argv": ["npm", "install", "-g", "tasks-axi@" + row["available"]]}
    if target == "no-mistakes" and owner == "no-mistakes-native":
        return {"argv": ["no-mistakes", "update"]}
    raise Invalid("Update owner is unverified or not supported by this helper; inspect its current help, never substitute another owner.")


def bound_context(row):
    return {field: copy.deepcopy(row[field]) for field in
            ("source", "scope", "declarations", "pins", "dependencies", "disruption", "maintenance",
             "rollback", "verification", "compatibility_evidence", "owner_evidence", "release_evidence",
             "observed_at")}


def proposal(data, rows):
    target = data.get("target")
    if target not in TARGETS:
        raise Invalid("Select exactly one default target; dependency-only tools are not update targets.")
    row = rows.get(target, {})
    selector = data.get("resource")
    selected = None
    parent_context = None
    if selector is not None:
        identity_fields = {"name", "kind", "scope", "source", "path", "update_unit"}
        object_fields(selector, identity_fields)
        object_fields(selector.get("update_unit"), {"type", "identity", "scope"})
        if set(selector) != identity_fields or set(selector["update_unit"]) != {"type", "identity", "scope"} or target != "pi":
            raise Invalid("Select one Pi package resource by its complete source/path-backed identity.")
        parent_context = parent_pi_context(row)
        matches = [resource for resource in row.get("resources", []) if resource["identity"] == selector]
        if len(matches) != 1:
            raise Invalid("Select one unambiguous inventoried Pi package resource.")
        selected = matches[0]
    else:
        if any(row.get(k) is not True for k in
               ("installed", "compatible", "owner_verified", "available_verified")) or \
                any(type(row.get(field)) is not bool for field in ("used", "loaded")):
            raise Invalid("Installed status, actual-use evidence, compatibility, owner, and available release must be established first.")
    if target == "pi" and row.get("resources_complete") is not True:
        raise Invalid("Complete Pi extensions, skills, templates, and scope inventory before proposing an update.")
    affected = copy.deepcopy(row.get("resources", [])) if target == "pi" else []
    if selected is not None:
        identity = update_identity(selected["source"])
        affected = [copy.deepcopy(resource) for resource in row["resources"] if
                    update_identity(resource.get("source")) == identity and
                    (resource.get("scope") == selected["scope"] or
                     (selected["scope"] == "user" and is_project_filter_delta(resource)))]
        if any(resource.get("owner") != "pi-package" for resource in affected):
            raise Invalid("Every resource affected by a package update must retain its verified package owner.")
        npm_sources = [npm_declaration(resource["source"]) for resource in affected]
        if identity[0] == "npm" and len({selector_identity(source[1]) for source in npm_sources}) != 1:
            raise Invalid("Conflicting declarations for one npm package require reconciliation before approval.")
        if identity[0] == "npm" and any(source[1] and VERSION.fullmatch(source[1]) for source in npm_sources):
            raise Invalid("Pinned npm packages are excluded by Pi update and have no preparable owner action.")
        for resource in affected:
            require_assessment(resource, "loaded")
            if any(resource.get(k) is not True for k in
                   ("installed", "discovered", "compatible", "owner_verified", "available_verified")) or \
                    any(type(resource.get(k)) is not bool for k in ("loaded", "used")):
                raise Invalid("Every affected resource needs its own presence, loading, use, compatibility, owner, and release evidence.")
            if outcome(target, resource)["category"] != "candidate":
                raise Invalid("Every affected resource must be assessed for the same candidate package release.")
        if any((resource.get("installed_version"), resource.get("available")) !=
               (selected.get("installed_version"), selected.get("available")) for resource in affected):
            raise Invalid("Affected resources must identify one concrete package version transition.")
    candidate = selected if selected is not None else row
    if target == "pi" and selected is None:
        for resource in affected:
            require_pi_resource_compatibility(resource)
    require_assessment(candidate, "loaded")
    if outcome(target, candidate)["category"] != "candidate":
        raise Invalid("No verified, compatible newer semantic release can be proposed.")
    proposed = {"target": target, "resource": copy.deepcopy(selector),
                "update_unit": (copy.deepcopy(selected["identity"]["update_unit"])
                                if selected else {"target": target}),
                "owner": selected["owner"] if selected else row["owner"],
                "installed_version": candidate["installed_version"],
                "effective_version": candidate.get("effective_version"),
                "installed_version_evidence": candidate["installed_version_evidence"],
                "effective_version_evidence": candidate["effective_version_evidence"],
                "available": candidate["available"],
                "dispatch": dispatch(target, candidate, selected),
                "affected_resources": affected}
    if parent_context is not None:
        proposed["parent_pi"] = parent_context
    proposed.update(bound_context(candidate))
    return proposed


def prepare(data, proposed):
    if data.get("approval") != proposed:
        raise Invalid("One concrete matching captain approval is required; batch, stale, or altered approvals are refused.")
    checkpoint = data.get("checkpoint")
    object_fields(checkpoint, CHECKPOINT_FIELDS)
    if set(checkpoint) != CHECKPOINT_FIELDS or checkpoint["actor"] != "primary":
        raise Invalid("Preparation requires the owning primary's complete checkpoint, not worker or second-mate authority.")
    for field in ("active_sessions", "active_workers", "active_validation"):
        if checkpoint[field] is not False:
            raise Invalid("Active or unknown affected work refuses preparation; never stop, cancel, reload, or resume it to clear this check.")
    for field in CHECKPOINT_FIELDS - {"actor", "active_sessions", "active_workers", "active_validation"}:
        if checkpoint[field] is not True:
            raise Invalid("Pins, declarations, credentials, local state, and recovery must remain protected.")
    return {"status": "prepared-not-executed", "proposal": proposed, "execution_authorized_by_helper": False}


def main():
    parser = SafeParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog="Observation fields: " + ", ".join(sorted(OBS_FIELDS)) +
                                     "\nResource fields: " + ", ".join(sorted(RESOURCE_FIELDS)) +
                                     "\nCheckpoint fields: " + ", ".join(sorted(CHECKPOINT_FIELDS)) +
                                     "\nFlags are booleans, never strings. Missing evidence remains unknown.\n"
                                     "prepare does not execute; actual captain authority and fresh owner checks remain required.")
    parser.add_argument("command", choices=["catalog", "inspect", "propose", "prepare"], nargs="?", default="inspect")
    args = parser.parse_args()
    if args.command == "catalog":
        result = {"targets": [{"id": k, "name": v, "owners": OWNERS[k]} for k, v in TARGETS.items()],
                  "dependency_only": DEPENDENCY_ONLY, "resource_kinds": KINDS,
                  "discovery_scope": "firstmate-project-shared-not-main-only"}
    else:
        raw = b"" if sys.stdin.isatty() else sys.stdin.buffer.read(LIMIT + 1)
        if len(raw) > LIMIT:
            raise Invalid("Input exceeds the bounded evidence limit.")
        data = json.loads(raw, object_pairs_hook=unique_object) if raw.strip() else {}
        fields = {"observations"} if args.command == "inspect" else {"observations", "target", "resource"}
        if args.command == "prepare":
            fields |= {"approval", "checkpoint"}
        object_fields(data, fields)
        rows = observations(data)
        if args.command == "inspect":
            result = {"mode": "inspection-only", "targets": [{"id": k, "name": v,
                       "outcome": outcome(k, rows.get(k, {})), "observation": rows.get(k, {}),
                       "resource_collisions": resource_collisions(rows.get(k, {}).get("resources", []))}
                      for k, v in TARGETS.items()], "dependency_only": DEPENDENCY_ONLY}
        else:
            proposed = proposal(data, rows)
            result = {"status": "needs-individual-captain-approval", "proposal": proposed} if args.command == "propose" else prepare(data, proposed)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Invalid as error:
        # Invalid reasons are fixed diagnostic strings, never interpolated input.
        print(json.dumps({"status": "refused", "reason": str(error)}))
        sys.exit(2)
    except (ValueError, TypeError, RecursionError):
        # Never echo rejected input, secrets, arbitrary command text, or parser
        # exceptions into either output stream.
        print(json.dumps({"status": "refused", "reason": "Malformed or unsupported evidence; inspect the helper schema."}))
        sys.exit(2)
