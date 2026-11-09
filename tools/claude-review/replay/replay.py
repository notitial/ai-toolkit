#!/usr/bin/env python3
"""Replay one pull request through the review command offline, with a local `claude -p`.

Builds the same context folder the workflow's prep steps build (pr.json, pr-files.json, pr.diff) from git alone,
checks the PR head out in a clone under a work folder, installs the review command there and runs it with the
workflow's tool limits and result schema. The result and the run's cost go to a results folder outside the repo.
Nothing is posted anywhere. See README.md next to this file.
"""
import argparse, datetime, gzip, hashlib, json, os, pathlib, re, shutil, subprocess, sys

KIT = pathlib.Path(__file__).resolve().parent.parent
# 7.4's model line: "- Model: `opus` for <kinds> candidate; `sonnet` for <kinds> candidate." The first model is the one patched,
# whichever kinds the command gives it (the line was reworded when the defect verifier moved to sonnet).
VERIFIER_LINE = re.compile(r"^(- Model: )`opus`( for [^`\n]*candidate; `[a-z0-9.-]+` for )", re.M)


def patch_command(text, verifier_model):
    """The command with the verifiers 7.4 puts on `opus` moved to `verifier_model`.
    Fails when the line is not found, so a reworded command cannot silently run the unpatched arm."""
    if not re.fullmatch(r"[a-z0-9.-]+", verifier_model):
        raise SystemExit(f"bad verifier model: {verifier_model!r}")
    if len(VERIFIER_LINE.findall(text)) != 1:
        raise SystemExit("the command's verifier-model line (7.4) was not found exactly once: update VERIFIER_LINE")
    return VERIFIER_LINE.sub(lambda m: f"{m.group(1)}`{verifier_model}`{m.group(2)}", text)


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


# Plain git, whatever the user's config says: GitHub's a/ b/ prefixes, no external diff, no colour.
GIT = ["git", "-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false",
       "-c", "color.ui=false", "-c", "core.quotepath=false"]
DIFF = ["--no-ext-diff", "--no-textconv", "--no-color"]
GIT_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def run_git(args, cwd):
    r = subprocess.run([*GIT, *args], cwd=cwd, env=GIT_ENV, capture_output=True)   # bytes: no newline translation
    r.stdout, r.stderr = (b.decode("utf-8", errors="replace") for b in (r.stdout, r.stderr))
    return r


def git(*args, cwd=None):
    r = run_git(args, cwd)
    if r.returncode:
        raise SystemExit(f"git {' '.join(args[:2])} failed: {r.stderr.strip()[:300]}")
    return r.stdout


def git_ok(*args, cwd):
    return run_git(args, cwd).returncode == 0


def entries_from(diff, name_status):
    """pr-files.json: what the pulls/files API returns for each changed file (renames detected, binary files without a patch).
    `diff` is one `git diff -M` and `name_status` the same diff's `--name-status -z`: git lists the files in the same
    order in both, so the Nth `diff --git` block belongs to the Nth entry. No path ever goes to git as a pathspec."""
    parts = name_status.split("\0")
    names, i = [], 0
    while i < len(parts) and parts[i]:
        if parts[i][0] in "RC":
            names.append((parts[i][0], parts[i + 1], parts[i + 2]))
            i += 3
        else:
            names.append((parts[i][0], None, parts[i + 1]))
            i += 2
    blocks = [b for b in re.split(r"^(?=diff --git )", diff, flags=re.M) if b]
    if len(blocks) != len(names):
        raise SystemExit(f"the diff has {len(blocks)} files but name-status lists {len(names)}")
    entries = []
    for (code, old, new), block in zip(names, blocks):
        hunks = re.search(r"^@@ ", block, re.M)
        patch = block[hunks.start():] if hunks else None
        lines = patch.split("\n") if patch else []
        entries.append({
            "filename": new,
            "status": {"A": "added", "D": "removed", "R": "renamed", "C": "copied"}.get(code, "modified"),
            "additions": sum(1 for line in lines if line.startswith("+")),
            "deletions": sum(1 for line in lines if line.startswith("-")),
            "previous_filename": old,
            "patch": patch,
        })
    return entries


