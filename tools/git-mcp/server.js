#!/usr/bin/env node
'use strict';
// A small MCP server for git: JSON-RPC 2.0 over stdio, one JSON message per line. No dependencies, no build.
// Register it under the name `git-mcp` (see README.md here), so its tools are `mcp__git-mcp__git_*`: the guard
// hooks and the permission rules are keyed on those names and on the parameter names below. Changing a tool
// name, a parameter name, a default or what a parameter means changes what those hooks decide: read
// hooks/git-mcp-guard.sh, hooks/protected-paths-guard.sh and hooks/workspace-lock-guard.sh first.
//
// What this file guarantees (the hooks decide what is allowed; this decides what a call can mean):
//   - git runs through execFile with an argument array. No shell, no string joined into a command line.
//   - Every call carries an absolute `path`. There is no working-directory state and no default folder.
//   - A closed parameter set per tool and strict types: an unknown key, a string where a boolean belongs
//     ("true"), a number where a string belongs, or null is refused. The hooks read the same fields with jq,
//     which prints "true" and true alike, so a loose type here would let the two disagree.
//   - No model-supplied value can become an option: a value in a ref, remote, URL or file position may not
//     start with `-`; free text (a message, a date, a search pattern) is only ever passed as `--option=value`;
//     file paths come after `--`. No value reaches `-c`, and nothing sets git configuration beyond what the
//     git command itself records (a remote's name and URL, a branch's upstream).
//   - A remote is a name the repo has configured, never a URL or a path. A branch or tag name has no `:`, no
//     leading `+`, no whitespace and none of `~^?*[\`, so a refspec is only ever built here, and a named branch
//     is pushed with an explicit destination. git_push picks no remote for the caller.
//   - A dry run (git_push, git_clean) changes nothing whatever else the call carries.
//   - A URL (git_clone, git_remote) is http(s), ssh, git or file, `user@host:path`, or an absolute path. The
//     `transport::address` form, which runs a helper program, is refused.
//   - Children get the server's environment without any `GIT_*` variable (no inherited GIT_DIR, GIT_WORK_TREE,
//     GIT_CONFIG_*, GIT_SSH_COMMAND, GIT_EXTERNAL_DIFF), plus the four set in ENV below.
// Not defended here, as with any git front end: a program named in the repo's own .git/config or .git/hooks
// runs when git runs it.
//
// Output is git's own text (stdout, then stderr) in one text block; a failed command sets isError.
// Tests: bash tools/git-mcp/test-server.sh

const { execFile } = require('node:child_process');
const fs = require('node:fs');
const readline = require('node:readline');

const VERSION = '1.0.0';
const PROTOCOLS = ['2025-06-18', '2025-03-26', '2024-11-05']; // MCP revisions answered as asked; any other gets the first
const TIMEOUT_MS = 10 * 60 * 1000;
const MAX_BUFFER = 64 * 1024 * 1024;
const MAX_TEXT = 1024 * 1024; // characters returned to the client; the rest is cut with a note
const MAX_UNTRACKED_DIFFS = 50;
// Generated files left out of git_diff unless autoExclude is false.
const LOCKFILES = ['package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'bun.lock', 'bun.lockb', 'poetry.lock',
  'uv.lock', 'Cargo.lock', 'go.sum', 'Gemfile.lock', 'composer.lock', 'Podfile.lock'];
const STRATEGIES = ['ort', 'recursive', 'octopus', 'ours', 'subtree'];

const ENV = {};
for (const [k, v] of Object.entries(process.env)) if (!k.startsWith('GIT_')) ENV[k] = v;
// No prompt on a missing credential, no editor or pager waiting on a terminal that is not there, and no index
// refresh written by a read (git status) while another session works in the same repo.
Object.assign(ENV, { GIT_TERMINAL_PROMPT: '0', GIT_EDITOR: 'true', GIT_PAGER: 'cat', GIT_OPTIONAL_LOCKS: '0' });

class Refused extends Error {}
const refuse = (msg) => { throw new Refused(msg); };

