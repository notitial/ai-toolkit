import json, os, re, sys, time, urllib.error, urllib.request
from collections import Counter

# This workflow's markers. Only text this script builds from validated fields (hex, enums, ints) ever sits inside one.
FOLLOWUP_MARKER = re.compile(
    r"<!-- claude-review:followup verdict=(resolved|open) sha=([0-9a-f]{40})(?: mode=(rereview|followup))? -->")
SUMMARY_PREFIX = "<!-- claude-review:summary "
HISTORY_MARKER = re.compile(r"<!-- claude-review:history (\[[^\n]*\]) -->")
SLOT_OPEN, SLOT_CLOSE = "<!-- claude-review:overview -->", "<!-- /claude-review:overview -->"
OWN_PR = re.compile(r"own pull request", re.I)
MODES = ("initial", "rereview", "followup")
RESULTS = ("clean", "issues", "stopped", "followup")
SIDES = ("LEFT", "RIGHT")
RESULT_KEYS = {"no_issues", "stopped", "findings", "threads", "overview"}
FINDING_KEYS = {"path", "line", "side", "start_line", "start_side", "body", "line_text", "reopens"}
FINDING_MARK = "<!-- claude-review:finding -->"   # one per body finding: Claude's text can't contain it
# Fences GitHub renders as something richer than code (diagrams, maps, 3D, math): their content is treated as prose.
RICH_FENCES = {"mermaid", "geojson", "topojson", "stl", "math"}
FORBIDDEN = ("<!--", "-->", "claude-review:")
ZWSP = "\u200b"
BODY_BUDGET = 60000   # GitHub's limit for a review or comment body is 65536 characters
ERRORS = (OSError, ValueError, RuntimeError, KeyError, TypeError, IndexError)


class ApiError(RuntimeError):
    def __init__(self, status, message="", retry_after=None):
        super().__init__(f"HTTP {status}")
        self.status, self.message, self.retry_after = status, message, retry_after


def request(method, url, token, payload=None):
    """The one network call: (status, headers, parsed body). An HTTP error raises ApiError."""
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": "bearer " + token,
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            raw = res.read()
            return res.status, res.headers, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        with e:
            try:
                body = json.loads(e.read() or b"{}") or {}
                errors = body.get("errors") if isinstance(body.get("errors"), list) else []
                message = " ".join([str(body.get("message", ""))] + [
                    str(x.get("message", "")) if isinstance(x, dict) else str(x) for x in errors])
            except (ValueError, AttributeError):
                message = ""
            raise ApiError(e.code, message[:300], e.headers.get("Retry-After") if e.headers else None) from None


def pause(seconds):
    time.sleep(seconds)


class Ctx:
    def __init__(self, env):
        self.env = env
        self.repo = env["GITHUB_REPOSITORY"]
        self.owner, self.name = self.repo.split("/")
        self.number = int(env["PR_NUMBER"])
        self.api = env["GITHUB_API_URL"].rstrip("/")
        self.graphql = env["GITHUB_GRAPHQL_URL"]
        self.app_token = env.get("APP_TOKEN", "")
        self.gh_token = env.get("GH_TOKEN", "")
        self.app_login = env.get("APP_LOGIN", "")
        self.app_bot = self.app_login + "[bot]"
        self.mode = env.get("MODE", "")
        self.head = env.get("HEAD_SHA", "")
        self.run_id = env.get("GITHUB_RUN_ID", "")
        self.attempt = env.get("GITHUB_RUN_ATTEMPT", "1")
        self.changes_event = env.get("CHANGES_EVENT", "REQUEST_CHANGES")
        self.cross_repo = True    # the PR's head is in a fork; current_head sets it, and until then assume a fork
        self.approve_event = env.get("APPROVE_EVENT", "APPROVE")
        if self.changes_event not in ("REQUEST_CHANGES", "COMMENT") or self.approve_event not in ("APPROVE", "COMMENT"):
            sys.exit("::error::changes-event must be REQUEST_CHANGES or COMMENT, and approve-event APPROVE or COMMENT")
        self.counts = Counter(replied=0, resolved=0, reopened=0, dismissed=0, inline=0, body=0, dropped=0,
                              moved=0, skipped=0)
        self.reasons = Counter()
        self.failed = 0
        self.verdict = "none"
        self.stale = []          # lines for the overview: a review this run couldn't dismiss
        self.overview_written = False
        self.unchecked = ""      # a follow-up's note on review-body findings it couldn't judge

    def skip(self, reason, n=1):
        self.counts["skipped"] += n
        self.reasons[reason] += n

    def fail(self, what, e):
        print(f"::warning::{what} failed: {type(e).__name__} {getattr(e, 'status', '')}".rstrip())
        self.failed += 1


# --- GitHub API ---

def rest(ctx, method, path, payload=None, token=None):
    return request(method, ctx.api + path, token or ctx.app_token, payload)[2]


def paginate(ctx, path, token=None, max_pages=50):
    url = ctx.api + path + ("&" if "?" in path else "?") + "per_page=100"
    items = []
    for _ in range(max_pages):
        _, headers, data = request("GET", url, token or ctx.app_token)
        if not isinstance(data, list):
            raise ValueError("expected a list")
        items.extend(data)
        m = re.search(r'<([^<>]+)>;\s*rel="next"', (headers.get("Link") if headers else None) or "")
        if not m:
            return items
        url = m.group(1)
        if not url.startswith(ctx.api + "/"):
            raise ValueError("unexpected next-page URL")
    raise ValueError("too many pages")


def gql(ctx, query, variables, token=None):
    out = request("POST", ctx.graphql, token or ctx.app_token, {"query": query, "variables": variables})[2]
    if not isinstance(out, dict) or out.get("errors"):
        errors = (out or {}).get("errors") if isinstance(out, dict) else None
        raise RuntimeError("GraphQL error: " + ", ".join(str(e.get("type", "?")) for e in errors or []))
    return out["data"]


def current_head(ctx):
    q = "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { headRefOid isCrossRepository } } }"
    pr = gql(ctx, q, {"owner": ctx.owner, "name": ctx.name, "number": ctx.number})["repository"]["pullRequest"]
    ctx.cross_repo = pr.get("isCrossRepository") is not False
    return pr["headRefOid"]


def author(c):
    a = (c or {}).get("author") or {}
    return a.get("__typename"), a.get("login")


def started_by_claude(ctx, c):
    """A thread this review started: the App's inline finding, or a legacy claude[bot] comment."""
    return author(c) in (("Bot", "claude"), ("Bot", ctx.app_login))


