import json, os, re, sys, urllib.request

# This workflow's own markers, for the current head only (one review per branch state, below). A summary
# marker without `result=` is from before v2.4, when it was only posted for a clean review.
FOLLOWUP_MARKER = re.compile(
    r"<!-- claude-review:followup verdict=(resolved|open) sha=([0-9a-f]{40})(?: mode=(rereview|followup))? -->")
SUMMARY_MARKER = re.compile(
    r"<!-- claude-review:summary sha=([0-9a-f]{40})(?: result=(clean|issues|stopped|followup))? -->")
APP_LOGIN = os.environ["APP_LOGIN"]

QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      headRefOid
      reviewThreads(first: 100) {
        pageInfo { hasNextPage }
        nodes {
          id isResolved isOutdated path line originalLine
          comments(first: 50) {
            pageInfo { hasNextPage }
            nodes { fullDatabaseId author { __typename login } body createdAt diffHunk }
          }
        }
      }
    }
  }
}
"""

def gql(query, variables):
    req = urllib.request.Request(
        os.environ["GITHUB_GRAPHQL_URL"],
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={"Authorization": "bearer " + os.environ["GH_TOKEN"], "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as res:
        out = json.load(res)
    if out.get("errors"):
        sys.exit("GraphQL error: " + ", ".join(str(e.get("type", "?")) for e in out["errors"]))
    return out["data"]

def issue_comments():
    """Every top-level comment on the PR, all pages."""
    api = os.environ["GITHUB_API_URL"]
    url = f"{api}/repos/{os.environ['GITHUB_REPOSITORY']}/issues/{os.environ['PR_NUMBER']}/comments?per_page=100"
    for _ in range(50):
        req = urllib.request.Request(url, headers={
            "Authorization": "bearer " + os.environ["GH_TOKEN"], "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=30) as res:
            yield from json.load(res)
            m = re.search(r'<([^<>]+)>;\s*rel="next"', res.headers.get("Link") or "")
        if not m:
            return
        url = m.group(1)
        if not url.startswith(api + "/"):
            sys.exit("Unexpected next-page URL")
    sys.exit("Too many pages of comments")

def author(c):
    a = c.get("author") or {}
    return a.get("__typename"), a.get("login")

def who(c):
    kind, login = author(c)
    return (login or "ghost") + ("[bot]" if kind == "Bot" else "")

owner, name = os.environ["GITHUB_REPOSITORY"].split("/")
head_sha = os.environ["HEAD_SHA"]
pr = gql(QUERY, {"owner": owner, "name": name, "number": int(os.environ["PR_NUMBER"])})["repository"]["pullRequest"]
threads = pr["reviewThreads"]
if threads["pageInfo"]["hasNextPage"]:
    print("More than 100 review threads: only the first 100 are followed up")
moved = pr["headRefOid"] != head_sha
if moved:
    print("The PR moved after the checkout: no thread is followed up in this run")

def ours(c):
    """A marker this workflow posted (author the App, or github-actions before v2.4), or None."""
    return (author(c) in (("Bot", APP_LOGIN), ("Bot", "github-actions"))
            and (FOLLOWUP_MARKER.search(c.get("body") or "") or None))

mode = os.environ["REVIEW_MODE"]
open_threads, raised, long_threads, pending, retry = [], [], 0, 0, []
for t in threads["nodes"]:
    comments = t["comments"]["nodes"]
    if not comments or author(comments[0]) not in (("Bot", APP_LOGIN), ("Bot", "claude")):
        continue
    too_long = t["comments"]["pageInfo"]["hasNextPage"]
    long_threads += too_long
    if t["isResolved"]:
        continue   # a resolved thread no longer covers its issue: if the issue is back, it is an ordinary new finding
    said = [{"author": who(c), "created_at": c["createdAt"], "body": c["body"]} for c in comments]
    m = ours(comments[-1])
    if moved or too_long:
        raised.append({"thread_id": t["id"], "path": t["path"], "line": t["line"] or t["originalLine"],
                       "issue": comments[0]["body"]})
        continue
    open_threads.append({
        "thread_id": t["id"], "path": t["path"], "line": t["line"],
        "original_line": t["originalLine"], "outdated": t["isOutdated"],
        "diff_hunk": comments[0].get("diffHunk"),
        "comments": said,
        "last_comment_id": int(comments[-1]["fullDatabaseId"]),
    })
    # Covered for this head: the thread ends with this workflow's reply for this head. An `open` reply
    # covers a followup always, and a rereview only if a rereview wrote it (a followup doesn't review new
    # code). A `resolved` reply on a still-open thread means its resolve failed: covered, and queued for
    # `publish` to resolve again without running Claude.
    if m and m.group(2) == head_sha and m.group(1) == "resolved":
        retry.append(t["id"])
    elif not (m and m.group(2) == head_sha and (mode == "followup" or m.group(3) == "rereview")):
        pending += 1

with open(os.environ["THREADS_FILE"], "w") as f:
    json.dump({"head_sha": head_sha, "open": open_threads, "raised": raised}, f)
print(f"Claude's threads: {len(open_threads)} open to follow up, {len(raised)} as context ({long_threads} too long to follow)")

def summarised():
    """This head already has a clean overview from the App (or a legacy no-findings summary)."""
    return any((c.get("user") or {}).get("login") in (APP_LOGIN + "[bot]", "github-actions[bot]")
               and (m := SUMMARY_MARKER.search(c.get("body") or "")) and m.group(1) == head_sha
               and m.group(2) in (None, "clean")
               for c in issue_comments())

# One review per branch state: skip Claude when this head was already covered. That is when every open
# thread already ends with this workflow's `verdict=open` reply for this head (a `verdict=resolved` reply on
# a still-open thread doesn't count, so a failed resolve is retried), or, with no open thread, when this is a
# followup with nothing to follow up, or this head already has a clean overview. A new push or a reply
# after the follow-up makes the next request run again. A person's Unresolve alone looks like a failed
# resolve, so it is resolved again: to reopen a thread, reply in it.
if not moved and ((open_threads and not pending) or (not open_threads and (mode == "followup" or summarised()))):
    print("This head was already covered: skipping Claude. Push a change, or reply in a thread, to ask again.")
    with open(os.environ["GITHUB_OUTPUT"], "a") as f:
        f.write("covered=true\n")
        if retry:
            print(f"Queued {len(retry)} thread(s) for publish to resolve again")
            f.write(f"retry_ids={json.dumps(retry)}\n")
