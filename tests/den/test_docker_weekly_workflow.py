""".github/workflows/docker-weekly.yml: the dev image's weekly build and scan.

The workflow runs only on GitHub, on its schedule or by hand, so these tests
read it instead: its triggers, its token's permissions, the build, how it pins
what it runs, the scan's flags, and the entries of the ignore file the scan
reads (.trivyignore.yaml). They also run its shell steps in a scratch
directory the way the runner runs them (bash --noprofile --norc -eo pipefail),
with curl, gh and Trivy as stubs: the Trivy install against a fake release,
the scan with a fake Trivy, and the failure notice against a fake issue list.
The step tests are skipped on native Windows and where a tool they need is
missing.
"""

import datetime
import hashlib
import io
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
WORKFLOW = WORKFLOWS / "docker-weekly.yml"
DEV_IMAGE_WORKFLOW = WORKFLOWS / "docker-dev-image.yml"
# The findings the scan does not fail on while they wait on an upstream fix.
IGNORE_FILE = ROOT / ".trivyignore.yaml"
SYSTEM_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# What the runner runs a step with under `shell: bash`; the step's script is
# the file {0}.
BASH_SHELL = ["--noprofile", "--norc", "-eo", "pipefail"]
_TRIVY = "https://github.com/aquasecurity/trivy/releases"
# The runner architectures the install step maps to Trivy's archive names.
_PLATFORMS = {"X64": "Linux-64bit", "ARM64": "Linux-ARM64"}
_INSTALL_TOOLS = ("bash", "awk", "env", "install", "mktemp", "sha256sum", "tar")

# Renovate's customManagers:githubActionsVersions preset, as Renovate defines
# it in lib/config/presets/internal/custom-managers.preset.ts (renovatebot/
# renovate b5121c7), with JavaScript's (?<name>) written as Python's (?P<name>).
_RENOVATE_FILES = re.compile(
    r"(^|/)(workflow-templates|\.(?:github|gitea|forgejo)/(?:workflows|actions))/.+\.ya?ml$"
)
_RENOVATE_MATCH = re.compile(
    r"# renovate: datasource=(?P<datasource>[a-zA-Z0-9-._]+?)"
    r" depName=(?P<depName>[^\s]+?)"
    r"(?: (?:lookupName|packageName)=(?P<packageName>[^\s]+?))?"
    r"(?: versioning=(?P<versioning>[^\s]+?))?"
    r"(?: extractVersion=(?P<extractVersion>[^\s]+?))?"
    r"(?: registryUrl=(?P<registryUrl>[^\s]+?))?"
    r"\s+[A-Za-z0-9_]+?_VERSION\s*:\s*[\"']?(?P<currentValue>.+?)[\"']?\s"
)


def _load(path: Path) -> dict:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    # YAML 1.1 reads the bare key `on` as true; GitHub reads it as "on".
    data["on"] = data.pop(True)
    return data


def _workflow() -> dict:
    return _load(WORKFLOW)


def _step(job: str, name: str) -> dict:
    steps = _workflow()["jobs"][job]["steps"]
    found = [step for step in steps if step.get("name") == name]
    assert len(found) == 1, f"{job} has no single step named {name!r}"
    return found[0]


def _tool(name: str) -> str:
    """Absolute path of a program the test's skip mark checked for (ruff S607)."""
    exe = shutil.which(name)
    assert exe is not None, f"the skip mark skips this test without {name}"
    return exe


def _needs(*tools: str) -> pytest.MarkDecorator:
    return pytest.mark.skipif(
        sys.platform == "win32" or any(shutil.which(tool) is None for tool in tools),
        reason=f"needs {', '.join(tools)} on a POSIX system",
    )


# --- triggers, permissions and pins ---------------------------------------------


def test_the_scan_runs_on_mondays_at_0042_tokyo_time():
    # GitHub reads cron in UTC unless the entry names an IANA time zone.
    assert _workflow()["on"]["schedule"] == [
        {"cron": "42 0 * * 1", "timezone": "Asia/Tokyo"}
    ]


def test_the_scan_can_be_run_by_hand():
    assert "workflow_dispatch" in _workflow()["on"]


