#!/usr/bin/env bash
# The lint is a guard; this proves the guard actually fires.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$ROOT/scripts/site-lint.sh"
rc=0
fail() { echo "FAIL: $1" >&2; rc=1; }

[[ -f "$LINT" ]] || { echo "FAIL: $LINT missing" >&2; exit 1; }

# The real site must pass.
bash "$LINT" >/dev/null 2>&1 || fail "site-lint.sh must pass on the real site/"

# A third-party request must be caught.
tmp="$(mktemp -d)"
mkdir -p "$tmp/assets/css"
cat > "$tmp/index.html" <<'HTML'
<!doctype html><html><head>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter">
</head><body></body></html>
HTML
printf '@media (prefers-reduced-motion: reduce){*{animation:none}}\n' > "$tmp/assets/css/site.css"
if SITE_DIR="$tmp" bash "$LINT" >/dev/null 2>&1; then
  fail "site-lint.sh must reject an external host (fonts.googleapis.com)"
fi

# A missing local asset must be caught.
rm -rf "${tmp:?}"/*
mkdir -p "$tmp/assets/css"
cat > "$tmp/index.html" <<'HTML'
<!doctype html><html><head>
<link rel="stylesheet" href="assets/css/site.css">
<script src="assets/js/does-not-exist.js"></script>
</head><body></body></html>
HTML
printf '@media (prefers-reduced-motion: reduce){*{animation:none}}\n' > "$tmp/assets/css/site.css"
if SITE_DIR="$tmp" bash "$LINT" >/dev/null 2>&1; then
  fail "site-lint.sh must reject a reference to a missing local asset"
fi

# A clean URL (no extension) resolves to <name>.html, and / to index.html.
rm -rf "${tmp:?}"/*
mkdir -p "$tmp/assets/css"
cat > "$tmp/index.html" <<'HTML'
<!doctype html><html><head><link rel="stylesheet" href="assets/css/site.css"></head>
<body><a href="/">home</a><a href="/loom-alternative">loom</a></body></html>
HTML
cat > "$tmp/loom-alternative.html" <<'HTML'
<!doctype html><html><head><link rel="stylesheet" href="assets/css/site.css"></head><body></body></html>
HTML
printf '@media (prefers-reduced-motion: reduce){*{animation:none}}\n' > "$tmp/assets/css/site.css"
SITE_DIR="$tmp" bash "$LINT" >/dev/null 2>&1 \
  || fail "site-lint.sh must accept clean URLs backed by <name>.html and / by index.html"

# A clean URL with no backing file must still be caught.
rm -rf "${tmp:?}"/*
mkdir -p "$tmp/assets/css"
cat > "$tmp/index.html" <<'HTML'
<!doctype html><html><head><link rel="stylesheet" href="assets/css/site.css"></head>
<body><a href="/ghost-page">ghost</a></body></html>
HTML
printf '@media (prefers-reduced-motion: reduce){*{animation:none}}\n' > "$tmp/assets/css/site.css"
if SITE_DIR="$tmp" bash "$LINT" >/dev/null 2>&1; then
  fail "site-lint.sh must reject a clean URL with no backing .html"
fi

# A stylesheet with no reduced-motion block must be caught.
rm -rf "${tmp:?}"/*
mkdir -p "$tmp/assets/css"
printf '<!doctype html><html><head><link rel="stylesheet" href="assets/css/site.css"></head><body></body></html>\n' > "$tmp/index.html"
printf '.a{color:red}\n' > "$tmp/assets/css/site.css"
if SITE_DIR="$tmp" bash "$LINT" >/dev/null 2>&1; then
  fail "site-lint.sh must reject CSS with no prefers-reduced-motion block"
fi

rm -rf "$tmp"
[[ $rc -eq 0 ]] && echo "site-lint.test: all checks passed"
exit $rc