// ---- parameter kinds ---------------------------------------------------------------------------------------------
// Every string kind refuses a NUL byte. Every kind but `text` refuses a leading `-`.
const KINDS = {
  dir: { pattern: '^/', hint: 'must be an absolute path' },
  remote: { pattern: '^[A-Za-z0-9_][A-Za-z0-9._-]*$', max: 255, hint: 'must be a remote name (letters, digits, . _ -, not starting with a dot)' },
  name: { pattern: '^[^+~^:?*\\[\\\\\\s\\x00-\\x1f\\x7f][^~^:?*\\[\\\\\\s\\x00-\\x1f\\x7f]*$', max: 255,
    hint: 'must be a branch or tag name (no leading +, no whitespace, none of ~ ^ : ? * [ \\)' },
  ref: { pattern: '^[^\\x00-\\x1f\\x7f]+$', hint: 'must be a commit, branch or tag reference without control characters' },
  stash: { pattern: '^(stash@\\{[0-9]+\\}|[0-9]+)$', hint: 'must look like stash@{0}' },
  url: { pattern: '^((https?|ssh|git|file)://[^-\\s\\x00-\\x1f\\x7f][^\\s\\x00-\\x1f\\x7f]*|[A-Za-z0-9._-]+@[A-Za-z0-9][A-Za-z0-9.-]*:[^\\s\\x00-\\x1f\\x7f]+|/[^\\x00-\\x1f\\x7f]*)$',
    hint: 'must be an http(s), ssh, git or file URL, user@host:path, or an absolute path' },
  file: { hint: 'must be a file path' },
  text: {},
};
for (const k of Object.values(KINDS)) if (k.pattern) k.re = new RegExp(k.pattern);

const str = (kind, extra) => ({ type: 'string', kind, ...extra });
const bool = (dflt = false, extra) => ({ type: 'boolean', default: dflt, ...extra });
const int = (min, max, dflt) => ({ type: 'integer', min, max, default: dflt });
const oneOf = (values, dflt) => ({ type: 'string', enum: values, default: dflt });
const list = (kind, extra) => ({ type: 'array', kind, ...extra });

function checkString(key, v, kind) {
  if (typeof v !== 'string') refuse(`${key} must be a string`);
  if (v.includes('\0')) refuse(`${key} must not contain a NUL byte`);
  if (kind !== 'text' && v.startsWith('-')) refuse(`${key} must not start with "-"${kind === 'file' ? ' (write ./-name for such a file)' : ''}`);
  const k = KINDS[kind];
  if (k.max && v.length > k.max) refuse(`${key} is longer than ${k.max} characters`);
  if (k.re && !k.re.test(v)) refuse(`${key} ${k.hint}`);
}

// Returns a copy of `input` holding only checked values. An empty string counts as not given (the hooks read it
// the same way); anything else that does not fit its declared type is refused, never coerced.
function validate(tool, input) {
  if (input === undefined) input = {};
  if (input === null || typeof input !== 'object' || Array.isArray(input)) refuse('arguments must be an object');
  const out = {};
  for (const [key, v] of Object.entries(input)) {
    const spec = Object.prototype.hasOwnProperty.call(tool.params, key) ? tool.params[key] : null;
    if (!spec) refuse(`unknown parameter: ${key}`);
    if (v === '') continue;
    if (spec.type === 'boolean') {
      if (typeof v !== 'boolean') refuse(`${key} must be true or false`);
    } else if (spec.type === 'integer') {
      if (!Number.isInteger(v) || v < spec.min || v > spec.max) refuse(`${key} must be an integer from ${spec.min} to ${spec.max}`);
    } else if (spec.type === 'array') {
      if (!Array.isArray(v)) refuse(`${key} must be an array`);
      v.forEach((item, i) => {
        if (item === '') refuse(`${key}[${i}] must not be empty`);
        if (spec.enum) { if (!spec.enum.includes(item)) refuse(`${key}[${i}] must be one of: ${spec.enum.join(', ')}`); } else checkString(`${key}[${i}]`, item, spec.kind);
      });
    } else if (spec.type === 'object') {
      if (v === null || typeof v !== 'object' || Array.isArray(v)) refuse(`${key} must be an object`);
      for (const sub of Object.keys(v)) if (!Object.prototype.hasOwnProperty.call(spec.fields, sub)) refuse(`unknown parameter: ${key}.${sub}`);
      for (const [sub, kind] of Object.entries(spec.fields)) {
        if (v[sub] === undefined || v[sub] === '') refuse(`${key}.${sub} is required`);
        checkString(`${key}.${sub}`, v[sub], kind);
      }
    } else if (spec.type === 'flagOrRef') {
      if (typeof v !== 'boolean') checkString(key, v, 'ref');
    } else if (spec.enum) {
      if (!spec.enum.includes(v)) refuse(`${key} must be one of: ${spec.enum.join(', ')}`);
    } else {
      checkString(key, v, spec.kind);
      if (spec.maxLength && v.length > spec.maxLength) refuse(`${key} is longer than ${spec.maxLength} characters`);
    }
    out[key] = v;
  }
  for (const [key, spec] of Object.entries(tool.params)) {
    if (out[key] === undefined && spec.default !== undefined) out[key] = spec.default;
  }
  for (const key of ['path', ...(tool.required || [])]) {
    if (out[key] === undefined || (Array.isArray(out[key]) && out[key].length === 0)) refuse(`${key} is required${key === 'path' ? ': pass the absolute path of the repository on every call' : ''}`);
  }
  return out;
}

