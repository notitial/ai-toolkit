import json, os, re, sys, urllib.error, urllib.request
from collections import Counter

# This workflow's markers. Only text this script builds from validated fields (hex, enums, ints) ever sits inside one.
FOLLOWUP_MARKER = re.compile(
    r"<!-- claude-review:followup verdict=(resolved|open) sha=([0-9a-f]{40})(?: mode=(rereview|followup))? -->")
SUMMARY_PREFIX = "<!-- claude-review:summary "
# Starts every inline suggestion (a non-blocking comment): a thread that opens with it never counts as open.
SUGGESTION_MARKER = "<!-- claude-review:suggestion -->"
SLOT_OPEN, SLOT_CLOSE = "<!-- claude-review:overview -->", "<!-- /claude-review:overview -->"
MODES = ("initial", "rereview", "followup")
# Fences GitHub renders as something richer than code (diagrams, maps, 3D, math): their content is treated as prose.
RICH_FENCES = {"mermaid", "geojson", "topojson", "stl", "math"}
FORBIDDEN = ("<!--", "-->", "claude-review:")
ZWSP = "\u200b"
BODY_BUDGET = 60000   # GitHub's limit for a review or comment body is 65536 characters
SCHEMA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "reviewer", "result-schema.json")
ERRORS = (OSError, ValueError, RuntimeError, KeyError, TypeError, IndexError)


class ApiError(RuntimeError):
    def __init__(self, status):
        super().__init__(f"HTTP {status}")
        self.status = status


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
            raise ApiError(e.code) from None


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
        self.counts = Counter(replied=0, resolved=0, dismissed=0, inline=0, body=0, dropped=0,
                              moved=0, skipped=0, suggested=0)
        self.suggestions = []   # placed suggestions: inline comments that ride on the review, whatever its verdict
        self.reasons = Counter()
        self.failed = 0
        self.verdict = "none"

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


def by_app(ctx, c):
    """A comment the App posted: an inline finding (it starts a thread) or a reply of this workflow."""
    return author(c) == ("Bot", ctx.app_login)


def on_this_pr(ctx, node):
    """A thread node on this repository's PR (an App can be installed on several repositories)."""
    pr = node.get("pullRequest") or {}
    repo = (pr.get("repository") or {}).get("nameWithOwner") or ""
    return pr.get("number") == ctx.number and repo.lower() == ctx.repo.lower()


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


def conforms(schema, value, root):
    """Whether `value` fits `schema`: the JSON Schema subset result-schema.json uses (type, enum, minLength, maxLength, maxItems,
    properties, required, additionalProperties false, items, and a local $ref)."""
    if "$ref" in schema:
        node = root
        for part in schema["$ref"][2:].split("/"):   # "#/$defs/name"
            node = node[part]
        return conforms(node, value, root)
    kind = schema.get("type")
    if kind == "integer" and not is_int(value):
        return False
    if kind in ("object", "array", "string", "boolean") and not isinstance(
            value, {"object": dict, "array": list, "string": str, "boolean": bool}[kind]):
        return False
    if "enum" in schema and value not in schema["enum"]:
        return False
    if kind == "string":
        return schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", len(value))
    if kind == "array":
        return len(value) <= schema.get("maxItems", len(value)) and all(conforms(schema["items"], v, root) for v in value)
    if kind == "object":
        props = schema["properties"]
        return (set(schema.get("required", ())) <= set(value) and set(value) <= set(props)
                and all(conforms(props[k], v, root) for k, v in value.items()))
    return True


def load_result(path):
    """(result, None) when the file holds a result that fits the result schema, else (None, why)."""
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
    try:
        with open(SCHEMA, encoding="utf-8") as f:
            schema = json.load(f)
    except (OSError, ValueError):
        return None, "the result schema is missing"
    return (data, None) if conforms(schema, data, schema) else (None, "the wrong shape")


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
    """Claude's reply, sanitized like a finding and quoted, then this workflow's marker for the head. Tabs are expanded
    first: the "> " prefix shifts a tab stop, so a tab-indented fence line would count differently quoted than judged."""
    text = sanitize(text.expandtabs(4)).strip() or (
        "The current code handles this." if verdict == "resolved" else "This still looks open in the current code.")
    quoted = "\n".join("> " + line for line in text.split("\n"))   # not splitlines(): sanitize() saw only "\n" as a line break
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


