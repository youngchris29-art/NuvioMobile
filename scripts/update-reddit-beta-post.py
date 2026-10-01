#!/usr/bin/env python3
"""Update the "Latest build" changelog block in the r/NuvioForks beta thread's post body.

The beta thread (https://www.reddit.com/r/NuvioForks/comments/1wtmutc/; it replaced
r/Nuvio post 1v26ebw, which that sub removed on 2026-09-27) carries a
"Latest build: beta N (build M)" section right under the download link, so the
post body always describes what releases/latest actually serves. This script
swaps that block for a new one at release time.

The edit is sent as Reddit rich-text JSON (`richtext_json=`), not markdown
(`text=`). The post is a rich-text post whose four inline screenshots live at the
end of the body; a `text=` edit converts the whole post to markdown mode and
those screenshots degrade to bare links (`![img](url)` renders as the literal
word "img"). Seen live on 2026-10-01 and repaired by re-sending the body as
rich text. So after the block swap the new body is converted with the outer
repo's scripts/reddit/md-to-rtjson.py (each bare preview.redd.it line becomes an
{"e":"img","id":<media id>} node) and every image id is checked against the
post's media_metadata before anything is sent. The converter is looked up at
../../scripts/reddit/md-to-rtjson.py relative to this file (the fork wrapper
layout); override with --rtjson-converter or NUVIO_RTJSON_CONVERTER.

It deliberately does NOT write the changelog for you. The Reddit changelog is
hand-written prose with its own constraints (no em dashes, straight quotes, and
wording that avoids the Automod rules that have tripped this sub before); text
generated from commit subjects would read badly and risk removal. Pass a file
you wrote, the same way scripts/release-beta.sh takes --changelog.

Auth is a refresh token, not the account password. The token is scoped to
"read edit" (fetch the post, edit own posts) and nothing else, so a leak cannot
post, delete, message, or touch the account. Credentials come from the
environment, never from the repo:

    REDDIT_CLIENT_ID, REDDIT_REFRESH_TOKEN, and REDDIT_CLIENT_SECRET
    (secret is required for a "web app", omitted for an "installed app")

One-time setup:
  1. https://www.reddit.com/prefs/apps as the post author -> create an app.
     "installed app" needs no secret; "web app" issues one. Set the redirect
     URI to anything you control, e.g. http://localhost:8080 (nothing has to
     listen there; you just copy the code out of the URL bar).
  2. export REDDIT_CLIENT_ID=... [REDDIT_CLIENT_SECRET=...]
  3. ./update-reddit-beta-post.py --authorize --redirect-uri http://localhost:8080
     Open the printed URL, approve, then paste the URL you land on. It prints a
     refresh token; export it as REDDIT_REFRESH_TOKEN. It does not expire, so
     this is done once.

Usage:
    update-reddit-beta-post.py --changelog notes.md [--post-id 1wtmutc]
                               [--dry-run] [--yes] [--rtjson-converter PATH]
    update-reddit-beta-post.py --authorize [--redirect-uri URI]
    update-reddit-beta-post.py --self-test

    --dry-run    Fetch and show the diff, convert the new body to rich text and
                 report its image nodes, write nothing. Needs credentials
                 (Reddit returns 403 for unauthenticated reads).
    --yes        Skip the confirmation prompt. For non-interactive release runs.
    --authorize  One-time flow that turns an approval into a refresh token.
    --self-test  Run the block-replacement and rich-text conversion logic
                 against fixtures and exit. Needs no credentials and no
                 network (it does need the converter file, see above).
"""

from __future__ import annotations

import argparse
import difflib
import importlib.util
import json
import os
import re
import sys
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_POST_ID = "1wtmutc"
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


# The docs/comms-reddit-*-changelog.md files open with <!-- --> notes (when the
# block was applied, what it replaces). Those are for the repo, not the post.
HTML_COMMENT = re.compile(r"<!--.*?-->\s*", re.DOTALL)


def strip_html_comments(block: str) -> str:
    return HTML_COMMENT.sub("", block)


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


# The markdown -> rich-text converter lives in the fork wrapper repo (this file
# sits at <wrapper>/NuvioMobile/scripts/, the converter at
# <wrapper>/scripts/reddit/md-to-rtjson.py). It handles exactly the constructs
# the thread body uses: paragraphs, **bold**, [text](url), "* " bullets and the
# bare preview.redd.it image lines.
CONVERTER_ENV = "NUVIO_RTJSON_CONVERTER"
DEFAULT_CONVERTER = Path(__file__).resolve().parents[2] / "scripts" / "reddit" / "md-to-rtjson.py"
# The converter turns a bare image line into an img node when it looks like
# this. Mirrored here so the pre-send check can count what the body carries.
IMAGE_LINE = re.compile(r"^https://preview\.redd\.it/([a-z0-9]+)\.png", re.MULTILINE)


