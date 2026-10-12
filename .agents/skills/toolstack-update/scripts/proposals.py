#!/usr/bin/env python3
"""Non-executing update proposal helper for the toolstack-update skill.

The skill owns the workflow; this module owns the catalog, input schema,
outcome classification, and supported dispatch descriptions. It only reads bounded JSON
from stdin and writes JSON to stdout. It never probes tools, reads configuration
or credentials, downloads, installs, executes a dispatch, or records approvals.
A supplied approval is a caller's assertion, not proof of captain authority.

Commands: catalog; inspect (default); propose; prepare.
Resource source records can retain credential-free npm, Git, and local sources;
only exact-version/unpinned npm user packages have a preparable resource action.
inspect takes {observations: {target: observation}} and always returns the full
catalog. propose adds target and optionally resource (a Pi resource name).
prepare additionally needs approval equal to the current proposal and checkpoint.
Use --help for the observation/checkpoint fields. No apply command exists.
"""

import argparse
import copy
import json
import re
import sys

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
VERSION = re.compile(r"v?\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?(?:\+[a-zA-Z0-9.-]+)?\Z")
WEZ_VERSION = re.compile(r"\d{8}-\d{6}-[a-f0-9]{8}\Z")
COMMIT = re.compile(r"[a-f0-9]{40}\Z")
NAME = re.compile(r"(?:@[a-z0-9_-]+/)?[a-z0-9][a-z0-9._-]*\Z")
PACKAGE = re.compile(r"npm:((?:@[a-z0-9_-]+/)?[a-z0-9][a-z0-9._-]*)(?:@(.+))?\Z")
GIT_SOURCE = re.compile(r"git:(?:(?:https://)?[a-zA-Z0-9.-]+/|git@[a-zA-Z0-9.-]+:)[a-zA-Z0-9_.-]+/[a-zA-Z0-9_./-]+(?:@[a-zA-Z0-9_./-]+)?\Z")
LOCAL_SOURCE = re.compile(r"(?:~/|/|\./|\.\./)[a-zA-Z0-9_./ -]+\Z")
NPM_SELECTOR = re.compile(r"[a-zA-Z0-9.^~+*-]{1,64}\Z")
ASSESSMENT_FIELDS = {"source", "scope", "declarations", "pins", "dependencies", "disruption",
                     "maintenance", "rollback", "verification", "compatibility_evidence",
                     "owner_evidence", "release_evidence", "availability_status"}
VERSION_FIELDS = {"installed_version", "effective_version", "installed_version_evidence",
                  "effective_version_evidence"}
OBS_FIELDS = {"installed", "used", "available", "owner", "compatible", "owner_verified",
              "available_verified", "relation", "update_label", "resources", "resources_complete"} \
             | ASSESSMENT_FIELDS | VERSION_FIELDS
