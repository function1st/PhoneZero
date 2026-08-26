#!/usr/bin/env python3
"""Reject non-fixture phones, mailbox addresses in files, and personal commit authors."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST_PATH = ROOT / "scripts" / "privacy-phone-allowlist.txt"

SKIP_DIRS = {".git", "node_modules", "agent-tools", "recordings"}
SKIP_SUFFIXES = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".mp3", ".woff", ".woff2"}

# ITU E.164: + then 8–15 digits, first digit 1–9.
E164_RE = re.compile(r"\+[1-9]\d{7,14}")
# Separated NANP / US written forms. Dates, semver, and $0.05 do not match.
US_RE = re.compile(r"\(?[2-9]\d{2}\)?[-.\s]\d{3}[-.\s]\d{4}")

TRAILER_RE = re.compile(
    r"^(?:Co-authored-by|Signed-off-by|Reviewed-by|Acked-by):\s.*<([^>]+)>",
    re.IGNORECASE | re.MULTILINE,
)

ALLOWED_AUTHOR_EMAIL_RES = (
    re.compile(r"^[^@\s]+@users\.noreply\.github\.com$", re.IGNORECASE),
    re.compile(r"^[^@\s]+@noreply\.github\.com$", re.IGNORECASE),
    re.compile(r"^noreply@github\.com$", re.IGNORECASE),
    re.compile(r"^cursoragent@cursor\.com$", re.IGNORECASE),
)

# File-content mailboxes: same plus RFC 2606 reserved example domains.
ALLOWED_FILE_EMAIL_RES = ALLOWED_AUTHOR_EMAIL_RES + (
    re.compile(r"^[^@\s]+@example\.(?:com|org|net)$", re.IGNORECASE),
)

# mailbox form (local-part + at-sign + host + dot-TLD). Skips npm scopes,
# actions/checkout@v6, and sip:{DID}@host.
EMAIL_RE = re.compile(r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b")


def load_allowlist(path: Path) -> tuple[set[str], list[re.Pattern[str]]]:
    exact: set[str] = set()
    patterns: list[re.Pattern[str]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("pattern:"):
            patterns.append(re.compile(line[len("pattern:") :]))
            continue
        exact.add(line)
    return exact, patterns


def allowed_phone(match: str, exact: set[str], patterns: list[re.Pattern[str]]) -> bool:
    if match in exact:
        return True
    return any(pattern.fullmatch(match) for pattern in patterns)


def iter_text_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        if path.suffix.lower() in SKIP_SUFFIXES:
            continue
        files.append(path)
    return files


def scan_phones(root: Path, exact: set[str], patterns: list[re.Pattern[str]]) -> list[str]:
    flagged: list[str] = []
    for path in iter_text_files(root):
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        rel = path.relative_to(root)
        for lineno, line in enumerate(text.splitlines(), start=1):
            for regex in (E164_RE, US_RE):
                for match in regex.finditer(line):
                    token = match.group(0)
                    if not allowed_phone(token, exact, patterns):
                        flagged.append(f"{rel}:{lineno}:{token}")
    return flagged


def author_allowed(email: str) -> bool:
    return any(pattern.fullmatch(email) for pattern in ALLOWED_AUTHOR_EMAIL_RES)


def file_email_allowed(email: str) -> bool:
    return any(pattern.fullmatch(email) for pattern in ALLOWED_FILE_EMAIL_RES)


def scan_emails(root: Path) -> list[str]:
    flagged: list[str] = []
    for path in iter_text_files(root):
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        rel = path.relative_to(root)
        for lineno, line in enumerate(text.splitlines(), start=1):
            for match in EMAIL_RE.finditer(line):
                token = match.group(0)
                if not file_email_allowed(token):
                    flagged.append(f"{rel}:{lineno}:{token}")
    return flagged


def collect_commit_emails(repo: Path, extra_args: list[str] | None = None) -> list[tuple[str, str]]:
    fmt = "%H%n%ae%n%ce%n%b%x1e"
    cmd = ["git", "-C", str(repo), "log", f"--format={fmt}"]
    if extra_args:
        cmd.extend(extra_args)
    proc = subprocess.run(
        cmd,
        check=True,
        capture_output=True,
        text=True,
    )
    found: list[tuple[str, str]] = []
    for record in proc.stdout.split("\x1e"):
        record = record.strip()
        if not record:
            continue
        lines = record.splitlines()
        sha = lines[0]
        emails = [lines[1], lines[2]] if len(lines) >= 3 else []
        body = "\n".join(lines[3:])
        emails.extend(TRAILER_RE.findall(body))
        for email in emails:
            email = email.strip()
            if email:
                found.append((sha, email))
    return found


def _ref_exists(repo: Path, ref: str) -> bool:
    probe = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--verify", ref],
        capture_output=True,
        text=True,
    )
    return probe.returncode == 0


def _author_log_args(repo: Path) -> list[str] | None:
    """Check only commits that are not already on the base branch."""
    candidates: list[str] = []
    base = os.environ.get("GITHUB_BASE_REF", "").strip()
    if base:
        candidates.extend([f"origin/{base}", base])
    before = os.environ.get("GITHUB_EVENT_BEFORE", "").strip()
    if before and set(before) != {"0"}:
        candidates.append(before)
    candidates.append("origin/main")
    for ref in candidates:
        if _ref_exists(repo, ref):
            return ["HEAD", "--not", ref]
    parents = subprocess.run(
        ["git", "-C", str(repo), "rev-list", "--parents", "-n", "1", "HEAD"],
        capture_output=True,
        text=True,
    )
    parts = (parents.stdout or "").split()
    if parents.returncode == 0 and len(parts) >= 3:
        return ["HEAD", "--not", parts[1]]
    return None


def scan_authors(repo: Path) -> list[str]:
    flagged: list[str] = []
    emails = collect_commit_emails(repo, _author_log_args(repo))
    if not emails:
        return ["no commits to check"]
    for sha, email in emails:
        if not author_allowed(email):
            flagged.append(f"{sha[:12]} {email}")
    return flagged


def _git(repo: Path, *args: str, extra_env: dict[str, str] | None = None) -> None:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True, env=env)


def self_test() -> None:
    exact, patterns = load_allowlist(ALLOWLIST_PATH)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "ok.txt").write_text("fixture +15555550100 and 555-0199\n", encoding="utf-8")
        ok = scan_phones(root, exact, patterns)
        if ok:
            raise SystemExit(f"self-test: allowed fixtures were flagged: {ok}")

        plus = "+"
        intl = plus + "44" + "2071234567"
        us = "-".join(("415", "555", "1234"))
        (root / "bad.txt").write_text(f"intl {intl} us {us}\n", encoding="utf-8")
        bad = scan_phones(root, exact, patterns)
        if intl not in "".join(bad) or us not in "".join(bad):
            raise SystemExit(f"self-test: expected international and US rejects, got {bad}")

        git_repo = root / "repo"
        git_repo.mkdir()
        _git(git_repo, "init", "-b", "main")
        _git(git_repo, "config", "commit.gpgsign", "false")
        (git_repo / "README").write_text("x\n", encoding="utf-8")
        _git(git_repo, "add", "README")
        bad_env = {
            "GIT_AUTHOR_NAME": "Person",
            "GIT_AUTHOR_EMAIL": "person@" + "gmail.com",
            "GIT_COMMITTER_NAME": "Person",
            "GIT_COMMITTER_EMAIL": "person@" + "gmail.com",
        }
        _git(git_repo, "commit", "-m", "bad", extra_env=bad_env)
        if not scan_authors(git_repo):
            raise SystemExit("self-test: personal author email was allowed")

        good_env = {
            "GIT_AUTHOR_NAME": "Function1st",
            "GIT_AUTHOR_EMAIL": "function1st@users.noreply.github.com",
            "GIT_COMMITTER_NAME": "Function1st",
            "GIT_COMMITTER_EMAIL": "function1st@users.noreply.github.com",
        }
        (git_repo / "README").write_text("y\n", encoding="utf-8")
        _git(git_repo, "add", "README")
        _git(git_repo, "commit", "-m", "good", extra_env=good_env)
        leftover = [row for row in scan_authors(git_repo) if row.endswith("@users.noreply.github.com")]
        if leftover:
            raise SystemExit(f"self-test: noreply author was flagged: {leftover}")

        merge_env = {
            "GIT_AUTHOR_NAME": "GitHub",
            "GIT_AUTHOR_EMAIL": "noreply@github.com",
            "GIT_COMMITTER_NAME": "GitHub",
            "GIT_COMMITTER_EMAIL": "noreply@github.com",
        }
        (git_repo / "README").write_text("z\n", encoding="utf-8")
        _git(git_repo, "add", "README")
        _git(git_repo, "commit", "-m", "merge", extra_env=merge_env)
        leftover = [row for row in scan_authors(git_repo) if "noreply@github.com" in row]
        if leftover:
            raise SystemExit(f"self-test: GitHub merge author was flagged: {leftover}")

        (root / "mail-ok.txt").write_text(
            "noreply function1st@users.noreply.github.com fixture reporter@example.com\n",
            encoding="utf-8",
        )
        mail_ok = scan_emails(root)
        if mail_ok:
            raise SystemExit(f"self-test: allowed file emails were flagged: {mail_ok}")
        personal = "person@" + "gmail.com"
        (root / "mail-bad.txt").write_text(f"contact {personal}\n", encoding="utf-8")
        mail_bad = scan_emails(root)
        if personal not in "".join(mail_bad):
            raise SystemExit(f"self-test: expected personal file email reject, got {mail_bad}")
    print("privacy-check self-test ok")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--skip-authors", action="store_true")
    parser.add_argument("--skip-phones", action="store_true")
    parser.add_argument("--skip-emails", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    failed = False
    if not args.skip_phones:
        exact, patterns = load_allowlist(ALLOWLIST_PATH)
        flagged = scan_phones(ROOT, exact, patterns)
        if flagged:
            print("Real-looking phone numbers are not allowed. Use allowlisted fixtures only.")
            print("\n".join(flagged))
            failed = True
        else:
            print("phone fixtures ok")

    if not args.skip_emails:
        flagged = scan_emails(ROOT)
        if flagged:
            print("Mailbox addresses in the tree are not allowed. Use a GitHub noreply or example.com.")
            print("\n".join(flagged))
            failed = True
        else:
            print("file emails ok")

    if not args.skip_authors:
        flagged = scan_authors(ROOT)
        if flagged:
            print("Personal commit-author emails are not allowed. Use a GitHub noreply identity.")
            print("\n".join(flagged))
            failed = True
        else:
            print("commit authors ok")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
