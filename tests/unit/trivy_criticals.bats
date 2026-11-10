#!/usr/bin/env bats
# trivy-criticals: only critical CVEs with a fixed version count, each image and CVE once, the
# bound trips above it, and reports that cannot be read are never read as all clear.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # kubectl logs its arguments and answers from $SANDBOX/<resource>.json; a missing file is an
  # unreachable cluster
  cat > "$SANDBOX/bin/kubectl" <<KUBECTL
#!/usr/bin/env bash
echo "\$*" >> "$SANDBOX/kubectl.log"
for a; do case "\$a" in vulnerabilityreports|replicasets) cat "$SANDBOX/\$a.json" 2>/dev/null; exit; esac; done
exit 1
KUBECTL
  chmod +x "$SANDBOX/bin/kubectl"
  echo '{"items":[]}' > "$SANDBOX/replicasets.json"
}

# report <repository> <tag> <vulnerability json objects...>; OWNER="<kind> <ns> <name>" labels it
report() {
  local repo="$1" tag="$2"; shift 2
  local kind ns name
  read -r kind ns name <<<"${OWNER:-Deployment default app}"
  local IFS=,
  printf '{"metadata":{"labels":{"trivy-operator.resource.kind":"%s","trivy-operator.resource.namespace":"%s","trivy-operator.resource.name":"%s"}},"report":{"registry":{"server":"ghcr.io"},"artifact":{"repository":"%s","tag":"%s","digest":"sha256:d"},"vulnerabilities":[%s]}}' "$kind" "$ns" "$name" "$repo" "$tag" "$*"
}
# vuln <id> <severity> <fixedVersion, empty for none>
vuln() { printf '{"vulnerabilityID":"%s","severity":"%s","fixedVersion":"%s"}' "$1" "$2" "$3"; }
reports() { local IFS=,; printf '{"items":[%s]}' "$*" > "$SANDBOX/vulnerabilityreports.json"; }

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
  echo 'not json' > "$SANDBOX/vulnerabilityreports.json"
  run "$REPO_ROOT/.local/bin/trivy-criticals" --max 0
  assert_failure 2
}

@test "a bound that is not a count, or a flag with no value, is a usage error" {
  run "$REPO_ROOT/.local/bin/trivy-criticals" --max lots
  assert_failure 64
  run "$REPO_ROOT/.local/bin/trivy-criticals" --max
  assert_failure 64
}

@test "a ReplicaSet scaled to 0 runs nothing and does not count" {
  echo '{"items":[{"metadata":{"namespace":"ns","name":"old"},"spec":{"replicas":0}},{"metadata":{"namespace":"ns","name":"live"},"spec":{"replicas":1}}]}' > "$SANDBOX/replicasets.json"
  reports "$(OWNER='ReplicaSet ns old' report app/a 1.0 "$(vuln CVE-1 CRITICAL 1.1)")" \
          "$(OWNER='ReplicaSet ns live' report app/a 2.0 "$(vuln CVE-4 CRITICAL 3)")" \
          "$(OWNER='CronJob ns old' report app/c 1.0 "$(vuln CVE-5 CRITICAL 3)")"
  run "$REPO_ROOT/.local/bin/trivy-criticals"
  assert_success
  assert_output '   1 fixable  ghcr.io/app/a:2.0
   1 fixable  ghcr.io/app/c:1.0
Fixable critical CVEs on home-k3s: 2 in 2 images; 0 more have no fix'
}

@test "--context picks the cluster, and an image with no tag is named by its digest" {
  reports '{"report":{"registry":{"server":"ghcr.io"},"artifact":{"repository":"app/a","digest":"sha256:d"},"vulnerabilities":[{"vulnerabilityID":"CVE-1","severity":"CRITICAL","fixedVersion":"1"}]}}'
  run "$REPO_ROOT/.local/bin/trivy-criticals" --context other
  assert_success
  assert_line --index 0 '   1 fixable  ghcr.io/app/a@sha256:d'
  assert_line --index 1 'Fixable critical CVEs on other: 1 in 1 images; 0 more have no fix'
  run grep -c -- '--context other .* get vulnerabilityreports -A -o json' "$SANDBOX/kubectl.log"
  assert_output 1
}