def open_thread(ctx, thread_id, token=None):
    """The thread when it is on this PR, this review started it and it is still open. Else None, counted as skipped."""
    node = gql(ctx, THREAD, {"id": thread_id}, token=token)["node"]
    if not node or not node["first"]["nodes"] or not node["last"]["nodes"]:
        reason = "thread gone"
    elif not on_this_pr(ctx, node):
        reason = "thread on another PR"
    elif not by_app(ctx, node["first"]["nodes"][0]):
        reason = "not a Claude thread"
    elif node["isResolved"]:
        reason = "already resolved"
    else:
        return node
    ctx.skip(reason)
    return None


def marker_verdict(ctx, comment, head):
    """(verdict, mode) of a valid marker: posted by this workflow, for the current head. Else (None, None)."""
    if not by_app(ctx, comment):
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
            node = open_thread(ctx, thread_id)
            if not node:
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

def resolve_threads(ctx, ids):
    """Resolves a thread only if this review started it, it's still open, and its last comment is this workflow's
    `verdict=resolved` marker for the head the review judged."""
    forbidden = False
    for thread_id in dict.fromkeys(ids):
        try:
            node = open_thread(ctx, thread_id, token=ctx.gh_token)
            if not node:
                continue
            last = node["last"]["nodes"][0]
            m = FOLLOWUP_MARKER.search(last.get("body") or "")
            if not by_app(ctx, last) or not m or m.group(1, 2) != ("resolved", ctx.head):
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


THREADS = """
query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { isResolved path line originalLine comments(first: 1) { nodes { author { __typename login } url body } } }
      }
    }
  }
}
"""


def scan_threads(ctx):
    """(resolved count, [(path, line, url)] of the open ones) over every thread this review started, suggestion
    threads excepted: they never block, so they are not counted."""
    resolved, open_links, after = 0, [], None
    for _ in range(30):
        page = gql(ctx, THREADS, {"owner": ctx.owner, "name": ctx.name, "number": ctx.number, "after": after})
        threads = page["repository"]["pullRequest"]["reviewThreads"]
        for t in threads["nodes"]:
            first = (t["comments"]["nodes"] or [None])[0]
            if not first or not by_app(ctx, first) or (first.get("body") or "").startswith(SUGGESTION_MARKER):
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
        item = f"**{code_path(f['path'])} line {f['line']}**\n\n{f['text']}"
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


def dismiss(ctx, review, message):
    """Dismisses the App's review. True when it is dismissed (an already dismissed one included), else the job fails."""
    try:
        rest(ctx, "PUT", f"/repos/{ctx.repo}/pulls/{ctx.number}/reviews/{review['id']}/dismissals",
             {"message": message, "event": "DISMISS"})
        ctx.counts["dismissed"] += 1
    except ERRORS as e:
        if isinstance(e, ApiError) and e.status == 422:
            return True   # already dismissed
        ctx.fail("Dismissing the App's review", e)
        return False
    return True


def dismiss_stale_approval(ctx):
    """A push dismisses the App's APPROVE for an older commit. CHANGES_REQUESTED is never dismissed by a push."""
    try:
        head = current_head(ctx)
        latest = effective(app_reviews(ctx))
    except ERRORS as e:
        ctx.fail("Checking for a stale approval", e)
        return
    if latest and latest["state"] == "APPROVED" and latest.get("commit_id") != head:
        dismiss(ctx, latest, "New commits since this approval.")


def review_body(ctx, line, overview_url, body_findings):
    first = line + (f" See the [review overview]({overview_url})." if safe_url(overview_url) else "")
    parts = [f"<!-- claude-review:review run={ctx.run_id} attempt={ctx.attempt} sha={ctx.head} -->\n{first}"]
    if body_findings:
        parts += ["**Not on a changed line:**"] + finding_items(body_findings, BODY_BUDGET - 1000)
    return "\n\n".join(parts)


