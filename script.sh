#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_APP="backup-tool"
CURRENT_DESTINATION_FILE="$SCRIPT_DIR/current_destination"

DESTINATION=""
BASE_MOUNT=""
BACKUP_MOUNT=""
HOST_KEY_FILE=""
FILTER_FILE=""

TMP_DIR=""
TMP_CONFIG=""
MOUNT_LOG=""

# --- Logging ---------------------------------------------------------------

if [[ -t 1 ]]; then
    COLOR_INFO="\033[32m"; COLOR_WARN="\033[33m"; COLOR_ERROR="\033[31m"; COLOR_RESET="\033[0m"
else
    COLOR_INFO=""; COLOR_WARN=""; COLOR_ERROR=""; COLOR_RESET=""
fi

info()  { printf "%b\n" "${COLOR_INFO}[info]${COLOR_RESET} $*"; }
warn()  { printf "%b\n" "${COLOR_WARN}[warn]${COLOR_RESET} $*" >&2; }
error() { printf "%b\n" "${COLOR_ERROR}[error]${COLOR_RESET} $*" >&2; }

die() { error "$1"; exit "${2:-1}"; }

# --- Setup -------------------------------------------------------------------

check_dependencies() {
    local missing=0
    local cmd
    for cmd in rclone secret-tool mktemp sed; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "Missing dependency: $cmd"
            missing=1
        fi
    done
    [[ "$missing" -eq 0 ]] || die "Install the missing dependencies and try again."
}

resolve_destination() {
    [[ -f "$CURRENT_DESTINATION_FILE" ]] || die "No active destination set. Run: ./script.sh destinations-use <name>"
    local name
    name="$(<"$CURRENT_DESTINATION_FILE")"
    [[ -n "$name" ]] || die "current_destination is empty. Run: ./script.sh destinations-use <name>"
    [[ -f "$SCRIPT_DIR/destinations/$name/config.sh" ]] || die "Active destination '$name' has no destinations/$name/config.sh."
    printf '%s' "$name"
}

load_destination_config() {
    DESTINATION="$(resolve_destination)"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/destinations/$DESTINATION/config.sh"

    case "$BASE_TYPE" in
        sftp|local) ;;
        *) die "Unknown BASE_TYPE '$BASE_TYPE' in destinations/$DESTINATION/config.sh (expected sftp or local)." ;;
    esac

    # config.sh may set BASE_MOUNT/BACKUP_MOUNT/FILTER_FILE itself to override these defaults.
    BASE_MOUNT="${BASE_MOUNT:-$SCRIPT_DIR/mounts/$DESTINATION/base}"
    BACKUP_MOUNT="${BACKUP_MOUNT:-$SCRIPT_DIR/mounts/$DESTINATION/backup}"
    HOST_KEY_FILE="$SCRIPT_DIR/destinations/$DESTINATION/host_key"
    FILTER_FILE="${FILTER_FILE:-$SCRIPT_DIR/destinations/$DESTINATION/filters.txt}"

    declare -gA TARGET_REMOTE=(
        [base]="$(base_root_remote)"
        [backup]="backup:"
    )
    declare -gA TARGET_MOUNT=(
        [base]="$BASE_MOUNT"
        [backup]="$BACKUP_MOUNT"
    )
    declare -gA TARGET_SUPPORTS_SYNC=(
        [base]="false"
        [backup]="true"
    )
}

# --- Destinations --------------------------------------------------------------

