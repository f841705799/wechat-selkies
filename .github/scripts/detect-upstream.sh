#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Basic config
# -----------------------------
STATE_FILE="${STATE_FILE:-versions/upstream.env}"
TMP_DIR="$(mktemp -d)"
CHANGE_DETECTED="false"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# -----------------------------
# Load previous state if exists
# -----------------------------
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi

# -----------------------------
# WeChat URLs
# -----------------------------
WECHAT_AMD64_URL="${WECHAT_AMD64_URL:-https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_x86_64.deb}"
WECHAT_ARM64_URL="${WECHAT_ARM64_URL:-https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_arm64.deb}"

# -----------------------------
# QQ config
# -----------------------------
QQ_CONFIG_URL="${QQ_CONFIG_URL:-https://cdn-go.cn/qq-web/im.qq.com_new/latest/rainbow/pcConfig.json}"

# -----------------------------
# Helpers
# -----------------------------
download_package() {
  local source_path="$1"
  local destination="$2"

  case "$source_path" in
    http://*|https://*)
      curl --fail --silent --show-error \
        --retry 3 --retry-delay 5 --retry-all-errors \
        -o "$destination" "$source_path"
      ;;
    *)
      cp "$source_path" "$destination"
      ;;
  esac
}

read_metadata() {
  local package_name="$1"
  local arch="$2"
  local source_path="$3"

  local package_path="$TMP_DIR/${package_name}-${arch}.deb"
  local version_var="${package_name}_${arch}_VERSION"
  local sha_var="${package_name}_${arch}_SHA256"

  local current_version="${!version_var:-}"
  local current_sha="${!sha_var:-}"

  local detected_version
  local detected_sha

  echo "🔍 Checking ${package_name} ${arch}"
  echo "    Source: ${source_path}"

  download_package "$source_path" "$package_path"

  detected_version="$(dpkg-deb -f "$package_path" Version)"
  detected_sha="$(sha256sum "$package_path" | awk '{print $1}')"

  printf -v "$version_var" '%s' "$detected_version"
  printf -v "$sha_var" '%s' "$detected_sha"

  if [[ "$current_version" != "$detected_version" || "$current_sha" != "$detected_sha" ]]; then
    CHANGE_DETECTED="true"
  fi
}

# -----------------------------
# Fetch QQ Linux deb URLs
# -----------------------------
fetch_qq_linux_deb_urls() {
  local config_json

  echo "🌐 Fetching QQ config from $QQ_CONFIG_URL"
  config_json="$(curl --fail --silent --show-error \
    --retry 3 --retry-delay 5 "$QQ_CONFIG_URL")"

  QQ_AMD64_URL="$(jq -r '.Linux.x64DownloadUrl.deb' <<<"$config_json")"
  QQ_ARM64_URL="$(jq -r '.Linux.armDownloadUrl.deb' <<<"$config_json")"
  QQ_LINUX_VERSION_FROM_JSON="$(jq -r '.Linux.version' <<<"$config_json")"

  if [[ -z "$QQ_AMD64_URL" || "$QQ_AMD64_URL" == "null" ]]; then
    echo "❌ Failed to resolve QQ amd64 deb URL"
    exit 1
  fi

  if [[ -z "$QQ_ARM64_URL" || "$QQ_ARM64_URL" == "null" ]]; then
    echo "❌ Failed to resolve QQ arm64 deb URL"
    exit 1
  fi

  echo "✅ QQ Linux version (from JSON): $QQ_LINUX_VERSION_FROM_JSON"
}

# -----------------------------
# Detect WeChat
# -----------------------------
read_metadata "WECHAT" "AMD64" "$WECHAT_AMD64_URL"
read_metadata "WECHAT" "ARM64" "$WECHAT_ARM64_URL"

# -----------------------------
# Detect QQ
# -----------------------------
fetch_qq_linux_deb_urls
read_metadata "QQ" "AMD64" "$QQ_AMD64_URL"
read_metadata "QQ" "ARM64" "$QQ_ARM64_URL"

# -----------------------------
# Timestamp
# -----------------------------
if [[ "$CHANGE_DETECTED" == "true" || ! -f "$STATE_FILE" ]]; then
  LAST_CHECKED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
fi

# -----------------------------
# Write new state file
# -----------------------------
NEW_STATE_FILE="$TMP_DIR/upstream.env"
cat > "$NEW_STATE_FILE" <<EOF
# Upstream package state tracked by automation.

# ---- WeChat ----
WECHAT_AMD64_URL="$WECHAT_AMD64_URL"
WECHAT_ARM64_URL="$WECHAT_ARM64_URL"
WECHAT_AMD64_VERSION="$WECHAT_AMD64_VERSION"
WECHAT_ARM64_VERSION="$WECHAT_ARM64_VERSION"
WECHAT_AMD64_SHA256="$WECHAT_AMD64_SHA256"
WECHAT_ARM64_SHA256="$WECHAT_ARM64_SHA256"

# ---- QQ ----
QQ_AMD64_URL="$QQ_AMD64_URL"
QQ_ARM64_URL="$QQ_ARM64_URL"
QQ_AMD64_VERSION="$QQ_AMD64_VERSION"
QQ_ARM64_VERSION="$QQ_ARM64_VERSION"
QQ_AMD64_SHA256="$QQ_AMD64_SHA256"
QQ_ARM64_SHA256="$QQ_ARM64_SHA256"
QQ_LINUX_VERSION_FROM_JSON="$QQ_LINUX_VERSION_FROM_JSON"

LAST_CHECKED_AT="$LAST_CHECKED_AT"
EOF

mkdir -p "$(dirname "$STATE_FILE")"
if [[ ! -f "$STATE_FILE" ]] || ! cmp -s "$NEW_STATE_FILE" "$STATE_FILE"; then
  cp "$NEW_STATE_FILE" "$STATE_FILE"
fi

# -----------------------------
# Console output
# -----------------------------
echo ""
echo "✅ Detection completed"
echo "Changed: $CHANGE_DETECTED"
echo "WeChat amd64: $WECHAT_AMD64_VERSION"
echo "WeChat arm64: $WECHAT_ARM64_VERSION"
echo "QQ amd64:     $QQ_AMD64_VERSION"
echo "QQ arm64:     $QQ_ARM64_VERSION"

# -----------------------------
# GitHub Actions outputs
# -----------------------------
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "changed=$CHANGE_DETECTED"

    echo "wechat_amd64_version=$WECHAT_AMD64_VERSION"
    echo "wechat_arm64_version=$WECHAT_ARM64_VERSION"

    echo "qq_amd64_version=$QQ_AMD64_VERSION"
    echo "qq_arm64_version=$QQ_ARM64_VERSION"
    echo "qq_amd64_url=$QQ_AMD64_URL"
    echo "qq_arm64_url=$QQ_ARM64_URL"

    echo "state_file=$STATE_FILE"
  } >> "$GITHUB_OUTPUT"
fi

# -----------------------------
# GitHub Actions summary
# -----------------------------
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Upstream Detection"
    echo ""
    echo "- Changed: \`$CHANGE_DETECTED\`"
    echo ""
    echo "### WeChat"
    echo "- amd64: \`$WECHAT_AMD64_VERSION\`"
    echo "- arm64: \`$WECHAT_ARM64_VERSION\`"
    echo ""
    echo "### QQ"
    echo "- amd64: \`$QQ_AMD64_VERSION\`"
    echo "- arm64: \`$QQ_ARM64_VERSION\`"
    echo "- JSON version: \`$QQ_LINUX_VERSION_FROM_JSON\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
