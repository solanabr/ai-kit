---
description: "Format, lint and commit with a conventional message on a kit-named branch"
---

Commit the current work with a conventional commit message. `$ARGUMENTS`, if given, is the message or a hint for it.

## Steps

1. **Branch.** On `main` or `master`, propose `<type>/<scope>-<description>-<DD-MM-YYYY>` (e.g. `feat/program-vault-15-01-2026`; date from `date +%d-%m-%Y`; type from the change: feat, fix, docs, test, refactor, chore) and ask: create it, use a custom name, or stay. Create it with `git checkout -b <name>`; uncommitted changes come along.
2. **Stage.** If `git status --short` is empty, stop. If something is already staged, commit only that. Otherwise stage modified and new files, leaving out secrets and build output (`.env`, `.env.local`, `*keypair*.json`, `id.json`, `target/`, `node_modules/`) and saying what was left out.
3. **Format**, then re-stage what it touched (`git add -u`): `cargo fmt` for Rust, `npx prettier --write` on the changed TS/JS/JSON files, `ruff format` for Python.
4. **Lint:** `cargo clippy --all-targets -- -D warnings`; `npm run lint` when `package.json` defines it. Fix what is quick and report the rest.
5. **Message:** `type(scope): summary`, imperative, under 72 characters, written from `git diff --cached` rather than from file names. Types: feat, fix, refactor, perf, test, docs, style, chore, ci. Scope is the area touched (program, frontend, tests, docs, deps). Add a body with the why when the change is not obvious. No AI attribution or `Co-Authored-By` trailer (the kit sets `attribution` to empty strings in settings.json).
6. **Commit.** Show `git diff --cached --stat` and the message, then `git commit`. If the project's own git pre-commit hook fails, fix, re-stage and retry; don't skip it with `--no-verify`.

## Output

Branch, commit hash and message, files committed, and any lint warnings left unfixed. This only runs quick checks; run the full suites (`/test-rust`, `/test-ts`) before pushing.
