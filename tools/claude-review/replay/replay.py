#!/usr/bin/env python3
"""Replay one pull request through the review command offline, with a local `claude -p`.

Builds the same context folder the workflow's prep steps build (pr.json, pr-files.json, pr.diff) from git alone,
checks the PR head out in a clone under a work folder, installs the review command there and runs it with the
workflow's tool limits and result schema. The result and the run's cost go to a results folder outside the repo.
Nothing is posted anywhere. See README.md next to this file.
"""
import argparse, datetime, gzip, hashlib, json, os, pathlib, re, shutil, subprocess, sys

KIT = pathlib.Path(__file__).resolve().parent.parent
VERIFIER_LINE = "- Model: `opus` for a defect, interaction, security or failure-path candidate;"


def patch_command(text, verifier_model):
    """The command with its defect, interaction, security and failure-path verifiers on `verifier_model`.
    Fails when the line is not found, so a reworded command cannot silently run the unpatched arm."""
    if not re.fullmatch(r"[a-z0-9.-]+", verifier_model):
        raise SystemExit(f"bad verifier model: {verifier_model!r}")
    if text.count(VERIFIER_LINE) != 1:
        raise SystemExit("the command's verifier-model line (7.4) was not found exactly once: update VERIFIER_LINE")
    return text.replace(VERIFIER_LINE, VERIFIER_LINE.replace("`opus`", f"`{verifier_model}`"))


def workflow_settings(workflow_text):
    """The tool limits and the result schema, read from the workflow so the replay cannot drift from it."""
    def one(pattern, what):
        found = re.findall(pattern, workflow_text, re.M)
        if len(found) != 1:
            raise SystemExit(f"workflow: {what} not found exactly once")
        return found[0]
    tools = one(r"^\s*TOOLS: '([^']*)'\s*$", "TOOLS")
    deny = one(r'^\s*--disallowedTools "([^"]*)"\s*$', "--disallowedTools")
    schema = one(r"^\s*RESULT_SCHEMA: '(\{.*\})'\s*$", "RESULT_SCHEMA")
    json.loads(schema)
    return {"allowed": tools, "disallowed": deny, "schema": schema}


def git(*args, cwd=None, check=True, text=True):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=text)
    if check and r.returncode:
        err = r.stderr if text else r.stderr.decode(errors="replace")
        raise SystemExit(f"git {' '.join(args[:2])} failed: {err.strip()[:300]}")
    return r.stdout


def git_ok(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True).returncode == 0


def file_entries(clone, merge_base, head):
    """pr-files.json: what the pulls/files API returns for each changed file (renames detected, binary files without a patch)."""
    out = git("diff", "-M", "--name-status", "-z", merge_base, head, cwd=clone)
    parts = out.split("\0")
    entries, i = [], 0
    while i < len(parts) and parts[i]:
        code = parts[i][0]
        if code in "RC":
            old, new, i = parts[i + 1], parts[i + 2], i + 3
        else:
            old, new, i = None, parts[i + 1], i + 2
        numstat = git("diff", "-M", "--numstat", merge_base, head, "--", *( [old, new] if old else [new] ), cwd=clone).split("\t")
        binary = numstat[0] == "-"
        diff = git("diff", "-M", merge_base, head, "--", *([old, new] if old else [new]), cwd=clone)
        patch = None if binary or "@@" not in diff else diff[diff.index("\n@@") + 1:]
        entries.append({
            "filename": new,
            "status": {"A": "added", "D": "removed", "R": "renamed", "C": "copied"}.get(code, "modified"),
            "additions": 0 if binary else int(numstat[0]),
            "deletions": 0 if binary else int(numstat[1]),
            "previous_filename": old,
            "patch": patch,
        })
    return entries


