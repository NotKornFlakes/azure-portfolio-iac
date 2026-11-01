#!/usr/bin/env bash
# Checks the live site's security controls from the outside, the way a
# visitor or a scanner sees them. A green `terraform apply` only proves the
# API accepted the config; this proves the controls are actually served.
#
# Runs after every deploy and weekly (.github/workflows/). Run it yourself:
#   scripts/verify-live.sh                 # checks timfletcher.tech
#   scripts/verify-live.sh example.com     # any domain set up the same way
#
# Needs bash, curl, jq and GNU date (any Linux, WSL or a GitHub runner).
# Only public, unauthenticated requests: no secrets, nothing account-specific.
# Exits 1 if any check fails.

set -uo pipefail

DOMAIN="${1:-timfletcher.tech}"

# Overridable so the script can be tested against a local mock server
: "${BASE_URL:=https://${DOMAIN}}"
: "${WWW_URL:=https://www.${DOMAIN}}"
: "${HTTP_URL:=http://${DOMAIN}}"
# Google's public resolver, not Cloudflare's, so DNS is checked by a party
# that doesn't host the zone. It sets AD=true only if DNSSEC validates.
: "${DOH_URL:=https://dns.google/resolve}"
# Fail this many days before security.txt expires, so there's time to renew
: "${SECURITY_TXT_MIN_DAYS:=30}"

SITE_DIR="$(cd "$(dirname "$0")/.." && pwd)/site"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0
summary="| | Check | Result |\n|---|---|---|\n"

result() { # result <pass|fail> <check> <detail>
  local icon
  if [[ "$1" == pass ]]; then
    passed=$((passed + 1)); icon="✅"
    printf 'PASS  %s: %s\n' "$2" "$3"
  else
    failed=$((failed + 1)); icon="❌"
    printf 'FAIL  %s: %s\n' "$2" "$3"
    [[ -n "${GITHUB_ACTIONS:-}" ]] && printf '::error title=%s::%s\n' "$2" "$3"
  fi
  summary+="| ${icon} | $2 | ${3//|/\\|} |\n"
}

# fetch <name> <url>: saves headers to $TMP/<name>.h, prints the status code
fetch() {
  : > "$TMP/$1.h"
  curl -sS -o /dev/null -D "$TMP/$1.h" -w '%{http_code}' \
    --max-time 20 --retry 3 --retry-all-errors "$2" 2>/dev/null || true
}

# header <name> <header>: prints that header's value (case-insensitive)
header() {
  tr -d '\r' < "$TMP/$1.h" |
    awk -v h="$(tr '[:upper:]' '[:lower:]' <<< "$2")" '
      { n = index($0, ":") }
      n && tolower(substr($0, 1, n - 1)) == h { print substr($0, n + 2); exit }'
}

# expect <check> <name> <header> <required substring>
expect() {
  local value
  value="$(header "$2" "$3")"
  if [[ "${value,,}" == *"${4,,}"* ]]; then
    result pass "$1" "$3: $value"
  else
    result fail "$1" "$3 should contain '$4', got '${value:-<missing>}'"
  fi
}

# dns <name> <type>: prints the resolver's JSON answer
dns() {
  curl -sS --max-time 20 --retry 3 --retry-all-errors \
    -H 'accept: application/dns-json' "${DOH_URL}?name=$1&type=$2" 2>/dev/null || echo '{}'
}

echo "Checking ${DOMAIN}"
echo

# --- HTTPS -----------------------------------------------------------------

redirect="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 \
  --retry 3 --retry-all-errors "${HTTP_URL}/" 2>/dev/null || true)"
if [[ "$redirect" =~ ^30[1278]\ ${BASE_URL}/?$ ]]; then
  result pass "HTTP redirects to HTTPS" "$redirect"
else
  result fail "HTTP redirects to HTTPS" "expected 301/308 to ${BASE_URL}/, got '$redirect'"
fi

code="$(fetch home "${BASE_URL}/")"
if [[ "$code" == 200 ]]; then
  result pass "Home page" "HTTP $code"
else
  result fail "Home page" "expected 200, got $code"
fi

code="$(fetch www "${WWW_URL}/")"
if [[ "$code" == 200 ]]; then
  result pass "www" "HTTP $code"
else
  result fail "www" "expected 200, got $code"
fi

# --- Security headers on the home page -------------------------------------

expect "HSTS for a year" home Strict-Transport-Security "max-age=31536000"
expect "HSTS covers subdomains" home Strict-Transport-Security "includeSubDomains"
expect "No MIME sniffing" home X-Content-Type-Options "nosniff"
expect "No framing" home X-Frame-Options "DENY"
expect "Referrer policy" home Referrer-Policy "strict-origin-when-cross-origin"
expect "Permissions policy" home Permissions-Policy "camera=()"
expect "Cross-origin opener isolation" home Cross-Origin-Opener-Policy "same-origin"
expect "Cross-origin resource policy" home Cross-Origin-Resource-Policy "same-origin"