def on_this_pr(ctx, node):
    """A thread node on this repository's PR (an App can be installed on several repositories)."""
    pr = node.get("pullRequest") or {}
    repo = (pr.get("repository") or {}).get("nameWithOwner") or ""
    return pr.get("number") == ctx.number and repo.lower() == ctx.repo.lower()


def by_this_workflow(ctx, c):
    """A reply this workflow posted: the App's, or a legacy github-actions one."""
    return author(c) in (("Bot", "github-actions"), ("Bot", ctx.app_login))


# --- Sanitizer for Claude's text (finding bodies, the overview) ---
# Splits the text into fenced code blocks, code spans and prose. Code is kept as written (a ```suggestion block must
# survive); prose has every character escaped that could build a link, image, HTML or a fence, and mentions, bare
# URLs and cross-repo references are broken up. A fence counts only when GitHub surely sees one: a backtick or tilde
# fence at column 0. Anything else is prose, so where the two parsers might disagree the text is escaped.

def strip_forbidden(text):
    while True:
        cleaned = text
        for s in FORBIDDEN:
            cleaned = cleaned.replace(s, "")
        if cleaned == text:
            return text
        text = cleaned


def escape_prose(text):
    text = re.sub(r"([\w.-]+/[\w.-]+)#(?=\d)", "\\1#" + ZWSP, text)
    text = text.replace("@", "@" + ZWSP).replace("://", ":/" + ZWSP + "/")
    text = re.sub(r"(?i)(www)\.", "\\1" + ZWSP + ".", text)
    return re.sub(r"([\\`\[\]<>&~$])", r"\\\1", text)


def backtick_run(line, i):
    j = i
    while j < len(line) and line[j] == "`":
        j += 1
    return j


def closing_run(line, start, length):
    """Where the next backtick run of exactly `length` starts on this line, or None."""
    i = start
    while i < len(line):
        if line[i] == "`":
            j = backtick_run(line, i)
            if j - i == length:
                return i
            i = j
        else:
            i += 1
    return None


def prose_line(line):
    """One line outside a fence: code spans that open and close on this line are kept, the rest is escaped."""
    out, i, start = [], 0, 0
    while i < len(line):
        if line[i] != "`":
            i += 1
            continue
        j = backtick_run(line, i)
        slashes = len(line[:i]) - len(line[:i].rstrip("\\"))
        close = closing_run(line, j, j - i) if slashes % 2 == 0 else None
        if close is None:
            i = j
            continue
        out.append(escape_prose(line[start:i]))
        out.append(line[i:close + j - i])
        i = start = close + j - i
    out.append(escape_prose(line[start:]))
    return "".join(out)


def fence_opener(line):
    """(fence string, rich) when this line surely opens a fenced block on GitHub, else (None, False)."""
    m = re.fullmatch(r"(`{3,})[^`]*|(~{3,}).*", line)
    if not m:
        return None, False
    fence = m.group(1) or m.group(2)
    info = line[len(fence):].split()
    return fence, bool(info) and info[0].lower() in RICH_FENCES


def closes(fence, line):
    return re.fullmatch(r" {0,3}" + re.escape(fence[0]) + "{%d,}[ \t]*" % len(fence), line) is not None


def sanitize(text):
    text = strip_forbidden(text.replace("\r\n", "\n").replace("\r", "\n"))
    # A rich fence is tracked like any fence (so its closing line isn't taken for an opener) but every line of it,
    # opener and closer included, is escaped as prose: GitHub then sees no fence there at all.
    out, fence, rich = [], None, False
    for line in text.split("\n"):
        if fence:
            out.append(prose_line(line) if rich else line)
            if closes(fence, line):
                fence = None
            continue
        fence, rich = fence_opener(line)
        out.append(prose_line(line) if not fence or rich else line)
    if fence and not rich:
        out.append(fence)
    return "\n".join(out).strip("\n")


def overview_slot(text):
    """Claude's `overview` rendered for the overview slot of the sticky comment ("" leaves the slot empty)."""
    text = " ".join(strip_forbidden(" ".join(str(text).split())).split())   # ONE line, so never a fence
    line = prose_line(text)
    if re.match(r"[#|=]|[-+*_](?:\s|$|[-+*_=])|\d+[.)](?:\s|$)", line):   # would open a block: escape the marker
        m = re.match(r"\d+", line)
        i = m.end() if m else 0
        line = line[:i] + "\\" + line[i:]
    return line


def code_path(path):
    return "`" + re.sub(r"[\x00-\x1f\x7f]", " ", strip_forbidden(str(path))).replace("`", "") + "`"


def safe_url(url):
    return isinstance(url, str) and re.fullmatch(r"https://[^\s()<>\[\]`\"']+", url) is not None


# --- Claude's result ---

def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def is_str(v, limit):
    return isinstance(v, str) and len(v) <= limit


def valid_finding(f):
    return (isinstance(f, dict) and set(f) <= FINDING_KEYS and {"path", "line", "side", "body"} <= set(f)
            and is_str(f["path"], 512) and f["path"] != "" and is_int(f["line"]) and f["side"] in SIDES
            and is_str(f["body"], 4000)
            and ("start_line" not in f or is_int(f["start_line"]))
            and ("start_side" not in f or f["start_side"] in SIDES)
            and ("line_text" not in f or is_str(f["line_text"], 500))
            and ("reopens" not in f or is_str(f["reopens"], 200)))


def valid_thread(t):
    return (isinstance(t, dict) and set(t) == {"thread_id", "verdict", "reply"} and isinstance(t["thread_id"], str)
            and t["verdict"] in ("resolved", "open") and is_str(t["reply"], 800))


def load_result(path):
    """(result, None) when the file holds a well-formed result, else (None, why)."""
    try:
        size = os.path.getsize(path)
    except (OSError, TypeError, ValueError):
        return None, "missing"
    if size == 0:
        return None, "empty"
    if size > 1 << 20:
        return None, "larger than 1 MiB"
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None, "not JSON"
    ok = (isinstance(data, dict) and set(data) == RESULT_KEYS
          and isinstance(data["no_issues"], bool) and isinstance(data["stopped"], bool)
          and isinstance(data["findings"], list) and len(data["findings"]) <= 8
          and all(valid_finding(f) for f in data["findings"])
          and isinstance(data["threads"], list) and len(data["threads"]) <= 100
          and all(valid_thread(t) for t in data["threads"])
          and is_str(data["overview"], 600))
    return (data, None) if ok else (None, "the wrong shape")


INCOMPLETE = "issues reported without findings"


def contradiction(mode, data):
    """Why a well-formed result can't be used in this mode, or None."""
    if data["stopped"] and (mode != "initial" or data["findings"]):
        return "a stop outside an initial review, or a stop with findings"
    if mode != "followup" and not data["stopped"] and not data["no_issues"] and not data["findings"]:
        return INCOMPLETE
    return None


