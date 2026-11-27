#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl jq python3 nix git
# Refresh sources.json (Linux) and sources-darwin.json (Apple Silicon) from
# upstream. No binaries are stored in the repo, only URLs/revisions and hashes;
# Nix fetches everything at build time.
#
# Phoenix: build number, URL and SHA-256 are scraped from sunbird.tools for
#          both linux-x64 and macos-arm64 (the hash comes from Sunbird, the
#          file from the mirror, so Nix checks one against the other).
# Linux loader: version from assets.sunbird.tools/version.json. Sunbird
#          publishes no hash for it, so the file is downloaded once and hashed
#          (trust on first use).
# Darwin loader: tracks upstream PR #67 (or sunbird-tools/sunbird main once
#          merged), prefetching the GitHub source archive and sunhook-sys git
#          dependency from Cargo.lock whenever the revision moves.
#
# Exit code 0 with "unchanged" on stdout means there was nothing to do.
set -euo pipefail
cd "$(dirname "$0")"

page=${SUNBIRD_PAGE:-https://sunbird.tools/}
site=${SUNBIRD_SITE:-https://assets.sunbird.tools}
darwin_pr_api=${SUNBIRD_DARWIN_PR_API:-https://api.github.com/repos/sunbird-tools/sunbird/pulls/67}
darwin_main_api=${SUNBIRD_DARWIN_MAIN_API:-https://api.github.com/repos/sunbird-tools/sunbird/commits/main}

gh_api() {
  local -a headers=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fsSL --proto =https "${headers[@]}" "$1"
}

html=$(curl -fsSL --proto =https "$page")
{
  read -r linux_build linux_url linux_hex
  read -r darwin_build darwin_url darwin_hex
} < <(printf %s "$html" | python3 -I -c '
import re, sys
s = sys.stdin.read()
for label, pat in [
    ("linux-x64 AppImage", r"https://dl\.redeem\.saarland/desktop/(\d+)/linux-x64\.AppImage"),
    ("macos-arm64 zip", r"https://dl\.redeem\.saarland/desktop/(\d+)/macos-arm64\.zip"),
]:
    m = re.search(pat, s)
    if not m:
        sys.exit(f"no {label} link on the page")
    h = re.search(r"\b[0-9a-f]{64}\b", s[m.end():m.end() + 2000])
    if not h:
        sys.exit(f"no SHA-256 next to the {label} link")
    print(m.group(1), m.group(0), h.group(0))
')

linux_phoenix_hash=$(nix --extra-experimental-features nix-command hash convert --hash-algo sha256 --to sri "$linux_hex")
darwin_phoenix_hash=$(nix --extra-experimental-features nix-command hash convert --hash-algo sha256 --to sri "$darwin_hex")

# --- Linux loader (sources.json) ---
loader_ver=$(curl -fsSL --proto =https "$site/version.json" | jq -er .loader)
old_loader_ver=$(jq -r .loader.version sources.json)
if [ "$loader_ver" = "$old_loader_ver" ]; then
  loader_hash=$(jq -r .loader.hash sources.json)
else
  loader_hash=$(nix --extra-experimental-features nix-command store prefetch-file --json \
    "$site/plugins/libphoenix-linux-x86_64.so" | jq -r .hash)
fi

new_linux=$(jq -n \
  --arg pv "$linux_build" --arg pu "$linux_url" --arg ph "$linux_phoenix_hash" \
  --arg lv "$loader_ver" --arg lu "$site/plugins/libphoenix-linux-x86_64.so" --arg lh "$loader_hash" \
  '{phoenix: {version: $pv, url: $pu, hash: $ph}, loader: {version: $lv, url: $lu, hash: $lh}}')

# --- Darwin loader (sources-darwin.json) ---
pr_json=$(gh_api "$darwin_pr_api")
pr_state=$(printf %s "$pr_json" | jq -r .state)
pr_merged=$(printf %s "$pr_json" | jq -r .merged)

if [ "$pr_state" = open ]; then
  darwin_owner=$(printf %s "$pr_json" | jq -er .head.repo.owner.login)
  darwin_repo=$(printf %s "$pr_json" | jq -er .head.repo.name)
  darwin_rev=$(printf %s "$pr_json" | jq -er .head.sha)
elif [ "$pr_merged" = true ]; then
  darwin_owner="sunbird-tools"
  darwin_repo="sunbird"
  darwin_rev=$(gh_api "$darwin_main_api" | jq -er .sha)
else
  echo "upstream macOS PR is closed without merge; refusing to update sources-darwin.json" >&2
  exit 1
fi

old_darwin_owner=$(jq -r .loader.owner sources-darwin.json)
old_darwin_repo=$(jq -r .loader.repo sources-darwin.json)
old_darwin_rev=$(jq -r .loader.rev sources-darwin.json)

if [ "$darwin_owner" = "$old_darwin_owner" ] && [ "$darwin_repo" = "$old_darwin_repo" ] && [ "$darwin_rev" = "$old_darwin_rev" ]; then
  darwin_loader_ver=$(jq -r .loader.version sources-darwin.json)
  darwin_loader_hash=$(jq -r .loader.hash sources-darwin.json)
  darwin_sunhook_hash=$(jq -r .loader.sunhookHash sources-darwin.json)
else
  commit_date=$(gh_api "https://api.github.com/repos/${darwin_owner}/${darwin_repo}/commits/${darwin_rev}" |
    jq -er '.commit.committer.date // .commit.author.date')
  darwin_loader_ver=$(python3 -I -c '
import datetime, sys
dt = datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).astimezone(datetime.timezone.utc)
print(f"{dt:%Y.%m.%d.%H%M}-{sys.argv[2][:7]}")
' "$commit_date" "$darwin_rev")

  prefetch_json=$(nix --extra-experimental-features "nix-command flakes" flake prefetch --json \
    "github:${darwin_owner}/${darwin_repo}/${darwin_rev}")
  darwin_loader_hash=$(printf %s "$prefetch_json" | jq -er .hash)
  darwin_store_path=$(printf %s "$prefetch_json" | jq -er .storePath)

  read -r sunhook_url sunhook_rev < <(python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    data = tomllib.load(fh)
for pkg in data.get("package", []):
    src = pkg.get("source", "")
    if pkg.get("name") == "sunhook-sys" and src.startswith("git+") and "#" in src:
        url, rev = src[4:].split("#", 1)
        print(url, rev)
        sys.exit(0)
sys.exit("sunhook-sys git source not found in Cargo.lock")
' "${darwin_store_path}/Cargo.lock")

  darwin_sunhook_hash=$(nix --extra-experimental-features "nix-command flakes" flake prefetch --json \
    "git+${sunhook_url}?rev=${sunhook_rev}" | jq -er .hash)
fi

new_darwin=$(jq -n \
  --arg pv "$darwin_build" --arg pu "$darwin_url" --arg ph "$darwin_phoenix_hash" \
  --arg lv "$darwin_loader_ver" --arg lo "$darwin_owner" --arg lr "$darwin_repo" \
  --arg rev "$darwin_rev" --arg lh "$darwin_loader_hash" --arg sh "$darwin_sunhook_hash" \
  '{
    phoenix: {version: $pv, url: $pu, hash: $ph},
    loader: {version: $lv, owner: $lo, repo: $lr, rev: $rev, hash: $lh, sunhookHash: $sh}
  }')

changed=false
if [ "$new_linux" != "$(jq . sources.json)" ]; then
  printf '%s\n' "$new_linux" >sources.json
  echo "phoenix: $linux_build ($linux_phoenix_hash)"
  echo "loader:  $loader_ver ($loader_hash)"
  changed=true
fi

if [ "$new_darwin" != "$(jq . sources-darwin.json)" ]; then
  printf '%s\n' "$new_darwin" >sources-darwin.json
  echo "darwin phoenix: $darwin_build ($darwin_phoenix_hash)"
  echo "darwin loader:  $darwin_loader_ver ($darwin_owner/$darwin_repo@${darwin_rev:0:7}, $darwin_loader_hash)"
  changed=true
fi

if [ "$changed" = false ]; then
  echo unchanged
  exit 0
fi
