# fetch-exec-guard.awk — find a "download a package and run it" command whose
# package is not already a dependency of this project.
#
#   awk -f lib-tokenize.awk -f fetch-exec-guard.awk
#
# stdin : raw command text (one tool call)
# stdout: "GATE|<ecosystem>|<runner>|<package>", or nothing.  First match wins.
# env   : KIT_PROJECT_DIR  where the manifests live (default ".")
#
# Decides on COMMAND position only.  `echo "run npx -y create-solana-dapp"` is
# prose, a heredoc body is a document, and both must stay silent — which is why
# this runs on the shared tokenizer rather than on a regex over the whole string.
#
# The dependency readers below are deliberately loose: they would rather call
# something a dependency than not.  A false "declared" lets one package through;
# a false "undeclared" fires on a project's own tooling, which is the
# false-positive class secrets-guard.sh was rewritten to eliminate.

# ---- the library's callbacks.
function kit_wrapper(c) { return (is_wrapper(c) || is_shell(c)) }
function kit_heredoc_is_code(c) { return is_shell(c) }
# reskip=1 so `env NODE_ENV=1 npx -y x` finds npx; operands=1 so `timeout 5 npx
# -y x` does too — skipping a wrapper's OPTIONS alone leaves "5" in command
# position, which is the bug that bit twice.
function cmdword(T, n) { return cmdword_x(T, n, 1, 1) }

# ---------------------------------------------------------------- specs

# A path is local code, never a download: ./x, /x, ~/x, file:...
function is_localish(s) { return (s ~ /^[.\/~]/ || s ~ /^file:/) }

# A URL, a git shorthand or a tarball can never be a declared dependency by
# name, so it is gated without consulting a manifest.
function is_remote_spec(s) {
  return (s ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\// || s ~ /^(github|gitlab|bitbucket|git|git\+ssh|npm):/ \
       || s ~ /\.(tgz|tar\.gz|whl)$/)
}

# node_name — bare package name.  Keeps an @scope/ prefix, drops an @version.
function node_name(s,   p) {
  if (substr(s, 1, 1) == "@") {
    p = index(substr(s, 2), "@")
    return (p > 0) ? substr(s, 1, p) : s
  }
  p = index(s, "@")
  return (p > 1) ? substr(s, 1, p - 1) : s
}
# py_name — drop PEP 508 extras and version specifiers: pkg[extra]>=1.2 -> pkg
function py_name(s) { sub(/[\[<>=!~;].*$/, "", s); return s }
# rust_name — drop an @version: crate@1.2.3 -> crate
function rust_name(s) { sub(/@.*$/, "", s); return s }

# ---------------------------------------------------------------- manifests

function slurp(path,   line, acc) {
  acc = ""
  while ((getline line < path) > 0) acc = acc line "\n"
  close(path)
  return acc
}
# exists — getline returns -1 when the path cannot be opened at all.
function exists(path,   r, junk) {
  r = (getline junk < path)
  close(path)
  return (r >= 0)
}

# dep_node — declared in package.json, or already a local binary.  The binary
# check is what makes `npx tsc` pass in a project with typescript installed:
# "tsc" is never a dependency NAME, it is node_modules/.bin/tsc.
function dep_node(name,   pj, S, i, body, p, q) {
  if (name == "") return 1
  if (exists(PROJ "/node_modules/.bin/" name)) return 1
  pj = slurp(PROJ "/package.json")
  if (pj == "") return 0
  gsub(/[\n\r\t]/, " ", pj)
  split("dependencies devDependencies optionalDependencies peerDependencies", S, " ")
  for (i = 1; i <= 4; i++) {
    p = index(pj, "\"" S[i] "\"")
    if (p == 0) continue
    body = substr(pj, p + length(S[i]) + 2)
    q = index(body, "{")
    if (q == 0) continue
    body = substr(body, q + 1)
    q = index(body, "}")            # a dependency map has no nested object
    if (q > 0) body = substr(body, 1, q - 1)
    if (index(body, "\"" name "\"") > 0) return 1
  }
  return 0
}

# dep_rust — a [*dependencies] key in Cargo.toml, or any package in Cargo.lock.
# Cargo.lock includes transitive crates, which is the closest analogue Rust has
# to "already in this project's tree".
function dep_rust(name,   t, L, nl, i, l, insec) {
  if (name == "") return 1
  t = slurp(PROJ "/Cargo.toml")
  if (t != "") {
    nl = split(t, L, "\n"); insec = 0
    for (i = 1; i <= nl; i++) {
      l = L[i]; gsub(/^[ \t]+|[ \t]+$/, "", l)
      if (substr(l, 1, 1) == "[") { insec = (l ~ /dependencies\]$/); continue }
      if (!insec || l == "" || substr(l, 1, 1) == "#") continue
      if (l ~ ("^\"?" name "\"?[ \t]*=")) return 1
    }
  }
  t = slurp(PROJ "/Cargo.lock")
  return (t != "" && index(t, "name = \"" name "\"") > 0)
}

