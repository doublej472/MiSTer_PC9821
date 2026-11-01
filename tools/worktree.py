#!/usr/bin/env python3
"""Lightweight git-worktree wrapper for isolated parallel lines of work.

Each "lane" is a git worktree on its own branch (`lane/<name>`) checked out
from a base commit (default: the current HEAD of the repo's main branch). The
worktree has its own checkout, so the central tree stays clean while the lane
is edited in isolation. Merge back only when the work is done and reviewed.

Commands:
    new    <name> [--base REF] [--root DIR]
    list
    status <name>
    diff   <name>          diff of the lane branch vs its fork point
    merge  <name> [--apply] [--message MSG]
    rm     <name> [--force]

Examples:
    tools/worktree.py new gfx-fix
    tools/worktree.py list
    tools/worktree.py diff gfx-fix          # review the lane's changes
    tools/worktree.py merge gfx-fix --apply # merge lane/gfx-fix into the repo
    tools/worktree.py rm gfx-fix

The worktree root defaults to `<repo>/.worktrees/<name>` (in-repo and
git-ignored, per AGENTS.md's self-containment rule); override with `--root`
or the `WORKTREE_ROOT` environment variable.
"""

import argparse
import os
import subprocess
import sys

REPO = None  # set in main(); the repo top level (git rev-parse --show-toplevel)


def sh(*args, cwd=None, check=True):
    p = subprocess.run(list(args), cwd=cwd or REPO, text=True,
                       capture_output=True)
    if check and p.returncode != 0:
        sys.stderr.write(p.stderr or p.stdout or f"git {args[0]} failed\n")
        sys.exit(p.returncode)
    return p


def main_branch():
    # The branch the lane will eventually merge back into.
    return sh("git", "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()


def lane_branch(name):
    return f"lane/{name}"


def worktree_path(name, root):
    base = root or os.environ.get("WORKTREE_ROOT")
    if base:
        return os.path.join(base, name)
    return os.path.abspath(os.path.join(REPO, ".worktrees", name))


def cmd_new(args):
    branch = lane_branch(args.name)
    path = worktree_path(args.name, args.root)
    base = args.base or "HEAD"
    if os.path.exists(path):
        sys.stderr.write(f"worktree path already exists: {path}\n")
        sys.exit(1)
    out = sh("git", "branch", "--list", branch).stdout.strip()
    if out:
        sys.stderr.write(f"branch already exists: {branch}\n")
        sys.exit(1)
    p = sh("git", "worktree", "add", "-b", branch, path, base)
    print(f"created lane '{args.name}' at {path} (branch {branch}, base {base})")
    print(f"work in {path}; merge back with:")
    print(f"  tools/worktree.py merge {args.name} --apply")


def short_branch(br):
    return br[len("refs/heads/"):] if br.startswith("refs/heads/") else br


def _worktrees():
    """Parse `git worktree list --porcelain` into [{path, branch}] entries."""
    entries, cur = [], None
    for line in sh("git", "worktree", "list", "--porcelain").stdout.splitlines():
        if line.startswith("worktree "):
            cur = {"path": line[len("worktree "):]}
        elif line.startswith("branch ") and cur is not None:
            cur["branch"] = short_branch(line[len("branch "):])
        elif line == "" and cur is not None:
            entries.append(cur)
            cur = None
    if cur is not None:
        entries.append(cur)
    return entries


def cmd_list(args):
    found = False
    for e in _worktrees():
        br = e.get("branch", "")
        if br.startswith("lane/"):
            found = True
            name = br[len("lane/"):]
            dirty = ""
            p = sh("git", "status", "--short", cwd=e["path"], check=False)
            if p.stdout.strip():
                dirty = f" (dirty: {len(p.stdout.splitlines())} files)"
            print(f"  {name:20s} {e['path']}{dirty}")
    if not found:
        print("  (no lane worktrees)")


def cmd_status(args):
    branch = lane_branch(args.name)
    target = None
    for e in _worktrees():
        if e.get("branch") == branch:
            target = e["path"]
    if not target:
        sys.stderr.write(f"no worktree for branch {branch}\n")
        sys.exit(1)
    st = sh("git", "status", "--short", "--branch", cwd=target, check=False)
    print(f"lane '{args.name}' at {target}\n")
    print(st.stdout or "  (clean)")


def cmd_diff(args):
    branch = lane_branch(args.name)
    base = sh("git", "merge-base", "HEAD", branch).stdout.strip()
    p = sh("git", "diff", "--stat", f"{base}...{branch}", check=False)
    print(f"lane '{args.name}' ({branch}) vs merge-base {base[:12]}\n")
    print(p.stdout or "  (no changes)")
    print("\nfull diff:")
    sh("git", "diff", f"{base}...{branch}")


def cmd_merge(args):
    branch = lane_branch(args.name)
    base = sh("git", "merge-base", "HEAD", branch).stdout.strip()
    if not args.apply:
        p = sh("git", "diff", "--stat", f"{base}...{branch}", check=False)
        print(f"lane '{args.name}' ({branch}) vs merge-base {base[:12]}\n")
        print(p.stdout or "  (no changes)")
        print("\nre-run with --apply to merge into the current branch.")
        return
    # Refuse to merge over a dirty central tree.
    st = sh("git", "status", "--short", check=False).stdout
    if st.strip():
        sys.stderr.write("central tree is dirty; commit or stash before merging:\n")
        sys.stderr.write(st)
        sys.exit(1)
    msg = args.message or f"merge lane/{args.name}"
    sh("git", "merge", "--no-ff", "-m", msg, branch)
    print(f"merged {branch} into {main_branch()}")


def cmd_rm(args):
    branch = lane_branch(args.name)
    path = worktree_path(args.name, args.root)
    flags = ["--force"] if args.force else []
    if os.path.exists(path):
        sh("git", "worktree", "remove", *flags, path)
        print(f"removed worktree {path}")
    if sh("git", "branch", "--list", branch).stdout.strip():
        sh("git", "branch", "-D", branch)
        print(f"deleted branch {branch}")


def main():
    global REPO
    REPO = sh("git", "rev-parse", "--show-toplevel").stdout.strip()
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("new", help="create a lane worktree")
    p.add_argument("name")
    p.add_argument("--base", help="base commit (default HEAD)")
    p.add_argument("--root", help="worktree root dir (default <repo>/.worktrees)")
    p.set_defaults(fn=cmd_new)

    p = sub.add_parser("list", help="list lane worktrees")
    p.set_defaults(fn=cmd_list)

    p = sub.add_parser("status", help="status of one lane")
    p.add_argument("name")
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("diff", help="diff a lane vs its fork point")
    p.add_argument("name")
    p.set_defaults(fn=cmd_diff)

    p = sub.add_parser("merge", help="merge a lane back (default: dry-run diff)")
    p.add_argument("name")
    p.add_argument("--apply", action="store_true", help="actually merge")
    p.add_argument("--message", help="merge commit message")
    p.set_defaults(fn=cmd_merge)

    p = sub.add_parser("rm", help="remove a lane worktree + branch")
    p.add_argument("name")
    p.add_argument("--root", help="worktree root dir (default <repo>/.worktrees)")
    p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_rm)

    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
