"""Reads the kit workflow (the reusable one), the command and the kit's two scripts, collect.py and publish.py.

The tests run the scripts as the workflow does, from tools/claude-review/ (no copy to keep in sync).
"""
import importlib.util, json, pathlib, re, shutil, subprocess

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]   # the repo root: tools/claude-review/tests -> .
WORKFLOWS = ROOT / ".github" / "workflows"
WORKFLOW = WORKFLOWS / "claude-review-kit.yml"   # the reusable workflow: the live kit
CALLER = WORKFLOWS / "claude-review.yml"         # this repo's thin caller of it
FROZEN = HERE.parent / "claude-review.yml"       # v3.4, the vendored copy for repos not yet migrated; never edited
COMMAND = HERE.parent / "claude-pr-review.md"
COLLECT = HERE.parent / "collect.py"             # the review job's thread collection (a script: run it as __main__)
PUBLISH = HERE.parent / "publish.py"             # the publish job's script
SCHEMA = HERE.parent / "reviewer" / "result-schema.json"   # Claude's result schema, for `review` and `publish`


def load_publish():
    """The publish script as the namespace of its imported module (its main() isn't run); tests patch names in it."""
    spec = importlib.util.spec_from_file_location("publish_under_test", PUBLISH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return vars(module)


def parse_yaml(path=WORKFLOW):
    """A workflow as data, via PyYAML or Ruby's YAML (both parse YAML 1.1 like GitHub, so `on:` comes out as the key
    True). None if neither exists."""
    try:
        import yaml
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except ImportError:
        pass
    ruby = shutil.which("ruby")
    if not ruby:
        return None
    out = subprocess.run([ruby, "-ryaml", "-rjson", "-e", "puts JSON.dump(YAML.load_file(ARGV[0]))", str(path)],
                         capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


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


def triggers(wf):
    """A parsed workflow's `on:` block. YAML 1.1 reads the key as a boolean: True from PyYAML, "true" through Ruby's JSON."""
    return next(wf[k] for k in (True, "true", "on") if k in wf)