def submit(ctx, event, line, overview_url, inline, body_findings):
    """Submits one review; GitHub's 422 (it refuses an inline comment) is tried again without the suggestions, then
    with every finding in the body. Returns (review, inline findings it carries, body findings it carries); the review is None when the write
    failed, which fails the job: the re-run finds no review of this run and tries again."""
    for _ in range(3):
        payload = {"commit_id": ctx.head, "event": event,
                   "body": review_body(ctx, line, overview_url, body_findings)}
        if inline or ctx.suggestions:
            payload["comments"] = [dict(f["comment"], body=f["text"]) for f in inline + ctx.suggestions]
        try:
            return rest(ctx, "POST", f"/repos/{ctx.repo}/pulls/{ctx.number}/reviews", payload), inline, body_findings
        except ERRORS as e:
            if not (isinstance(e, ApiError) and e.status == 422 and (inline or ctx.suggestions)):
                ctx.fail("Submitting the review", e)
                break
            if ctx.suggestions:   # a suggestion is the first thing to give up
                print("Submitting the review failed: HTTP 422; trying again without the suggestions")
                ctx.suggestions = []
                continue
            print("Submitting the review failed: HTTP 422; trying again with every finding in the body")
            body_findings, inline = inline + body_findings, []
    return None, inline, body_findings


# --- The sticky overview comment: one render of the current state, edited in place ---

def find_overview(ctx):
    found = [c for c in paginate(ctx, f"/repos/{ctx.repo}/issues/{ctx.number}/comments")
             if isinstance(c, dict) and (c.get("user") or {}).get("login") == ctx.app_bot
             and (c.get("body") or "").startswith(SUMMARY_PREFIX)]
    if len(found) > 1:
        print(f"::warning::{len(found)} overview comments from the App: editing the newest")
    return max(found, key=lambda c: c["id"]) if found else None


def old_slot(body):
    """Claude's paragraph in an earlier overview: a follow-up judges threads only, so it carries the paragraph over."""
    i, j = body.find(SLOT_OPEN), body.find(SLOT_CLOSE)
    return body[i + len(SLOT_OPEN):j].strip("\n") if 0 <= i < j else ""


def threads_line(threads):
    if threads is None:
        return "**Threads:** couldn't be counted."
    resolved, open_links = threads
    text = f"**Threads:** {resolved} resolved · {len(open_links)} still open"
    if open_links:
        links = []
        for path, line, url in open_links[:10]:
            label = code_path(f"{path}:{line}" if line else path)
            links.append(f"[{label}]({url})" if safe_url(url) else label)
        more = len(open_links) - 10
        text += ": " + ", ".join(links) + (f", and {more} more" if more > 0 else "")
    return text


def write_overview(ctx, comment, result, line, slot, threads):
    """PATCH the App's overview comment, or POST one. Returns the comment, or None when the write failed (the job
    fails)."""
    body = "\n\n".join([
        f"{SUMMARY_PREFIX}sha={ctx.head} result={result} -->\n### Claude review · `{ctx.head[:7]}` · {ctx.mode}",
        f"**Result:** {line}",
        SLOT_OPEN + ("\n" + slot if slot else "") + "\n" + SLOT_CLOSE,
        threads_line(threads)])
    try:
        if comment and comment.get("body") == body:
            return comment
        if comment:
            return rest(ctx, "PATCH", f"/repos/{ctx.repo}/issues/comments/{comment['id']}", {"body": body})
        return rest(ctx, "POST", f"/repos/{ctx.repo}/issues/{ctx.number}/comments", {"body": body})
    except ERRORS as e:
        ctx.fail("Writing the overview comment", e)
        return None


# --- The run ---

def parse_ids(raw):
    try:
        ids = json.loads(raw) if raw else []
    except ValueError:
        return None
    if isinstance(ids, list) and len(ids) <= 100 and all(isinstance(i, str) and i for i in ids):
        return ids
    return None


FAILED = "A write failed: re-run this job. No verdict."