def test_the_token_reads_only_and_the_notice_job_alone_writes_issues():
    # A job that sets permissions gets exactly those, and none it leaves out;
    # the other jobs get the workflow's. Only the notice writes, and only
    # issues.
    workflow = _workflow()
    assert workflow["permissions"] == {"contents": "read"}
    for job_id, job in workflow["jobs"].items():
        if job_id == "notify":
            assert job["permissions"] == {"issues": "write"}
        else:
            assert "permissions" not in job, job_id


def test_every_action_is_pinned_to_a_commit_with_its_version():
    # A tag can be moved to other code; a commit cannot. The comment names
    # the release the commit is, for the reader and for Renovate.
    text = WORKFLOW.read_text(encoding="utf-8")
    lines = [ln.strip() for ln in text.splitlines() if re.match(r"\s*-?\s*uses:", ln)]
    used = [
        step["uses"]
        for job in _workflow()["jobs"].values()
        for step in job.get("steps", [])
        if "uses" in step
    ]
    assert lines
    assert len(lines) == len(used)
    for line in lines:
        assert re.fullmatch(
            r"(- )?uses: [\w.-]+/[\w./-]+@[0-9a-f]{40} # v\d+\.\d+\.\d+", line
        ), line


def test_run_steps_take_expressions_only_through_env():
    # An expression in a run script is pasted into the script before bash
    # reads it; through env it stays a value.
    for job in _workflow()["jobs"].values():
        for step in job.get("steps", []):
            assert "${{" not in step.get("run", ""), step.get("name")


def test_the_scan_job_budget_covers_its_steps():
    # Every step has a budget of its own, so a hung step is stopped by it,
    # and the job's budget covers them all.
    job = _workflow()["jobs"]["scan"]
    budgets = [step.get("timeout-minutes", 0) for step in job["steps"]]
    assert all(budget > 0 for budget in budgets), budgets
    assert job["timeout-minutes"] >= sum(budgets)
    assert _workflow()["jobs"]["notify"]["timeout-minutes"] > 0


# --- the build -------------------------------------------------------------------


def _build(workflow: dict, job: str) -> dict:
    steps = [
        step
        for step in workflow["jobs"][job]["steps"]
        if step.get("uses", "").startswith("docker/build-push-action@")
    ]
    assert len(steps) == 1, f"{job} has no single docker/build-push-action step"
    return steps[0]


def test_the_image_is_built_as_the_dev_image_workflow_does_without_cache_or_push():
    # A cold build fetches today's base image, packages and releases, as a
    # user's --pull --no-cache build does, and nothing leaves the runner.
    weekly = _build(_workflow(), "scan")["with"]
    dev = _build(_load(DEV_IMAGE_WORKFLOW), "dev-image")["with"]
    for key in ("context", "file", "tags", "load"):
        assert weekly[key] == dev[key], key
    assert weekly["load"] is True
    assert weekly["no-cache"] is True
    assert not {"push", "cache-from", "cache-to", "outputs"} & weekly.keys()


# --- Trivy: the pin, the install, the scan --------------------------------------


def _install_step() -> dict:
    return _step("scan", "Install Trivy")


def test_trivy_is_pinned_where_renovate_reads_it():
    # customManagers:githubActionsVersions reads a `# renovate:` comment right
    # above a *_VERSION key in a workflow file.
    pinned = _install_step()["env"]["TRIVY_VERSION"]
    assert re.fullmatch(r"v\d+\.\d+\.\d+", pinned), pinned
    assert _RENOVATE_FILES.search(WORKFLOW.relative_to(ROOT).as_posix())
    found = [
        m.groupdict()
        for m in _RENOVATE_MATCH.finditer(WORKFLOW.read_text(encoding="utf-8"))
    ]
    assert [(m["datasource"], m["depName"], m["currentValue"]) for m in found] == [
        ("github-releases", "aquasecurity/trivy", pinned)
    ]


def test_only_the_install_step_sets_trivy_version():
    # Trivy reads each TRIVY_<FLAG> variable as that flag, and --version is
    # one: the scan must not run with TRIVY_VERSION set.
    workflow = _workflow()
    assert "TRIVY_VERSION" not in workflow.get("env", {})
    setters = []
    for job_id, job in workflow["jobs"].items():
        assert "TRIVY_VERSION" not in job.get("env", {}), job_id
        setters += [
            (job_id, step.get("name"))
            for step in job.get("steps", [])
            if "TRIVY_VERSION" in step.get("env", {})
        ]
    assert setters == [("scan", "Install Trivy")]