RESOURCE_FIELDS = {"name", "kind", "owner", "available", "pin", "installed", "discovered",
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


def assessment_record(row):
    status = row.get("availability_status")
    if status is not None and status not in {"unknown", "unavailable", "verified"}:
        raise Invalid("Availability status must distinguish unknown, unavailable, and verified evidence.")
    if row.get("scope") is not None and row["scope"] not in {"user", "project", "system", "shared"}:
        raise Invalid("Scope must identify the concrete update boundary.")
    for field in ("declarations", "pins", "dependencies", "verification"):
        values = row.get(field)
        if values is not None and (not isinstance(values, list) or len(values) > 100 or
                                   any(not isinstance(value, str) or not value or len(value) > 300 for value in values)):
            raise Invalid("Declarations, pins, dependencies, and verification facts must be bounded non-empty strings.")
    for field in ("disruption", "maintenance", "rollback", "compatibility_evidence",
                  "owner_evidence", "release_evidence", "installed_version_evidence",
                  "effective_version_evidence"):
        value = row.get(field)
        if value is not None and (not isinstance(value, str) or not value or len(value) > 500):
            raise Invalid("Assessment evidence must be a bounded non-empty string.")
    source = row.get("source")
    if source is not None and (not isinstance(source, str) or not source or len(source) > 200):
        raise Invalid("Source must be a bounded non-secret identifier.")


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


def resource_record(row):
    object_fields(row, RESOURCE_FIELDS)
    assessment_record(row)
    if not isinstance(row.get("name"), str) or not NAME.fullmatch(row["name"]):
        raise Invalid("A resource needs a safe canonical name.")
    if row.get("kind") not in KINDS or row.get("owner") not in {"pi-package", "firstmate", "local"}:
        raise Invalid("Unknown resource kind or owner.")
    if row.get("scope") not in {"user", "project"}:
        raise Invalid("A resource needs its actual user or project scope.")
    for field in ("installed", "discovered", "loaded", "used", "compatible", "owner_verified", "available_verified"):
        if row.get(field) is not None and type(row[field]) is not bool:
            raise Invalid("Resource inventory and assessment flags must be booleans or unknown.")
    for field in ("installed_version", "effective_version", "available", "pin"):
        value = row.get(field)
        version(value, "firstmate" if row["owner"] == "firstmate" or (isinstance(value, str) and COMMIT.fullmatch(value)) else "pi")
    availability_evidence(row)
    source = row.get("source")
    if source is not None:
        if not isinstance(source, str) or len(source) > 200:
            raise Invalid("Resource sources must be bounded non-secret declarations.")
        match = PACKAGE.fullmatch(source)
        if match:
            if match[2] is not None and not NPM_SELECTOR.fullmatch(match[2]):
                raise Invalid("Unsupported npm declaration; never include credentials or command text.")
        elif not GIT_SOURCE.fullmatch(source) and not LOCAL_SOURCE.fullmatch(source):
            raise Invalid("Only credential-free npm, Git, or local resource declarations are accepted.")
        if row.get("declarations") is not None and row["declarations"] != [source]:
            raise Invalid("A resource declaration must exactly identify its update unit.")
        declared_pin = row.get("pin") or (match[2] if match else None)
        expected_pins = [declared_pin] if declared_pin else []
        if row.get("pins") is not None and row["pins"] != expected_pins:
            raise Invalid("Resource pin evidence must match its unchanged declaration.")
    return copy.deepcopy(row)


def observations(data):
    rows = data.get("observations", {})
    object_fields(rows, set(TARGETS))
    result = {}
    for target, raw in rows.items():
        object_fields(raw, OBS_FIELDS)
        row = copy.deepcopy(raw)
        assessment_record(row)
        for field in ("installed", "used", "compatible", "owner_verified", "available_verified", "resources_complete"):
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
        keys = [(r["kind"], r["scope"], r["name"]) for r in row["resources"]]
        if len(keys) != len(set(keys)):
            raise Invalid("Duplicate resources must be reconciled rather than hidden.")
        result[target] = row
    return result


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
    elif installed_version.lstrip("v") == available.lstrip("v"):
        category = "unchanged"
    elif target == "firstmate":
        category = "candidate" if row.get("relation") == "fast-forward" else "deferred"
    elif target == "wezterm":
        category = "candidate" if available[:15] > installed_version[:15] else "deferred"
    else:
        stable = r"v?(\d+)\.(\d+)\.(\d+)"
        a, b = re.fullmatch(stable, installed_version), re.fullmatch(stable, available)
        category = "candidate" if a and b and tuple(map(int, b.groups())) > tuple(map(int, a.groups())) else "deferred"
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
                "owner_evidence", "release_evidence")
    if any(field not in row for field in required):
        raise Invalid("A proposal requires complete source, scope, declaration, dependency, consequence, recovery, verification, and evidence facts.")
    if any(not row[field] for field in ("source", "disruption", "maintenance", "rollback", "verification",
                                        "compatibility_evidence", "owner_evidence", "release_evidence")):
        raise Invalid("A proposal requires concrete non-empty assessment and verification facts.")
    if row.get("availability_status") != "verified":
        raise Invalid("A proposal requires a verified available release.")
    require_version_evidence(row, loaded_field)


def require_pi_resource_compatibility(row):
    required = ("source", "scope", "declarations", "pins", "compatibility_evidence",
                "owner_evidence", "installed_version_evidence", "effective_version_evidence")
    if any(field not in row for field in required) or any(not row[field] for field in
            ("source", "compatibility_evidence", "owner_evidence", "installed_version_evidence",
             "effective_version_evidence")):
        raise Invalid("A Pi update requires complete resource presence, owner, source, version, and compatibility evidence.")
    if any(row.get(field) is not True for field in
           ("installed", "discovered", "compatible", "owner_verified")) or type(row.get("loaded")) is not bool:
        raise Invalid("A Pi update requires verified resource presence, owner, loading, and compatibility.")
    require_version_evidence(row, "loaded")


