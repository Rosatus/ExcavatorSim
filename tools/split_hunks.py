"""Split a git diff into two patches by hunk-content regex.

Usage: python split_hunks.py <file> <keep_regex> <out_keep> <out_drop>
Writes <out_keep> containing diff header + hunks whose text matches
<keep_regex>; remaining hunks go to <out_drop>. Binary-safe: reads and
writes bytes under latin-1 so CRLF content survives untouched.
"""
import re
import subprocess
import sys


def main() -> int:
    path, keep_re, out_keep, out_drop = sys.argv[1:5]
    raw = subprocess.run(
        ["git", "diff", "HEAD", "--", path], capture_output=True, check=True
    ).stdout.decode("latin-1")
    # Worktree files are CRLF while blobs are LF; strip \r so the patch
    # applies cleanly against the index.
    raw = raw.replace("\r\n", "\n")
    lines = raw.splitlines(keepends=True)
    header, hunks, cur = [], [], []
    for line in lines:
        if line.startswith("@@"):
            if cur:
                hunks.append(cur)
            cur = [line]
        elif hunks or cur:
            cur.append(line)
        else:
            header.append(line)
    if cur:
        hunks.append(cur)
    pat = re.compile(keep_re)
    keep = [h for h in hunks if pat.search("".join(h))]
    drop = [h for h in hunks if not pat.search("".join(h))]
    for out, picked in ((out_keep, keep), (out_drop, drop)):
        with open(out, "w", encoding="latin-1", newline="") as fh:
            fh.writelines(header)
            for h in picked:
                fh.writelines(h)
    print(f"{path}: {len(hunks)} hunks -> keep {len(keep)} drop {len(drop)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