# dep_go — a module in go.mod, or a package under one.  Note that `go install
# pkg@version` IGNORES go.mod by design ("go help install"), so this is not Go
# semantics: it is "the user already pinned this module here, so they know it".
function dep_go(spec,   t, L, nl, i, l, m) {
  if (spec == "") return 1
  sub(/@.*$/, "", spec)
  t = slurp(PROJ "/go.mod")
  if (t == "") return 0
  nl = split(t, L, "\n")
  for (i = 1; i <= nl; i++) {
    l = L[i]; gsub(/^[ \t]+|[ \t]+$/, "", l)
    sub(/^require[ \t]+/, "", l)
    if (l == "" || l ~ /^\/\// || l == "(" || l == ")" || substr(l, 1, 1) == "[") continue
    m = l; sub(/[ \t].*$/, "", m)
    if (m == "" || m == "module" || m == "go" || m == "toolchain") continue
    if (m == spec || index(spec "/", m "/") == 1) return 1
  }
  return 0
}

# dep_python — named anywhere in a dependency manifest.  Loose on purpose: the
# five file formats here have five grammars, and the cost of a real parser is
# paid on every Bash call.
function dep_python(name,   F, nf, i, t) {
  if (name == "") return 1
  nf = split("pyproject.toml requirements.txt requirements-dev.txt uv.lock poetry.lock Pipfile Pipfile.lock setup.cfg", F, " ")
  for (i = 1; i <= nf; i++) {
    t = slurp(PROJ "/" F[i])
    if (t != "" && t ~ ("(^|[^A-Za-z0-9_.-])" name "([^A-Za-z0-9_.-]|$)")) return 1
  }
  return 0
}

# ---------------------------------------------------------------- reporting

function gate(eco, runner, pkg) { print "GATE|" eco "|" runner "|" pkg; return 1 }

function report(eco, runner, pkg,   name) {
  if (pkg == "" || is_localish(pkg)) return 0
  if (is_remote_spec(pkg)) return gate(eco, runner, pkg)
  if (eco == "node")   { if (dep_node(node_name(pkg))) return 0 }
  if (eco == "python") { if (dep_python(py_name(pkg))) return 0 }
  if (eco == "rust")   { if (dep_rust(rust_name(pkg))) return 0 }
  if (eco == "go")     { if (dep_go(pkg)) return 0 }
  return gate(eco, runner, pkg)
}

# ---------------------------------------------------------------- per-ecosystem

# node_scan — npx / npm exec / npm x / pnpm dlx / yarn dlx / bunx / bun x.
# `pnpm exec` and `yarn exec` are absent on purpose: they run a binary that is
# already in the project and never fetch.
function node_scan(T, n, i, runner,   a, pkg) {
  pkg = ""
  while (i <= n) {
    a = T[i]
    if (a == "--") { i++; continue }
    # npx is being told never to install; npm's modern spelling is --no.
    if (a == "--no-install" || a == "--no") return 0
    if (a == "-p" || a == "--package") { if (i < n) { pkg = T[i+1]; break } ; i++; continue }
    if (a ~ /^(-p|--package)=/) { pkg = a; sub(/^[^=]*=/, "", pkg); break }
    # Value-taking flags whose value is not the package.
    if (a == "-c" || a == "--call" || a == "-w" || a == "--workspace") { i += 2; continue }
    if (a ~ /^-/) { i++; continue }
    pkg = a; break
  }
  return report("node", runner, pkg)
}

# py_scan — uvx / uv tool run / pipx run.  --from (uv) and --spec (pipx) name
# the package when it differs from the command.
function py_scan(T, n, i, runner,   a, pkg) {
  pkg = ""
  while (i <= n) {
    a = T[i]
    if (a == "--") { i++; continue }
    if (a == "--from" || a == "--spec") { if (i < n) { pkg = T[i+1]; break } ; i++; continue }
    if (a ~ /^(--from|--spec)=/) { pkg = a; sub(/^[^=]*=/, "", pkg); break }
    if (a == "-w" || a == "--with" || a == "-p" || a == "--python" \
        || a == "--index" || a == "--index-url" || a == "--constraint") { i += 2; continue }
    if (a ~ /^-/) { i++; continue }
    pkg = a; break
  }
  return report("python", runner, pkg)
}

# py_with_scan — `uv run --with <pkg> script.py` builds an ephemeral environment
# around a downloaded package.  A bare `uv run script.py` uses the project's own
# dependencies and is not a fetch, so only --with is looked at.
function py_with_scan(T, n, i, runner,   a, pkg) {
  pkg = ""
  while (i <= n) {
    a = T[i]
    if (a == "-w" || a == "--with") { if (i < n) { pkg = T[i+1]; break } ; i++; continue }
    if (a ~ /^(-w|--with)=/) { pkg = a; sub(/^[^=]*=/, "", pkg); break }
    i++
  }
  return report("python", runner, pkg)
}

function rust_optarg(f) {
  return (f ~ /^(--vers|--branch|--tag|--rev|--root|--target|--profile|--bin|--example|--features|--target-dir|--config|--message-format|--artifact-dir|-F|-j|--jobs|-Z)$/)
}

# rust_scan — `cargo install` and cargo-binstall.  --path is a local crate and
# never a download; --list only prints.  A --git source is gated whatever the
# manifests say: the code comes from that URL, not from the project's registry
# dependency of the same name.
function rust_scan(T, n, i, runner,   a, pkg, git) {
  pkg = ""; git = ""
  while (i <= n) {
    a = T[i]
    if (a == "--") { i++; continue }
    if (a == "--path" || a ~ /^--path=/) return 0
    if (a == "--list") return 0
    if (a == "--git" || a == "--index" || a == "--registry") { if (i < n) git = T[i+1]; i += 2; continue }
    if (a ~ /^(--git|--index|--registry)=/) { git = a; sub(/^[^=]*=/, "", git); i++; continue }
    # A BARE --version/-V is the version query; with an operand after it, it
    # pins the crate version instead.
    if (a == "--version" || a == "-V") { if (i < n) { i += 2; continue } ; return 0 }
    if (a ~ /^-/) { if (rust_optarg(a) && i < n) i++; i++; continue }
    pkg = a; break
  }
  if (git != "") return gate("rust", runner, (pkg != "" ? pkg " from " git : git))
  return report("rust", runner, pkg)
}

# go_scan — `go run pkg@version` and `go install pkg@version`.  The @version
# suffix IS the discriminator: `go help install` says those forms fetch in
# module-aware mode and ignore go.mod, while `go build`, `go run ./...`,
# `go run .` and `go install ./cmd/x` only compile local code.
function go_scan(T, n, i, runner,   a) {
  while (i <= n) {
    a = T[i]
    if (a == "--") { i++; continue }
    if (a == "-exec" || a == "-o" || a == "-tags" || a == "-mod" || a == "-ldflags" \
        || a == "-gcflags" || a == "-asmflags" || a == "-buildmode" || a == "-overlay" \
        || a == "-pkgdir" || a == "-toolexec" || a == "-covermode" || a == "-p" || a == "-C") { i += 2; continue }
    if (a ~ /^-/) { i++; continue }
    break                                      # the package operand
  }
  if (i > n) return 0
  return (index(T[i], "@") > 0) ? report("go", runner, T[i]) : 0
}

# decide — route one stage's command word to its ecosystem.
function decide(c0, T, n,   s1, s2) {
  s1 = (CWI + 1 <= n) ? T[CWI+1] : ""
  s2 = (CWI + 2 <= n) ? T[CWI+2] : ""
  if (c0 == "npx")  return node_scan(T, n, CWI + 1, "npx")
  if (c0 == "bunx") return node_scan(T, n, CWI + 1, "bunx")
  if (c0 == "npm"  && (s1 == "exec" || s1 == "x")) return node_scan(T, n, CWI + 2, "npm " s1)
  if (c0 == "pnpm" && s1 == "dlx")  return node_scan(T, n, CWI + 2, "pnpm dlx")
  if (c0 == "yarn" && s1 == "dlx")  return node_scan(T, n, CWI + 2, "yarn dlx")
  if (c0 == "bun"  && s1 == "x")    return node_scan(T, n, CWI + 2, "bun x")
  if (c0 == "uvx")  return py_scan(T, n, CWI + 1, "uvx")
  if (c0 == "uv") {
    if (s1 == "tool" && s2 == "run") return py_scan(T, n, CWI + 3, "uv tool run")
    if (s1 == "run")                 return py_with_scan(T, n, CWI + 2, "uv run --with")
  }
  if (c0 == "pipx" && s1 == "run")  return py_scan(T, n, CWI + 2, "pipx run")
  if (c0 == "cargo-binstall") return rust_scan(T, n, CWI + 1, "cargo-binstall")
  if (c0 == "cargo") {
    if (s1 == "install")  return rust_scan(T, n, CWI + 2, "cargo install")
    if (s1 == "binstall") return rust_scan(T, n, CWI + 2, "cargo binstall")
  }
  if (c0 == "go" && (s1 == "run" || s1 == "install")) return go_scan(T, n, CWI + 2, "go " s1)
  return 0
}

BEGIN {
  PROJ = ENVIRON["KIT_PROJECT_DIR"]
  if (PROJ == "") PROJ = "."
}
{ raw = raw $0 "\n" }
END {
  text = split_cmd(strip_heredocs(raw))
  nst = split(text, ST, "\001")
  for (q = 1; q <= nst; q++) {
    nstg = split(ST[q], STG, "\002")

    # Unwrap one level of `sh -c "<inner>"` / `eval "<inner>"`: the quoted
    # string is code, so it becomes a stage of its own.
    for (g = 1; g <= nstg && nstg < 64; g++) {
      n = tokenize(STG[g], T, Q); if (n == 0) continue
      ci = first_word(T, n); if (ci > n) continue
      w = base(T[ci])
      if (!(is_shell(w) || w == "eval" || is_wrapper(w))) continue
      for (i = ci + 1; i <= n; i++) if (Q[i] && T[i] ~ /[ \t]/) { STG[++nstg] = split_cmd(T[i]); break }
    }

    for (g = 1; g <= nstg; g++) {
      n = tokenize(STG[g], T, Q); if (n == 0) continue
      c0 = cmdword(T, n)
      if (c0 == "") continue
      if (decide(c0, T, n)) exit
    }
  }
}
