#!/usr/bin/env bats
# trivy-criticals: only critical CVEs with a fixed version count, each image and CVE once, the
# bound trips above it, and reports that cannot be read are never read as all clear.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # kubectl answers from $SANDBOX/reports.json; a missing file is an unreachable cluster
  cat > "$SANDBOX/bin/kubectl" <<KUBECTL
#!/usr/bin/env bash
cat "$SANDBOX/reports.json" 2>/dev/null
KUBECTL
  chmod +x "$SANDBOX/bin/kubectl"
}

# report <repository> <tag> <vulnerability json objects...>
report() {
  local repo="$1" tag="$2"; shift 2
  local IFS=,
  printf '{"report":{"registry":{"server":"ghcr.io"},"artifact":{"repository":"%s","tag":"%s"},"vulnerabilities":[%s]}}' "$repo" "$tag" "$*"
}
# vuln <id> <severity> <fixedVersion, empty for none>
vuln() { printf '{"vulnerabilityID":"%s","severity":"%s","fixedVersion":"%s"}' "$1" "$2" "$3"; }
reports() { local IFS=,; printf '{"items":[%s]}' "$*" > "$SANDBOX/reports.json"; }

@test "only criticals with a fix count; high and no-fix ones do not" {
  reports "$(report app/a 1.0 "$(vuln CVE-1 CRITICAL 1.1)" "$(vuln CVE-2 CRITICAL '')" "$(vuln CVE-3 HIGH 2.0)")"
  run "$REPO_ROOT/.local/bin/trivy-criticals" --max 1
  assert_success
  assert_line --index 0 '   1 fixable  ghcr.io/app/a:1.0'
  assert_line --index 1 'Fixable critical CVEs on home-k3s: 1 in 1 images (bound 1); 1 more have no fix'
}

@test "an image in two workloads and a CVE in two packages count once" {
  local a; a="$(report app/a 1.0 "$(vuln CVE-1 CRITICAL 1.1)" "$(vuln CVE-1 CRITICAL '')" "$(vuln CVE-4 CRITICAL 3)")"
  reports "$a" "$a" "$(report app/b 2.0 "$(vuln CVE-1 CRITICAL 1.1)")"
  run "$REPO_ROOT/.local/bin/trivy-criticals"
  assert_success
  assert_output '   2 fixable  ghcr.io/app/a:1.0
   1 fixable  ghcr.io/app/b:2.0
Fixable critical CVEs on home-k3s: 3 in 2 images; 0 more have no fix'
}

@test "above the bound trips, with the totals on the last line" {
  reports "$(report app/a 1.0 "$(vuln CVE-1 CRITICAL 1.1)" "$(vuln CVE-4 CRITICAL 3)")"
  run "$REPO_ROOT/.local/bin/trivy-criticals" --max 1
  assert_failure 1
  assert_line --index -1 'Fixable critical CVEs on home-k3s: 2 in 1 images (bound 1); 0 more have no fix'
}

@test "no criticals at all is zero, not an error" {
  reports "$(report app/a 1.0)"
  run "$REPO_ROOT/.local/bin/trivy-criticals" --max 0
  assert_success
  assert_output 'Fixable critical CVEs on home-k3s: 0 in 0 images (bound 0); 0 more have no fix'
}

@test "reports that cannot be read exit 2, never all clear" {
  run "$REPO_ROOT/.local/bin/trivy-criticals" --max 0
  assert_failure 2
  assert_output 'Trivy vulnerability reports on home-k3s could not be read'
  echo 'not json' > "$SANDBOX/reports.json"
  run "$REPO_ROOT/.local/bin/trivy-criticals" --max 0
  assert_failure 2
}

@test "a bound that is not a count is a usage error" {
  run "$REPO_ROOT/.local/bin/trivy-criticals" --max lots
  assert_failure 64
}