def dispatch(target, row, selected):
    owner = row.get("owner")
    if selected is None and owner not in OWNERS[target]:
        raise Invalid("Unsupported installation owner; never infer or substitute another owner.")
    if selected is not None:
        if selected["owner"] != "pi-package":
            raise Invalid("Use /updatefirstmate for Firstmate resources; local resources need their source owner's reviewed edit.")
        source = selected.get("source")
        if not source:
            raise Invalid("A managed resource needs its unchanged package declaration.")
        match = PACKAGE.fullmatch(source)
        if not match or (match[2] is not None and not VERSION.fullmatch(match[2])):
            raise Invalid("Git, local, or range/tag sources need their existing owner's separately reviewed proposal.")
        pin = selected.get("pin") or match[2]
        if selected.get("pin") and match[2] and selected["pin"].lstrip("v") != match[2].lstrip("v"):
            raise Invalid("Pin evidence contradicts the unchanged package declaration.")
        if pin and selected["available"].lstrip("v") != pin.lstrip("v"):
            raise Invalid("Explicit pins are preserved; changing a pin is a separate authorization.")
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
             "rollback", "verification", "compatibility_evidence", "owner_evidence", "release_evidence")}


def proposal(data, rows):
    target = data.get("target")
    if target not in TARGETS:
        raise Invalid("Select exactly one default target; dependency-only tools are not update targets.")
    row = rows.get(target, {})
    if any(row.get(k) is not True for k in ("installed", "compatible", "owner_verified", "available_verified")) or type(row.get("used")) is not bool:
        raise Invalid("Installed status, actual-use evidence, compatibility, owner, and available release must be established first.")
    if target == "pi" and row.get("resources_complete") is not True:
        raise Invalid("Complete Pi extensions, skills, templates, and scope inventory before proposing an update.")
    selected = None
    affected = copy.deepcopy(row.get("resources", [])) if target == "pi" else []
    if data.get("resource") is not None:
        matches = [r for r in row.get("resources", []) if r["name"] == data["resource"]]
        if target != "pi" or len(matches) != 1:
            raise Invalid("Select one unambiguous inventoried Pi resource.")
        selected = matches[0]
        if not selected.get("source"):
            raise Invalid("A managed resource needs its unchanged package declaration.")
        affected = [copy.deepcopy(r) for r in row["resources"] if r.get("source") == selected["source"]]
        if any(r.get("owner") != "pi-package" or r.get("scope") != selected.get("scope") for r in affected):
            raise Invalid("Every resource supplied by a package must share its verified owner and scope.")
        for resource in affected:
            require_assessment(resource, "loaded")
            if any(resource.get(k) is not True for k in
                   ("installed", "discovered", "compatible", "owner_verified", "available_verified")) or \
                    any(type(resource.get(k)) is not bool for k in ("loaded", "used")):
                raise Invalid("Every affected resource needs its own presence, loading, use, compatibility, owner, and release evidence.")
            if outcome(target, resource)["category"] != "candidate":
                raise Invalid("Every affected resource must be assessed for the same candidate package release.")
        if any((r.get("installed_version"), r.get("available")) !=
               (selected.get("installed_version"), selected.get("available")) for r in affected):
            raise Invalid("Affected resources must identify one concrete package version transition.")
    candidate = selected if selected is not None else row
    if target == "pi" and selected is None:
        for resource in affected:
            require_pi_resource_compatibility(resource)
    require_assessment(candidate, "loaded" if selected is not None else "used")
    if outcome(target, candidate)["category"] != "candidate":
        raise Invalid("No verified, compatible newer stable release can be proposed.")
    proposed = {"target": target, "resource": data.get("resource"),
                "update_unit": selected["source"] if selected else target,
                "owner": selected["owner"] if selected else row["owner"],
                "installed_version": candidate["installed_version"],
                "effective_version": candidate.get("effective_version"),
                "installed_version_evidence": candidate["installed_version_evidence"],
                "effective_version_evidence": candidate["effective_version_evidence"],
                "available": candidate["available"],
                "dispatch": dispatch(target, candidate, selected),
                "affected_resources": affected}
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
                       "outcome": outcome(k, rows.get(k, {})), "observation": rows.get(k, {})}
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