def load_converter(path: str | None = None):
    """Import md-to-rtjson.py by path and return its convert(body) -> rtjson dict."""
    chosen = path or os.environ.get(CONVERTER_ENV) or str(DEFAULT_CONVERTER)
    file = Path(chosen)
    if not file.is_file():
        raise SystemExit(
            f"error: rich-text converter not found at {file}\n"
            "       It is scripts/reddit/md-to-rtjson.py in the NuvioTV wrapper repo. "
            f"Point --rtjson-converter or ${CONVERTER_ENV} at it."
        )
    spec = importlib.util.spec_from_file_location("md_to_rtjson", file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not callable(getattr(module, "convert", None)):
        raise SystemExit(f"error: {file} has no convert() function")
    return module.convert


def image_ids(document: dict) -> list[str]:
    """Media ids of the top-level img nodes, in document order."""
    return [n["id"] for n in document.get("document", []) if n.get("e") == "img"]


def check_images(body: str, document: dict, media_metadata: dict | None) -> None:
    """Refuse to send a rich-text body that would lose a screenshot.

    Every bare preview line in the markdown must have become an img node, and
    every img node's id must be in the post's media_metadata (Reddit renders an
    img node only when it can resolve the id there).
    """
    expected = IMAGE_LINE.findall(body)
    got = image_ids(document)
    if got != expected:
        raise BlockError(
            f"image lines in the body {expected} did not convert to img nodes {got}"
        )
    known = set((media_metadata or {}).keys())
    missing = [i for i in got if i not in known]
    if missing:
        raise BlockError(
            f"image ids {missing} are not in the post's media_metadata "
            f"(known: {sorted(known)}); sending would drop those screenshots"
        )


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


# Only what the job needs: read the post, edit our own post. Not submit, not
# modify account settings, not send messages.
OAUTH_SCOPE = "read edit"


def _client() -> tuple[str, str]:
    """(client_id, client_secret). Secret is "" for an installed (public) app."""
    cid = os.environ.get("REDDIT_CLIENT_ID")
    if not cid:
        raise SystemExit(
            "error: REDDIT_CLIENT_ID is not set.\n"
            "       Create an app at https://www.reddit.com/prefs/apps as the post author,\n"
            "       then see --help for the one-time --authorize step."
        )
    return cid, os.environ.get("REDDIT_CLIENT_SECRET", "")


def get_token() -> str:
    cid, csec = _client()
    refresh = os.environ.get("REDDIT_REFRESH_TOKEN")
    if not refresh:
        raise SystemExit(
            "error: REDDIT_REFRESH_TOKEN is not set.\n"
            "       Run once:  ./update-reddit-beta-post.py --authorize\n"
            "       then export the token it prints. It does not expire."
        )
    out = _api("POST", "https://www.reddit.com/api/v1/access_token",
               auth=(cid, csec),
               data={"grant_type": "refresh_token", "refresh_token": refresh})
    if "access_token" not in out:
        raise SystemExit(f"error: no access_token in refresh response: {out}")
    return out["access_token"]


def authorize(redirect_uri: str) -> int:
    """One-time: turn a browser approval into a long-lived refresh token."""
    import secrets
    cid, csec = _client()
    state = secrets.token_urlsafe(16)
    url = "https://www.reddit.com/api/v1/authorize?" + urllib.parse.urlencode({
        "client_id": cid, "response_type": "code", "state": state,
        "redirect_uri": redirect_uri, "duration": "permanent",
        "scope": OAUTH_SCOPE,
    })
    print("1. Open this URL as the post author and approve:\n")
    print("   " + url + "\n")
    print(f"2. You will land on {redirect_uri}?... (nothing needs to be listening there).")
    try:
        pasted = input("   Paste that full URL, or just the code: ").strip()
    except EOFError:
        raise SystemExit("\nerror: --authorize needs a terminal to paste the code into") from None

    if "code=" in pasted:
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(pasted).query)
        if qs.get("error"):
            raise SystemExit(f"error: reddit returned {qs['error'][0]}")
        got_state = (qs.get("state") or [None])[0]
        if got_state and got_state != state:
            raise SystemExit("error: state mismatch, discarding (possible mix-up or tampering)")
        code = (qs.get("code") or [""])[0]
    else:
        code = pasted
    # Reddit appends #_ to the redirect fragment; strip anything trailing.
    code = code.split("#")[0].strip()
    if not code:
        raise SystemExit("error: no authorization code found in that input")

    out = _api("POST", "https://www.reddit.com/api/v1/access_token",
               auth=(cid, csec),
               data={"grant_type": "authorization_code", "code": code,
                     "redirect_uri": redirect_uri})
    token = out.get("refresh_token")
    if not token:
        raise SystemExit(
            f"error: no refresh_token in response: {out}\n"
            "       Make sure the authorize URL had duration=permanent and that the\n"
            "       redirect URI matches the app's exactly."
        )
    print("\n==> Add this to your shell profile (scope: " + OAUTH_SCOPE + "):\n")
    print(f'export REDDIT_REFRESH_TOKEN="{token}"\n')
    print("It does not expire. Treat it like a password: it can read and edit as you.")
    return 0


