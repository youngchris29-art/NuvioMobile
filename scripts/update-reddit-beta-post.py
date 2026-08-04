#!/usr/bin/env python3
"""Update the "Latest build" changelog block in the r/Nuvio beta thread's post body.

The beta thread (https://www.reddit.com/r/Nuvio/comments/1v26ebw/) carries a
"Latest build: beta N (build M)" section right under the download link, so the
post body always describes what releases/latest actually serves. This script
swaps that block for a new one at release time.

It deliberately does NOT write the changelog for you. The Reddit changelog is
hand-written prose with its own constraints (no em dashes, straight quotes, and
wording that avoids the Automod rules that have tripped this sub before); text
generated from commit subjects would read badly and risk removal. Pass a file
you wrote, the same way scripts/release-beta.sh takes --changelog.

Credentials come from the environment, never from the repo. Create a "script"
app at https://www.reddit.com/prefs/apps (the account must be the post author)
and export:

    REDDIT_CLIENT_ID, REDDIT_CLIENT_SECRET, REDDIT_USERNAME, REDDIT_PASSWORD

Usage:
    update-reddit-beta-post.py --changelog notes.md [--post-id 1v26ebw]
                               [--dry-run] [--yes]
    update-reddit-beta-post.py --self-test

    --dry-run    Fetch and show the diff, write nothing. Needs credentials
                 (Reddit returns 403 for unauthenticated reads).
    --yes        Skip the confirmation prompt. For non-interactive release runs.
    --self-test  Run the block-replacement logic against fixtures and exit.
                 Needs no credentials and no network.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_POST_ID = "1v26ebw"
USER_AGENT = "nuviotv-release/1.0 (beta thread changelog updater)"

# The block runs from the "Latest build:" heading through the build-number line
# that closes it. Both anchors are part of the published format, so a post that
# has drifted from it fails loudly below rather than being silently mangled.
BLOCK_START = re.compile(r"^\*\*Latest build:.*$", re.MULTILINE)
BLOCK_END = re.compile(r"^Settings -> About should read.*$", re.MULTILINE)
# Where the block goes when the post does not have one yet. The live post writes
# this line bold ("**Download the beta IPA:** <url>"), so the leading asterisks
# are optional here rather than assumed away.
ANCHOR = re.compile(r"^\**Download the beta IPA:.*$", re.MULTILINE)


class BlockError(RuntimeError):
    """The post body is not in the shape this script knows how to edit."""


def replace_block(body: str, new_block: str) -> tuple[str, str]:
    """Return (new_body, action). Pure: no network, no globals. See --self-test.

    action is "replaced" when an existing block was swapped, "inserted" when the
    block was added after the download link for the first time.
    """
    new_block = new_block.strip()
    if not new_block:
        raise BlockError("changelog is empty")

    starts = list(BLOCK_START.finditer(body))
    if len(starts) > 1:
        raise BlockError(
            f"found {len(starts)} 'Latest build:' headings; expected at most 1. "
            "Fix the post by hand so there is exactly one."
        )

    if starts:
        start = starts[0]
        ends = [m for m in BLOCK_END.finditer(body) if m.start() > start.start()]
        if not ends:
            raise BlockError(
                "found a 'Latest build:' heading but no closing "
                "'Settings -> About should read ...' line after it"
            )
        end = ends[0]
        return body[: start.start()] + new_block + body[end.end() :], "replaced"

    anchors = list(ANCHOR.finditer(body))
    if len(anchors) != 1:
        raise BlockError(
            f"no existing block, and found {len(anchors)} 'Download the beta IPA:' "
            "lines to anchor to; expected exactly 1"
        )
    at = anchors[0].end()
    return body[:at] + "\n\n" + new_block + body[at:], "inserted"


def _api(method: str, url: str, token: str | None = None, data: dict | None = None,
         auth: tuple[str, str] | None = None) -> dict:
    body = urllib.parse.urlencode(data).encode() if data else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("User-Agent", USER_AGENT)
    if token:
        req.add_header("Authorization", f"bearer {token}")
    if auth:
        import base64
        raw = base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()
        req.add_header("Authorization", f"Basic {raw}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:400]
        raise SystemExit(f"error: {method} {url} -> HTTP {exc.code}\n{detail}") from exc


def get_token() -> str:
    missing = [k for k in ("REDDIT_CLIENT_ID", "REDDIT_CLIENT_SECRET",
                           "REDDIT_USERNAME", "REDDIT_PASSWORD") if not os.environ.get(k)]
    if missing:
        raise SystemExit(
            "error: missing credentials: " + ", ".join(missing) + "\n"
            "       Create a 'script' app at https://www.reddit.com/prefs/apps as the\n"
            "       post author and export those four variables. They are read from the\n"
            "       environment only; do not put them in the repo."
        )
    out = _api(
        "POST", "https://www.reddit.com/api/v1/access_token",
        auth=(os.environ["REDDIT_CLIENT_ID"], os.environ["REDDIT_CLIENT_SECRET"]),
        data={"grant_type": "password",
              "username": os.environ["REDDIT_USERNAME"],
              "password": os.environ["REDDIT_PASSWORD"]},
    )
    if "access_token" not in out:
        raise SystemExit(f"error: no access_token in auth response: {out}")
    return out["access_token"]


def fetch_post(token: str, post_id: str) -> dict:
    out = _api("GET", f"https://oauth.reddit.com/api/info?id=t3_{post_id}", token=token)
    children = out.get("data", {}).get("children", [])
    if not children:
        raise SystemExit(f"error: post t3_{post_id} not found (or not visible to this account)")
    return children[0]["data"]


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True, description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--changelog", help="file holding the new 'Latest build' block")
    ap.add_argument("--post-id", default=DEFAULT_POST_ID)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    if not args.changelog:
        ap.error("--changelog is required (or use --self-test)")
    try:
        with open(args.changelog, encoding="utf-8") as fh:
            new_block = fh.read()
    except OSError as exc:
        raise SystemExit(f"error: cannot read changelog: {exc}") from exc

    token = get_token()
    post = fetch_post(token, args.post_id)
    old_body = post.get("selftext", "")
    print(f"==> post t3_{args.post_id} by u/{post.get('author')}: "
          f"{len(old_body)} chars")

    try:
        new_body, action = replace_block(old_body, new_block)
    except BlockError as exc:
        raise SystemExit(
            f"error: {exc}\n"
            "       Refusing to edit a post whose shape I do not recognise. "
            "Fix it by hand, then re-run."
        ) from exc

    if new_body == old_body:
        print("==> post body already matches this changelog, nothing to do")
        return 0

    diff = difflib.unified_diff(old_body.splitlines(), new_body.splitlines(),
                                fromfile="post (current)", tofile="post (new)",
                                lineterm="", n=2)
    print(f"==> block will be {action}\n")
    print("\n".join(diff))
    print(f"\n==> {len(old_body)} chars -> {len(new_body)} chars")

    if args.dry_run:
        print("==> dry run, post not modified")
        return 0

    if not args.yes:
        if not sys.stdin.isatty():
            raise SystemExit("error: refusing to edit a live post non-interactively "
                             "without --yes")
        if input("\nApply this edit to the live post? [y/N] ").strip().lower() != "y":
            print("==> aborted, post not modified")
            return 1

    out = _api("POST", "https://oauth.reddit.com/api/editusertext", token=token,
               data={"thing_id": f"t3_{args.post_id}", "text": new_body,
                     "api_type": "json"})
    errors = out.get("json", {}).get("errors") or []
    if errors:
        raise SystemExit(f"error: reddit rejected the edit: {errors}")
    print("==> post updated")
    return 0


def self_test() -> int:
    """Exercise replace_block without credentials or network."""
    # Mirrors the live post, which writes these two lines bold. An earlier version
    # of ANCHOR only matched the unbolded form and would have refused to insert.
    base = (
        "Hey everyone,\n\n"
        "**Repo:** https://example.invalid/repo\n"
        "**Download the beta IPA:** https://example.invalid/releases/latest\n\n"
        "So what does it do?\n\nStuff.\n"
    )
    base_plain = base.replace("**", "")
    block10 = ("**Latest build: beta 10 (build 106)**\n\nHero follows focus.\n\n"
               "Settings -> About should read 0.3.0 (106).")
    block11 = ("**Latest build: beta 11 (build 107)**\n\nSimkl.\n\n"
               "Settings -> About should read 0.3.0 (107).")
    failures = []

    def check(name, cond):
        print(("  ok   " if cond else "  FAIL ") + name)
        if not cond:
            failures.append(name)

    inserted, action = replace_block(base, block10)
    check("inserts when absent (bold anchor, as the live post writes it)",
          action == "inserted")
    check("inserts when absent (plain anchor)",
          replace_block(base_plain, block10)[1] == "inserted")
    check("insert lands after the download line",
          inserted.index("Latest build") > inserted.index("Download the beta IPA"))
    check("insert lands before the body", inserted.index("Latest build") < inserted.index("So what does it do?"))
    check("insert keeps intro", inserted.startswith("Hey everyone,"))
    check("insert keeps outro", inserted.rstrip().endswith("Stuff."))

    replaced, action = replace_block(inserted, block11)
    check("replaces when present", action == "replaced")
    check("old build gone", "build 106" not in replaced)
    check("new build present", "build 107" in replaced)
    check("exactly one heading", replaced.count("**Latest build:") == 1)
    check("replace keeps intro", replaced.startswith("Hey everyone,"))
    check("replace keeps outro", replaced.rstrip().endswith("Stuff."))
    check("replace is idempotent", replace_block(replaced, block11)[0] == replaced)
    check("no unbounded growth", len(replaced) - len(inserted) < 40)

    for name, body in (
        ("two headings rejected", inserted + "\n" + block10),
        ("heading without closer rejected", base + "\n**Latest build: beta 9 (build 105)**\n"),
        ("missing anchor rejected", "Hey everyone,\n\nNo download line here.\n"),
    ):
        try:
            replace_block(body, block11)
            check(name, False)
        except BlockError:
            check(name, True)

    try:
        replace_block(base, "   ")
        check("empty changelog rejected", False)
    except BlockError:
        check("empty changelog rejected", True)

    print(("\nself-test FAILED: " + ", ".join(failures)) if failures else "\nself-test passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