csp="$(header home Content-Security-Policy)"
missing=()
for directive in "default-src 'none'" "script-src 'none'" "frame-ancestors 'none'" \
  "base-uri 'none'" "form-action 'none'"; do
  [[ "$csp" == *"$directive"* ]] || missing+=("$directive")
done
if [[ -z "$csp" ]]; then
  result fail "Content-Security-Policy" "header missing"
elif ((${#missing[@]})); then
  result fail "Content-Security-Policy" "missing: ${missing[*]}"
else
  result pass "Content-Security-Policy" "no scripts, no framing, no base or form targets"
fi
if [[ -n "$csp" && "$csp" != *unsafe-* && "$csp" != *http* && "$csp" != *'*'* ]]; then
  result pass "CSP allows first-party only" "no 'unsafe-*', no third-party origins, no wildcards"
else
  result fail "CSP allows first-party only" "got '${csp:-<missing>}'"
fi

# --- Other responses --------------------------------------------------------

# Unknown paths: the 404 page needs the same protection as real pages
code="$(fetch notfound "${BASE_URL}/verify-live-$RANDOM$RANDOM")"
if [[ "$code" == 404 && -n "$(header notfound Content-Security-Policy)" ]]; then
  result pass "404 page" "HTTP 404 with a CSP"
else
  result fail "404 page" "expected 404 with a CSP, got $code"
fi

# The PDF skips the CSP by design (headers.tf), but not the framing block
code="$(fetch resume "${BASE_URL}/resume.pdf")"
if [[ "$code" == 200 && "$(header resume Content-Type)" == application/pdf* &&
  "$(header resume X-Frame-Options)" == DENY ]]; then
  result pass "Résumé PDF" "HTTP 200, application/pdf, not frameable"
else
  result fail "Résumé PDF" "HTTP $code, $(header resume Content-Type), X-Frame-Options '$(header resume X-Frame-Options)'"
fi

# The first font the home page preloads, cached by browsers for a year
font="$(grep -o '/fonts/[^"]*\.woff2' "$SITE_DIR/index.html" 2>/dev/null | head -1)"
if [[ -n "$font" ]]; then
  code="$(fetch font "${BASE_URL}${font}")"
  if [[ "$code" == 200 && "$(header font Cache-Control)" == *immutable* ]]; then
    result pass "Self-hosted font" "$font, Cache-Control: $(header font Cache-Control)"
  else
    result fail "Self-hosted font" "$font: HTTP $code, Cache-Control '$(header font Cache-Control)'"
  fi
fi

# --- security.txt (RFC 9116) ------------------------------------------------

code="$(curl -sS -o "$TMP/security.txt" -w '%{http_code}' --max-time 20 --retry 3 \
  --retry-all-errors "${BASE_URL}/.well-known/security.txt" 2>/dev/null || true)"
expires="$(tr -d '\r' < "$TMP/security.txt" 2>/dev/null | sed -n 's/^Expires: *//p' | head -1)"
expires_at="$(date -d "$expires" +%s 2>/dev/null || echo 0)"
days_left=$(((expires_at - $(date +%s)) / 86400))
if [[ "$code" != 200 || -z "$expires" ]]; then
  result fail "security.txt" "HTTP $code, Expires '${expires:-<missing>}'"
elif ((days_left < SECURITY_TXT_MIN_DAYS)); then
  result fail "security.txt" "expires $expires, in $days_left days: update Expires in site/.well-known/security.txt"
else
  result pass "security.txt" "expires in $days_left days"
fi

# --- DNS --------------------------------------------------------------------

ad="$(dns "$DOMAIN" A | jq -r '.AD // false')"
if [[ "$ad" == true ]]; then
  result pass "DNSSEC" "answers validate (AD flag set)"
else
  result fail "DNSSEC" "resolver did not validate the answer (AD=$ad)"
fi

mx="$(dns "$DOMAIN" MX | jq -r '[.Answer[]?.data] | join(", ")')"
if [[ "$mx" == "0 ." ]]; then
  result pass "Null MX" "MX $mx"
else
  result fail "Null MX" "expected '0 .', got '${mx:-<none>}'"
fi

spf="$(dns "$DOMAIN" TXT | jq -r '[.Answer[]?.data | select(test("v=spf1"))] | join(", ")')"
if [[ "$spf" == *"v=spf1 -all"* ]]; then
  result pass "SPF" "$spf"
else
  result fail "SPF" "expected 'v=spf1 -all', got '${spf:-<none>}'"
fi

dmarc="$(dns "_dmarc.$DOMAIN" TXT | jq -r '[.Answer[]?.data] | join(", ")')"
if [[ "$dmarc" == *"p=reject"* ]]; then
  result pass "DMARC" "$dmarc"
else
  result fail "DMARC" "expected p=reject, got '${dmarc:-<none>}'"
fi

# --- Result -----------------------------------------------------------------

echo
echo "$passed passed, $failed failed"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Live security checks: ${DOMAIN}"
    echo
    printf '%b' "$summary"
    echo
    echo "$passed passed, $failed failed"
  } >> "$GITHUB_STEP_SUMMARY"
fi
((failed == 0))
