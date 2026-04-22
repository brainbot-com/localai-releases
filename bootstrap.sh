#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage:
  ./bootstrap.sh RELEASES_DIR --from-repo VERSION --repo-owner OWNER --repo-name NAME --compose-project-name PROJECT [--use-github-token]
  ./bootstrap.sh RELEASES_DIR --from-tar /path/to/release.tar.gz --repo-owner OWNER --repo-name NAME --compose-project-name PROJECT [--use-github-token]

This script creates the releases directory structure, installs the specified
release source (GitHub release or local tarball), and starts the docker
compose stack.

Token behavior:
  GITHUB_TOKEN env var is ignored unless --use-github-token is provided.
  With --use-github-token, GITHUB_TOKEN is required and will be persisted to .env.
EOF
}

die_usage() {
  echo "$1" >&2
  usage >&2
  exit 1
}

SEMVER_REGEX='[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?(\+[0-9A-Za-z][0-9A-Za-z.-]*)?'
RELEASE_ARCHIVE_ASSET_REGEX='^localai-(.+)\.tar\.gz$'

# Parse the positional releases directory first, then process named flags.
if [[ $# -eq 0 ]]; then
  die_usage "Missing required argument: RELEASES_DIR"
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

releases_dir="${1:-}"
shift

# Parsed CLI state.
source_mode=""
requested_version=""
tarball_path=""
releases_repo_owner=""
releases_repo_name=""
compose_project_name=""
use_github_token=false

# Parse flags. Source selection is mutually exclusive.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-repo)
      if [[ -n "${source_mode}" ]]; then
        die_usage "--from-repo and --from-tar are mutually exclusive"
      fi
      source_mode="repo"
      if [[ -z "${2:-}" ]]; then
        die_usage "Missing required argument: VERSION"
      fi
      requested_version="${2}"
      shift 2
      ;;
    --from-tar)
      if [[ -n "${source_mode}" ]]; then
        die_usage "--from-repo and --from-tar are mutually exclusive"
      fi
      source_mode="tar"
      if [[ -z "${2:-}" ]]; then
        die_usage "Missing required argument: TARBALL_PATH"
      fi
      tarball_path="${2}"
      shift 2
      ;;
    --repo-owner)
      if [[ -z "${2:-}" ]]; then
        die_usage "Missing required argument: OWNER"
      fi
      releases_repo_owner="${2}"
      shift 2
      ;;
    --repo-name)
      if [[ -z "${2:-}" ]]; then
        die_usage "Missing required argument: NAME"
      fi
      releases_repo_name="${2}"
      shift 2
      ;;
    --compose-project-name)
      if [[ -z "${2:-}" ]]; then
        die_usage "Missing required argument: PROJECT"
      fi
      compose_project_name="${2}"
      shift 2
      ;;
    --use-github-token)
      use_github_token=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "Unknown argument: $1"
      ;;
  esac
done

# Validate required inputs before doing any filesystem/network work.
if [[ -z "${source_mode}" ]]; then
  die_usage "Specify exactly one source: --from-repo or --from-tar"
fi
if [[ -z "${releases_repo_owner}" ]]; then
  die_usage "Missing required flag: --repo-owner"
fi
if [[ -z "${releases_repo_name}" ]]; then
  die_usage "Missing required flag: --repo-name"
fi
if [[ -z "${compose_project_name}" ]]; then
  die_usage "Missing required flag: --compose-project-name"
fi

if [[ "${source_mode}" == "repo" ]]; then
  if [[ ! "${requested_version}" =~ ^v?${SEMVER_REGEX}$ ]]; then
    echo "VERSION must be semantic (vMAJOR.MINOR.PATCH[-PRERELEASE][+BUILD] or MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD])" >&2
    exit 1
  fi
else
  if [[ ! -f "${tarball_path}" ]]; then
    echo "Tarball file not found: ${tarball_path}" >&2
    exit 1
  fi
fi