# --- Thread replies (comment runs) ---

def reply_text(ctx, text, verdict, head):
    while True:
        cleaned = text
        for s in ("<!--", "-->", "claude-review:followup"):
            cleaned = cleaned.replace(s, "")
        if cleaned == text:
            break
        text = cleaned
    # Defuse mentions and fences, escape every markdown and HTML character that could make a viewer's browser
    # load something (images, links, tags) or open a code span (backticks, so nothing is ever left unescaped),
    # break bare URLs so they don't autolink, and quote it. The reply then shows as plain text.
    text = text.replace("@", "@​").replace("~~~", "~​~​~").strip()[:800].strip()
    text = re.sub(r"([\w.-]+/[\w.-]+)#(?=\d)", "\\1#" + ZWSP, text)   # cross-repo references make backlinks
    text = re.sub(r"([\\`\[\]()!<>&$])", r"\\\1", text).replace("://", ":/​/").replace("www.", "www​.")
    if not text:
        text = "The current code handles this." if verdict == "resolved" else "This still looks open in the current code."
    quoted = "\n".join("> " + line for line in text.splitlines())
    return f"{quoted}\n\n— Claude review follow-up\n<!-- claude-review:followup verdict={verdict} sha={head} mode={ctx.mode} -->"


THREAD = """
query($id: ID!) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      isResolved
      pullRequest { number repository { nameWithOwner } }
      first: comments(first: 1) { nodes { fullDatabaseId author { __typename login } } }
      last: comments(last: 1) { nodes { fullDatabaseId author { __typename login } body } }
    }
  }
}
"""


def marker_verdict(ctx, comment, head):
    """(verdict, mode) of a valid marker: posted by this workflow, for the current head. Else (None, None)."""
    if not by_this_workflow(ctx, comment):
        return None, None
    m = FOLLOWUP_MARKER.search(comment.get("body") or "")
    return (m.group(1), m.group(3)) if m and m.group(2) == head else (None, None)


def reply_in_threads(ctx, items):
    """Posts Claude's verdict in each of its open threads (App token); returns the ids it judged fixed.
    Accepts only verdicts for threads collected as open in `review`."""
    try:
        with open(ctx.env.get("THREADS_FILE", "")) as f:
            collected = json.load(f)
        open_threads = {t["thread_id"]: t for t in collected.get("open", [])}
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as e:
        ctx.fail("Reading the collected threads", e)
        return []
    if collected.get("head_sha") != ctx.head:
        ctx.skip("collected at another head", len(items))
        return []
    seen = Counter(i["thread_id"] for i in items)
    to_resolve = []
    for i in items:
        thread_id = i["thread_id"]
        if seen[thread_id] != 1:
            ctx.skip("thread judged more than once")
            continue
        if thread_id not in open_threads:
            ctx.skip("not a collected open thread")
            continue
        try:
            node = gql(ctx, THREAD, {"id": thread_id})["node"]
            if not node or not node["last"]["nodes"] or not node["first"]["nodes"]:
                ctx.skip("thread gone")
                continue
            if not on_this_pr(ctx, node):
                ctx.skip("thread on another PR")
                continue
            if not started_by_claude(ctx, node["first"]["nodes"][0]):
                ctx.skip("not a Claude thread")
                continue
            if node["isResolved"]:
                ctx.skip("resolved meanwhile")
                continue
            last = node["last"]["nodes"][0]
            # This workflow's own reply for this head comes first: on a re-run it is the thread's new last comment.
            done, done_mode = marker_verdict(ctx, last, ctx.head)
            if done == "resolved" and i["verdict"] == "resolved":
                to_resolve.append(thread_id)   # replied before, but not resolved (a cancelled or refused resolve)
                continue
            if done == "open" and (done_mode == "rereview" or ctx.mode == "followup"):
                ctx.skip("already replied for this head")
                continue
            if int(last["fullDatabaseId"]) != int(open_threads[thread_id]["last_comment_id"]):
                ctx.skip("new reply during the run")
                continue
            # Otherwise (no marker, or a person unresolved a thread this workflow resolved) reply with the new verdict.
            first_id = int(node["first"]["nodes"][0]["fullDatabaseId"])
            rest(ctx, "POST", f"/repos/{ctx.repo}/pulls/{ctx.number}/comments/{first_id}/replies",
                 {"body": reply_text(ctx, i["reply"], i["verdict"], ctx.head)})
            ctx.counts["replied"] += 1
            if i["verdict"] == "resolved":
                to_resolve.append(thread_id)
        except ERRORS as e:
            ctx.fail("A thread reply", e)
    return to_resolve


# --- Resolve (GITHUB_TOKEN: the App has no contents permission, which resolveReviewThread needs) ---

RESOLVE_THREAD = """
query($id: ID!) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      isResolved
      pullRequest { number repository { nameWithOwner } }
      first: comments(first: 1) { nodes { author { __typename login } } }
      last: comments(last: 1) { nodes { author { __typename login } body } }
    }
  }
}
"""


def resolve_threads(ctx, ids):
    """Resolves a thread only if this review started it, it's still open, and its last comment is this workflow's
    `verdict=resolved` marker for the head the review judged."""
    forbidden = False
    for thread_id in dict.fromkeys(ids):
        try:
            node = gql(ctx, RESOLVE_THREAD, {"id": thread_id}, token=ctx.gh_token)["node"]
            if not node or not node["first"]["nodes"] or not node["last"]["nodes"]:
                ctx.skip("thread gone")
                continue
            if not on_this_pr(ctx, node):
                ctx.skip("thread on another PR")
                continue
            if not started_by_claude(ctx, node["first"]["nodes"][0]):
                ctx.skip("not a Claude thread")
                continue
            if node["isResolved"]:
                ctx.skip("already resolved")
                continue
            last = node["last"]["nodes"][0]
            m = FOLLOWUP_MARKER.search(last.get("body") or "")
            if not by_this_workflow(ctx, last) or not m or m.group(1, 2) != ("resolved", ctx.head):
                ctx.skip("last comment isn't this review's resolved marker")
                continue
            if forbidden:
                ctx.skip("resolving not permitted")
                continue
            try:
                gql(ctx, "mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }",
                    {"id": thread_id}, token=ctx.gh_token)
            except RuntimeError as e:
                if isinstance(e, ApiError) or "FORBIDDEN" not in str(e):
                    raise
                print("contents: write isn't enough to resolve")
                forbidden = True
                ctx.skip("resolving not permitted")
                continue
            ctx.counts["resolved"] += 1
        except ERRORS as e:
            ctx.fail("Resolving a thread", e)