function jsonSchema(tool) {
  const one = (spec) => {
    if (spec.type === 'array') return { type: 'array', items: spec.enum ? { type: 'string', enum: spec.enum } : one({ type: 'string', kind: spec.kind }) };
    if (spec.type === 'object') return { type: 'object', additionalProperties: false, required: Object.keys(spec.fields), properties: Object.fromEntries(Object.entries(spec.fields).map(([k, kind]) => [k, one({ type: 'string', kind })])) };
    if (spec.type === 'flagOrRef') return { anyOf: [{ type: 'boolean' }, one({ type: 'string', kind: 'ref' })] };
    const s = { type: spec.type };
    if (spec.enum) s.enum = spec.enum;
    if (spec.kind && KINDS[spec.kind].pattern) s.pattern = KINDS[spec.kind].pattern;
    if (spec.maxLength || (spec.kind && KINDS[spec.kind].max)) s.maxLength = spec.maxLength || KINDS[spec.kind].max;
    if (spec.type === 'string' && !spec.enum) s.minLength = 1;
    if (spec.min !== undefined) s.minimum = spec.min;
    if (spec.max !== undefined) s.maximum = spec.max;
    if (spec.default !== undefined) s.default = spec.default;
    return s;
  };
  const properties = {};
  for (const [key, spec] of Object.entries(tool.params)) {
    properties[key] = one(spec);
    if (spec.desc) properties[key].description = spec.desc;
  }
  return { type: 'object', additionalProperties: false, required: ['path', ...(tool.required || [])], properties };
}

// ---- running git -------------------------------------------------------------------------------------------------

function runGit(cwd, args, okCodes) {
  return new Promise((resolve, reject) => {
    const child = execFile('git', ['--no-pager', ...args], { cwd, env: ENV, timeout: TIMEOUT_MS, maxBuffer: MAX_BUFFER },
      (err, stdout, stderr) => {
        let text = stdout;
        if (stderr) text += (text && !text.endsWith('\n') ? '\n' : '') + stderr;
        if (!err || okCodes.includes(err.code)) return resolve(text);
        const why = typeof err.code === 'number' ? `exit ${err.code}` : err.killed ? 'stopped: timeout or too much output' : String(err.code || err.message);
        reject(Object.assign(new Refused(`git ${args[0]} failed (${why})\n${text}`), { exitCode: err.code }));
      });
    if (child.stdin) child.stdin.end();
  });
}

const firstLines = (text, n) => {
  if (!n) return text;
  const lines = text.split('\n');
  return lines.length > n + 1 ? `${lines.slice(0, n).join('\n')}\n[first ${n} shown]\n` : text;
};
const pathsTail = (paths) => (paths && paths.length ? ['--', ...paths] : []);
const need = (a, key, when) => { if (a[key] === undefined) refuse(`${key} is required for ${when}`); return a[key]; };
// git reads a remote name it does not know as a URL or a path relative to the repo, so a name is only passed on
// once the repo has it configured.
const configured = async (git, remote) => {
  await git(['remote', 'get-url', remote]).catch((e) => { throw e.exitCode === 2 ? new Refused(`remote '${remote}' is not configured in this repository`) : e; });
  return remote;
};

// ---- tools -------------------------------------------------------------------------------------------------------
// params: every tool also takes `path` (added below). run(a, git) returns the text to send back; `a` is validated.