def plural(n, word):
    return f"{n} {word}{'s' if n != 1 else ''}"


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
    suggested = data.get("suggestions", []) if full and not data["stopped"] else []

    # Replies, then resolve: resolve keys on the reply's marker.
    to_resolve = list(retry)
    if data is not None and data["threads"] and ctx.mode != "initial" and not incomplete:
        to_resolve += reply_in_threads(ctx, data["threads"])
    if to_resolve:
        resolve_threads(ctx, to_resolve)
    # The run marker on a review is the only idempotency key: a run that finds its own review stops. The thread writes
    # above are idempotent, so a re-run still finishes a reply or a resolve that failed.
    try:
        found = run_review(ctx, app_reviews(ctx))
    except ERRORS as e:
        ctx.fail("Reading the App's reviews", e)
        return
    if found:
        print("This run's review was already submitted (a re-run): not submitting another")
        ctx.verdict = "already submitted"
        return
    try:
        threads = scan_threads(ctx)
    except ERRORS as e:
        ctx.fail("Counting the review threads", e)
        threads = None
    try:
        sticky = find_overview(ctx)
    except ERRORS as e:
        ctx.fail("Reading the overview comment", e)
        return

    inline, in_body = [], []
    if findings or suggested:
        try:
            files = pr_files(ctx)
        except ERRORS as e:
            print(f"::warning::Reading the PR's files failed ({type(e).__name__}): every finding goes in the review body")
            files = None
        seen = set()
        for soft, group in ((False, findings), (True, suggested)):
            for f in group:
                key = (f["path"], f["line"], f["body"])
                if key in seen:
                    continue
                seen.add(key)
                where, comment = place(f, files)
                item = {"path": f["path"], "line": comment["line"] if comment else f["line"],
                        "text": sanitize(f["body"]), "comment": comment}
                if where in ("inline", "moved"):
                    item["moved"] = where == "moved"
                    if soft:   # a suggestion is worth a comment only where it sits on its line
                        item["text"] = SUGGESTION_MARKER + "\n**Suggestion (non-blocking):**\n\n" + item["text"]
                    (ctx.suggestions if soft else inline).append(item)
                elif soft or where == "drop":
                    ctx.counts["dropped"] += 1
                else:
                    in_body.append(item)
    resolved, n_open = (threads[0], len(threads[1])) if threads is not None else (0, 0)   # a failed count fails the job
    n_found = len(inline) + len(in_body)

    if data is not None and data["stopped"]:
        decision, result, line = "none", "stopped", "Review stopped (eligibility): nothing to review. No verdict."
    elif incomplete:
        decision, result, line = "none", "issues", "Review incomplete: issues reported without findings. No verdict."
    elif full:
        if n_found:
            decision, result, line = "changes+findings", "issues", f"{plural(n_found, 'finding')}."
        elif n_open:
            decision, result, line = "changes", "issues", f"No new findings; {n_open} thread(s) still open."
        elif ctx.failed:   # a failed write never approves; it never holds back a request for changes
            decision, result, line = "none", "issues", FAILED
        elif data["no_issues"] and not data["findings"]:
            decision, result, line = "approve", "clean", "No issues found."
        else:
            decision, result, line = "none", "issues", "No finding named one of this PR's files. No verdict."
    elif threads is None:
        decision, result, line = "none", "issues", FAILED
    else:
        decision, result = "changes" if n_open else "clear", "followup"
        line = f"Follow-up: {resolved} resolved, {n_open} still open."

    if not full:
        slot = old_slot((sticky or {}).get("body") or "")
    else:
        slot = "" if data["stopped"] else overview_slot(data["overview"])
    # `clean` marks the head as covered (collect.py), so it is written only once the approval is posted.
    sticky = write_overview(ctx, sticky, "issues" if decision == "approve" else result, line, slot, threads)

    review, inline, in_body = verdict(ctx, decision, (sticky or {}).get("html_url"), inline, in_body, n_open)
    if sticky is None:
        return   # the overview write failed (the job is red); there is nothing to update
    if ctx.verdict == "failed":   # the verdict's own write failed
        result, line = "issues", FAILED
    elif review and n_found:
        # The review is posted: say where, and count the threads its inline findings opened.
        url = review.get("html_url")
        line = f"{plural(n_found, 'finding')} in the " + (f"[review]({url})." if safe_url(url) else "review.")
        if inline:
            try:
                threads = scan_threads(ctx)
            except ERRORS as e:
                ctx.fail("Counting the review threads again", e)
                threads = None
    if ctx.counts["suggested"]:   # set only when the review carrying them was posted
        line += f" {plural(ctx.counts['suggested'], 'suggestion')} (non-blocking)."
    write_overview(ctx, sticky, result, line, slot, threads)


