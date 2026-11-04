"""An in-memory GitHub for the workflow's scripts: the REST and GraphQL calls they make, served through a fake
urllib.request.urlopen. Patch it in with `unittest.mock.patch("urllib.request.urlopen", gh.urlopen)`."""
import email.message, io, json, re, urllib.error, urllib.parse

API = "https://api.github.test"
GRAPHQL = API + "/graphql"
WEB = "https://github.test/o/r/pull/7"
REPO, NUMBER = "o/r", 7
APP = "notitial"
APP_TOKEN, GH_TOKEN = "app-token", "gh-token"


def headers(values=None):
    h = email.message.Message()
    for k, v in (values or {}).items():
        h[k] = v
    return h


class Response:
    def __init__(self, status, body, hdrs):
        self.status, self.headers = status, hdrs
        self._raw = b"" if body is None else json.dumps(body).encode()

    def read(self):
        return self._raw

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def bot(login):
    """A bot author as GraphQL shows it (login without [bot])."""
    return {"__typename": "Bot", "login": login}


def user(login):
    return {"__typename": "User", "login": login}


class FakeGitHub:
    def __init__(self, head="a" * 40, page_size=100):
        self.head = head
        self.page_size = page_size
        self.files = []            # {"filename", "patch"?}
        self.reviews = []          # REST review objects
        self.review_comments = []  # REST review comments: also the first comment of a thread
        self.issue_comments = []
        self.threads = {}          # id -> {"isResolved", "isOutdated", "path", "line", "originalLine", "comments": [...]}
        self.calls = []            # (method, route, token)
        self.failures = {}         # route -> [(status, body, landed)], raised in order
        self.cross_repo = False    # the PR's head is in a fork
        self.on_submit = None      # called after a review lands (e.g. to simulate a push)
        self.next_id = 1000

    # --- setup helpers ---

    def new_id(self):
        self.next_id += 1
        return self.next_id

    def add_file(self, filename, patch=None):
        self.files.append({"filename": filename, "status": "modified", **({"patch": patch} if patch else {})})

    def add_review(self, state, body="", commit_id=None, login=APP + "[bot]"):
        r = {"id": self.new_id(), "user": {"login": login}, "state": state, "body": body,
             "commit_id": commit_id or self.head}
        r["html_url"] = f"{WEB}#pullrequestreview-{r['id']}"
        self.reviews.append(r)
        return r

    def add_issue_comment(self, body, login=APP + "[bot]"):
        c = {"id": self.new_id(), "user": {"login": login}, "body": body}
        c["html_url"] = f"{WEB}#issuecomment-{c['id']}"
        self.issue_comments.append(c)
        return c

    def add_thread(self, author, body="An issue.", path="src/a.py", line=3, resolved=False, number=NUMBER):
        cid = self.new_id()
        tid = f"PRRT_{cid}"
        self.threads[tid] = {"isResolved": resolved, "isOutdated": False, "path": path, "line": line,
                             "originalLine": line, "comments": [], "number": number}
        self.thread_comment(tid, author, body, cid)
        return tid

    def thread_comment(self, tid, author, body, cid=None):
        cid = cid or self.new_id()
        self.threads[tid]["comments"].append({
            "fullDatabaseId": str(cid), "author": author, "body": body, "createdAt": "2026-10-22T00:00:00Z",
            "diffHunk": "@@", "url": f"{WEB}#discussion_r{cid}"})
        return cid

    def fail(self, route, status, message="", landed=False, errors=None):
        body = {"message": message, **({"errors": errors} if errors is not None else {})}
        self.failures.setdefault(route, []).append((status, body, landed))

    # --- views for assertions ---

    def app_reviews(self):
        return [r for r in self.reviews if r["user"]["login"] == APP + "[bot]"]

    def overviews(self):
        return [c for c in self.issue_comments if c["body"].startswith("<!-- claude-review:summary ")]

    def tokens(self, route):
        return {t for m, r, t in self.calls if r == route}

    # --- the fake urlopen ---

    def urlopen(self, req, timeout=None):
        url = req.full_url
        method = req.get_method()
        token = (req.get_header("Authorization") or "").removeprefix("bearer ")
        payload = json.loads(req.data) if req.data else None
        status, body, hdrs = self.route(method, url, token, payload)
        if status >= 400:
            raise urllib.error.HTTPError(url, status, "error", hdrs, io.BytesIO(json.dumps(body).encode()))
        return Response(status, body, hdrs)

    def injected(self, route):
        queue = self.failures.get(route)
        return queue.pop(0) if queue else None

    def page(self, items, url):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
        page = int(query.get("page", ["1"])[0])
        start = (page - 1) * self.page_size
        hdrs = {}
        if start + self.page_size < len(items):
            base = url.split("?")[0]
            hdrs["Link"] = f'<{base}?per_page=100&page={page + 1}>; rel="next"'
        return 200, items[start:start + self.page_size], headers(hdrs)

    def route(self, method, url, token, payload):
        if url == GRAPHQL:
            return self.graphql(token, payload)
        path = urllib.parse.urlsplit(url).path
        assert url.startswith(API), url
        pr = f"/repos/{REPO}/pulls/{NUMBER}"
        routes = [
            ("GET", rf"{pr}/reviews", "list reviews"),
            ("POST", rf"{pr}/reviews", "submit review"),
            ("PUT", rf"{pr}/reviews/(\d+)/dismissals", "dismiss"),
            ("GET", rf"{pr}/reviews/(\d+)/comments", "review comments"),
            ("GET", rf"{pr}/files", "files"),
            ("POST", rf"{pr}/comments/(\d+)/replies", "reply"),
            ("GET", rf"/repos/{REPO}/issues/{NUMBER}/comments", "list issue comments"),
            ("POST", rf"/repos/{REPO}/issues/{NUMBER}/comments", "post issue comment"),
            ("PATCH", rf"/repos/{REPO}/issues/comments/(\d+)", "edit issue comment"),
        ]
        for m, pattern, name in routes:
            match = re.fullmatch(pattern, path)
            if m == method and match:
                self.calls.append((method, name, token))
                failure = self.injected(name)
                if failure:
                    status, body, landed = failure
                    if landed:
                        getattr(self, "r_" + name.replace(" ", "_"))(token, payload, *match.groups())
                    return status, body, headers({})
                return getattr(self, "r_" + name.replace(" ", "_"))(token, payload, *match.groups(), url=url)
        raise AssertionError(f"unexpected call {method} {path}")

    # --- REST ---

    def r_list_reviews(self, token, payload, url=None):
        return self.page(sorted(self.reviews, key=lambda r: r["id"]), url)

    def r_submit_review(self, token, payload, url=None):
        assert token == APP_TOKEN
        for c in payload.get("comments", []):
            if c["path"] not in {f["filename"] for f in self.files}:
                return 422, {"message": "Validation Failed"}, headers({})
        state = {"APPROVE": "APPROVED", "REQUEST_CHANGES": "CHANGES_REQUESTED", "COMMENT": "COMMENTED"}[payload["event"]]
        r = self.add_review(state, payload["body"], payload["commit_id"])
        r["event"] = payload["event"]
        for c in payload.get("comments", []):
            cid = self.new_id()
            self.review_comments.append({"id": cid, "review_id": r["id"], **c,
                                         "html_url": f"{WEB}#discussion_r{cid}", "user": {"login": APP + "[bot]"}})
            tid = f"PRRT_{cid}"
            self.threads[tid] = {"isResolved": False, "isOutdated": False, "path": c["path"], "line": c["line"],
                                 "originalLine": c["line"], "comments": [], "number": NUMBER}
            self.thread_comment(tid, bot(APP), c["body"], cid)
        if self.on_submit:
            self.on_submit(r)
        return 200, r, headers({})

    def r_dismiss(self, token, payload, rid, url=None):
        r = next(r for r in self.reviews if r["id"] == int(rid))
        if r["state"] not in ("APPROVED", "CHANGES_REQUESTED"):
            return 422, {"message": "Can not dismiss a review in this state"}, headers({})
        r["state"] = "DISMISSED"
        r["dismiss_message"] = payload["message"]
        return 200, r, headers({})

    def r_review_comments(self, token, payload, rid, url=None):
        return self.page([c for c in self.review_comments if c["review_id"] == int(rid)], url)

    def r_files(self, token, payload, url=None):
        return self.page(self.files, url)

    def r_reply(self, token, payload, first_id, url=None):
        tid = next(t for t, th in self.threads.items() if th["comments"][0]["fullDatabaseId"] == first_id)
        cid = self.thread_comment(tid, bot(APP) if token == APP_TOKEN else bot("github-actions"), payload["body"])
        return 201, {"id": cid}, headers({})

    def r_list_issue_comments(self, token, payload, url=None):
        return self.page(sorted(self.issue_comments, key=lambda c: c["id"]), url)

    def r_post_issue_comment(self, token, payload, url=None):
        assert token == APP_TOKEN
        return 201, self.add_issue_comment(payload["body"]), headers({})

    def r_edit_issue_comment(self, token, payload, cid, url=None):
        assert token == APP_TOKEN
        c = next(c for c in self.issue_comments if c["id"] == int(cid))
        c["body"] = payload["body"]
        return 200, c, headers({})

    # --- GraphQL ---

    def graphql(self, token, payload):
        q, v = payload["query"], payload["variables"]
        if "unresolveReviewThread" in q:
            self.calls.append(("POST", "unresolve", token))
            failure = self.injected("unresolve")
            if failure:
                return failure[0], failure[1], headers({})
            if token != GH_TOKEN:
                return 200, {"errors": [{"type": "FORBIDDEN"}]}, headers({})
            self.threads[v["id"]]["isResolved"] = False
            return 200, {"data": {"unresolveReviewThread": {"thread": {"isResolved": False}}}}, headers({})
        if "resolveReviewThread" in q:
            self.calls.append(("POST", "resolve", token))
            failure = self.injected("resolve")
            if failure:
                return failure[0], failure[1], headers({})
            if token != GH_TOKEN:
                return 200, {"errors": [{"type": "FORBIDDEN"}]}, headers({})
            self.threads[v["id"]]["isResolved"] = True
            return 200, {"data": {"resolveReviewThread": {"thread": {"isResolved": True}}}}, headers({})
        if "reviewThreads(first: 100, after: $after)" in q:
            self.calls.append(("POST", "scan threads", token))
            ids = list(self.threads)
            start = int(v["after"] or 0)
            chunk = ids[start:start + self.page_size]
            more = start + self.page_size < len(ids)
            nodes = [{"isResolved": self.threads[t]["isResolved"], "path": self.threads[t]["path"],
                      "line": self.threads[t]["line"], "originalLine": self.threads[t]["originalLine"],
                      "comments": {"nodes": [{"author": self.threads[t]["comments"][0]["author"],
                                              "url": self.threads[t]["comments"][0]["url"]}]}} for t in chunk]
            return 200, {"data": {"repository": {"pullRequest": {"reviewThreads": {
                "pageInfo": {"hasNextPage": more, "endCursor": str(start + self.page_size)}, "nodes": nodes}}}}}, headers({})
        if "comments(first: 50)" in q:
            self.calls.append(("POST", "collect", token))
            nodes = [{"id": t, "isResolved": th["isResolved"], "isOutdated": th["isOutdated"], "path": th["path"],
                      "line": th["line"], "originalLine": th["originalLine"],
                      "comments": {"pageInfo": {"hasNextPage": False}, "nodes": th["comments"]}}
                     for t, th in self.threads.items()]
            return 200, {"data": {"repository": {"pullRequest": {"headRefOid": self.head, "reviewThreads": {
                "pageInfo": {"hasNextPage": False}, "nodes": nodes}}}}}, headers({})
        if "node(id: $id)" in q:
            self.calls.append(("POST", "thread", token))
            th = self.threads.get(v["id"])
            if th is None:
                return 200, {"data": {"node": None}}, headers({})
            first, last = th["comments"][0], th["comments"][-1]
            return 200, {"data": {"node": {
                "isResolved": th["isResolved"],
                **({"pullRequest": {"number": th["number"], "repository": {"nameWithOwner": th.get("repo", "o/r")}}}
                   if "pullRequest { number" in q else {}),
                "first": {"nodes": [{"fullDatabaseId": first["fullDatabaseId"], "author": first["author"]}]},
                "last": {"nodes": [{"fullDatabaseId": last["fullDatabaseId"], "author": last["author"],
                                    "body": last["body"]}]}}}}, headers({})
        if "headRefOid" in q:
            self.calls.append(("POST", "head", token))
            failure = self.injected("head")
            if failure:
                return failure[0], failure[1], headers({})
            pr = {"headRefOid": self.head, **({"isCrossRepository": self.cross_repo} if "isCrossRepository" in q else {})}
            return 200, {"data": {"repository": {"pullRequest": pr}}}, headers({})
        raise AssertionError("unexpected GraphQL query")