def fetch_post(token: str, post_id: str) -> dict:
    # raw_json=1: without it Reddit HTML-escapes selftext ("->" arrives as
    # "-&gt;"), which would break the BLOCK_END anchor and, worse, be sent back
    # verbatim inside rich-text text nodes.
    out = _api("GET", f"https://oauth.reddit.com/api/info?id=t3_{post_id}&raw_json=1",
               token=token)
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
    ap.add_argument("--rtjson-converter", metavar="PATH",
                    help="markdown -> rich-text converter (default: "
                         f"scripts/reddit/md-to-rtjson.py in the wrapper repo, or ${CONVERTER_ENV})")
    ap.add_argument("--authorize", action="store_true",
                    help="one-time: exchange a browser approval for a refresh token")
    ap.add_argument("--redirect-uri", default="http://localhost:8080",
                    help="must match the app's redirect URI exactly (default: %(default)s)")
    args = ap.parse_args()

    if args.self_test:
        return self_test(args.rtjson_converter)

    if args.authorize:
        return authorize(args.redirect_uri)

    if not args.changelog:
        ap.error("--changelog is required (or use --self-test)")
    try:
        with open(args.changelog, encoding="utf-8") as fh:
            new_block = strip_html_comments(fh.read())
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

    # Convert before the prompt so a body the converter cannot represent, or an
    # image id Reddit would not resolve, stops the run before anyone says yes.
    convert = load_converter(args.rtjson_converter)
    document = convert(new_body)
    try:
        check_images(new_body, document, post.get("media_metadata"))
    except BlockError as exc:
        raise SystemExit(f"error: {exc}\n       Post not modified.") from exc
    nodes = document.get("document", [])
    print(f"==> rich text: {len(nodes)} top-level nodes, "
          f"{len(image_ids(document))} inline images (all in media_metadata)")

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

    # richtext_json, never text: a markdown edit flips the post out of rich-text
    # mode and the inline screenshots degrade to links (see the module docstring).
    out = _api("POST", "https://oauth.reddit.com/api/editusertext", token=token,
               data={"thing_id": f"t3_{args.post_id}",
                     "richtext_json": json.dumps(document),
                     "api_type": "json"})
    return report_edit(out, args.post_id)


def report_edit(out: dict, post_id: str) -> int:
    """Interpret the editusertext response and print the outcome.

    A markdown edit answers {"json": {"errors": [...]}}. A rich-text edit
    answers with the post object itself (id, name, selftext, ...), so the
    absence of a "json" key is not a failure.
    """
    if isinstance(out, dict) and "json" in out:
        errors = (out.get("json") or {}).get("errors") or []
        if errors:
            raise SystemExit(f"error: reddit rejected the edit: {errors}")
        print("==> post updated")
        return 0
    if isinstance(out, dict) and out.get("id") == post_id:
        print(f"==> post updated (reddit returned the post object, "
              f"{len(out.get('selftext') or '')} chars of selftext)")
        return 0
    data = out.get("data") if isinstance(out, dict) else None
    if isinstance(data, dict) and data.get("id") == post_id:
        print(f"==> post updated (reddit returned the post object, "
              f"{len(data.get('selftext') or '')} chars of selftext)")
        return 0
    raise SystemExit(
        "error: unrecognised editusertext response, check the post by hand:\n"
        + json.dumps(out)[:600]
    )