def verdict(ctx, decision, overview_url, inline, in_body, n_open):
    """Applies the transition table. Returns (review, inline, body) as submitted; the review is None when nothing was
    posted: no verdict, the App's review already says it, or a failed write (which fails the job)."""
    if decision == "none":
        return None, inline, in_body
    try:
        latest = effective(app_reviews(ctx))   # read again: the replies and the overview took time
    except ERRORS as e:
        ctx.fail("Reading the App's reviews", e)
        ctx.verdict = "failed"
        return None, inline, in_body
    state = latest["state"] if latest else None
    short = f"`{ctx.head[:7]}`"
    n_found = len(inline) + len(in_body)

    if decision == "approve":
        if state == "APPROVED" and latest.get("commit_id") == ctx.head and not ctx.suggestions:
            return None, inline, in_body
        if ctx.failed:   # a write failed since the decision (the overview): no approval until a re-run does it all
            ctx.verdict = "failed"
            return None, inline, in_body
        # A push to a fork PR never reaches `publish`, so its approval could never be dismissed: COMMENT instead.
        event, line = "COMMENT" if ctx.cross_repo else ctx.approve_event, f"No issues found at {short}."
        if state == "CHANGES_REQUESTED" and event == "COMMENT":
            if not dismiss(ctx, latest, "No issues found in a later review."):
                ctx.verdict = "failed"
                return None, inline, in_body
    elif decision in ("changes+findings", "changes"):
        if decision == "changes" and state == "CHANGES_REQUESTED" and not ctx.suggestions:
            return None, inline, in_body
        event = ctx.changes_event
        line = (f"{plural(n_found, 'finding')} at {short}." if decision == "changes+findings"
                else f"{n_open} review thread(s) still open at {short}.")
        if state == "APPROVED" and event == "COMMENT":
            dismiss(ctx, latest, "New findings since this approval.")   # the findings are posted even if this fails
    else:   # clear
        if state != "CHANGES_REQUESTED":
            return None, inline, in_body
        if not dismiss(ctx, latest, "Findings addressed."):
            ctx.verdict = "failed"
            return None, inline, in_body
        event, line = "COMMENT", "Findings addressed; new code was not re-reviewed."

    review, inline, in_body = submit(ctx, event, line, overview_url, inline, in_body)
    if review is None:
        ctx.verdict = "failed"
        return None, inline, in_body
    ctx.verdict = event
    ctx.counts["inline"], ctx.counts["body"], ctx.counts["suggested"] = len(inline), len(in_body), len(ctx.suggestions)
    ctx.counts["moved"] = sum(1 for f in inline if f.get("moved"))
    if event == "APPROVE":
        # A push after the head check would leave this approval on older code, and that push's own dismissal
        # check may have run before it landed.
        try:
            moved = current_head(ctx) != ctx.head
        except ERRORS as e:
            ctx.fail("Re-reading the PR head after the approval", e)
            moved = False
        if moved:
            dismiss(ctx, dict(review, state="APPROVED"), "New commits arrived while this approval was posted.")
    return review, inline, in_body


def main(env=None):
    ctx = Ctx(os.environ if env is None else env)
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", ctx.app_login):
        print("::error::The App login (CLAUDE_REVIEW_APP_LOGIN) is missing or malformed")
        return 1
    try:
        publish(ctx)
    finally:
        c = ctx.counts
        summary = (f"Publish: {c['inline']} inline, {c['body']} in body, {c['dropped']} dropped, "
                   f"{c['moved']} moved, {c['suggested']} suggested, verdict {ctx.verdict}, "
                   f"{c['replied']} replied, {c['resolved']} resolved, "
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