def file_entries(clone, merge_base, head):
    return entries_from(git("diff", *DIFF, "-M", merge_base, head, cwd=clone),
                        git("diff", *DIFF, "-M", "--name-status", "-z", merge_base, head, cwd=clone))


def build_context(clone, ctx, args, merge_base):
    ctx.mkdir(parents=True, exist_ok=True)
    diff = git("diff", *DIFF, "-M", merge_base, args.head, cwd=clone)
    files = entries_from(diff, git("diff", *DIFF, "-M", "--name-status", "-z", merge_base, args.head, cwd=clone))
    pr = {
        "number": args.pr, "title": args.title or f"Pull request {args.pr}", "body": args.body or "",
        "state": "OPEN", "isDraft": False, "author": {"login": "replay"},
        "baseRefName": args.base_ref, "headRefName": f"pull/{args.pr}/head", "headRefOid": args.head,
        "files": [{"path": f["filename"], "additions": f["additions"], "deletions": f["deletions"]} for f in files[:100]],
        "url": f"https://github.com/{args.repo}/pull/{args.pr}",
    }
    (ctx / "pr.json").write_text(json.dumps(pr), encoding="utf-8")
    (ctx / "pr-files.json").write_text(json.dumps(files), encoding="utf-8")
    (ctx / "pr.diff").write_text(diff, encoding="utf-8", newline="")
    return files


def prepare_clone(args, work):
    clone = work / "clone"
    if clone.exists() and not (clone / ".git").exists():
        raise SystemExit(f"{clone} exists but is not a clone: remove it or use another --work-dir")
    if not clone.exists():
        work.mkdir(parents=True, exist_ok=True)
        git("clone", "--quiet", "--no-checkout", f"https://github.com/{args.repo}.git", str(clone))
    refs = [f"refs/pull/{args.pr}/head"]
    if args.base == "auto":   # the default branch's tip: the PR's merge base is where its head left it
        refs.append("+HEAD:refs/replay/default")
    else:
        refs.append(args.base)
    git("fetch", "--quiet", "origin", *refs, cwd=clone)
    base = git("rev-parse", "refs/replay/default" if args.base == "auto" else args.base, cwd=clone).strip()
    if not git_ok("cat-file", "-e", f"{args.head}^{{commit}}", cwd=clone) or not git_ok("cat-file", "-e", f"{base}^{{commit}}", cwd=clone):
        raise SystemExit("head or base is not in the fetched history (a force-pushed PR?)")
    merge_base = git("merge-base", base, args.head, cwd=clone).strip()
    if merge_base == args.head:
        raise SystemExit("the head is already in the base's history, so there is no diff: pass --base <the PR's base SHA>")
    git("checkout", "--quiet", "--force", "--detach", args.head, cwd=clone)
    git("clean", "-fdxq", cwd=clone)
    # The workflow runs the default branch's .claude/ and root CLAUDE.md, whatever the PR changes: take them from the base.
    for path in (".claude", "CLAUDE.md"):
        target = clone / path
        if target.is_dir() and not target.is_symlink():
            shutil.rmtree(target)
        else:
            target.unlink(missing_ok=True)
        if git_ok("cat-file", "-e", f"{merge_base}:{path}", cwd=clone):
            git("checkout", "--quiet", merge_base, "--", path, cwd=clone)
    return clone, merge_base