def build_context(clone, ctx, args, merge_base):
    ctx.mkdir(parents=True, exist_ok=True)
    files = file_entries(clone, merge_base, args.head)
    pr = {
        "number": args.pr, "title": args.title or f"Pull request {args.pr}", "body": args.body or "",
        "state": "OPEN", "isDraft": False, "author": {"login": "replay"},
        "baseRefName": args.base_ref, "headRefName": f"pull/{args.pr}/head", "headRefOid": args.head,
        "files": [{"path": f["filename"], "additions": f["additions"], "deletions": f["deletions"]} for f in files[:100]],
        "url": f"https://github.com/{args.repo}/pull/{args.pr}",
    }
    (ctx / "pr.json").write_text(json.dumps(pr))
    (ctx / "pr-files.json").write_text(json.dumps(files))
    (ctx / "pr.diff").write_text(git("diff", "-M", merge_base, args.head, cwd=clone))
    return files


def prepare_clone(args, work):
    clone = work / "clone"
    if not clone.exists():
        work.mkdir(parents=True, exist_ok=True)
        git("clone", "--quiet", "--no-checkout", f"https://github.com/{args.repo}.git", str(clone))
    git("fetch", "--quiet", "origin", f"refs/pull/{args.pr}/head", args.base, cwd=clone)
    git("cat-file", "-e", f"{args.head}^{{commit}}", cwd=clone)
    git("checkout", "--quiet", "--force", "--detach", args.head, cwd=clone)
    git("clean", "-fdxq", cwd=clone)
    # The workflow runs the default branch's .claude/ and root CLAUDE.md, whatever the PR changes: take them from the base.
    for path in (".claude", "CLAUDE.md"):
        target = clone / path
        if target.is_dir():
            shutil.rmtree(target)
        else:
            target.unlink(missing_ok=True)
        if git_ok("cat-file", "-e", f"{args.base}:{path}", cwd=clone):
            git("checkout", "--quiet", args.base, "--", path, cwd=clone)
    return clone, git("merge-base", args.base, args.head, cwd=clone).strip()


def summarize(stream_lines):
    """The run's result message plus the subagents launched (Agent/Task calls, counted by the model they asked for)."""
    result, agents = None, {}
    for line in stream_lines:
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if m.get("type") == "result":
            result = m
        for block in (m.get("message") or {}).get("content") or []:
            if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") in ("Agent", "Task"):
                model = (block.get("input") or {}).get("model") or "default"
                agents[model] = agents.get(model, 0) + 1
    if result is None:
        return None
    return {
        "structured_output": result.get("structured_output"),
        "is_error": result.get("is_error"),
        "subtype": result.get("subtype"),
        "total_cost_usd": result.get("total_cost_usd"),
        "duration_ms": result.get("duration_ms"),
        "num_turns": result.get("num_turns"),
        "model_cost_usd": {k: (v or {}).get("costUSD") for k, v in (result.get("modelUsage") or {}).items()},
        "agent_calls": sum(agents.values()),
        "agent_models": agents,
        "permission_denials": len(result.get("permission_denials") or []),
    }