def _tar_gz(members: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o755
            tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# A Trivy that logs its arguments and, like Trivy, would read TRIVY_VERSION
# as --version: it refuses to run with it set. `image` exits $FAKE_TRIVY_EXIT.
_FAKE_TRIVY = """\
#!/bin/sh
printf 'trivy %s\\n' "$*" >> "$CALLS_LOG"
if [ -n "${{TRIVY_VERSION+set}}" ]; then
    echo "trivy: TRIVY_VERSION=$TRIVY_VERSION is read as --version" >&2
    exit 2
fi
case $1 in
    --version) echo 'Version: {label}' ;;
    image) exit "${{FAKE_TRIVY_EXIT:-0}}" ;;
esac
"""


def _fake_trivy(label: str) -> bytes:
    return _FAKE_TRIVY.format(label=label).encode()


def _trivy_web(
    version: str, *, served: str = "", listed: bool = True
) -> dict[str, bytes]:
    """Trivy ``version`` (no v) for both runner platforms, with its checksums.

    ``served`` serves that platform's archive with other contents than the
    checksums file lists; ``listed=False`` lists no Linux-64bit archive.
    """
    web = {}
    sums = []
    for platform in _PLATFORMS.values():
        name = f"trivy_{version}_{platform}.tar.gz"
        archive = _tar_gz({"trivy": _fake_trivy(f"{version} {platform}")})
        if listed or platform != "Linux-64bit":
            sums.append(f"{_sha256(archive)}  {name}\n")
        if platform == served:
            archive = _tar_gz({"trivy": _fake_trivy(f"{version} tampered")})
        web[f"{_TRIVY}/download/v{version}/{name}"] = archive
    checksums = f"{_TRIVY}/download/v{version}/trivy_{version}_checksums.txt"
    web[checksums] = "".join(sums).encode()
    return web


# curl that serves https://HOST/PATH from $FAKE_WEB/HOST/PATH, and refuses a
# call without --proto =https and --tlsv1.2.
_CURL_STUB = """\
url='' out='' proto='' tls=''
while [ "$#" -gt 0 ]; do
    case $1 in
        --proto) proto=$2; shift ;;
        --tlsv1.2) tls=1 ;;
        --retry) shift ;;
        -o) out=$2; shift ;;
        -*) ;;
        *) url=$1 ;;
    esac
    shift
done
if [ "$proto" != =https ] || [ "$tls" != 1 ]; then
    echo "curl stub: insecure call" >&2
    exit 2
fi
case $url in https://*) ;; *) echo "curl stub: $url" >&2; exit 2 ;; esac
file=$FAKE_WEB/${url#https://}
[ -f "$file" ] || { echo "curl: (22) HTTP 404: $url" >&2; exit 22; }
if [ -n "$out" ]; then cp "$file" "$out"; else cat "$file"; fi
"""
# gh that needs the token and repository from the step's env, prints
# $FAKE_ISSUES for `gh issue list`, and only logs every other call.
_GH_STUB = """\
if [ -z "$GH_TOKEN" ] || [ -z "$GH_REPO" ]; then
    echo "gh stub: GH_TOKEN and GH_REPO are not both set" >&2
    exit 4
fi
if [ "$1 $2" = "issue list" ]; then cat "$FAKE_ISSUES"; fi
"""


def _run_step(
    tmp_path: Path,
    step: dict,
    *,
    web: dict[str, bytes] | None = None,
    expressions: dict[str, str] | None = None,
    env: dict[str, str] | None = None,
    tools: tuple[str, ...] = ("bash",),
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    """Run ``step``'s script as the runner does, with the stubs first on PATH.

    The step's env goes in as the runner sets it; each value that is an
    expression must be in ``expressions`` (expression -> value). HOME,
    TMPDIR and RUNNER_TEMP are in tmp_path, and so is the fake web the curl
    stub serves (URL -> body). Returns the result and the stubs' call log.
    """
    assert _workflow()["defaults"]["run"]["shell"] == "bash"
    assert "shell" not in step
    step_env = {}
    for key, value in step.get("env", {}).items():
        value = str(value)
        if "${{" in value:
            assert value in (expressions or {}), f"no test value for {value}"
            value = (expressions or {})[value]
        step_env[key] = value
    root = tmp_path / "web"
    for url, data in (web or {}).items():
        path = root / url.removeprefix("https://")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    stubs = tmp_path / "stubs"
    stubs.mkdir(exist_ok=True)
    log = tmp_path / "calls.log"
    log.touch()
    bash = _tool("bash")
    # One log line per call: a newline in an argument (an issue body) is
    # logged as a space.
    log_call = 'printf \'%s %s\\n\' "${0##*/}" "${*//$\'\\n\'/ }" >> "$CALLS_LOG"'
    for name, body in {"curl": _CURL_STUB, "gh": _GH_STUB}.items():
        path = stubs / name
        path.write_text(f"#!{bash}\n{log_call}\n{body}", encoding="utf-8")
        path.chmod(0o755)
    tool_dirs = [str(Path(_tool(name)).parent) for name in tools]
    path_dirs = list(dict.fromkeys([str(stubs), *tool_dirs, *SYSTEM_PATH.split(":")]))
    for name in ("home", "tmp", "runner-temp"):
        (tmp_path / name).mkdir(exist_ok=True)
    script = tmp_path / "step.sh"
    script.write_text(step["run"], encoding="utf-8")
    run_env = {
        "HOME": str(tmp_path / "home"),
        "TMPDIR": str(tmp_path / "tmp"),
        "PATH": os.pathsep.join(path_dirs),
        "RUNNER_TEMP": str(tmp_path / "runner-temp"),
        "RUNNER_ARCH": "X64",
        "FAKE_WEB": str(root),
        "CALLS_LOG": str(log),
        **step_env,
        **(env or {}),
    }
    result = subprocess.run(
        [bash, *BASH_SHELL, str(script)],
        env=run_env,
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    return result, log.read_text(encoding="utf-8").splitlines()


def _pinned_version() -> str:
    return _install_step()["env"]["TRIVY_VERSION"].removeprefix("v")


def _installed_trivy(tmp_path: Path) -> Path:
    return tmp_path / "runner-temp" / "trivy" / "trivy"


@_needs(*_INSTALL_TOOLS)
@pytest.mark.parametrize("runner_arch", sorted(_PLATFORMS))
def test_trivy_comes_from_its_release_for_the_runner(tmp_path, runner_arch):
    version = _pinned_version()
    platform = _PLATFORMS[runner_arch]
    result, calls = _run_step(
        tmp_path,
        _install_step(),
        web=_trivy_web(version),
        env={"RUNNER_ARCH": runner_arch},
        tools=_INSTALL_TOOLS,
    )
    assert result.returncode == 0, result.stderr
    # The step ran the binary it installed: the fake Trivy's --version, which
    # fails when TRIVY_VERSION is set.
    assert f"Version: {version} {platform}" in result.stdout
    assert f"{version} {platform}" in _installed_trivy(tmp_path).read_text()
    archive = f"{_TRIVY}/download/v{version}/trivy_{version}_{platform}.tar.gz"
    assert any(call.startswith("curl ") and archive in call for call in calls)
    assert not any((tmp_path / "tmp").iterdir()), "the work directory was left"


@_needs(*_INSTALL_TOOLS)
@pytest.mark.parametrize(
    "web_args",
    [{"served": "Linux-64bit"}, {"listed": False}],
    ids=["other", "unlisted"],
)
def test_trivy_that_its_checksums_do_not_vouch_for_is_not_installed(tmp_path, web_args):
    result, _ = _run_step(
        tmp_path,
        _install_step(),
        web=_trivy_web(_pinned_version(), **web_args),
        tools=_INSTALL_TOOLS,
    )
    assert result.returncode != 0
    assert not _installed_trivy(tmp_path).exists()


@_needs(*_INSTALL_TOOLS)
def test_an_unknown_runner_architecture_installs_nothing(tmp_path):
    result, calls = _run_step(
        tmp_path,
        _install_step(),
        web=_trivy_web(_pinned_version()),
        env={"RUNNER_ARCH": "ARM"},
        tools=_INSTALL_TOOLS,
    )
    assert result.returncode != 0
    assert not calls
    assert not _installed_trivy(tmp_path).exists()


def _scan_step() -> dict:
    return _step("scan", "Scan the dev image")


def _trivy_args(run: str) -> list[str]:
    words = shlex.split(run.replace("\\\n", " "))
    starts = [
        i
        for i, word in enumerate(words)
        if word.endswith("/trivy") and words[i + 1 : i + 2] == ["image"]
    ]
    assert len(starts) == 1, "the scan step runs no single `trivy image`"
    return words[starts[0] + 2 :]


def _option(args: list[str], name: str) -> str | None:
    return args[args.index(name) + 1] if name in args else None


def test_the_scan_fails_on_critical_and_high_findings_that_have_a_fix():
    args = _trivy_args(_scan_step()["run"])
    assert _option(args, "--severity") == "CRITICAL,HIGH"
    assert "--ignore-unfixed" in args
    assert _option(args, "--exit-code") == "1"
    # A readable table in the log, for vulnerabilities only.
    assert _option(args, "--format") == "table"
    assert _option(args, "--scanners") == "vuln"
    # The image the build step loaded into the runner's Docker engine, never
    # an image of that name from a registry.
    assert _option(args, "--image-src") == "docker"
    assert args[-1] == _build(_workflow(), "scan")["with"]["tags"]


@_needs(*_INSTALL_TOOLS)
@pytest.mark.parametrize("trivy_exit", [0, 1])
def test_the_scan_step_fails_when_trivy_finds_something(tmp_path, trivy_exit):
    # Install first, so the scan runs the binary the install step put there.
    installed, _ = _run_step(
        tmp_path,
        _install_step(),
        web=_trivy_web(_pinned_version()),
        tools=_INSTALL_TOOLS,
    )
    assert installed.returncode == 0, installed.stderr
    workspace = tmp_path / "workspace"
    result, calls = _run_step(
        tmp_path,
        _scan_step(),
        env={"FAKE_TRIVY_EXIT": str(trivy_exit), "GITHUB_WORKSPACE": str(workspace)},
    )
    assert result.returncode == trivy_exit, result.stderr
    scans = [call for call in calls if call.startswith("trivy image ")]
    assert len(scans) == 1, calls
    assert f" --ignorefile {workspace}/.trivyignore.yaml " in scans[0]


# --- the ignore file -------------------------------------------------------------


def test_the_scan_reads_the_ignore_file_of_the_checkout():
    # Trivy 0.76 reads a .trivyignore.yaml only when --ignorefile names it (its
    # docs/guide/configuration/filtering.md), as YAML for a .yml or .yaml
    # name, and quietly ignores nothing when the file is missing. The checkout
    # puts the repository in $GITHUB_WORKSPACE.
    assert IGNORE_FILE.is_file()
    args = _trivy_args(_scan_step()["run"])
    assert _option(args, "--ignorefile") == "$GITHUB_WORKSPACE/.trivyignore.yaml"
    checkouts = [
        step
        for step in _workflow()["jobs"]["scan"]["steps"]
        if step.get("uses", "").startswith("actions/checkout@")
    ]
    assert len(checkouts) == 1
    assert "path" not in checkouts[0].get("with", {})


def _ignore_entries() -> list[dict]:
    data = yaml.safe_load(IGNORE_FILE.read_text(encoding="utf-8"))
    # The scan looks for vulnerabilities only.
    assert isinstance(data, dict), data
    assert set(data) == {"vulnerabilities"}, data
    entries = data["vulnerabilities"]
    assert isinstance(entries, list), entries
    return entries


def test_every_ignore_entry_is_one_finding_in_one_image_file_with_a_reason():
    # Without paths an entry would ignore the finding in every file of the
    # image, the next tool to bring it included.
    for entry in _ignore_entries():
        assert set(entry) == {"id", "paths", "expired_at", "statement"}, entry
        # One finding's ID, such as CVE-2026-111943 or a GHSA-... advisory.
        assert isinstance(entry["id"], str), entry
        assert re.fullmatch(r"[A-Z]+(-[0-9A-Za-z]+)+", entry["id"]), entry
        paths = entry["paths"]
        assert isinstance(paths, list), entry
        assert len(paths) == 1, entry
        path = paths[0]
        # A path in the image as Trivy names it: relative to its root, and no
        # glob (Trivy matches each entry with doublestar).
        assert isinstance(path, str), entry
        assert re.fullmatch(r"[\w.+-]+(/[\w.+-]+)*", path), path
        assert ".." not in path.split("/"), path
        assert isinstance(entry["statement"], str), entry
        assert entry["statement"].strip(), entry


def test_no_ignore_entry_covers_an_npm_package():
    # npm's bundled dependencies get their fixes with a new NPM_VERSION; the
    # scan keeps failing on them until that comes.
    for entry in _ignore_entries():
        for path in entry["paths"]:
            parts = path.split("/")
            assert "node_modules" not in parts, path
            assert parts[-1] != "package.json", path


# The longest an entry may wait: its expired_at is at most this many days
# after the day it was written.
_IGNORE_DAYS = 45


def test_every_ignore_entry_expires_within_45_days():
    # Checked against today: the pull request that writes or renews an entry
    # runs this on that day, or soon after. Once an entry has expired, Trivy
    # applies it no more and the weekly scan fails on the finding again.
    limit = datetime.datetime.now(datetime.UTC).date() + datetime.timedelta(
        days=_IGNORE_DAYS
    )
    for entry in _ignore_entries():
        expired_at = entry["expired_at"]
        # A YAML date, yyyy-mm-dd, as Trivy reads it; not a string or a time.
        assert type(expired_at) is datetime.date, entry
        assert expired_at <= limit, entry


# --- the failure notice --------------------------------------------------------


def _notify_job() -> dict:
    return _workflow()["jobs"]["notify"]


def test_the_notice_runs_when_the_scan_job_did_not_succeed():
    # Any result of the scan job but success notifies, unless the run was
    # cancelled (by hand).
    job = _notify_job()
    assert job["needs"] == "scan"
    assert job["if"] == "${{ !cancelled() && needs.scan.result != 'success' }}"


def test_notices_run_one_at_a_time_across_runs():
    # Two failed runs that overlap would both find no open issue and both open
    # one. Every notify job shares one fixed concurrency group (no expression
    # that would split it by branch or run), and none cancels a running one.
    concurrency = _notify_job()["concurrency"]
    assert concurrency == {"group": "docker-weekly-notify", "cancel-in-progress": False}


_NOTICE_EXPRESSIONS = {
    "${{ github.token }}": "fake-token",
    "${{ github.repository }}": "owner/den",
    "${{ needs.scan.result }}": "failure",
}
_RUN_ENV = {
    "GITHUB_SERVER_URL": "https://github.com",
    "GITHUB_REPOSITORY": "owner/den",
    "GITHUB_RUN_ID": "4242",
    "GITHUB_EVENT_NAME": "schedule",
    "GITHUB_REF_NAME": "main",
    "GITHUB_SHA": "0123abc",
}
_RUN_URL = "https://github.com/owner/den/actions/runs/4242"


def _notice(tmp_path: Path, issues: list[dict]) -> tuple[str, list[str]]:
    (tmp_path / "issues.json").write_text(json.dumps(issues), encoding="utf-8")
    step = _notify_job()["steps"][0]
    result, calls = _run_step(
        tmp_path,
        step,
        expressions=_NOTICE_EXPRESSIONS,
        env={**_RUN_ENV, "FAKE_ISSUES": str(tmp_path / "issues.json")},
        tools=("bash", "jq"),
    )
    assert result.returncode == 0, result.stderr
    return step["env"]["ISSUE_TITLE"], calls


@_needs("bash", "jq")
def test_the_notice_comments_on_the_open_issue(tmp_path):
    title = _notify_job()["steps"][0]["env"]["ISSUE_TITLE"]
    issues = [
        {"number": 9, "title": f"{title} (old)"},
        {"number": 7, "title": title},
    ]
    _, calls = _notice(tmp_path, issues)
    writes = [call for call in calls if not call.startswith("gh issue list")]
    assert len(writes) == 1, calls
    assert writes[0].startswith("gh issue comment 7 --body ")
    assert _RUN_URL in writes[0]
    assert "failure" in writes[0]


@_needs("bash", "jq")
def test_the_notice_opens_an_issue_when_none_is_open(tmp_path):
    title = _notify_job()["steps"][0]["env"]["ISSUE_TITLE"]
    _, calls = _notice(tmp_path, [{"number": 9, "title": f"{title} (old)"}])
    writes = [call for call in calls if not call.startswith("gh issue list")]
    assert len(writes) == 1, calls
    assert writes[0].startswith(f"gh issue create --title {title} --body ")
    assert _RUN_URL in writes[0]