def summarize(stream_lines):
    """The run's result message plus the subagents launched (Agent/Task calls, counted by the model they asked for)."""
    result, agents = None, {}
    for line in stream_lines:
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if not isinstance(m, dict):
            continue
        if m.get("type") == "result":
            result = m
        message = m.get("message")   # some stream messages (system notices) carry a plain string here
        content = message.get("content") if isinstance(message, dict) else None
        for block in content if isinstance(content, list) else []:
            if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") in ("Agent", "Task"):
                model = (block.get("input") or {}).get("model") or "default"
                agents[model] = agents.get(model, 0) + 1
    if result is None:
        return None
    out = result.get("structured_output")
    if isinstance(out, str):   # the workflow's own save step accepts a JSON string too
        try:
            out = json.loads(out)
        except ValueError:
            out = None
    return {
        "structured_output": out if isinstance(out, dict) else None,
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
    p.add_argument("--base", default="auto", help="the PR's base commit, or auto: the merge base with the default branch")
    p.add_argument("--head", required=True, help="the PR head commit (refs/pull/N/head must contain it)")
    p.add_argument("--command", default=str(KIT / "claude-pr-review.md"), help="the review command file")
    p.add_argument("--workflow", default=str(KIT / "claude-review.yml"), help="the workflow to take tool limits from")
    p.add_argument("--verifier-model", help="run the 7.4 defect, interaction, security and failure-path verifiers on this model")
    p.add_argument("--model", default="sonnet", help="the lead's model; CI's main session runs on sonnet (default)")
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
        if not re.fullmatch(r"[0-9a-f]{40}", getattr(args, k)) and not (k == "base" and args.base == "auto"):
            raise SystemExit(f"--{k} must be a full 40-character SHA" + (" (or auto)" if k == "base" else ""))
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo):
        raise SystemExit("--repo must look like owner/name")
    if not re.fullmatch(r"[\w.-]+", args.arm):
        raise SystemExit("--arm may hold only letters, digits, _ . -")
    if os.environ.get("ANTHROPIC_API_KEY"):
        print("warning: ANTHROPIC_API_KEY is set, so claude bills the API instead of the subscription", file=sys.stderr)

    command_text = pathlib.Path(args.command).read_text()
    if args.verifier_model:
        command_text = patch_command(command_text, args.verifier_model)
    settings = workflow_settings(pathlib.Path(args.workflow).read_text())

    slug = args.repo.replace("/", "_")
    work = pathlib.Path(args.work_dir).expanduser().resolve() / slug
    clone, merge_base = prepare_clone(args, work)
    cmd_path = clone / ".claude" / "commands" / "claude-pr-review.md"
    cmd_path.parent.mkdir(parents=True, exist_ok=True)
    cmd_path.write_text(command_text)
    ctx = work / f"context-{args.pr}-{args.head[:8]}"
    shutil.rmtree(ctx, ignore_errors=True)
    files = build_context(clone, ctx, args, merge_base)
    if not files:
        raise SystemExit("the PR changes no files between the merge base and the head: nothing to review")
    prompt = f"/claude-pr-review {args.repo}/pull/{args.pr} --mode initial --context {ctx}"
    cmd = claude_command(settings, ctx, prompt, args.model)
    print(f"prepared {args.repo}#{args.pr}: {len(files)} files, clone {clone}, context {ctx}", file=sys.stderr)
    if args.prepare_only:
        print(json.dumps(cmd))
        return 0

    out_dir = pathlib.Path(args.results_dir).expanduser().resolve() / slug
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
        "repo": args.repo, "pr": args.pr, "base": args.base, "merge_base": merge_base, "head": args.head, "arm": args.arm, "run": args.run,
        "verifier_model": args.verifier_model, "lead_model": args.model,
        "command_sha256": hashlib.sha256(command_text.encode()).hexdigest(),
        "started": started, "exit_code": rc, "stderr_tail": stderr,
        "summary": summarize(stream.splitlines()),
    }
    (out_dir / f"{stem}.json").write_text(json.dumps(record, indent=1))
    s = record["summary"] or {}
    result = s.get("structured_output")
    if result is None:
        print(f"{stem}: NO RESULT (exit {rc}): do not score this run", file=sys.stderr)
        return 1
    print(f"{stem}: exit {rc}, ${s.get('total_cost_usd')}, {s.get('agent_calls')} agents, "
          f"{len(result.get('findings') or [])} findings", file=sys.stderr)
    return 0 if not s.get("is_error") else 1


if __name__ == "__main__":
    sys.exit(main())