const TOOLS = {
  git_status: {
    desc: 'Working tree status: `git status --porcelain=v1 --branch` (a `## branch...upstream [ahead N]` line, then one `XY file` line per change).',
    params: { includeUntracked: bool(true) },
    run: (a, git) => git(['status', '--porcelain=v1', '--branch', ...(a.includeUntracked ? [] : ['--untracked-files=no'])]),
  },
  git_log: {
    desc: 'Commit history.',
    params: {
      maxCount: int(1, 1000, 10), skip: int(0, Number.MAX_SAFE_INTEGER), since: str('text'), until: str('text'),
      author: str('text'), grep: str('text'), branch: str('ref', { desc: 'Branch, ref or range to list (default: HEAD).' }),
      filePath: str('file'), oneline: bool(), stat: bool(), patch: bool(), showSignature: bool(),
    },
    run: (a, git) => {
      const args = ['log', '--no-ext-diff', `--max-count=${a.maxCount}`];
      if (a.skip) args.push(`--skip=${a.skip}`);
      for (const k of ['since', 'until', 'author', 'grep']) if (a[k]) args.push(`--${k}=${a[k]}`);
      if (a.oneline) args.push('--oneline');
      if (a.stat) args.push('--stat');
      if (a.patch) args.push('--patch');
      if (a.showSignature) args.push('--show-signature');
      if (a.branch) args.push(a.branch);
      return git([...args, '--', ...(a.filePath ? [a.filePath] : [])]);
    },
  },
  git_show: {
    desc: 'Show a commit, tag or other object, or one file at a revision (object plus filePath).',
    params: { object: str('ref'), format: oneOf(['raw']), stat: bool(), filePath: str('file') },
    required: ['object'],
    run: (a, git) => {
      const args = ['show', '--no-ext-diff'];
      if (a.stat) args.push('--stat');
      if (a.format) args.push('--format=raw');
      // `./` makes git read the file path from `path`, as every other tool does, not from the top of the repo.
      return git([...args, a.filePath ? `${a.object}:${a.filePath.startsWith('/') ? '' : './'}${a.filePath}` : a.object, '--']);
    },
  },
  git_diff: {
    desc: 'Diff. No source or target: unstaged changes. target only: the working tree against target. Both: source against target.',
    params: {
      target: str('ref'), source: str('ref'), paths: list('file'), staged: bool(),
      includeUntracked: bool(false), nameOnly: bool(), stat: bool(), contextLines: int(0, 100, 3),
      autoExclude: bool(true),
    },
    run: async (a, git) => {
      const args = ['diff', '--no-ext-diff'];
      if (a.staged) args.push('--cached');
      if (a.nameOnly) args.push('--name-only');
      else if (a.stat) args.push('--stat');
      else args.push(`--unified=${a.contextLines}`);
      if (a.source) args.push(a.source);
      if (a.target) args.push(a.target);
      const spec = ['--', ...(a.paths || []), ...(a.autoExclude ? LOCKFILES.map((f) => `:(exclude,top,glob)**/${f}`) : [])];
      let text = await git([...args, ...spec]);
      if (!a.includeUntracked) return text;
      const untracked = (await git(['ls-files', '--others', '--exclude-standard', '-z', ...spec])).split('\0').filter(Boolean);
      if (!untracked.length) return text;
      if (a.nameOnly || a.stat) return `${text}Untracked:\n${untracked.join('\n')}\n`;
      // A name ending in `/` is a folder with a repository of its own: named, not diffed.
      const files = untracked.filter((f) => !f.endsWith('/')).slice(0, MAX_UNTRACKED_DIFFS);
      for (const f of files) {
        text += await git(['diff', '--no-ext-diff', '--no-index', `--unified=${a.contextLines}`, '--', '/dev/null', f], [0, 1]);
      }
      const rest = untracked.filter((f) => !files.includes(f));
      if (rest.length) text += `Untracked, not shown:\n${rest.join('\n')}\n`;
      return text;
    },
  },
  git_blame: {
    desc: 'Who last changed each line of a file.',
    params: { filePath: str('file'), startLine: int(1, Number.MAX_SAFE_INTEGER), endLine: int(1, Number.MAX_SAFE_INTEGER), ignoreWhitespace: bool() },
    required: ['filePath'],
    run: (a, git) => {
      const args = ['blame'];
      if (a.ignoreWhitespace) args.push('-w');
      if (a.startLine || a.endLine) args.push(`-L${a.startLine || 1},${a.endLine || ''}`);
      return git([...args, '--', a.filePath]);
    },
  },
  git_reflog: {
    desc: 'Reference log of a ref.',
    params: { ref: str('ref', { default: 'HEAD' }), maxCount: int(1, 1000, 25) },
    run: (a, git) => git(['reflog', 'show', `--max-count=${a.maxCount}`, a.ref, '--']),
  },
  git_add: {
    desc: 'Stage files: paths, or all, or update (tracked files only).',
    params: { paths: list('file'), update: bool(), all: bool(), force: bool(false, { desc: 'Also add ignored files.' }) },
    run: (a, git) => {
      const args = ['add'];
      if (a.force) args.push('--force');
      if (a.all) args.push('--all');
      else if (a.update) args.push('--update');
      else if (!a.paths || !a.paths.length) refuse('give paths, or set all or update');
      return git([...args, ...pathsTail(a.paths)]);
    },
  },
  git_commit: {
    desc: 'Commit the staged changes; filesToStage are staged first.',
    params: {
      message: str('text', { maxLength: 10000 }), author: { type: 'object', fields: { name: 'text', email: 'text' } },
      amend: bool(), allowEmpty: bool(), noVerify: bool(), filesToStage: list('file'),
    },
    required: ['message'],
    run: async (a, git) => {
      let text = '';
      if (a.filesToStage && a.filesToStage.length) text += await git(['add', '--', ...a.filesToStage]);
      const args = ['commit', `--message=${a.message}`];
      if (a.amend) args.push('--amend');
      if (a.allowEmpty) args.push('--allow-empty');
      if (a.noVerify) args.push('--no-verify');
      if (a.author) args.push(`--author=${a.author.name} <${a.author.email}>`);
      return text + await git(args);
    },
  },
  git_branch: {
    desc: 'Branches: list (default), show-current, create, delete, rename.',
    params: {
      mode: oneOf(['list', 'create', 'delete', 'rename', 'show-current'], 'list'), branchName: str('name'),
      newBranchName: str('name'), startPoint: str('ref'), force: bool(), all: bool(), remote: bool(),
      merged: { type: 'flagOrRef' }, noMerged: { type: 'flagOrRef' }, limit: int(1, 1000),
    },
    run: async (a, git) => {
      if (a.mode === 'show-current') return git(['branch', '--show-current']);
      if (a.mode === 'create') return git(['branch', ...(a.force ? ['--force'] : []), need(a, 'branchName', 'create'), ...(a.startPoint ? [a.startPoint] : [])]);
      if (a.mode === 'delete') return git(['branch', a.force ? '-D' : '-d', need(a, 'branchName', 'delete')]);
      if (a.mode === 'rename') return git(['branch', '--move', ...(a.force ? ['--force'] : []), need(a, 'branchName', 'rename'), need(a, 'newBranchName', 'rename')]);
      const args = ['branch', '--list', '-vv'];
      if (a.all) args.push('--all');
      else if (a.remote) args.push('--remotes');
      if (a.merged) args.push(`--merged=${a.merged === true ? 'HEAD' : a.merged}`);
      if (a.noMerged) args.push(`--no-merged=${a.noMerged === true ? 'HEAD' : a.noMerged}`);
      return firstLines(await git(args), a.limit);
    },
  },
  git_checkout: {
    desc: 'Switch to a branch or commit, create a branch (createBranch), or restore paths from target.',
    params: { target: str('ref'), createBranch: bool(), force: bool(), paths: list('file'), track: bool() },
    required: ['target'],
    run: (a, git) => {
      const args = ['checkout'];
      if (a.force) args.push('--force');
      if (a.createBranch) {
        checkString('target', a.target, 'name');
        if (a.track) args.push('--track');
        return git([...args, '-b', a.target]);
      }
      // `--` always follows, so target is only ever read as a branch or commit, never as a path to restore.
      return git([...args, a.target, '--', ...(a.paths || [])]);
    },
  },
  git_merge: {
    desc: 'Merge a branch into the current one, or abort a merge in progress.',
    params: { branch: str('name'), strategy: oneOf(STRATEGIES), noFastForward: bool(), squash: bool(), message: str('text', { maxLength: 10000 }), abort: bool() },
    run: (a, git) => {
      if (a.abort) return git(['merge', '--abort']);
      const args = ['merge'];
      if (a.noFastForward) args.push('--no-ff');
      if (a.strategy) args.push(`--strategy=${a.strategy}`);
      if (a.squash) args.push('--squash');
      if (a.message) args.push(`--message=${a.message}`);
      return git([...args, need(a, 'branch', 'a merge')]);
    },
  },
  git_rebase: {
    desc: 'Rebase onto upstream (mode start), or continue, skip or abort one in progress. Interactive rebase is not offered.',
    params: { mode: oneOf(['start', 'continue', 'abort', 'skip'], 'start'), upstream: str('ref'), branch: str('ref'), interactive: bool(), onto: str('ref'), preserve: bool(false, { desc: 'Keep merge commits (--rebase-merges).' }) },
    run: (a, git) => {
      if (a.mode !== 'start') return git(['rebase', `--${a.mode}`]);
      if (a.interactive) refuse('interactive rebase needs an editor; it is not offered here');
      const args = ['rebase'];
      if (a.preserve) args.push('--rebase-merges');
      if (a.onto) args.push(`--onto=${a.onto}`);
      return git([...args, need(a, 'upstream', 'mode start'), ...(a.branch ? [a.branch] : [])]);
    },
  },
  git_cherry_pick: {
    desc: 'Apply commits onto the current branch, or continue or abort a pick in progress.',
    params: { commits: list('ref'), noCommit: bool(), continueOperation: bool(), abort: bool(), mainline: int(1, 64), strategy: oneOf(STRATEGIES), signoff: bool() },
    run: (a, git) => {
      if (a.abort) return git(['cherry-pick', '--abort']);
      if (a.continueOperation) return git(['cherry-pick', '--continue']);
      if (!a.commits || !a.commits.length) refuse('commits is required');
      const args = ['cherry-pick'];
      if (a.noCommit) args.push('--no-commit');
      if (a.mainline) args.push(`--mainline=${a.mainline}`);
      if (a.strategy) args.push(`--strategy=${a.strategy}`);
      if (a.signoff) args.push('--signoff');
      return git([...args, ...a.commits]);
    },
  },
  git_reset: {
    desc: 'Move HEAD to target (mode soft, mixed, hard, merge, keep), or unstage paths.',
    params: { mode: oneOf(['soft', 'mixed', 'hard', 'merge', 'keep'], 'mixed'), target: str('ref', { default: 'HEAD' }), paths: list('file'), confirmed: bool() },
    run: (a, git) => {
      if (a.paths && a.paths.length) {
        if (a.mode !== 'mixed') refuse('paths can only be reset with mode mixed');
        return git(['reset', a.target, '--', ...a.paths]);
      }
      return git(['reset', `--${a.mode}`, a.target, '--']);
    },
  },
  git_clean: {
    desc: 'Remove untracked files. dryRun lists them and removes nothing; without it, force is needed.',
    params: { force: bool(), dryRun: bool(), directories: bool(), ignored: bool() },
    run: (a, git) => {
      const args = ['clean', a.dryRun ? '--dry-run' : a.force ? '--force' : refuse('set dryRun to preview, or force to remove')];
      if (a.directories) args.push('-d');
      if (a.ignored) args.push('-x');
      return git(args);
    },
  },
  git_stash: {
    desc: 'Stashes: push (default), list, pop, apply, drop, clear.',
    params: { mode: oneOf(['list', 'push', 'pop', 'apply', 'drop', 'clear'], 'push'), message: str('text'), stashRef: str('stash'), includeUntracked: bool(), keepIndex: bool(), limit: int(1, 1000) },
    run: (a, git) => {
      if (a.mode === 'list') return git(['stash', 'list', ...(a.limit ? [`--max-count=${a.limit}`] : [])]);
      if (a.mode === 'clear') return git(['stash', 'clear']);
      if (a.mode === 'drop') return git(['stash', 'drop', need(a, 'stashRef', 'drop')]);
      if (a.mode !== 'push') return git(['stash', a.mode, ...(a.stashRef ? [a.stashRef] : [])]);
      const args = ['stash', 'push'];
      if (a.message) args.push(`--message=${a.message}`);
      if (a.includeUntracked) args.push('--include-untracked');
      if (a.keepIndex) args.push('--keep-index');
      return git(args);
    },
  },
  git_tag: {
    desc: 'Tags: list (default), create, delete, verify.',
    params: { mode: oneOf(['list', 'create', 'delete', 'verify'], 'list'), tagName: str('name'), commit: str('ref'), message: str('text'), annotated: bool(), force: bool(), limit: int(1, 1000) },
    run: async (a, git) => {
      if (a.mode === 'list') return firstLines(await git(['tag', '--list', '-n1', '--sort=-creatordate']), a.limit);
      const name = need(a, 'tagName', a.mode);
      if (a.mode === 'delete') return git(['tag', '--delete', name]);
      if (a.mode === 'verify') return git(['tag', '--verify', name]);
      const args = ['tag'];
      if (a.message || a.annotated) args.push('--annotate', `--message=${a.message || `Tag ${name}`}`);
      if (a.force) args.push('--force');
      return git([...args, name, ...(a.commit ? [a.commit] : [])]);
    },
  },
  git_remote: {
    desc: 'Remotes: list (default), add, remove, rename, get-url, set-url.',
    params: { mode: oneOf(['list', 'add', 'remove', 'rename', 'get-url', 'set-url'], 'list'), name: str('remote'), url: str('url'), newName: str('remote'), push: bool(false, { desc: 'The push URL, for get-url and set-url.' }) },
    run: (a, git) => {
      if (a.mode === 'list') return git(['remote', '--verbose']);
      const name = need(a, 'name', a.mode);
      if (a.mode === 'add') return git(['remote', 'add', name, need(a, 'url', 'add')]);
      if (a.mode === 'remove') return git(['remote', 'remove', name]);
      if (a.mode === 'rename') return git(['remote', 'rename', name, need(a, 'newName', 'rename')]);
      const pushFlag = a.push ? ['--push'] : [];
      if (a.mode === 'get-url') return git(['remote', 'get-url', ...pushFlag, name]);
      return git(['remote', 'set-url', ...pushFlag, name, need(a, 'url', 'set-url')]);
    },
  },
  git_fetch: {
    desc: 'Fetch from a remote (default origin).',
    params: { remote: str('remote', { default: 'origin' }), prune: bool(), tags: bool(), depth: int(1, Number.MAX_SAFE_INTEGER) },
    run: async (a, git) => {
      const args = ['fetch'];
      if (a.prune) args.push('--prune');
      if (a.tags) args.push('--tags');
      if (a.depth) args.push(`--depth=${a.depth}`);
      return git([...args, await configured(git, a.remote)]);
    },
  },
  git_pull: {
    desc: 'Pull from a remote (default origin) into the current branch.',
    params: { remote: str('remote', { default: 'origin' }), branch: str('name'), rebase: bool(), fastForwardOnly: bool() },
    run: async (a, git) => {
      // --no-rebase: `rebase: false` means a merge even where the user's config sets pull.rebase.
      const args = ['pull', a.rebase ? '--rebase' : '--no-rebase'];
      if (a.fastForwardOnly) args.push('--ff-only');
      return git([...args, await configured(git, a.remote), ...(a.branch ? [a.branch] : [])]);
    },
  },
  git_push: {
    desc: 'Push. With no remote and no branch: the current branch to its configured remote. branch, remoteBranch and delete need remote; remoteBranch names a different branch on the remote.',
    params: {
      remote: str('remote'), branch: str('name'), remoteBranch: str('name'), force: bool(),
      forceWithLease: bool(), setUpstream: bool(), tags: bool(), dryRun: bool(), delete: bool(),
      confirmed: bool(false, { desc: 'Accepted and ignored.' }),
    },
    run: async (a, git) => {
      const args = ['push'];
      if (a.dryRun) args.push('--dry-run');
      if (a.force) args.push('--force');
      else if (a.forceWithLease) args.push('--force-with-lease');
      if (a.setUpstream) args.push('--set-upstream');
      if (a.tags) args.push('--tags');
      // The hooks judge the remote git itself would pick when none is given, so none is picked here: a call that
      // names a branch must name the remote too.
      if (!a.remote) {
        if (a.branch || a.remoteBranch || a.delete) refuse('remote is required with branch, remoteBranch or delete (usually "origin")');
        return git(args);
      }
      const remote = await configured(git, a.remote);
      if (a.delete) return git([...args, '--delete', remote, a.remoteBranch || a.branch || refuse('delete needs branch or remoteBranch')]);
      // HEAD and @ are the current branch, which the guard resolves itself. Any other branch gets an explicit
      // destination, so no push.default or remote.<name>.push mapping can send it somewhere the call does not name.
      const src = a.branch && a.branch !== 'HEAD' && a.branch !== '@' ? a.branch : 'HEAD';
      if (a.remoteBranch) args.push(remote, `${src}:${a.remoteBranch}`);
      else args.push(remote, ...(a.branch ? [src === 'HEAD' ? 'HEAD' : `${src}:${src}`] : []));
      return git(args);
    },
  },
  git_init: {
    desc: 'Create a repository at path (the folder is made if missing).',
    params: { initialBranch: str('name', { default: 'main' }), bare: bool() },
    anyDir: true,
    run: (a, git) => {
      fs.mkdirSync(a.path, { recursive: true });
      return git(['init', ...(a.bare ? ['--bare'] : []), `--initial-branch=${a.initialBranch}`]);
    },
  },
  git_clone: {
    desc: 'Clone url into path (the destination, which must not exist yet or be empty).',
    // No mirror option: a mirror clone marks its remote so that every later plain push is a forced push of all refs.
    params: { url: str('url'), branch: str('name'), depth: int(1, Number.MAX_SAFE_INTEGER), bare: bool() },
    required: ['url'],
    anyDir: true,
    run: (a, git) => {
      const args = ['clone'];
      if (a.branch) args.push(`--branch=${a.branch}`);
      if (a.depth) args.push(`--depth=${a.depth}`);
      if (a.bare) args.push('--bare');
      return git([...args, '--', a.url, a.path], undefined, '/');
    },
  },
};
for (const tool of Object.values(TOOLS)) {
  tool.params = { path: str('dir', { desc: tool.anyDir ? 'Absolute path of the folder.' : 'Absolute path of the repository (or a folder inside it). Required on every call.' }), ...tool.params };
}

