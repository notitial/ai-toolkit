"""Reads the canonical workflow and command, and pulls the inline Python scripts out of the workflow.

The tests run the scripts exactly as they are in claude-review.yml (no copy to keep in sync).
"""
import json, pathlib, re, shutil, subprocess

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]   # the repo root: tools/claude-review/tests -> .
WORKFLOW = HERE.parent / "claude-review.yml"
COMMAND = HERE.parent / "claude-pr-review.md"
# This repo's own install: the files the kit says to copy, at their install paths.
INSTALLED = {WORKFLOW: ROOT / ".github" / "workflows" / "claude-review.yml",
             COMMAND: ROOT / ".claude" / "commands" / "claude-pr-review.md"}


def heredocs():
    """[(step name, Python source)] for every `python3 -I - <<'PY'` block in the workflow, in file order."""
    lines = WORKFLOW.read_text(encoding="utf-8").split("\n")
    out, step, i = [], None, 0
    while i < len(lines):
        m = re.match(r"\s*- name: (.+)$", lines[i])
        if m:
            step = m.group(1)
        if lines[i].rstrip().endswith("python3 -I - <<'PY'"):
            indent = len(lines[i]) - len(lines[i].lstrip())
            j, body = i + 1, []
            while lines[j].strip() != "PY":
                body.append(lines[j][indent:] if lines[j].strip() else "")
                j += 1
            out.append((step, "\n".join(body) + "\n"))
            i = j
        i += 1
    return out


def script(step):
    found = [src for name, src in heredocs() if name == step]
    assert len(found) == 1, f"expected one script in step {step!r}, found {len(found)}"
    return found[0]


def load_publish():
    """The publish script as a namespace of its functions (its main() isn't run)."""
    ns = {"__name__": "publish_under_test"}
    exec(compile(script("Publish the review"), "publish.py", "exec"), ns)
    return ns


def parse_yaml():
    """The workflow as data, via PyYAML or Ruby's YAML (both parse YAML 1.1 like GitHub). None if neither exists."""
    try:
        import yaml
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    except ImportError:
        pass
    ruby = shutil.which("ruby")
    if not ruby:
        return None
    out = subprocess.run([ruby, "-ryaml", "-rjson", "-e", "puts JSON.dump(YAML.load_file(ARGV[0]))", str(WORKFLOW)],
                         capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def command_schema():
    """The one-line schema in the command's "The result" section."""
    text = COMMAND.read_text(encoding="utf-8")
    return re.search(r'^(\{"type":"object".*\})$', text, re.M).group(1)


def save_threads(collected):
    """`collected` (the collect step's threads file) as the "Save the result" step's jq hands it to `publish`."""
    import unittest
    jq = shutil.which("jq")
    if not jq:
        raise unittest.SkipTest("jq isn't installed")
    m = re.search(r"""jq -c '(\{head_sha[^']*)' "\$THREADS_FILE" > "\$dir/threads\.json\"""", WORKFLOW.read_text(encoding="utf-8"))
    assert m, "the Save the result step's threads projection moved"
    out = subprocess.run([jq, "-c", m.group(1)], input=json.dumps(collected), capture_output=True, text=True, check=True)
    return json.loads(out.stdout)