# --- Reopen (a rereview finding whose issue was fixed and is back) ---

REOPEN_NOTE = "Regressed: this was fixed earlier, and the current code has the issue again. "


def reopen_threads(ctx, findings):
    """For each finding Claude marked `reopens`, unresolves that thread (GITHUB_TOKEN, like resolve) and posts the
    finding in it as the App. Only a thread `review` collected as reopenable at this head qualifies: one this
    review started, resolved after this workflow's `resolved` reply for an earlier head. A `reopens` naming
    another thread collected for this PR is dropped, since that thread already covers the issue (a person's
    resolve stays). Any other one, and a failed reopen, posts as a new finding: better than a lost one. Returns
    the findings still to post."""
    if not any("reopens" in f for f in findings):
        return findings
    reopenable, collected_ids = set(), set()
    try:
        with open(ctx.env.get("THREADS_FILE", "")) as fh:
            collected = json.load(fh)
        if collected.get("head_sha") == ctx.head:
            raised = collected.get("raised", [])
            reopenable = {t["thread_id"] for t in raised if t.get("reopenable") is True}
            collected_ids = {t["thread_id"] for t in collected.get("open", []) + raised}
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as e:
        ctx.fail("Reading the collected threads", e)
    left, done, forbidden = [], set(), False
    for f in findings:
        thread_id = f.get("reopens")
        if thread_id is None:
            left.append(f)
            continue
        if thread_id in done or (thread_id in collected_ids and thread_id not in reopenable):
            ctx.skip("regression already covered by its thread")
            continue
        if thread_id not in reopenable or forbidden:
            ctx.skip("regression posted as a new finding")
            left.append(f)
            continue
        done.add(thread_id)
        unresolved = False
        try:
            node = gql(ctx, THREAD, {"id": thread_id})["node"]
            if (not node or not node["first"]["nodes"] or not node["last"]["nodes"] or not on_this_pr(ctx, node)
                    or not started_by_claude(ctx, node["first"]["nodes"][0])):
                ctx.skip("regression's thread gone or not Claude's")
                left.append(f)
                continue
            last = node["last"]["nodes"][0]
            if marker_verdict(ctx, last, ctx.head) == ("open", "rereview"):
                # This workflow already reopened it for this head: a re-run counts it and posts nothing. If it
                # was resolved again since, a person did that, and their resolve stays.
                if node["isResolved"]:
                    ctx.skip("regression resolved again by a person")
                else:
                    ctx.counts["reopened"] += 1
                continue
            m = FOLLOWUP_MARKER.search(last.get("body") or "") if by_this_workflow(ctx, last) else None
            if not node["isResolved"] or not (m and m.group(1) == "resolved" and m.group(2) != ctx.head):
                ctx.skip("regression's thread changed since it was collected")
                left.append(f)
                continue
            try:
                gql(ctx, "mutation($id: ID!) { unresolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }",
                    {"id": thread_id}, token=ctx.gh_token)
            except RuntimeError as e:
                if isinstance(e, ApiError) or "FORBIDDEN" not in str(e):
                    raise
                print("contents: write isn't enough to reopen: regressions post as new findings")
                ctx.skip("reopening not permitted")
                forbidden = True
                left.append(f)
                continue
            unresolved = True
            first_id = int(node["first"]["nodes"][0]["fullDatabaseId"])
            rest(ctx, "POST", f"/repos/{ctx.repo}/pulls/{ctx.number}/comments/{first_id}/replies",
                 {"body": reply_text(ctx, REOPEN_NOTE + f["body"], "open", ctx.head)})
            ctx.counts["reopened"] += 1
        except ERRORS as e:
            ctx.fail("Reopening a thread", e)
            if unresolved:
                # Resolve it back, so the thread doesn't sit open under the old "fixed" reply.
                try:
                    gql(ctx, "mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }",
                        {"id": thread_id}, token=ctx.gh_token)
                except ERRORS as e2:
                    ctx.fail("Resolving a thread back", e2)
            left.append(f)
    return left


THREADS = """
query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { isResolved path line originalLine comments(first: 1) { nodes { author { __typename login } url } } }
      }
    }
  }
}
"""


def scan_threads(ctx):
    """(resolved count, [(path, line, url)] of the open ones) over every thread this review started."""
    resolved, open_links, after = 0, [], None
    for _ in range(30):
        page = gql(ctx, THREADS, {"owner": ctx.owner, "name": ctx.name, "number": ctx.number, "after": after})
        threads = page["repository"]["pullRequest"]["reviewThreads"]
        for t in threads["nodes"]:
            first = (t["comments"]["nodes"] or [None])[0]
            if not first or not started_by_claude(ctx, first):
                continue
            if t["isResolved"]:
                resolved += 1
            else:
                open_links.append((t.get("path"), t.get("line") or t.get("originalLine"), first.get("url")))
        if not threads["pageInfo"]["hasNextPage"]:
            return resolved, open_links
        after = threads["pageInfo"]["endCursor"]
    raise ValueError("too many thread pages")


# --- Findings: where each one can go ---