async function callTool(name, input) {
  const tool = Object.prototype.hasOwnProperty.call(TOOLS, name) ? TOOLS[name] : null;
  if (!tool) refuse(`unknown tool: ${name}`);
  const a = validate(tool, input);
  if (!tool.anyDir) {
    let isDir = false;
    try { isDir = fs.statSync(a.path).isDirectory(); } catch { /* not there */ }
    if (!isDir) refuse(`path is not an existing folder: ${a.path}`);
  }
  const text = await tool.run(a, (args, okCodes = [0], cwd = a.path) => runGit(cwd, args, okCodes));
  if (!text) return 'ok (no output)';
  return text.length > MAX_TEXT ? `${text.slice(0, MAX_TEXT)}\n[output cut at ${MAX_TEXT} characters of ${text.length}; narrow the request]` : text;
}

// ---- JSON-RPC over stdio -----------------------------------------------------------------------------------------

const send = (msg) => process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...msg })}\n`);

// Calls on one repository run one after another, so two tool calls sent together cannot collide on its index lock;
// calls on different paths run side by side. A job never rejects: it answers its own failure.
const queues = new Map();
function enqueue(key, job) {
  const next = (queues.get(key) || Promise.resolve()).then(job).finally(() => {
    if (queues.get(key) === next) queues.delete(key);
  });
  queues.set(key, next);
}

function handle(msg) {
  const { id, method, params } = msg;
  if (id === undefined || id === null) return; // a notification: nothing to answer
  if (method === 'initialize') {
    const asked = params && PROTOCOLS.includes(params.protocolVersion) ? params.protocolVersion : PROTOCOLS[0];
    return send({ id, result: { protocolVersion: asked, capabilities: { tools: {} }, serverInfo: { name: 'git-mcp', version: VERSION } } });
  }
  if (method === 'ping') return send({ id, result: {} });
  if (method === 'tools/list') {
    return send({ id, result: { tools: Object.entries(TOOLS).map(([name, tool]) => ({ name, description: tool.desc, inputSchema: jsonSchema(tool) })) } });
  }
  if (method === 'tools/call') {
    const name = params && params.name;
    const input = params && params.arguments;
    const key = input && typeof input === 'object' && typeof input.path === 'string' ? input.path : '';
    return enqueue(key, async () => {
      let text;
      let isError = false;
      try {
        text = await callTool(name, input);
      } catch (e) {
        isError = true;
        text = e instanceof Refused ? e.message : `internal error: ${e && e.message}`;
      }
      send({ id, result: { content: [{ type: 'text', text }], isError } });
    });
  }
  return send({ id, error: { code: -32601, message: `method not found: ${typeof method === 'string' ? method : typeof method}` } });
}

if (require.main === module) {
  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  rl.on('line', (line) => {
    if (!line.trim()) return;
    let msg;
    try { msg = JSON.parse(line); } catch { return send({ id: null, error: { code: -32700, message: 'parse error' } }); }
    if (msg === null || typeof msg !== 'object' || Array.isArray(msg)) return send({ id: null, error: { code: -32600, message: 'invalid request' } });
    handle(msg);
  });
  // When stdin closes, the process ends by itself once the calls in flight have answered and stdout has drained.
  process.stdout.on('error', () => process.exit(0)); // the client went away
}