if [[ "${use_github_token}" == true && -z "${GITHUB_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN is required when --use-github-token is provided." >&2
  exit 1
fi

versions_dir="${releases_dir}/versions"

# Bootstrap expects a clean target directory so layout and activation are
# deterministic.
if [[ -e "${releases_dir}" ]]; then
  if [[ -n "$(ls -A "${releases_dir}" 2>/dev/null)" ]]; then
    echo "Releases directory must not exist or be empty: ${releases_dir}" >&2
    exit 1
  fi
fi

auth_header=""
if [[ "${use_github_token}" == true ]]; then
  auth_header="Authorization: Bearer ${GITHUB_TOKEN}"
fi

# All temporary download/extract artifacts live under temp_dir and are removed
# on exit (success or failure).
temp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${temp_dir}"
}
trap cleanup EXIT

version_from_tag=""
archive_path=""
if [[ "${source_mode}" == "repo" ]]; then
  # Repo mode resolves an exact GitHub tag and then downloads its release asset.
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for --from-repo but not installed. Please install jq and retry." >&2
    exit 1
  fi

  tag_name="v${requested_version#v}"
  release_url="https://api.github.com/repos/${releases_repo_owner}/${releases_repo_name}/releases/tags/${tag_name}"
  release_json="$(curl -sSf ${auth_header:+-H "${auth_header}"} "${release_url}")"

  tag_name_json="$(jq -er '.tag_name' <<<"${release_json}")"
  if [[ ! "${tag_name_json}" =~ ^v${SEMVER_REGEX}$ ]]; then
    echo "GitHub release tag is not a canonical semantic version tag: ${tag_name_json}" >&2
    exit 1
  fi

  version_from_tag="${tag_name_json#v}"
  if [[ "${version_from_tag}" != "${requested_version#v}" ]]; then
    echo "Resolved release tag ${tag_name_json} does not match requested version ${requested_version}" >&2
    exit 1
  fi

  match_count=0
  matched_asset_name=""
  matched_asset_url=""
  while IFS=$'\t' read -r asset_name asset_url; do
    if [[ -z "${asset_name}" ]]; then
      continue
    fi
    if [[ "${asset_name}" =~ ${RELEASE_ARCHIVE_ASSET_REGEX} ]]; then
      asset_version="${BASH_REMATCH[1]}"
      if [[ "${asset_version}" == "${version_from_tag}" && -n "${asset_url}" ]]; then
        match_count=$((match_count + 1))
        if [[ "${match_count}" -eq 1 ]]; then
          matched_asset_name="${asset_name}"
          matched_asset_url="${asset_url}"
        fi
      fi
    fi
  done < <(jq -r '.assets[]? | [.name, (.browser_download_url // "")] | @tsv' <<<"${release_json}")

  if [[ "${match_count}" -eq 0 ]]; then
    echo "No matching release asset found for ${tag_name_json}. Expected localai-${version_from_tag}.tar.gz" >&2
    asset_names="$(jq -r '.assets[]?.name' <<<"${release_json}" | paste -sd ', ' - || true)"
    if [[ -n "${asset_names}" ]]; then
      echo "Available assets: ${asset_names}" >&2
    fi
    exit 1
  fi
  if [[ "${match_count}" -gt 1 ]]; then
    echo "Multiple matching release assets found for ${tag_name_json}." >&2
    exit 1
  fi

  archive_path="${temp_dir}/release.tar.gz"
  echo "Downloading ${tag_name_json} asset ${matched_asset_name} from ${matched_asset_url}"
  curl -sSfL ${auth_header:+-H "${auth_header}"} -o "${archive_path}" "${matched_asset_url}"
else
  # Tar mode uses a caller-provided local archive path.
  archive_path="${tarball_path}"
  echo "Using local release archive ${archive_path}"
fi

# Extract archive and assert the expected single top-level directory layout.
extract_root="${temp_dir}/extracted"
mkdir -p "${extract_root}"
tar -xf "${archive_path}" -C "${extract_root}"

entry_count=0
release_root=""
while IFS= read -r entry; do
  entry_count=$((entry_count + 1))
  if [[ "${entry_count}" -eq 1 ]]; then
    release_root="${entry}"
  fi
done < <(find "${extract_root}" -mindepth 1 -maxdepth 1 -type d)
if [[ "${entry_count}" -ne 1 ]]; then
  echo "Unexpected release archive structure." >&2
  exit 1
fi

if [[ ! -f "${release_root}/compose.yml" ]]; then
  echo "Release is missing compose.yml: ${release_root}/compose.yml" >&2
  exit 1
fi

manifest_path="${release_root}/manifest.yml"
if [[ ! -f "${manifest_path}" ]]; then
  echo "Release is missing manifest.yml: ${manifest_path}" >&2
  exit 1
fi

# Extract the first "version:" key from manifest.yml using POSIX tools only.
# Bootstrap intentionally avoids yq/python dependencies.
manifest_version="$(
  awk '
    /^[[:space:]]*version[[:space:]]*:/ {
      sub(/^[[:space:]]*version[[:space:]]*:[[:space:]]*/, "", $0)
      sub(/[[:space:]]*(#.*)?$/, "", $0)
      print
      exit
    }
  ' "${manifest_path}"
)"
manifest_version="$(printf '%s' "${manifest_version}" | sed -e "s/^['\"]//" -e "s/['\"]$//")"
if [[ -z "${manifest_version}" ]]; then
  echo "Release manifest does not contain a version: ${manifest_path}" >&2
  exit 1
fi
if [[ "${manifest_version}" =~ ^v ]]; then
  echo "Manifest version must not start with 'v': ${manifest_version}" >&2
  exit 1
fi
if [[ ! "${manifest_version}" =~ ^${SEMVER_REGEX}$ ]]; then
  echo "Manifest version is not valid semantic version: ${manifest_version}" >&2
  exit 1
fi
if [[ "${source_mode}" == "repo" && "${manifest_version}" != "${version_from_tag}" ]]; then
  echo "Manifest version ${manifest_version} does not match GitHub tag version ${version_from_tag}" >&2
  exit 1
fi

# Install under versions/v<manifest_version> and update active symlink.
install_dir="${versions_dir}/v${manifest_version}"

mkdir -p "${versions_dir}"
mv "${release_root}" "${install_dir}"
ln -sfn "versions/v${manifest_version}" "${releases_dir}/active"

env_file="${releases_dir}/.env"
releases_dir_abs="$(cd "${releases_dir}" && pwd -P)"
# Persist runtime configuration used by the updater service / docker compose.
# GITHUB_TOKEN is only written when explicitly opted in via --use-github-token.
{
  printf "RELEASES_DIR_HOST=%s\n" "${releases_dir_abs}"
  printf "RELEASES_REPO_OWNER=%s\n" "${releases_repo_owner}"
  printf "RELEASES_REPO_NAME=%s\n" "${releases_repo_name}"
  printf "COMPOSE_PROJECT_NAME=%s\n" "${compose_project_name}"
  if [[ "${use_github_token}" == true ]]; then
    printf "GITHUB_TOKEN=%s\n" "${GITHUB_TOKEN}"
  fi
} > "${env_file}"

echo "Installed v${manifest_version} into ${install_dir}"
echo "Activated ${releases_dir}/active -> versions/v${manifest_version}"
echo "Wrote ${env_file}"

# Start the stack against the freshly activated release compose file.
echo "Starting docker compose stack"
docker compose \
  --file "${releases_dir}/active/compose.yml" \
  --env-file "${env_file}" \
  --project-name "${compose_project_name}" \
  up \
  --pull missing \
  --build \
  --detach