def self_test(converter_path: str | None = None) -> int:
    """Exercise replace_block and the rich-text conversion without credentials or network."""
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

    # The r/NuvioForks post ends with its inline screenshots, which Reddit stores
    # as bare preview.redd.it lines. A block swap must leave them where they are.
    images = ("\n\nhttps://preview.redd.it/aaa.png?width=1920&format=png&auto=webp&s=1"
              "\n\nhttps://preview.redd.it/bbb.png?width=3840&format=png&auto=webp&s=2\n")
    with_images, _ = replace_block(inserted + images, block11)
    check("image lines survive a block swap", with_images.endswith(images))
    check("image lines are not duplicated", with_images.count("preview.redd.it") == 2)

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

    noted = ("<!-- APPLIED 2026-10-01 to post 1wtmutc. -->\n"
             "<!-- beta 11 block. Keep the image lines. -->\n" + block11)
    check("leading <!-- --> notes in the changelog file are dropped",
          strip_html_comments(noted) == block11)
    check("a changelog without notes is untouched", strip_html_comments(block11) == block11)

    # Rich text. The live post ends with four screenshots stored as bare
    # preview.redd.it lines; after a block swap each must become an img node
    # whose id is a media_metadata key, and nothing else may mention the URL.
    four = ["h0m3aaaa1", "h3r0bbbb2", "d3t41lccc3", "pl4y3rddd4"]
    image_lines = "".join(
        f"\n\nhttps://preview.redd.it/{i}.png?width=3840&format=png&auto=webp&s={n}"
        for n, i in enumerate(four, 1)) + "\n"
    block12 = ("**Latest build: beta 12 (build 108)**\n\nWhat's new in beta 12:\n\n"
               "* [Linked](https://example.invalid/a) **bold** item.\n"
               "* Second item.\n\n"
               "Settings -> About should read 0.3.0 (108).")
    swapped, action = replace_block(inserted + image_lines, block12)
    check("four-image swap replaces the block", action == "replaced")
    try:
        convert = load_converter(converter_path)
    except SystemExit as exc:
        print(f"  FAIL rich-text converter unavailable: {exc}")
        failures.append("rich-text converter unavailable")
        convert = None
    if convert is not None:
        doc = convert(swapped)
        nodes = doc.get("document", [])
        check("rich text has a document", isinstance(nodes, list) and len(nodes) > 0)
        check("four image lines become four img nodes, in order", image_ids(doc) == four)
        check("img nodes are the last four nodes",
              [n.get("e") for n in nodes[-4:]] == ["img"] * 4)
        check("img nodes carry only the media id",
              all(set(n) == {"e", "id"} for n in nodes if n.get("e") == "img"))
        flat = json.dumps(doc)
        check("no image URL survives as text", "preview.redd.it" not in flat)
        check("no literal img placeholder", "![img]" not in flat)
        check("new heading is a bold text node",
              any(n.get("e") == "par" and any(
                  c.get("t") == "Latest build: beta 12 (build 108)" and c.get("f") == [[1, 0, 33]]
                  for c in n.get("c", [])) for n in nodes))
        check("bullets become a list with two items",
              any(n.get("e") == "list" and len(n.get("c", [])) == 2 for n in nodes))
        check("link becomes a link node",
              any(c.get("e") == "link" and c.get("u") == "https://example.invalid/a"
                  for n in nodes if n.get("e") == "list"
                  for li in n["c"] for par in li["c"] for c in par["c"]))
        check("old build gone from rich text", "build 106" not in flat)
        meta = {i: {"status": "valid", "e": "Image", "id": i} for i in four}
        try:
            check_images(swapped, doc, meta)
            check("image check passes with all ids in media_metadata", True)
        except BlockError:
            check("image check passes with all ids in media_metadata", False)
        try:
            check_images(swapped, doc, {k: v for k, v in meta.items() if k != four[2]})
            check("image check rejects an id missing from media_metadata", False)
        except BlockError:
            check("image check rejects an id missing from media_metadata", True)
        try:
            check_images(swapped, {"document": nodes[:-1]}, meta)
            check("image check rejects a dropped img node", False)
        except BlockError:
            check("image check rejects a dropped img node", True)
        # A post with no screenshots still edits fine.
        try:
            check_images(replaced, convert(replaced), {})
            check("image check passes with no images", True)
        except BlockError:
            check("image check passes with no images", False)

    # The response of a rich-text edit is the post object, not the {"json": ...}
    # envelope a markdown edit returns; both are success, errors are not.
    check("post-object response is success",
          report_edit({"id": "abc123", "name": "t3_abc123", "selftext": "x"}, "abc123") == 0)
    check("wrapped post-object response is success",
          report_edit({"kind": "t3", "data": {"id": "abc123", "selftext": "x"}}, "abc123") == 0)
    check("empty-errors envelope is success",
          report_edit({"json": {"errors": []}}, "abc123") == 0)
    for name, resp in (
        ("errors envelope rejected", {"json": {"errors": [["TOO_LONG", "too long", "text"]]}}),
        ("unrelated response rejected", {"id": "other"}),
    ):
        try:
            report_edit(resp, "abc123")
            check(name, False)
        except SystemExit:
            check(name, True)

    print(("\nself-test FAILED: " + ", ".join(failures)) if failures else "\nself-test passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