HUNK = re.compile(r"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def parse_patch(patch):
    """{side: {line: (hunk index, text)}}: RIGHT holds added and context lines, LEFT removed and context lines."""
    sides = {"LEFT": {}, "RIGHT": {}}
    hunk, left, right = -1, 0, 0
    for line in patch.split("\n"):
        m = HUNK.match(line)
        if m:
            hunk, left, right = hunk + 1, int(m.group(1)), int(m.group(2))
        elif hunk < 0 or line == "" or line.startswith("\\"):
            continue
        elif line[0] == "+":
            sides["RIGHT"][right] = (hunk, line[1:])
            right += 1
        elif line[0] == "-":
            sides["LEFT"][left] = (hunk, line[1:])
            left += 1
        elif line[0] == " ":
            sides["LEFT"][left] = sides["RIGHT"][right] = (hunk, line[1:])
            left, right = left + 1, right + 1
    return sides


def pr_files(ctx):
    """{filename: parsed patch, or None when GitHub gives no patch (binary or too large)}."""
    files = {}
    for f in paginate(ctx, f"/repos/{ctx.repo}/pulls/{ctx.number}/files"):
        if isinstance(f, dict) and isinstance(f.get("filename"), str):
            patch = f.get("patch")
            files[f["filename"]] = parse_patch(patch) if isinstance(patch, str) and patch else None
    return files


def place(f, files):
    """("inline", review comment) when the finding's lines are in the diff, ("moved", review comment) when its
    `line_text` is on another line of the diff (Claude miscounted), ("body", None) when they aren't, ("drop", None)
    when its path isn't one of the PR's files. files None: the list couldn't be read."""
    if files is None:
        return "body", None
    if f["path"] not in files:
        return "drop", None
    sides = files[f["path"]]
    if sides is None:
        return "body", None
    line, side = f["line"], f["side"]
    lines = sides[side]
    raw = f.get("line_text") or ""
    want, shift = " ".join(raw.split()), 0
    cut = len(raw) >= 500   # the schema's limit: Claude had to cut a longer line

    def same(text):
        have = " ".join(text.split())
        return have == want or (cut and have.startswith(want))

    if want and (line not in lines or not same(lines[line][1])):
        # A short line (a brace, `else:`) is too common to say which line was meant.
        matches = [n for n, (_, text) in lines.items() if same(text)] if len(want) >= 3 else []
        if len(matches) != 1:
            return "body", None
        shift = matches[0] - line
        line = matches[0]
    if line < 1 or line not in lines:
        return "body", None
    comment = {"path": f["path"], "line": line, "side": side}
    if "start_line" in f:
        start, start_side = f["start_line"] + shift, f.get("start_side", side)
        if not (start == line and start_side == side):
            # Only `line` has a text to check: a moved range could cover the wrong lines, and a suggestion for it would
            # replace them.
            if shift or not (1 <= start < line and start in sides[start_side]
                             and sides[start_side][start][0] == lines[line][0]):
                return "body", None
            comment.update(start_line=start, start_side=start_side)
    return ("moved" if shift else "inline"), comment


def finding_items(findings, budget):
    """The findings as review-body sections, as many as fit in `budget` characters."""
    items, used = [], 0
    for f in findings:
        item = f"{FINDING_MARK}\n**{code_path(f['path'])} line {f['line']}**\n\n{f['text']}"
        if used + len(item) > budget:
            break
        items.append(item)
        used += len(item) + 2
    if len(items) < len(findings):
        items.append(f"({len(findings) - len(items)} more didn't fit here.)")
    return items


# --- The App's reviews ---

def app_reviews(ctx):
    reviews = [r for r in paginate(ctx, f"/repos/{ctx.repo}/pulls/{ctx.number}/reviews")
               if isinstance(r, dict) and (r.get("user") or {}).get("login") == ctx.app_bot]
    return sorted(reviews, key=lambda r: r.get("id") or 0)


def effective(reviews):
    """The App's latest APPROVED or CHANGES_REQUESTED review, or None (none yet, or the latest was dismissed)."""
    decisive = [r for r in reviews if r.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED")]
    return decisive[-1] if decisive and decisive[-1]["state"] != "DISMISSED" else None


def run_review(ctx, reviews):
    """The App's review from this run (any attempt), found by the run marker."""
    pattern = re.compile(r"<!-- claude-review:review run=" + re.escape(ctx.run_id) + " ")
    return next((r for r in reviews if pattern.search(r.get("body") or "")), None)


def dismiss(ctx, review, message, stale_line):
    try:
        rest(ctx, "PUT", f"/repos/{ctx.repo}/pulls/{ctx.number}/reviews/{review['id']}/dismissals",
             {"message": message, "event": "DISMISS"})
        ctx.counts["dismissed"] += 1
    except ApiError as e:
        if e.status == 422:
            return   # already dismissed
        print(f"::warning::Couldn't dismiss the App's {review.get('state')} review (HTTP {e.status}): dismiss it by hand")
        ctx.stale.append(stale_line)
    except ERRORS as e:
        print(f"::warning::Couldn't dismiss the App's review: {type(e).__name__}")
        ctx.stale.append(stale_line)


STALE_APPROVAL = "Approval is stale: dismiss it manually."
STALE_CHANGES = "Change request is stale: dismiss it manually."
UNCHECKED_APPROVAL = "The approval may be stale: the PR head couldn't be re-read after it was posted. Check it."


def dismiss_stale_approval(ctx):
    """A push dismisses the App's APPROVE for an older commit. CHANGES_REQUESTED is never dismissed by a push."""
    try:
        head = current_head(ctx)
        latest = effective(app_reviews(ctx))
    except ERRORS as e:
        ctx.fail("Checking for a stale approval", e)
        return
    if latest and latest["state"] == "APPROVED" and latest.get("commit_id") != head:
        dismiss(ctx, latest, "New commits since this approval.", STALE_APPROVAL)


def review_body(ctx, line, overview_url, body_findings):
    first = line + (f" See the [review overview]({overview_url})." if safe_url(overview_url) else "")
    parts = [f"<!-- claude-review:review run={ctx.run_id} attempt={ctx.attempt} sha={ctx.head} -->\n{first}"]
    if body_findings:
        parts += ["**Not on a changed line:**"] + finding_items(body_findings, BODY_BUDGET - 1000)
    return "\n\n".join(parts)


def submit(ctx, event, line, overview_url, inline, body_findings):
    """Submits one review. Returns (review, inline findings it carries, body findings it carries); review is "own"
    when GitHub refuses a review of the App's own PR, None after the final failure."""
    for attempt in (1, 2):
        payload = {"commit_id": ctx.head, "event": event,
                   "body": review_body(ctx, line, overview_url, body_findings)}
        if inline:
            payload["comments"] = [dict(f["comment"], body=f["text"]) for f in inline]
        try:
            return rest(ctx, "POST", f"/repos/{ctx.repo}/pulls/{ctx.number}/reviews", payload), inline, body_findings
        except ApiError as e:
            if e.status == 422 and OWN_PR.search(e.message):
                print("::warning::GitHub doesn't let the App review its own PR")
                return "own", inline, body_findings
            print(f"Submitting the review failed: HTTP {e.status}")
            if e.status == 422:
                body_findings, inline = inline + body_findings, []   # retry with every finding in the body
                continue
            failure = e
        except ERRORS as e:
            print(f"Submitting the review failed: {type(e).__name__}")
            failure = e
        # 403/429/5xx/timeout: it may have landed anyway.
        try:
            landed = run_review(ctx, app_reviews(ctx))
        except ERRORS:
            landed = None
        if landed:
            return landed, inline, body_findings
        if attempt == 1:
            wait = getattr(failure, "retry_after", None)
            pause(min(int(wait), 60) if wait and str(wait).isdigit() else 5)
    return None, inline, body_findings


def review_comment_urls(ctx, review):
    return [c["html_url"] for c in paginate(ctx, f"/repos/{ctx.repo}/pulls/{ctx.number}/reviews/{review['id']}/comments")
            if isinstance(c, dict) and safe_url(c.get("html_url"))]


# --- The sticky overview comment ---

def find_overview(ctx):
    found = [c for c in paginate(ctx, f"/repos/{ctx.repo}/issues/{ctx.number}/comments")
             if isinstance(c, dict) and (c.get("user") or {}).get("login") == ctx.app_bot
             and (c.get("body") or "").startswith(SUMMARY_PREFIX)]
    if len(found) > 1:
        print(f"::warning::{len(found)} overview comments from the App: editing the newest")
    return max(found, key=lambda c: c["id"]) if found else None


def old_slot(body):
    i, j = body.find(SLOT_OPEN), body.find(SLOT_CLOSE)
    return body[i + len(SLOT_OPEN):j].strip("\n") if 0 <= i < j else ""


def valid_entry(h):
    return (isinstance(h, dict) and set(h) - {"b"} == {"sha", "mode", "result", "n", "run", "attempt"}
            and isinstance(h["sha"], str) and re.fullmatch(r"[0-9a-f]{7}", h["sha"]) is not None
            and h["mode"] in MODES and h["result"] in RESULTS
            and all(is_int(h[k]) and h[k] >= 0 for k in ("n", "run", "attempt"))
            and ("b" not in h or is_int(h["b"]) and 0 <= h["b"] <= h["n"]))


def read_history(body):
    m = HISTORY_MARKER.search(body or "")
    if not m:
        return []
    try:
        raw = json.loads(m.group(1))
    except ValueError:
        raw = None
    if isinstance(raw, list):
        return [h for h in raw if valid_entry(h)]
    print("::warning::The overview's history couldn't be read: starting it again")
    return []


def merge_history(history, entry):
    """Newest first, at most 10, one entry per run (a re-run replaces its own)."""
    return ([entry] + [h for h in history if h["run"] != entry["run"]])[:10]


def history_item(h):
    n = f" · {h['n']} finding{'s' if h['n'] != 1 else ''}" if h["n"] else ""
    run = f"{h['run']}/{h['attempt']}" if h["attempt"] > 1 else str(h["run"])
    return f"- `{h['sha']}` · {h['mode']} · {h['result']}{n} · run {run}"


def threads_line(st):
    if st["open"] is None:
        return "**Threads:** couldn't be counted."
    text = f"**Threads:** {st['resolved']} resolved · {len(st['open'])} still open"
    if st["open"]:
        links = []
        for path, line, url in st["open"][:10]:
            label = code_path(f"{path}:{line}" if line else path)
            links.append(f"[{label}]({url})" if safe_url(url) else label)
        more = len(st["open"]) - 10
        text += ": " + ", ".join(links) + (f", and {more} more" if more > 0 else "")
    return text


def overview_text(ctx, st):
    history = st["history"]
    runs = f"{len(history)} run{'s' if len(history) != 1 else ''}"
    parts = [f"{SUMMARY_PREFIX}sha={ctx.head} result={st['result']} -->\n"
             f"### Claude review · `{ctx.head[:7]}` · {ctx.mode}",
             f"**Result:** {st['line']}"]
    reopened = ctx.counts["reopened"]
    if reopened:
        parts.append(f"**Regressions:** {reopened} resolved thread{'s' if reopened != 1 else ''} reopened: "
                     f"the issue is back in the current code.")
    parts += ctx.stale
    if st["fallback"]:
        parts += finding_items(st["fallback"], BODY_BUDGET - 4000)
    parts.append(SLOT_OPEN + ("\n" + st["slot"] if st["slot"] else "") + "\n" + SLOT_CLOSE)
    parts.append(threads_line(st))
    parts.append(f"<details><summary>History (last {runs})</summary>\n\n"
                 + "\n".join(history_item(h) for h in history) + "\n</details>\n"
                 f"<!-- claude-review:history {json.dumps(history, separators=(',', ':'))} -->")
    return "\n\n".join(parts)


def write_overview(ctx, st):
    """PATCH the App's overview comment, or POST one. Returns its html_url, or None when the write failed."""
    body = overview_text(ctx, st)
    try:
        target = st["comment"] or find_overview(ctx)   # looked up again right before a POST
        if target:
            if target.get("body") == body:
                return target.get("html_url")
            out = rest(ctx, "PATCH", f"/repos/{ctx.repo}/issues/comments/{target['id']}", {"body": body})
        else:
            out = rest(ctx, "POST", f"/repos/{ctx.repo}/issues/{ctx.number}/comments", {"body": body})
        st["comment"] = out
        ctx.overview_written = True
        return out.get("html_url")
    except ERRORS as e:
        print(f"::warning::Writing the overview comment failed: {type(e).__name__} {getattr(e, 'status', '')}".rstrip())
        return None


def note_stale_on_overview(ctx):
    """A push run that couldn't dismiss: add the stale line under the existing overview's result."""
    try:
        comment = find_overview(ctx)
        if not comment:
            return
        parts = comment["body"].split("\n\n")
        at = next((i for i, p in enumerate(parts) if p.startswith("**Result:**")), None)
        new = [s for s in ctx.stale if s not in parts]
        if at is None or not new:
            return
        body = "\n\n".join(parts[:at + 1] + new + parts[at + 1:])
        rest(ctx, "PATCH", f"/repos/{ctx.repo}/issues/comments/{comment['id']}", {"body": body})
    except ERRORS as e:
        print(f"::warning::Noting the stale review on the overview failed: {type(e).__name__}")


# --- The run ---

def parse_ids(raw):
    try:
        ids = json.loads(raw) if raw else []
    except ValueError:
        return None
    if isinstance(ids, list) and len(ids) <= 100 and all(isinstance(i, str) and i for i in ids):
        return ids
    return None


def publish(ctx):
    event, action = ctx.env.get("GITHUB_EVENT_NAME"), ctx.env.get("EVENT_ACTION")
    if event == "pull_request" and action == "synchronize":
        dismiss_stale_approval(ctx)

    review_result = ctx.env.get("REVIEW_RESULT", "")
    if review_result != "success":
        print(f"The review job's result is '{review_result or 'none'}': no verdict")
        return

    data, retry, incomplete = None, [], False
    if ctx.env.get("HAS_RESULT") == "true":
        data, why = load_result(ctx.env.get("RESULT_FILE", ""))
        if why == "missing":
            # `review` uploaded a result, so the download failed: fail red, so the job gets re-run.
            print("::error::Claude's result wasn't downloaded: re-run this job to publish the review")
            ctx.failed += 1
            return
        why = why or contradiction(ctx.mode, data)
        if why:
            print(f"No verdict: Claude's result is {why}" if data is None else f"No verdict: Claude's result has {why}")
            if why != INCOMPLETE:
                return
            incomplete = True   # say the review ran: carry on to the overview, with no verdict
    else:
        retry = parse_ids(ctx.env.get("RETRY_IDS", ""))
        if retry is None:
            print("No-op: the retry list is malformed")
            return
        if not retry:
            print("Claude ran but returned no result: no verdict" if ctx.env.get("RAN") == "true"
                  else "Nothing to publish: this head was already covered")
            return
    if ctx.mode not in MODES or not re.fullmatch(r"[0-9a-f]{40}", ctx.head) or not ctx.run_id.isdigit() \
            or not ctx.attempt.isdigit():
        print("No verdict: the review job's outputs are missing or malformed")
        return

    try:
        head = current_head(ctx)
    except ERRORS as e:
        ctx.fail("Reading the PR head", e)
        return
    if head != ctx.head:
        print("No-op: the PR moved after the review, so its result is for older code")
        if not (event == "pull_request" and action == "synchronize"):   # a push run already checked
            dismiss_stale_approval(ctx)
        return

    full = data is not None and ctx.mode != "followup"
    findings = data["findings"] if full and not data["stopped"] else []

    # Replies, then resolve: resolve keys on the reply's marker.
    to_resolve = list(retry)
    if data is not None and data["threads"] and ctx.mode != "initial" and not incomplete:
        to_resolve += reply_in_threads(ctx, data["threads"])
    if to_resolve:
        resolve_threads(ctx, to_resolve)
    # A regression reopens its old thread before the count, so the open thread asks for changes.
    if findings and ctx.mode == "rereview":
        findings = reopen_threads(ctx, findings)
    try:
        resolved, open_links = scan_threads(ctx)
    except ERRORS as e:
        ctx.fail("Counting the review threads", e)
        resolved, open_links = 0, None

    inline, in_body = [], []
    if findings:
        try:
            files = pr_files(ctx)
        except ERRORS as e:
            print(f"::warning::Reading the PR's files failed ({type(e).__name__}): every finding goes in the review body")
            files = None
        seen = set()
        for f in findings:
            key = (f["path"], f["line"], f["body"])
            if key in seen:
                continue
            seen.add(key)
            where, comment = place(f, files)
            item = {"path": f["path"], "line": comment["line"] if comment else f["line"],
                    "text": sanitize(f["body"]), "comment": comment}
            if where == "drop":
                ctx.counts["dropped"] += 1
            elif where in ("inline", "moved"):
                item["moved"] = where == "moved"
                inline.append(item)
            else:
                in_body.append(item)
    n_open = None if open_links is None else len(open_links)
    n_found = len(inline) + len(in_body)

    if data is not None and data["stopped"]:
        decision, result, line = "none", "stopped", "Review stopped (eligibility): nothing to review. No verdict."
    elif incomplete:
        decision, result, line = "none", "issues", "Review incomplete: issues reported without findings. No verdict."
    elif full:
        if n_found:
            decision, result, line = "changes+findings", "issues", f"{n_found} finding{'s' if n_found != 1 else ''}."
        elif n_open:
            decision, result, line = "changes", "issues", f"No new findings; {n_open} thread(s) still open."
        elif n_open == 0 and data["no_issues"] and not data["findings"] and not ctx.failed:
            decision, result, line = "approve", "clean", "No issues found."
        elif ctx.counts["dropped"]:
            decision, result, line = "none", "issues", "No finding named one of this PR's files. No verdict."
        elif ctx.reasons["regression already covered by its thread"]:
            decision, result, line = "none", "issues", "No new findings: Claude's are on resolved threads. No verdict."
        else:
            decision, result, line = "none", "issues", "No new findings, but this run couldn't finish its thread updates."
    else:
        decision = "none" if n_open is None else "changes" if n_open else "clear"
        result = "followup"
        line = f"Follow-up: {ctx.counts['resolved']} resolved, {'?' if n_open is None else n_open} still open."

    try:
        existing = find_overview(ctx)
    except ERRORS as e:
        print(f"::warning::Reading the overview comment failed: {type(e).__name__}")
        existing = None
    old = (existing or {}).get("body") or ""
    history = read_history(old)
    if decision == "none" and full and any(h["run"] == int(ctx.run_id) and h["sha"] == ctx.head[:7] for h in history):
        # "Re-run all jobs" that ends without a verdict: its note would replace what an earlier attempt posted.
        print("No verdict on a re-run: keeping this run's posted result")
        return
    st = {
        "comment": existing, "result": result, "line": line, "resolved": resolved, "open": open_links,
        "fallback": [],
        "slot": overview_slot(data["overview"]) if full and not data["stopped"] else "" if full else old_slot(old),
        "history": merge_history(history, {"sha": ctx.head[:7], "mode": ctx.mode, "result": result, "n": n_found,
                                       "b": len(in_body), "run": int(ctx.run_id), "attempt": int(ctx.attempt)}),
    }
    if not full:
        # Only threads are judged here: findings the last full review left without a thread (in its body, or in the
        # overview when it couldn't be posted) aren't. No `@claude` in the note: an App post could trigger other
        # workflows that listen for it.
        last_full = next((h for h in st["history"][1:] if h["result"] != "followup"), None)
        unchecked = (last_full or {}).get("b", 0)
        if unchecked:
            ctx.unchecked = (f"{unchecked} finding{'s' if unchecked != 1 else ''} without a review thread "
                             f"{'were' if unchecked != 1 else 'was'}n't re-checked: only a full review checks "
                             f"{'them' if unchecked != 1 else 'it'}.")
            st["line"] += " " + ctx.unchecked
    overview_url = write_overview(ctx, st)

    outcome, review, inline, in_body = verdict(ctx, decision, overview_url, inline, in_body, n_open)
    if full:   # the findings left without a thread, as posted (a 422 retry puts every finding in the body)
        st["history"][0]["b"] = n_found if outcome in ("own", "failed") else len(in_body)
    if outcome == "failed":
        ctx.failed += 1
        if result == "clean":   # a clean overview would mark this head covered, so a new request couldn't retry
            st["result"] = st["history"][0]["result"] = "issues"
            st["line"] = "No issues found, but posting the approval failed."
    if outcome in ("own", "failed") and n_found:
        st["fallback"] = inline + in_body
        st["line"] = ("GitHub doesn't let the App review its own PR; the findings are below." if outcome == "own"
                      else "Posting the review failed; the findings are below.")
    elif outcome == "landed" and full:
        # "Re-run all jobs": report the review that was posted, not this attempt's result.
        try:
            urls, read = review_comment_urls(ctx, review), True
        except ERRORS:
            urls, read = [], False
        body = review.get("body") or ""
        n_body = body.count(FINDING_MARK)
        n_found = len(urls) + n_body
        st["history"][0].update(n=n_found, b=n_body)
        st["slot"] = old_slot(old) or st["slot"]   # the paragraph the landed attempt wrote
        if n_found:
            st["result"] = st["history"][0]["result"] = "issues"
            st["line"] = findings_line(n_found, urls, n_body, review)
        elif n_open:   # it asked for changes on the open threads (a COMMENT when CHANGES_EVENT says so)
            st["result"] = st["history"][0]["result"] = "issues"
            st["line"] = f"No new findings; {n_open} thread(s) still open."
        elif read and (review.get("state") == "APPROVED"
                       or review.get("state") == "COMMENTED" and "No issues found at " in body):   # a fork's approval
            st["result"] = st["history"][0]["result"] = "clean"
            st["line"] = "No issues found."
        else:   # a change request whose threads were resolved since, or its comments couldn't be read: never clean
            st["result"] = st["history"][0]["result"] = "issues"
            st["line"] = "This run's review was already posted: see it on the PR."
    elif outcome == "submitted" and n_found:
        try:
            urls = review_comment_urls(ctx, review) if inline else []
        except ERRORS:
            urls = []
        st["line"] = findings_line(n_found, urls, len(in_body), review)
        if inline:
            try:   # this review's inline findings opened new threads
                st["resolved"], st["open"] = scan_threads(ctx)
            except ERRORS as e:
                print(f"::warning::Counting the review threads again failed: {type(e).__name__}")
    write_overview(ctx, st)


def findings_line(n_found, urls, n_body, review):
    """The overview's result line for a posted review with findings: numbered links, and how many are in its body."""
    links = " ".join(f"[{i}]({u})" for i, u in enumerate(urls, 1))
    body_note = ""
    if n_body:
        where = f"[review body]({review['html_url']})" if safe_url(review.get("html_url")) else "review body"
        body_note = f" ({n_body} in the {where})"
    line = f"{n_found} finding{'s' if n_found != 1 else ''}" + (f": {links}" if links else "") + body_note
    return line if links or body_note else line + "."


def verdict(ctx, decision, overview_url, inline, in_body, n_open):
    """Applies the transition table. Returns (outcome, review, inline, body), the last two as submitted. outcome:
    none (no verdict this run), kept (the App's review already says it), landed (a re-run: this run's review exists),
    submitted, own (GitHub refuses a review of the App's own PR), failed."""
    if decision == "none":
        return "none", None, inline, in_body
    try:
        reviews = app_reviews(ctx)
    except ERRORS as e:
        print(f"::warning::Reading the App's reviews failed: {type(e).__name__} {getattr(e, 'status', '')}".rstrip())
        ctx.verdict = "failed"
        return "failed", None, inline, in_body
    landed = run_review(ctx, reviews)
    if landed:
        print("This run's review was already submitted (a re-run): not submitting another")
        ctx.verdict = "already submitted"
        return "landed", landed, inline, in_body
    latest = effective(reviews)
    state = latest["state"] if latest else None
    short = f"`{ctx.head[:7]}`"
    n_found = len(inline) + len(in_body)

    if decision == "approve":
        if state == "APPROVED" and latest.get("commit_id") == ctx.head:
            return "kept", None, inline, in_body
        # A push to a fork PR never reaches `publish`, so its approval could never be dismissed: COMMENT instead.
        event, line = "COMMENT" if ctx.cross_repo else ctx.approve_event, f"No issues found at {short}."
        if state == "CHANGES_REQUESTED" and event == "COMMENT":
            dismiss(ctx, latest, "No issues found in a later review.", STALE_CHANGES)
    elif decision in ("changes+findings", "changes"):
        if decision == "changes" and state == "CHANGES_REQUESTED":
            return "kept", None, inline, in_body
        event = ctx.changes_event
        line = (f"{n_found} finding{'s' if n_found != 1 else ''} at {short}." if decision == "changes+findings"
                else f"{n_open} review thread(s) still open at {short}.")
        if state == "APPROVED" and event == "COMMENT":
            dismiss(ctx, latest, "New findings since this approval.", STALE_APPROVAL)
    else:   # clear
        if state != "CHANGES_REQUESTED":
            return "kept", None, inline, in_body
        dismiss(ctx, latest, "Findings addressed.", STALE_CHANGES)
        event, line = "COMMENT", "Findings addressed; new code was not re-reviewed."
        if ctx.unchecked:
            line += " " + ctx.unchecked

    review, inline, in_body = submit(ctx, event, line, overview_url, inline, in_body)
    if review is None:
        print("::error::Submitting the review failed twice: the findings are in the overview comment")
        ctx.verdict = "failed"
        return "failed", None, inline, in_body
    if review == "own":
        ctx.verdict = "own PR"
        return "own", None, inline, in_body
    ctx.verdict = event
    ctx.counts["inline"], ctx.counts["body"] = len(inline), len(in_body)
    ctx.counts["moved"] = sum(1 for f in inline if f.get("moved"))
    if event == "APPROVE":
        # A push after the head check would leave this approval on older code, and that push's own dismissal
        # check may have run before it landed.
        try:
            moved = current_head(ctx) != ctx.head
        except ERRORS as e:
            print(f"::warning::Re-reading the PR head after the approval failed: {type(e).__name__}")
            ctx.stale.append(UNCHECKED_APPROVAL)
            moved = False
        if moved:
            dismiss(ctx, dict(review, state="APPROVED"), "New commits arrived while this approval was posted.",
                    STALE_APPROVAL)
    return "submitted", review, inline, in_body


def main(env=None):
    ctx = Ctx(os.environ if env is None else env)
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", ctx.app_login):
        print("::error::The App login (CLAUDE_REVIEW_APP_LOGIN) is missing or malformed")
        return 1
    try:
        publish(ctx)
    finally:
        if ctx.stale and not ctx.overview_written:
            note_stale_on_overview(ctx)
        c = ctx.counts
        summary = (f"Publish: {c['inline']} inline, {c['body']} in body, {c['dropped']} dropped, "
                   f"{c['moved']} moved, verdict {ctx.verdict}, "
                   f"{c['replied']} replied, {c['resolved']} resolved, {c['reopened']} reopened, "
                   f"{c['dismissed']} dismissed, "
                   f"{c['skipped']} skipped, {ctx.failed} failed")
        print(summary)
        for reason, n in sorted(ctx.reasons.items()):
            print(f"  skipped, {reason}: {n}")
        if ctx.env.get("GITHUB_STEP_SUMMARY"):
            with open(ctx.env["GITHUB_STEP_SUMMARY"], "a") as f:
                f.write(summary + "\n")
    return 1 if ctx.failed else 0


if __name__ == "__main__":
    sys.exit(main())