destinations_list() {
    local current="" d name marker found=0
    [[ -f "$CURRENT_DESTINATION_FILE" ]] && current="$(<"$CURRENT_DESTINATION_FILE")"

    for d in "$SCRIPT_DIR"/destinations/*/; do
        name="$(basename "$d")"
        [[ "$name" == "_example" ]] && continue
        [[ -f "$d/config.sh" ]] || continue
        found=1
        marker=" "
        [[ "$name" == "$current" ]] && marker="*"
        printf "%s %s\n" "$marker" "$name"
    done

    [[ "$found" -eq 1 ]] || info "No destinations configured yet. Copy destinations/_example to destinations/<name> to add one."
}

destinations_use() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "Usage: destinations-use <name>"
    [[ -f "$SCRIPT_DIR/destinations/$name/config.sh" ]] || die "Unknown destination '$name' (no destinations/$name/config.sh)."
    printf '%s\n' "$name" > "$CURRENT_DESTINATION_FILE"
    info "Active destination set to '$name'."
}

# --- Base type behavior ---------------------------------------------------------

# Whether this destination's base type needs SSH host key pinning (only sftp does).
base_needs_host_key_pinning() {
    [[ "$BASE_TYPE" == "sftp" ]]
}

# The remote:path argument used to mount/browse the base target directly (remote-mount).
# sftp has no config-level root - "base:" alone already means the account root. rclone's local
# backend has no root field at all though - without a path, "base:" resolves relative to
# script.sh's current working directory, not LOCAL_BASE_PATH, so it must be spelled out here.
base_root_remote() {
    case "$BASE_TYPE" in
        sftp)  printf 'base:' ;;
        local) printf 'base:%s' "$LOCAL_BASE_PATH" ;;
    esac
}

# The path (relative to the base remote) that the crypt layer wraps.
base_remote_path() {
    case "$BASE_TYPE" in
        sftp)  printf '%s' "$BACKUP_PATH" ;;
        local) printf '%s/%s' "${LOCAL_BASE_PATH%/}" "$BACKUP_PATH" ;;
    esac
}

# --- Secrets -----------------------------------------------------------------

get_secret() {
    local name="$1"
    secret-tool lookup app "$SECRET_APP" secret "$name" 2>/dev/null || true
}

# Distinguishes "never configured" from "configured as empty" (get_secret returns "" for both).
secret_exists() {
    local name="$1"
    secret-tool lookup app "$SECRET_APP" secret "$name" >/dev/null 2>&1
}

prompt_secret() {
    local label="$1" value
    read -r -s -p "${label}: " value >&2
    printf "\n" >&2
    printf "%s" "$value"
}

store_secret() {
    local name="$1" value="$2"
    printf "%s" "$value" | secret-tool store --label="backup-tool: $name" app "$SECRET_APP" secret "$name"
}

delete_secret() {
    local name="$1"
    secret-tool clear app "$SECRET_APP" secret "$name" 2>/dev/null || true
}

# Looks up a secret; if never configured, prompts and stores the answer (even if blank, so
# an optional secret left blank is remembered as "skip" instead of being asked again).
get_or_prompt_secret() {
    local name="$1" label="$2" optional="$3" value
    if secret_exists "$name"; then
        get_secret "$name"
        return
    fi

    value="$(prompt_secret "$label")"
    if [[ -z "$value" && "$optional" != "true" ]]; then
        die "$label is required."
    fi

    if [[ -n "$value" ]]; then
        local answer
        read -r -p "Store in secret-tool? [Y/n] " answer >&2
        if [[ -z "$answer" || "$answer" =~ ^[Yy] ]]; then
            store_secret "$name" "$value"
        fi
    else
        store_secret "$name" ""
    fi
    printf "%s" "$value"
}

# Always prompts, regardless of an existing value (used by secrets-init).
#
# persist_blank controls what a blank answer means:
#   true  - remember "intentionally left blank" so it's never asked again (e.g. the crypt salt,
#           which may genuinely never be used).
#   false - leave it unconfigured, so a required-at-use-time secret (e.g. the crypt password) is
#           still prompted for fresh on every command that actually needs it.
init_secret() {
    local name="$1" label="$2" optional="$3" persist_blank="${4:-true}" value
    value="$(prompt_secret "$label")"
    if [[ -z "$value" && "$optional" != "true" ]]; then
        die "$label is required."
    fi
    if [[ -n "$value" || "$persist_blank" == "true" ]]; then
        store_secret "$name" "$value"
    else
        delete_secret "$name"
    fi
}

collect_secrets() {
    if [[ "$BASE_TYPE" == "sftp" ]]; then
        BASE_PASSWORD="$(get_or_prompt_secret "$DESTINATION-password" "SFTP password" false)"
    fi
    CRYPT_PASSWORD="$(get_or_prompt_secret "$DESTINATION-crypt-password" "Crypt password" false)"
    CRYPT_PASSWORD2="$(get_or_prompt_secret "$DESTINATION-crypt-password2" "Crypt salt (optional)" true)"
}

secrets_init() {
    info "Setting up secrets for destination '$DESTINATION'."
    if [[ "$BASE_TYPE" == "sftp" ]]; then
        init_secret "$DESTINATION-password" "SFTP password" false
    fi
    init_secret "$DESTINATION-crypt-password" "Crypt password (optional, press enter to skip and be prompted at run time)" true false
    init_secret "$DESTINATION-crypt-password2" "Crypt salt (optional, press enter to skip)" true true
    info "Secrets stored."
}

secrets_show() {
    local entries=()
    [[ "$BASE_TYPE" == "sftp" ]] && entries+=("$DESTINATION-password:SFTP password")
    entries+=("$DESTINATION-crypt-password:Crypt password" "$DESTINATION-crypt-password2:Crypt salt")

    local entry name label
    for entry in "${entries[@]}"; do
        name="${entry%%:*}"
        label="${entry#*:}"
        if ! secret_exists "$name"; then
            printf "%-20s: missing\n" "$label"
        elif [[ -n "$(get_secret "$name")" ]]; then
            printf "%-20s: stored\n" "$label"
        else
            printf "%-20s: skipped\n" "$label"
        fi
    done
}

secrets_delete() {
    local answer
    read -r -p "Delete all stored secrets for destination '$DESTINATION'? This cannot be undone. [y/N] " answer
    if [[ "$answer" =~ ^[Yy] ]]; then
        [[ "$BASE_TYPE" == "sftp" ]] && delete_secret "$DESTINATION-password"
        delete_secret "$DESTINATION-crypt-password"
        delete_secret "$DESTINATION-crypt-password2"
        info "Secrets deleted."
    else
        info "Aborted."
    fi
}

# --- Host key pinning ---------------------------------------------------------

# Trust-on-first-use via rclone's own --sftp-pin-host-key (rclone >= 1.75): connect once,
# show the fingerprint it logs, and on confirmation persist the host_keys line it writes into
# the probe config so every later connection can be verified against that pinned key.
ensure_known_host() {
    [[ -s "$HOST_KEY_FILE" ]] && return

    info "No pinned host key yet for $SFTP_HOST - connecting once to fetch and pin it (TOFU)."

    local probe_dir probe_config probe_output
    probe_dir="$(mktemp -d)"
    probe_config="$probe_dir/rclone.conf"
    printf '[base]\ntype = sftp\nhost = %s\nuser = %s\npass = %s\n' \
        "$SFTP_HOST" "$SFTP_USER" "$(rclone obscure "$BASE_PASSWORD")" > "$probe_config"
    chmod 600 "$probe_config"

    if ! probe_output="$(rclone --config "$probe_config" --sftp-pin-host-key lsd base: 2>&1 >/dev/null)"; then
        rm -rf "$probe_dir"
        die "Could not connect to pin the host key - check the SFTP host/credentials and try again."
    fi

    warn "$probe_output"

    local answer
    read -r -p "Trust this host key and pin it for future connections? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy] ]]; then
        rm -rf "$probe_dir"
        die "Host key not trusted."
    fi

    local host_keys_line
    host_keys_line="$(grep '^host_keys' "$probe_config" || true)"
    if [[ -z "$host_keys_line" ]]; then
        rm -rf "$probe_dir"
        die "rclone did not record a pinned host key - --sftp-pin-host-key needs rclone >= 1.75."
    fi

    printf '%s\n' "$host_keys_line" > "$HOST_KEY_FILE"
    rm -rf "$probe_dir"
    info "Host key pinned to $HOST_KEY_FILE"
}

# --- Temporary rclone configuration ------------------------------------------

generate_config() {
    base_needs_host_key_pinning && ensure_known_host

    TMP_DIR="$(mktemp -d)"
    TMP_CONFIG="$TMP_DIR/rclone.conf"

    case "$BASE_TYPE" in
        sftp)
            local obscured_password host_keys_line
            obscured_password="$(rclone obscure "$BASE_PASSWORD")"
            host_keys_line="$(cat "$HOST_KEY_FILE")"
            sed \
                -e "s|__HOST__|$SFTP_HOST|g" \
                -e "s|__USER__|$SFTP_USER|g" \
                -e "s|__PASSWORD__|$obscured_password|g" \
                -e "s|__HOST_KEYS_LINE__|$host_keys_line|g" \
                "$SCRIPT_DIR/templates/base-sftp.conf.template" > "$TMP_CONFIG"
            ;;
        local)
            cp "$SCRIPT_DIR/templates/base-local.conf.template" "$TMP_CONFIG"
            ;;
    esac

    printf '\n' >> "$TMP_CONFIG"

    local obscured_crypt obscured_crypt2 remote_path
    obscured_crypt="$(rclone obscure "$CRYPT_PASSWORD")"
    obscured_crypt2=""
    [[ -n "$CRYPT_PASSWORD2" ]] && obscured_crypt2="$(rclone obscure "$CRYPT_PASSWORD2")"
    remote_path="$(base_remote_path)"

    sed \
        -e "s|__BASE_REMOTE_PATH__|$remote_path|g" \
        -e "s|__CRYPT_PASSWORD__|$obscured_crypt|g" \
        -e "s|__CRYPT_PASSWORD2__|$obscured_crypt2|g" \
        "$SCRIPT_DIR/templates/backup.conf.template" >> "$TMP_CONFIG"

    # Drop the salt line entirely when unset, rather than leaving it empty.
    [[ -z "$CRYPT_PASSWORD2" ]] && sed -i "/^password2 = $/d" "$TMP_CONFIG"

    chmod 600 "$TMP_CONFIG"
}

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
    if [[ -n "$MOUNT_LOG" && -f "$MOUNT_LOG" ]]; then
        rm -f "$MOUNT_LOG"
    fi
}
trap cleanup EXIT

# --- rclone wrapper -----------------------------------------------------------

run_rclone() {
    rclone --config "$TMP_CONFIG" "$@"
}

# --- Targets ------------------------------------------------------------------

mount_remote() {
    local target="$1"
    local remote="${TARGET_REMOTE[$target]}"
    local mountpoint="${TARGET_MOUNT[$target]}"

    mkdir -p "$mountpoint"
    info "Mounting $remote -> $mountpoint (Ctrl+C to unmount)"

    local status
    MOUNT_LOG="$(mktemp)"
    if run_rclone mount "$remote" "$mountpoint" \
        --vfs-cache-mode "$VFS_CACHE_MODE" \
        --vfs-cache-max-age "$VFS_CACHE_MAX_AGE" \
        --vfs-write-back "$VFS_WRITE_BACK" \
        --poll-interval "$POLL_INTERVAL" \
        2>&1 | tee "$MOUNT_LOG"; then
        status=0
    else
        status="${PIPESTATUS[0]}"
    fi

    # rclone exits non-zero if it logged any ERROR-level line during the session (e.g. VFS
    # cache cleanup noise while unmounting), even after a normal mount and a clean Ctrl+C
    # unmount. Only CRITICAL means the mount itself actually failed.
    if [[ "$status" -ne 0 ]]; then
        if grep -q "CRITICAL:" "$MOUNT_LOG"; then
            die "Mount of $remote failed."
        fi
        warn "rclone reported non-fatal errors during this session (exit code $status) - see log above."
    fi
}

# Prompts before any real (non-dry-run) sync, since rclone sync deletes anything at the
# destination that isn't at the source - true in both directions.
confirm_sync() {
    local src="$1" dest="$2"
    warn "This will sync $src -> $dest, deleting anything at the destination that's not at the source."
    local answer
    read -r -p "Are you sure? [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] || die "Aborted."
}

sync_remote() {
    local target="$1" dryrun="$2" reverse="${3:-false}"
    local remote="${TARGET_REMOTE[$target]}"

    [[ "${TARGET_SUPPORTS_SYNC[$target]}" == "true" ]] || die "Target '$target' does not support sync."
    [[ -d "$LOCAL_BACKUP_DIR" ]] || die "Local backup directory not found: $LOCAL_BACKUP_DIR"

    local src dest
    if [[ "$reverse" == "true" ]]; then
        src="$remote" dest="$LOCAL_BACKUP_DIR"
    else
        src="$LOCAL_BACKUP_DIR" dest="$remote"
    fi

    [[ "$dryrun" == "true" ]] || confirm_sync "$src" "$dest"

    local args=(sync "$src" "$dest" --progress --stats=2s -v --combined -)
    [[ "$dryrun" == "true" ]] && args+=(--dry-run)
    [[ -f "$FILTER_FILE" ]] && args+=(--filter-from "$FILTER_FILE")

    run_rclone "${args[@]}" || die "Sync from $src to $dest failed."
}

# --- Usage ----------------------------------------------------------------

usage() {
    cat <<'EOF'
backup-tool - self-contained rclone backup wrapper, supports multiple destinations

Usage: script.sh <command> [args]

Destination management:
  destinations-list           List configured destinations (* marks the active one).
  destinations-use <name>     Set the active destination.

Commands (operate on the active destination):
  remote-mount                Mount the base target (unencrypted) for browsing.
  remote-backup-mount         Mount the encrypted backup target.
  remote-backup-sync-dry      Show what a backup sync would change (no writes).
  remote-backup-sync          Sync LOCAL_BACKUP_DIR to the encrypted backup target.
  remote-backup-restore-dry   Show what a restore (backup target -> local) would change.
  remote-backup-restore       Sync the encrypted backup target down to LOCAL_BACKUP_DIR.
  secrets-init                 Interactively store required secrets.
  secrets-show                 Show which secrets are stored (never prints values).
  secrets-delete                Delete all stored secrets for this destination.
  help                          Show this help.

To add a destination:
  cp -r destinations/_example destinations/<name>
  mv destinations/<name>/config.sh.template destinations/<name>/config.sh
  # edit destinations/<name>/config.sh
  ./script.sh destinations-use <name>
EOF
}

# --- Main -------------------------------------------------------------------

main() {
    check_dependencies

    local cmd="${1:-help}"
    case "$cmd" in
        remote-mount)
            load_destination_config
            collect_secrets
            generate_config
            mount_remote base
            ;;
        remote-backup-mount)
            load_destination_config
            collect_secrets
            generate_config
            mount_remote backup
            ;;
        remote-backup-sync-dry)
            load_destination_config
            collect_secrets
            generate_config
            sync_remote backup true
            ;;
        remote-backup-sync)
            load_destination_config
            collect_secrets
            generate_config
            sync_remote backup false
            ;;
        remote-backup-restore-dry)
            load_destination_config
            collect_secrets
            generate_config
            sync_remote backup true true
            ;;
        remote-backup-restore)
            load_destination_config
            collect_secrets
            generate_config
            sync_remote backup false true
            ;;
        secrets-init)
            load_destination_config
            secrets_init
            ;;
        secrets-show)
            load_destination_config
            secrets_show
            ;;
        secrets-delete)
            load_destination_config
            secrets_delete
            ;;
        destinations-list)
            destinations_list
            ;;
        destinations-use)
            destinations_use "${2:-}"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            error "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