def claude_command(settings, ctx, prompt, model):
    cmd = ["claude", "-p", prompt, "--output-format", "stream-json", "--verbose", "--no-session-persistence",
           "--strict-mcp-config", "--setting-sources", "project", "--settings", '{"disableAllHooks":true}',
           "--allowedTools", settings["allowed"], "--disallowedTools", settings["disallowed"],
           "--add-dir", str(ctx), "--json-schema", settings["schema"]]
    return cmd + (["--model", model] if model else [])


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--repo", required=True, help="owner/name on GitHub")
    p.add_argument("--pr", required=True, type=int)
    p.add_argument("--base", required=True, help="the PR's base commit")
    p.add_argument("--head", required=True, help="the PR head commit (refs/pull/N/head must contain it)")
    p.add_argument("--command", default=str(KIT / "claude-pr-review.md"), help="the review command file")
    p.add_argument("--workflow", default=str(KIT / "claude-review.yml"), help="the workflow to take tool limits from")
    p.add_argument("--verifier-model", help="run the 7.4 defect, interaction, security and failure-path verifiers on this model")
    p.add_argument("--model", help="the lead's model (default: the CLI default, as in the workflow)")
    p.add_argument("--arm", default="asis", help="label for the results file")
    p.add_argument("--run", type=int, default=1, help="repeat number, for the results file")
    p.add_argument("--title", help="the PR title (default: a placeholder)")
    p.add_argument("--body-file", help="a file holding the PR description")
    p.add_argument("--base-ref", default="main")
    p.add_argument("--work-dir", default="/tmp/review-replay")
    p.add_argument("--results-dir", default=str(pathlib.Path.home() / "review-replay-results"))
    p.add_argument("--timeout-min", type=int, default=25, help="the workflow's job limit")
    p.add_argument("--prepare-only", action="store_true", help="build the clone and context, print the command, do not call claude")
    args = p.parse_args(argv)
    args.body = pathlib.Path(args.body_file).read_text() if args.body_file else ""
    for k in ("base", "head"):
        if not re.fullmatch(r"[0-9a-f]{40}", getattr(args, k)):
            raise SystemExit(f"--{k} must be a full 40-character SHA")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo):
        raise SystemExit("--repo must look like owner/name")

    command_text = pathlib.Path(args.command).read_text()
    if args.verifier_model:
        command_text = patch_command(command_text, args.verifier_model)
    settings = workflow_settings(pathlib.Path(args.workflow).read_text())

    slug = args.repo.replace("/", "_")
    work = pathlib.Path(args.work_dir) / slug
    clone, merge_base = prepare_clone(args, work)
    cmd_path = clone / ".claude" / "commands" / "claude-pr-review.md"
    cmd_path.parent.mkdir(parents=True, exist_ok=True)
    cmd_path.write_text(command_text)
    ctx = work / f"context-{args.pr}-{args.head[:8]}"
    shutil.rmtree(ctx, ignore_errors=True)
    files = build_context(clone, ctx, args, merge_base)
    prompt = f"/claude-pr-review {args.repo}/pull/{args.pr} --mode initial --context {ctx}"
    cmd = claude_command(settings, ctx, prompt, args.model)
    print(f"prepared {args.repo}#{args.pr}: {len(files)} files, clone {clone}, context {ctx}", file=sys.stderr)
    if args.prepare_only:
        print(json.dumps(cmd))
        return 0

    out_dir = pathlib.Path(args.results_dir) / slug
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = f"pr{args.pr}-{args.head[:8]}-{args.arm}-{args.run}"
    started = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    env = dict(os.environ, CLAUDE_CODE_DISABLE_BACKGROUND_TASKS="1")
    try:
        r = subprocess.run(cmd, cwd=clone, env=env, capture_output=True, text=True, timeout=args.timeout_min * 60)
        stream, rc, stderr = r.stdout, r.returncode, r.stderr[-2000:]
    except subprocess.TimeoutExpired as e:
        stream, rc, stderr = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or ""), -1, "timeout"
    with gzip.open(out_dir / f"{stem}.stream.jsonl.gz", "wt") as f:
        f.write(stream)
    record = {
        "repo": args.repo, "pr": args.pr, "base": args.base, "head": args.head, "arm": args.arm, "run": args.run,
        "verifier_model": args.verifier_model, "lead_model": args.model,
        "command_sha256": hashlib.sha256(command_text.encode()).hexdigest(),
        "started": started, "exit_code": rc, "stderr_tail": stderr,
        "summary": summarize(stream.splitlines()),
    }
    (out_dir / f"{stem}.json").write_text(json.dumps(record, indent=1))
    s = record["summary"] or {}
    print(f"{stem}: exit {rc}, ${s.get('total_cost_usd')}, {s.get('agent_calls')} agents, "
          f"{len((s.get('structured_output') or {}).get('findings') or [])} findings", file=sys.stderr)
    return 0 if record["summary"] and not record["summary"]["is_error"] else 1


if __name__ == "__main__":
    sys.exit(main())
