#!/bin/sh
#
# Wyvern installer — the panel, the daemon and everything they need, on one Debian or
# Ubuntu host.
#
#   wget https://raw.githubusercontent.com/PatocheOnGit/wyvern-installer/main/install.sh
#   sudo sh install.sh
#
# Wyvern is a personal project. This script is published so its own installs are
# reproducible, not as a product. It makes large changes to a machine — packages, a web
# server, a database, a firewall — so read it before running it, and run it on a host you
# are willing to dedicate to Wyvern.
#
# Licensed MIT. See LICENSE.

set -eu

INSTALLER_VERSION="0.1.0"

PANEL_REPO="${WYVERN_PANEL_REPO:-PatocheOnGit/wyvern-panel-next}"
WINGS_REPO="${WYVERN_WINGS_REPO:-PatocheOnGit/wyvern-wings}"
GITHUB_TOKEN="${WYVERN_GITHUB_TOKEN:-}"
LOCALE="${WYVERN_LOCALE:-en}"

PANEL_DIR="${WYVERN_PANEL_DIR:-/var/www/wyvern}"
CONF_DIR=/etc/wyvern
DATA_DIR=/var/lib/wyvern
PMA_PARENT=/var/www/wyvern-pma
PMA_DIR="$PMA_PARENT/pma"
LOG_FILE=/var/log/wyvern-install.log
CRED_FILE=/root/wyvern-credentials.txt
WORK_DIR=

# Filled in by prompts or flags.
FQDN=""
USE_SSL=""
ADMIN_EMAIL=""
ADMIN_USER=""
ADMIN_PASS=""
NODE_NAME=""
INSTALL_PMA=""
TIMEZONE=""
UNATTENDED=0
SKIP_WINGS=0
SKIP_FIREWALL=0
PANEL_TAG=""

DB_NAME=wyvern
DB_USER=wyvern
DB_PASS=""
DB_HOST_PASS=""
PMA_BLOWFISH=""

OS_ID=""
OS_VERSION=""
OS_CODENAME=""
OS_NAME=""
REPO_CODENAME=""
ARCH=""
PHP=""
PHP_SOCK=""
NODE_ID=""
PANEL_URL=""
GENERATED_ADMIN_PASS=0
SSL_FAILED=0
SMOKE_FAILED=0

# --------------------------------------------------------------------------- output

if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    C_RESET=$(printf '\033[0m')
    C_BOLD=$(printf '\033[1m')
    C_DIM=$(printf '\033[2m')
    C_RED=$(printf '\033[31m')
    C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m')
    C_BLUE=$(printf '\033[34m')
else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

_log() { [ -n "${LOG_READY:-}" ] && printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1" >>"$LOG_FILE"; return 0; }

step()  { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"; _log "STEP $1"; }
info()  { printf '    %s\n' "$1"; _log "info $1"; }
ok()    { printf '    %s+%s %s\n' "$C_GREEN" "$C_RESET" "$1"; _log "ok $1"; }
warn()  { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; _log "warn $1"; }
note()  { printf '    %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }

die() {
    printf '\n%serror:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$1" >&2
    _log "FATAL $1"
    if [ -n "${LOG_READY:-}" ]; then
        printf '%sThe full log is in %s%s\n' "$C_DIM" "$LOG_FILE" "$C_RESET" >&2
    fi
    exit 1
}

# Every package manager and build step writes to the log, not to the screen: on a small
# VPS composer alone prints several hundred lines, and a wall of text hides the one line
# that matters. Failures print their own tail.
run() {
    _log "run $*"
    if ! "$@" >>"$LOG_FILE" 2>&1; then
        printf '\n%sfailed:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2
        printf '%s--- last 25 lines of the log ---%s\n' "$C_DIM" "$C_RESET" >&2
        tail -n 25 "$LOG_FILE" >&2
        die "command failed (full log: $LOG_FILE)"
    fi
}

# --------------------------------------------------------------------------- helpers

have() { command -v "$1" >/dev/null 2>&1; }

gen_pass() {
    # 32 characters from a set with no shell metacharacters and no lookalikes, because
    # these end up in .env, in a YAML file, in a MySQL statement, and read aloud off a
    # terminal.
    LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom 2>/dev/null | head -c 32 || \
        die "could not generate a password (/dev/urandom unreadable)"
}

# Unlike `hostname -I`, this answers with the address that actually reaches the internet,
# which on a VPS with several interfaces is the one the panel has to be reachable on.
guess_ip() {
    ip route get 1.1.1.1 2>/dev/null | awk '/src/ { for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

port_busy() {
    if have ss; then
        ss -HltnO 2>/dev/null | awk '{ print $4 }' | grep -qE "[:.]$1\$"
    else
        return 1
    fi
}

is_ip() {
    printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

gh_api() {
    _url="$1"
    if [ -n "$GITHUB_TOKEN" ]; then
        curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/vnd.github+json' "$_url"
    else
        curl -fsSL -H 'Accept: application/vnd.github+json' "$_url"
    fi
}

# A dependency-free read of one string field. jq is not installed yet when this first
# runs, and pulling in a JSON parser to read two fields is not a trade worth making.
json_str() {
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<EOF | head -n 1
$1
EOF
}

ask() {
    _prompt="$1" _default="${2:-}" _answer=""
    if [ "$UNATTENDED" -eq 1 ]; then
        printf '%s' "$_default"
        return 0
    fi
    if [ -n "$_default" ]; then
        printf '    %s %s[%s]%s: ' "$_prompt" "$C_DIM" "$_default" "$C_RESET" >&2
    else
        printf '    %s: ' "$_prompt" >&2
    fi
    IFS= read -r _answer <&3 || _answer=""
    [ -n "$_answer" ] || _answer="$_default"
    printf '%s' "$_answer"
}

ask_secret() {
    _prompt="$1" _answer=""
    if [ "$UNATTENDED" -eq 1 ]; then
        printf ''
        return 0
    fi
    printf '    %s: ' "$_prompt" >&2
    stty -echo 2>/dev/null || true
    IFS= read -r _answer <&3 || _answer=""
    stty echo 2>/dev/null || true
    printf '\n' >&2
    printf '%s' "$_answer"
}

ask_yn() {
    _prompt="$1" _default="$2" _answer=""
    if [ "$UNATTENDED" -eq 1 ]; then
        printf '%s' "$_default"
        return 0
    fi
    while :; do
        if [ "$_default" = "y" ]; then
            printf '    %s %s[Y/n]%s ' "$_prompt" "$C_DIM" "$C_RESET" >&2
        else
            printf '    %s %s[y/N]%s ' "$_prompt" "$C_DIM" "$C_RESET" >&2
        fi
        IFS= read -r _answer <&3 || _answer=""
        case "$_answer" in
            y|Y|yes|YES) printf 'y'; return 0 ;;
            n|N|no|NO)   printf 'n'; return 0 ;;
            '')          printf '%s' "$_default"; return 0 ;;
            *)           printf '    Answer y or n.\n' >&2 ;;
        esac
    done
}

# --------------------------------------------------------------------------- usage

usage() {
    cat <<EOF
Wyvern installer $INSTALLER_VERSION

  sh install.sh [options]

With no options the script asks its questions. The options exist for automated installs:
pass them all, together with --unattended.

  --fqdn <domain|ip>      Where the panel answers. No SSL if this is an IP address.
  --ssl / --no-ssl        Let's Encrypt certificate. Not possible for an IP address.
  --email <address>       Administrator account, and Let's Encrypt contact.
  --username <name>       Administrator username.
  --password <secret>     Administrator password. Generated when omitted.
  --node-name <name>      Name of the node created for this machine. Default: the hostname.
  --timezone <zone>       Default: the system's, falling back to UTC.
  --with-pma / --no-pma   phpMyAdmin at /pma, gated by the panel session.
  --skip-wings            Install the panel only.
  --skip-firewall         Leave ufw alone.
  --panel-version <tag>   Install a specific panel release. Default: the newest.
  --unattended            Ask nothing.
  -h, --help              This.

Environment: WYVERN_PANEL_REPO, WYVERN_WINGS_REPO, WYVERN_PANEL_DIR, WYVERN_LOCALE,
WYVERN_GITHUB_TOKEN (lifts the anonymous GitHub API limit of 60 requests per hour).
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --fqdn)           FQDN="${2:-}"; shift 2 ;;
            --ssl)            USE_SSL=y; shift ;;
            --no-ssl)         USE_SSL=n; shift ;;
            --email)          ADMIN_EMAIL="${2:-}"; shift 2 ;;
            --username)       ADMIN_USER="${2:-}"; shift 2 ;;
            --password)       ADMIN_PASS="${2:-}"; shift 2 ;;
            --node-name)      NODE_NAME="${2:-}"; shift 2 ;;
            --timezone)       TIMEZONE="${2:-}"; shift 2 ;;
            --with-pma)       INSTALL_PMA=y; shift ;;
            --no-pma)         INSTALL_PMA=n; shift ;;
            --skip-wings)     SKIP_WINGS=1; shift ;;
            --skip-firewall)  SKIP_FIREWALL=1; shift ;;
            --panel-version)  PANEL_TAG="${2:-}"; shift 2 ;;
            --unattended)     UNATTENDED=1; shift ;;
            -h|--help)        usage; exit 0 ;;
            *)                usage >&2; die "unknown option: $1" ;;
        esac
    done
}

# --------------------------------------------------------------------------- preflight

detect_os() {
    [ -r /etc/os-release ] || die "no /etc/os-release: this distribution cannot be identified."
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION="${VERSION_ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    OS_NAME="${PRETTY_NAME:-$OS_ID $OS_VERSION}"

    # Derivatives are common on VPS images: Mint, Pop, Devuan, Raspberry Pi OS. What
    # matters is the package manager and the codename, so a derivative is accepted on the
    # strength of ID_LIKE, and told which base it is being treated as.
    case "$OS_ID" in
        debian|ubuntu) ;;
        *)
            case " ${ID_LIKE:-} " in
                *" debian "*|*" ubuntu "*)
                    warn "$OS_NAME is untested; treating it as ${ID_LIKE%% *}."
                    OS_ID="${ID_LIKE%% *}"
                    ;;
                *) die "$OS_NAME is not Debian- or Ubuntu-based. Nothing to install onto." ;;
            esac
            ;;
    esac
    [ -n "$OS_CODENAME" ] || die "no VERSION_CODENAME in /etc/os-release: cannot pick repositories."
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) die "$(uname -m) is not supported. The daemon is published for amd64 and arm64." ;;
    esac
}

preflight() {
    step "Checks"

    [ "$(id -u)" -eq 0 ] || die "run as root (sudo sh install.sh)."

    detect_os
    detect_arch
    ok "$OS_NAME ($OS_CODENAME, $ARCH)"

    [ -d /run/systemd/system ] || die "no systemd. Wyvern needs it for the daemon and the queue worker."
    have apt-get || die "no apt-get."

    # An existing install is not upgraded by this script: it would have to reconcile a
    # database, an .env and a node token it did not create. Refusing is the honest answer.
    if [ -e "$PANEL_DIR/artisan" ]; then
        die "a panel is already installed in $PANEL_DIR. This script does not install over one."
    fi

    for p in 80 443; do
        if port_busy "$p"; then
            die "port $p is already in use. Stop whatever holds it (ss -ltnp), then run this again."
        fi
    done
    if [ "$SKIP_WINGS" -eq 0 ]; then
        for p in 8080 2022; do
            port_busy "$p" && die "port $p is already in use, and the daemon needs it."
        done
    fi
    ok "ports free"

    _mem=$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || echo 0)
    if [ "$_mem" -lt 1800 ]; then
        warn "${_mem} MB of RAM. The panel will run, but little will be left for game servers."
    else
        ok "${_mem} MB of RAM"
    fi

    _disk=$(df -Pm /var 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }')
    [ -n "$_disk" ] || _disk=0
    if [ "$_disk" -lt 10 ]; then
        die "${_disk} GB free on /var. Around ten are needed before the first game server."
    fi
    ok "${_disk} GB free on /var"

    have curl || run apt-get install -y curl
    curl -fsS -m 10 -o /dev/null https://api.github.com/ 2>/dev/null || \
        die "cannot reach api.github.com, which is where the panel and the daemon come from."
    ok "network reachable"
}

# --------------------------------------------------------------------------- questions

collect() {
    step "Configuration"

    if [ -z "$FQDN" ]; then
        _ip=$(guess_ip)
        note "A domain already pointed at this machine can get HTTPS. An IP address cannot."
        FQDN=$(ask "Panel domain or IP" "$_ip")
    fi
    [ -n "$FQDN" ] || die "no address for the panel."

    if is_ip "$FQDN"; then
        if [ "$USE_SSL" = "y" ]; then
            die "Let's Encrypt does not certify IP addresses. Use a domain, or --no-ssl."
        fi
        USE_SSL=n
        note "IP address: the panel will be served over HTTP."
    elif [ -z "$USE_SSL" ]; then
        USE_SSL=$(ask_yn "Get a Let's Encrypt certificate for $FQDN?" y)
    fi

    if [ "$USE_SSL" = "y" ]; then
        PANEL_URL="https://$FQDN"
    else
        PANEL_URL="http://$FQDN"
    fi

    [ -n "$ADMIN_EMAIL" ] || ADMIN_EMAIL=$(ask "Administrator email")
    case "$ADMIN_EMAIL" in
        *@*.*) ;;
        *) die "not an email address: ${ADMIN_EMAIL:-empty}" ;;
    esac

    [ -n "$ADMIN_USER" ] || ADMIN_USER=$(ask "Administrator username" admin)

    if [ -z "$ADMIN_PASS" ] && [ "$UNATTENDED" -eq 0 ]; then
        note "Leave empty for a generated password, shown at the end."
        ADMIN_PASS=$(ask_secret "Administrator password")
        if [ -n "$ADMIN_PASS" ]; then
            _confirm=$(ask_secret "Confirm")
            [ "$ADMIN_PASS" = "$_confirm" ] || die "the two passwords differ."
        fi
    fi
    if [ -z "$ADMIN_PASS" ]; then
        ADMIN_PASS=$(gen_pass)
        GENERATED_ADMIN_PASS=1
    else
        GENERATED_ADMIN_PASS=0
        # The panel's own rule, applied here rather than twenty minutes into the install.
        if [ "$(printf '%s' "$ADMIN_PASS" | wc -c)" -lt 8 ]; then
            die "the password must be at least 8 characters."
        fi
    fi

    [ -n "$NODE_NAME" ] || NODE_NAME=$(ask "Node name for this machine" "$(hostname -s 2>/dev/null || echo local)")

    if [ -z "$INSTALL_PMA" ]; then
        note "phpMyAdmin would be served at $PANEL_URL/pma, reachable only while you are"
        note "signed in to the panel as an administrator. Otherwise nginx refuses it."
        INSTALL_PMA=$(ask_yn "Install phpMyAdmin?" n)
    fi

    if [ -z "$TIMEZONE" ]; then
        TIMEZONE=$(cat /etc/timezone 2>/dev/null || echo UTC)
        [ -n "$TIMEZONE" ] || TIMEZONE=UTC
    fi

    DB_PASS=$(gen_pass)
    PMA_BLOWFISH=$(gen_pass)

    printf '\n'
    info "Panel           $PANEL_URL"
    info "Administrator   $ADMIN_USER <$ADMIN_EMAIL>"
    info "Node            $NODE_NAME"
    info "Database        local mariadb, $DB_NAME"
    info "Timezone        $TIMEZONE"
    if [ "$INSTALL_PMA" = "y" ]; then
        info "phpMyAdmin      $PANEL_URL/pma"
    else
        info "phpMyAdmin      no"
    fi
    if [ "$SKIP_WINGS" -eq 1 ]; then
        info "Daemon          no (--skip-wings)"
    else
        info "Daemon          yes, local node"
    fi

    if [ "$UNATTENDED" -eq 0 ]; then
        printf '\n'
        [ "$(ask_yn "Start the install?" y)" = "y" ] || die "cancelled."
    fi
}

# --------------------------------------------------------------------------- packages

apt_key() {
    # Keys go to /usr/share/keyrings and are referenced with signed-by, because apt-key is
    # deprecated and a key in /etc/apt/trusted.gpg.d signs every repository on the machine,
    # not just the one that shipped it.
    _url="$1" _dest="$2"
    mkdir -p /usr/share/keyrings
    curl -fsSL "$_url" -o "$WORK_DIR/key.tmp" || die "repository key unreachable: $_url"
    if head -c 5 "$WORK_DIR/key.tmp" | grep -q -- '-----'; then
        gpg --dearmor <"$WORK_DIR/key.tmp" >"$_dest" 2>/dev/null || die "unreadable key: $_url"
    else
        cp "$WORK_DIR/key.tmp" "$_dest"
    fi
    chmod 0644 "$_dest"
    rm -f "$WORK_DIR/key.tmp"
}

# Debian 12 ships PHP 8.2 and the panel needs 8.3 or newer, so on that release a PHP
# repository is unavoidable. Where the distribution already has a new enough PHP — Ubuntu
# 24.04, Debian 13 — nothing is added: one fewer third party in the trust chain.
setup_php_repo() {
    for v in 8.4 8.3; do
        if apt-cache policy "php$v-fpm" 2>/dev/null | grep -q 'Candidate: [0-9]'; then
            PHP="php$v"
            ok "PHP $v from the distribution"
            return 0
        fi
    done

    info "no PHP 8.3+ in $OS_NAME, adding a PHP repository"
    run apt-get install -y gnupg apt-transport-https lsb-release ca-certificates

    if [ "$OS_ID" = "debian" ]; then
        apt_key https://packages.sury.org/php/apt.gpg /usr/share/keyrings/sury-php.gpg
        printf 'deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ %s main\n' \
            "$REPO_CODENAME" >/etc/apt/sources.list.d/sury-php.list
    else
        apt_key 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x4f4ea0aae5267a6c' \
            /usr/share/keyrings/ondrej-php.gpg
        printf 'deb [signed-by=/usr/share/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu %s main\n' \
            "$REPO_CODENAME" >/etc/apt/sources.list.d/ondrej-php.list
    fi

    run apt-get update
    for v in 8.4 8.3; do
        if apt-cache policy "php$v-fpm" 2>/dev/null | grep -q 'Candidate: [0-9]'; then
            PHP="php$v"
            ok "PHP $v from the added repository"
            return 0
        fi
    done
    die "no PHP 8.3+ even after adding the repository."
}

setup_docker_repo() {
    if have docker; then
        ok "Docker already present"
        return 0
    fi
    # Docker publishes for Debian and Ubuntu under their own codenames only, so a
    # derivative has to borrow its base codename or the repository is empty.
    apt_key "https://download.docker.com/linux/$OS_ID/gpg" /usr/share/keyrings/docker.gpg
    printf 'deb [arch=%s signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "$ARCH" "$OS_ID" "$REPO_CODENAME" >/etc/apt/sources.list.d/docker.list
    run apt-get update
}

install_packages() {
    step "Packages"

    export DEBIAN_FRONTEND=noninteractive

    # A derivative reports its own codename, which no upstream repository knows about.
    # os-release carries the base codename for exactly this reason.
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "$OS_ID" = "ubuntu" ]; then
        REPO_CODENAME="${UBUNTU_CODENAME:-$OS_CODENAME}"
    else
        REPO_CODENAME="${DEBIAN_CODENAME:-$OS_CODENAME}"
    fi

    run apt-get update
    run apt-get install -y ca-certificates curl gnupg tar unzip git cron
    ok "base tools"

    setup_php_repo
    setup_docker_repo

    info "installing nginx, $PHP, mariadb, redis and docker — a few minutes"
    run apt-get install -y \
        nginx \
        "$PHP-fpm" "$PHP-cli" "$PHP-mysql" "$PHP-mbstring" "$PHP-xml" "$PHP-curl" \
        "$PHP-zip" "$PHP-intl" "$PHP-bcmath" "$PHP-gd" "$PHP-sqlite3" \
        mariadb-server redis-server \
        docker-ce docker-ce-cli containerd.io
    ok "packages installed"

    setup_php_pool

    if [ "$USE_SSL" = "y" ]; then
        run apt-get install -y certbot python3-certbot-nginx
        ok "certbot"
    fi

    if ! have composer; then
        info "installing composer"
        curl -fsSL https://getcomposer.org/installer -o "$WORK_DIR/composer-setup.php" \
            || die "could not download composer."
        _expected=$(curl -fsSL https://composer.github.io/installer.sig) \
            || die "could not fetch composer's signature."
        _actual=$(php -r "echo hash_file('sha384', '$WORK_DIR/composer-setup.php');")
        [ "$_expected" = "$_actual" ] || die "composer's signature does not match. Stopping."
        run php "$WORK_DIR/composer-setup.php" --install-dir=/usr/local/bin --filename=composer
        rm -f "$WORK_DIR/composer-setup.php"
    fi
    ok "composer $(composer --version 2>/dev/null | awk '{ print $3 }')"

    for s in docker redis-server mariadb cron "$PHP-fpm" nginx; do
        systemctl enable --now "$s" >>"$LOG_FILE" 2>&1 || warn "could not start $s"
    done
    ok "services running"
}

# Wyvern gets its own php-fpm pool.
#
# Using the distribution's default pool means inheriting whatever it has been set to. On a
# machine where php-fpm was configured once before, that pool can run as a different user
# than www-data — and then the panel, whose files this script chowns to www-data, cannot
# write its own log. Laravel's failure to log an exception then throws inside the exception
# handler, so the request dies with an empty 500 and nothing recorded anywhere: hours of
# debugging for a one-line cause.
#
# A dedicated pool also carries the panel's limits. The default memory_limit of 128M is
# below what a Filament page costs, and the fatal that produces is equally silent.
setup_php_pool() {
    cat >"/etc/php/${PHP#php}/fpm/pool.d/wyvern.conf" <<EOF
; Written by wyvern-installer. The panel runs in its own pool so that neither its user
; nor its limits depend on how the default pool happens to be configured.
[wyvern]
user = www-data
group = www-data

listen = /run/php/wyvern-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 12
pm.start_servers = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 5
pm.max_requests = 500

; A Filament page does not fit in the 128M default.
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 100M
php_admin_value[post_max_size] = 100M
php_admin_value[max_execution_time] = 300

php_admin_flag[log_errors] = on
catch_workers_output = yes
EOF

    run systemctl restart "$PHP-fpm"

    PHP_SOCK="/run/php/wyvern-fpm.sock"
    _waited=0
    while [ ! -S "$PHP_SOCK" ] && [ "$_waited" -lt 10 ]; do
        sleep 1
        _waited=$((_waited + 1))
    done
    [ -S "$PHP_SOCK" ] || die "the php-fpm pool did not come up ($PHP_SOCK is missing)."
    ok "php-fpm pool 'wyvern' as www-data, 512M"
}

# --------------------------------------------------------------------------- database

mysql_do() {
    # A fresh mariadb-server on Debian and Ubuntu authenticates root over the unix socket,
    # so no password is needed here and none is ever written down.
    if have mariadb; then
        mariadb -e "$1"
    else
        mysql -e "$1"
    fi
}

setup_database() {
    step "Database"

    # Loopback only. The panel, the queue worker and phpMyAdmin all run on this host; a
    # database reachable from the internet would be an attack surface with no user.
    mkdir -p /etc/mysql/mariadb.conf.d
    cat >/etc/mysql/mariadb.conf.d/99-wyvern.cnf <<EOF
[mysqld]
bind-address = 127.0.0.1
EOF
    run systemctl restart mariadb

    mysql_do "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
        || die "could not create the database."
    mysql_do "CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';"
    mysql_do "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1';"

    # A second, privileged account exists so the panel can offer per-server databases: that
    # feature creates databases and users of its own, which the panel's own account
    # deliberately cannot do. Register it as a database host in the admin area; its
    # password is in the summary at the end. Nothing uses it until you do.
    DB_HOST_PASS=$(gen_pass)
    mysql_do "CREATE USER IF NOT EXISTS 'wyvernhost'@'127.0.0.1' IDENTIFIED BY '$DB_HOST_PASS';"
    mysql_do "GRANT ALL PRIVILEGES ON *.* TO 'wyvernhost'@'127.0.0.1' WITH GRANT OPTION;"
    mysql_do "FLUSH PRIVILEGES;"

    ok "database $DB_NAME, user $DB_USER, listening on 127.0.0.1 only"
}

setup_redis() {
    step "Redis"
    # Cache, sessions and the queue all live here. Sessions get database 1 and the cache
    # database 0, because the panel clears its cache with FLUSHDB: sharing one database
    # means every cache clear signs every user out.
    if [ -f /etc/redis/redis.conf ]; then
        sed -i 's/^# *bind .*/bind 127.0.0.1 -::1/' /etc/redis/redis.conf
        grep -q '^bind ' /etc/redis/redis.conf || printf 'bind 127.0.0.1 -::1\n' >>/etc/redis/redis.conf
    fi
    run systemctl restart redis-server
    redis-cli ping >/dev/null 2>&1 || die "redis is not answering."
    ok "redis on 127.0.0.1:6379"
}

# --------------------------------------------------------------------------- panel

resolve_panel_release() {
    if [ -n "$PANEL_TAG" ]; then
        _api="https://api.github.com/repos/$PANEL_REPO/releases/tags/$PANEL_TAG"
    else
        # The list, not /releases/latest: "latest" excludes prereleases and every 0.x
        # Wyvern tag is marked as one, so "latest" answers 404 on this repository.
        _api="https://api.github.com/repos/$PANEL_REPO/releases?per_page=1"
    fi

    _json=$(gh_api "$_api") || die "the GitHub API did not answer. Anonymous rate limit reached? Try later, or set WYVERN_GITHUB_TOKEN."
    PANEL_TAG=$(json_str "$_json" tag_name)
    [ -n "$PANEL_TAG" ] || die "no release found on $PANEL_REPO."
    ok "version $PANEL_TAG"
}

# Everything artisan does runs as www-data, so no file it writes — caches, logs, storage —
# ends up owned by root and unreadable to php-fpm later.
#
# su takes a single string, so every argument is quoted on the way in. Without that, an
# admin password containing a space would arrive as two arguments and the account would be
# created with half of it: a very quiet way to be locked out of a fresh panel.
shquote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

_artisan() {
    _cmd="php artisan"
    for _a in "$@"; do
        _cmd="$_cmd $(shquote "$_a")"
    done
    _out=$(cd "$PANEL_DIR" && su -s /bin/sh -c "$_cmd" www-data 2>&1) || {
        printf '%s\n' "$_out" >>"$LOG_FILE"
        printf '%s\n' "$_out" >&2
        die "artisan $1 failed."
    }
    printf '%s\n' "$_out" >>"$LOG_FILE"
}

# The usual form: output goes to the log, because artisan is chatty and the screen is
# reserved for the few lines that need a decision.
panel_artisan() {
    _artisan "$@"
}

# For the two places that read what artisan said.
panel_artisan_out() {
    _artisan "$@"
    printf '%s\n' "$_out"
}

write_env() {
    # Written directly rather than through p:environment:setup, which is interactive from
    # end to end and cannot be driven by a script. The keys are the ones the panel's own
    # web installer writes, plus the few that only matter on a server.
    cat >"$PANEL_DIR/.env" <<EOF
APP_ENV=production
APP_DEBUG=false
APP_KEY=
APP_NAME=Wyvern
APP_URL=$PANEL_URL
APP_TIMEZONE=$TIMEZONE
APP_LOCALE=$LOCALE
APP_INSTALLED=true

DB_CONNECTION=mariadb
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=$DB_NAME
DB_USERNAME=$DB_USER
DB_PASSWORD=$DB_PASS

CACHE_STORE=redis
QUEUE_CONNECTION=redis
SESSION_DRIVER=redis
SESSION_SECURE_COOKIE=$([ "$USE_SSL" = "y" ] && echo true || echo false)

REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=

MAIL_MAILER=log
MAIL_FROM_ADDRESS=$ADMIN_EMAIL
MAIL_FROM_NAME=Wyvern
EOF
    chmod 640 "$PANEL_DIR/.env"
    ok ".env written"
}

install_panel() {
    step "Panel"

    resolve_panel_release

    _base="https://github.com/$PANEL_REPO/releases/download/$PANEL_TAG"
    info "downloading panel.tar.gz"
    curl -fsSL "$_base/panel.tar.gz" -o "$WORK_DIR/panel.tar.gz" \
        || die "could not download the panel ($_base/panel.tar.gz)."

    if curl -fsSL "$_base/checksum.txt" -o "$WORK_DIR/checksum.txt" 2>/dev/null; then
        ( cd "$WORK_DIR" && sha256sum -c checksum.txt ) >>"$LOG_FILE" 2>&1 \
            || die "panel.tar.gz does not match its checksum. Corrupt or tampered with: nothing installed."
        ok "sha256 checksum verified"
    else
        warn "no checksum.txt published for $PANEL_TAG: the archive was not verified."
    fi

    mkdir -p "$PANEL_DIR"
    run tar -xzf "$WORK_DIR/panel.tar.gz" -C "$PANEL_DIR"
    [ -f "$PANEL_DIR/artisan" ] || die "unexpected archive: $PANEL_DIR/artisan is missing."

    # The release archive carries no vendor/ — it is built from a git tag, not from an
    # installed tree — so composer runs here, on the host. public/build is included, so
    # node and yarn are not needed at all.
    info "composer install (2 to 5 minutes)"
    ( cd "$PANEL_DIR" && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction ) \
        >>"$LOG_FILE" 2>&1 || {
            tail -n 25 "$LOG_FILE" >&2
            die "composer install failed."
        }
    ok "PHP dependencies installed"

    write_env
    run chown -R www-data:www-data "$PANEL_DIR"

    info "application key and migrations"
    panel_artisan key:generate --force
    # --seed is not optional: the root admin role is created by the seeder, and without it
    # the administrator account below has no role to be granted.
    panel_artisan migrate --seed --force
    ok "database migrated"

    # --admin=1 and an explicit password are what make this non-interactive: without both,
    # the command falls back to prompting, and a prompt inside a script waits forever.
    info "creating the administrator"
    panel_artisan p:user:make \
        --admin=1 \
        --email="$ADMIN_EMAIL" \
        --username="$ADMIN_USER" \
        --password="$ADMIN_PASS"
    ok "administrator $ADMIN_USER"

    panel_artisan storage:link || true
    panel_artisan optimize
    run chown -R www-data:www-data "$PANEL_DIR"
    ok "panel installed in $PANEL_DIR"
}

setup_queue_and_cron() {
    step "Queue worker and scheduler"

    cat >/etc/systemd/system/wyvernq.service <<EOF
[Unit]
Description=Wyvern Panel Queue Worker
After=network.target docker.service redis-server.service mariadb.service

[Service]
User=www-data
Group=www-data
Restart=always
RestartSec=5s
StartLimitInterval=180
StartLimitBurst=30
ExecStart=/usr/bin/php $PANEL_DIR/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
EOF
    run systemctl daemon-reload
    run systemctl enable --now wyvernq
    ok "wyvernq running"

    # The scheduler is what runs backups, the egg index refresh and every user schedule. A
    # panel without it looks healthy and quietly does nothing on time.
    cat >/etc/cron.d/wyvern <<EOF
* * * * * www-data php $PANEL_DIR/artisan schedule:run >> /dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/wyvern
    run systemctl restart cron
    ok "scheduler every minute"
}

# --------------------------------------------------------------------------- nginx

nginx_pma_blocks() {
    [ "$INSTALL_PMA" = "y" ] || return 0
    cat <<EOF

    # phpMyAdmin, gated by the panel session.
    #
    # nginx asks the panel, on every request to /pma, whether the browser presenting these
    # cookies is a signed-in administrator. The panel answers 204 or 403 and nginx forwards
    # or refuses accordingly, so phpMyAdmin is never reachable to anyone who is not already
    # an administrator of this panel — no second password, and nothing to leak.
    #
    # The subrequest is served by the panel itself over the same php-fpm socket, so there
    # is no extra process and no internal HTTP hop.
    location = /wyvern-internal/pma-authorize {
        internal;
        include fastcgi_params;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_param SCRIPT_FILENAME $PANEL_DIR/public/index.php;
        fastcgi_param SCRIPT_NAME /index.php;
        fastcgi_param REQUEST_URI /wyvern/internal/pma-authorize;
        fastcgi_param DOCUMENT_URI /wyvern/internal/pma-authorize;
        fastcgi_param REQUEST_METHOD GET;
        fastcgi_param QUERY_STRING "";
        fastcgi_param CONTENT_TYPE "";
        fastcgi_param CONTENT_LENGTH "";
    }

    # A root, not an alias: nginx has a long-standing bug where try_files inside an
    # aliased location resolves against the wrong path. phpMyAdmin therefore lives in
    # $PMA_PARENT/pma, and /pma maps onto it by plain document root.
    location ^~ /pma {
        auth_request /wyvern-internal/pma-authorize;
        error_page 401 403 = @pma_denied;

        root $PMA_PARENT;
        index index.php;
        try_files \$uri \$uri/ /pma/index.php?\$query_string;

        location ~ ^/pma/.+\.php\$ {
            root $PMA_PARENT;
            include fastcgi_params;
            fastcgi_pass unix:$PHP_SOCK;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_param HTTP_PROXY "";
        }
    }

    # Not a 401 page: someone who is simply not signed in should be sent to sign in, which
    # is the only thing that would fix it.
    location @pma_denied {
        return 302 $PANEL_URL/;
    }
EOF
}

setup_nginx() {
    step "nginx"

    rm -f /etc/nginx/sites-enabled/default

    cat >/etc/nginx/sites-available/wyvern.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $FQDN;

    root $PANEL_DIR/public;
    index index.php;

    access_log /var/log/nginx/wyvern.access.log;
    error_log  /var/log/nginx/wyvern.error.log error;

    # Backups and world uploads are large, and the 1 MB default would reject them with a
    # 413 that looks like a panel bug.
    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size = 100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
$(nginx_pma_blocks)
}
EOF

    ln -sf /etc/nginx/sites-available/wyvern.conf /etc/nginx/sites-enabled/wyvern.conf
    run nginx -t
    run systemctl reload nginx
    ok "panel served at http://$FQDN"

    if [ "$USE_SSL" = "y" ]; then
        info "requesting the Let's Encrypt certificate"
        # --nginx rewrites the block above in place, adding the 443 listener, the
        # certificate paths and the redirect from 80. It also installs the renewal timer,
        # so nothing has to be scheduled here.
        if certbot --nginx --non-interactive --agree-tos --redirect \
            -m "$ADMIN_EMAIL" -d "$FQDN" >>"$LOG_FILE" 2>&1; then
            ok "certificate issued, HTTP redirects to HTTPS"
        else
            tail -n 15 "$LOG_FILE" >&2
            warn "certbot failed. The panel stays on http://$FQDN."
            warn "Usual causes: the domain does not point here yet, or port 80 is filtered."
            USE_SSL=n
            PANEL_URL="http://$FQDN"
            SSL_FAILED=1
        fi
    fi
}

# --------------------------------------------------------------------------- daemon

install_wings() {
    step "Daemon"

    _json=$(gh_api "https://api.github.com/repos/$WINGS_REPO/releases?per_page=1") \
        || die "could not list releases of $WINGS_REPO."
    _wtag=$(json_str "$_json" tag_name)
    [ -n "$_wtag" ] || die "no release on $WINGS_REPO."
    _wbase="https://github.com/$WINGS_REPO/releases/download/$_wtag"

    info "downloading wings $_wtag ($ARCH)"
    curl -fsSL "$_wbase/wings_linux_$ARCH" -o "$WORK_DIR/wings" \
        || die "could not download the daemon."

    if curl -fsSL "$_wbase/checksums.txt" -o "$WORK_DIR/checksums.txt" 2>/dev/null; then
        _want=$(awk -v f="wings_linux_$ARCH" '$2 == f { print $1 }' "$WORK_DIR/checksums.txt")
        _got=$(sha256sum "$WORK_DIR/wings" | awk '{ print $1 }')
        if [ -n "$_want" ] && [ "$_want" != "$_got" ]; then
            die "the daemon does not match its checksum. Corrupt or tampered with: nothing installed."
        fi
        ok "sha256 checksum verified"
    else
        warn "no checksums.txt published for $_wtag: the binary was not verified."
    fi

    install -m 0755 "$WORK_DIR/wings" /usr/local/bin/wings
    mkdir -p "$CONF_DIR" "$DATA_DIR/volumes"
    chmod 700 "$CONF_DIR"

    # Every option is supplied, because p:node:make prompts for anything it is not given
    # and a prompt in a script waits forever. A max of 0 with an overallocation of -1 is
    # how the panel spells "use whatever the machine has".
    info "creating node $NODE_NAME in the panel"
    _scheme=http
    [ "$USE_SSL" = "y" ] && _scheme=https
    panel_artisan p:node:make \
        --name="$NODE_NAME" \
        --description="Installed by wyvern-installer $INSTALLER_VERSION" \
        --fqdn="$FQDN" \
        --scheme="$_scheme" \
        --public=1 \
        --proxy=0 \
        --maintenance=0 \
        --maxMemory=0 \
        --overallocateMemory=-1 \
        --maxDisk=0 \
        --overallocateDisk=-1 \
        --maxCpu=0 \
        --overallocateCpu=-1 \
        --uploadSize=256 \
        --daemonListeningPort=8080 \
        --daemonConnectingPort=8080 \
        --daemonSFTPPort=2022 \
        --daemonSFTPAlias= \
        --daemonBase="$DATA_DIR/volumes"

    # The id comes from the panel rather than from parsing the creation message, which is a
    # translated string and would break the moment the locale changes.
    NODE_ID=$(panel_artisan_out p:node:list | awk -F'|' '/^\| *[0-9]+ *\|/ { gsub(/ /, "", $2); print $2; exit }')
    [ -n "$NODE_ID" ] || die "the node was created but does not appear in p:node:list."
    ok "node #$NODE_ID"

    panel_artisan_out p:node:configuration "$NODE_ID" --format=yaml >"$CONF_DIR/config.yml"
    [ -s "$CONF_DIR/config.yml" ] || die "the node configuration came back empty."

    # The panel does not emit app_name, so the daemon fills in its own default — "pelican"
    # — and then writes it back into this file on first start. It reaches operators: it is
    # what the daemon calls itself in its logs and in the SFTP banner.
    grep -q '^app_name:' "$CONF_DIR/config.yml" || printf 'app_name: Wyvern
' >>"$CONF_DIR/config.yml"

    chmod 600 "$CONF_DIR/config.yml"
    ok "configuration written to $CONF_DIR/config.yml"

    # --config is not optional: the daemon's built-in default is /etc/pelican/config.yml
    # and it exits immediately when it finds nothing there.
    cat >/etc/systemd/system/wyvern-wings.service <<EOF
[Unit]
Description=Wyvern Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=$CONF_DIR
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings --config $CONF_DIR/config.yml
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    run systemctl daemon-reload
    run systemctl enable --now wyvern-wings

    # A certificate renews every 90 days and the daemon keeps serving the old one until it
    # is restarted, so the panel loses its node in the middle of a quiet Tuesday. This hook
    # is the difference between an install that keeps working and one that breaks in a
    # season.
    if [ "$USE_SSL" = "y" ]; then
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat >/etc/letsencrypt/renewal-hooks/deploy/wyvern-wings.sh <<'EOF'
#!/bin/sh
# Wings loads its certificate once, at start.
systemctl is-active --quiet wyvern-wings && systemctl restart wyvern-wings
exit 0
EOF
        chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/wyvern-wings.sh
        ok "daemon restarts when the certificate renews"
    fi

    sleep 3
    if systemctl is-active --quiet wyvern-wings; then
        ok "daemon running"
    else
        warn "the daemon did not start."
        daemon_failure_reason
    fi
}

# --------------------------------------------------------------------------- phpmyadmin

install_pma() {
    [ "$INSTALL_PMA" = "y" ] || return 0
    step "phpMyAdmin"

    _pma_json=$(curl -fsSL https://www.phpmyadmin.net/home_page/version.json) \
        || die "could not look up the current phpMyAdmin version."
    _pma_ver=$(json_str "$_pma_json" version)
    [ -n "$_pma_ver" ] || die "could not read the phpMyAdmin version."

    _pma_url="https://files.phpmyadmin.net/phpMyAdmin/$_pma_ver/phpMyAdmin-$_pma_ver-all-languages.tar.gz"
    info "downloading phpMyAdmin $_pma_ver"
    curl -fsSL "$_pma_url" -o "$WORK_DIR/pma.tar.gz" || die "could not download phpMyAdmin."

    # phpMyAdmin publishes a sha256 next to every archive. Checking it costs one request.
    if curl -fsSL "$_pma_url.sha256" -o "$WORK_DIR/pma.sha256" 2>/dev/null; then
        _want=$(awk '{ print $1 }' "$WORK_DIR/pma.sha256")
        _got=$(sha256sum "$WORK_DIR/pma.tar.gz" | awk '{ print $1 }')
        [ "$_want" = "$_got" ] || die "phpMyAdmin does not match its checksum."
        ok "sha256 checksum verified"
    fi

    rm -rf "$PMA_DIR"
    mkdir -p "$PMA_DIR"
    run tar -xzf "$WORK_DIR/pma.tar.gz" -C "$PMA_DIR" --strip-components=1
    mkdir -p "$PMA_DIR/tmp"

    cat >"$PMA_DIR/config.inc.php" <<EOF
<?php
// Written by wyvern-installer. phpMyAdmin is reachable only through /pma, and nginx asks
// the panel whether the visitor is a signed-in administrator before forwarding anything
// here. This file therefore adds no login of its own beyond the MySQL one.

declare(strict_types=1);

\$cfg['blowfish_secret'] = '$PMA_BLOWFISH';

\$i = 1;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = '127.0.0.1';
\$cfg['Servers'][\$i]['port'] = 3306;
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;

\$cfg['TempDir'] = '$PMA_DIR/tmp';
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
\$cfg['ShowServerInfo'] = false;
\$cfg['VersionCheck'] = false;
EOF

    chown -R www-data:www-data "$PMA_DIR"
    chmod 640 "$PMA_DIR/config.inc.php"
    chmod 700 "$PMA_DIR/tmp"

    run nginx -t
    run systemctl reload nginx
    ok "phpMyAdmin $_pma_ver at $PANEL_URL/pma"
    note "Sign in with wyvernhost, or any other MySQL account on this machine."
}

# --------------------------------------------------------------------------- firewall

# "journalctl -u wyvern-wings -n 40" is forty lines of Go stack trace with the one useful
# sentence scrolled off the top. Print that sentence.
daemon_failure_reason() {
    _reason=$(journalctl -u wyvern-wings --no-pager 2>/dev/null \
        | grep -aoE '(FATAL|ERROR): \[[^]]*\] .*' \
        | tail -n 1 \
        | sed 's/^[A-Z]*: \[[^]]*\] //')

    if [ -n "$_reason" ]; then
        warn "It says: $_reason"
        case "$_reason" in
            *"networks have same bridge name"*)
                warn "A docker network from an earlier install is still there. Remove it:"
                warn "  docker network ls   then   docker network rm <the one whose bridge is pelican0>"
                ;;
            *"connection refused"*|*"no such host"*|*"401"*)
                warn "The daemon could not reach the panel at $PANEL_URL."
                ;;
        esac
    else
        warn "Look at: journalctl -u wyvern-wings -n 40"
    fi
}

setup_firewall() {
    [ "$SKIP_FIREWALL" -eq 0 ] || return 0
    step "Firewall"

    have ufw || run apt-get install -y ufw

    # The SSH port is read from the running configuration, not assumed to be 22. Enabling a
    # firewall that does not allow the port you are connected on is how a VPS becomes
    # unreachable, and it is not recoverable without console access.
    _ssh_port=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ { print $2; exit }' /etc/ssh/sshd_config 2>/dev/null)
    if [ -z "$_ssh_port" ] && [ -n "${SSH_CONNECTION:-}" ]; then
        _ssh_port=$(printf '%s' "$SSH_CONNECTION" | awk '{ print $4 }')
    fi
    [ -n "$_ssh_port" ] || _ssh_port=22

    run ufw allow "$_ssh_port/tcp"
    run ufw allow 80/tcp
    run ufw allow 443/tcp
    if [ "$SKIP_WINGS" -eq 0 ]; then
        run ufw allow 8080/tcp
        run ufw allow 2022/tcp
    fi

    if ufw status 2>/dev/null | grep -q '^Status: active'; then
        ok "rules added (ufw was already active)"
    else
        run sh -c 'ufw --force enable'
        ok "ufw enabled — ssh on $_ssh_port, 80, 443, 8080, 2022"
    fi
    note "Game server ports stay closed; open each one as you create its allocation."
}

# --------------------------------------------------------------------------- smoke test

# curl prints 000 of its own when it cannot connect, so `$(curl -w '%{http_code}' || echo 000)`
# yields "000000" on failure. One source of truth instead.
http_code() {
    curl -s -o /dev/null -m 15 -w '%{http_code}' "$1" 2>/dev/null || true
}

# The installer once finished with a cheerful summary while every page answered 500, and
# the daemon was failing behind it for the same reason. Finishing is not the same as
# working, so the last thing it does is ask.
smoke_test() {
    step "Checking it actually works"

    # Against the panel's own URL, not 127.0.0.1: the panel redirects everything to
    # APP_URL, so asking on another host measures the redirect rather than the panel.
    _code=$(http_code "$PANEL_URL/")
    case "$_code" in
        200|302)
            ok "the panel answers ($_code)"
            ;;
        *)
            warn "the panel answered $_code, not a redirect to the login page."
            warn "Look at: tail -n 50 $PANEL_DIR/storage/logs/*.log"
            warn "         journalctl -u $PHP-fpm -n 50"
            SMOKE_FAILED=1
            ;;
    esac

    # /login, not /auth/login. routes/auth.php is mounted under /auth, but the form the
    # browser lands on is Filament's, at /login, and /auth/login merely redirects there.
    _login=$(http_code "$PANEL_URL/login")
    if [ "$_login" = "200" ]; then
        ok "the login page renders"
    else
        warn "the login page answered $_login."
        SMOKE_FAILED=1
    fi

    if [ "$INSTALL_PMA" = "y" ]; then
        _pma=$(http_code "$PANEL_URL/pma/")
        case "$_pma" in
            302) ok "phpMyAdmin is shut to a visitor who is not signed in" ;;
            200) warn "phpMyAdmin answered 200 while signed out — the gate is not working." ; SMOKE_FAILED=1 ;;
            *)   warn "phpMyAdmin answered $_pma." ; SMOKE_FAILED=1 ;;
        esac
    fi

    if [ "$SKIP_WINGS" -eq 0 ]; then
        # 401 is the daemon refusing an unsigned request, which is the healthy answer.
        _w=$(http_code "http://127.0.0.1:8080/api/system")
        if [ "$_w" = "401" ]; then
            ok "the daemon is listening and refusing unsigned requests"
        else
            warn "the daemon is not answering on :8080 (got ${_w:-nothing})."
            daemon_failure_reason
            SMOKE_FAILED=1
        fi
    fi
}

# --------------------------------------------------------------------------- summary

summary() {
    _pw_line="the one you chose"
    [ "$GENERATED_ADMIN_PASS" -eq 1 ] && _pw_line="$ADMIN_PASS"

    {
        printf 'Wyvern — installed %s by wyvern-installer %s\n\n' "$(date '+%Y-%m-%d %H:%M')" "$INSTALLER_VERSION"
        printf 'Panel            %s\n' "$PANEL_URL"
        printf 'Version          %s\n' "$PANEL_TAG"
        printf 'Administrator    %s <%s>\n' "$ADMIN_USER" "$ADMIN_EMAIL"
        printf 'Password         %s\n\n' "$_pw_line"
        printf 'Panel database   %s / %s: %s\n' "$DB_NAME" "$DB_USER" "$DB_PASS"
        printf 'Database host    wyvernhost: %s\n' "${DB_HOST_PASS:-not created}"
        printf '                 (register this as a database host in the admin area, on\n'
        printf '                  127.0.0.1:3306, to give each game server its own database)\n\n'
        if [ "$INSTALL_PMA" = "y" ]; then
            printf 'phpMyAdmin       %s/pma — only reachable while signed in to the panel\n\n' "$PANEL_URL"
        fi
        printf 'Directories      panel   %s\n' "$PANEL_DIR"
        printf '                 daemon  %s/config.yml\n' "$CONF_DIR"
        printf '                 volumes %s/volumes\n\n' "$DATA_DIR"
        printf 'Services         systemctl status wyvern-wings wyvernq nginx %s-fpm mariadb redis-server\n' "$PHP"
        printf 'Install log      %s\n' "$LOG_FILE"
    } >"$CRED_FILE"
    chmod 600 "$CRED_FILE"

    if [ "$SMOKE_FAILED" -eq 1 ]; then
        printf '\n%sWyvern is installed, but it is not answering properly.%s\n\n' "$C_YELLOW$C_BOLD" "$C_RESET"
    else
        printf '\n%sWyvern is installed.%s\n\n' "$C_GREEN$C_BOLD" "$C_RESET"
    fi

    printf '    Panel            %s%s%s\n' "$C_BOLD" "$PANEL_URL" "$C_RESET"
    printf '    Administrator    %s\n' "$ADMIN_USER"
    if [ "$GENERATED_ADMIN_PASS" -eq 1 ]; then
        printf '    Password         %s%s%s\n' "$C_BOLD" "$ADMIN_PASS" "$C_RESET"
        printf '    %sAlso in %s. Change it after signing in.%s\n' "$C_DIM" "$CRED_FILE" "$C_RESET"
    else
        printf '    Password         the one you chose\n'
    fi
    printf '\n    Every credential, database ones included: %s\n' "$CRED_FILE"

    if [ "$SSL_FAILED" -eq 1 ]; then
        printf '\n    %s!%s No certificate was issued. Once the domain points here:\n' "$C_YELLOW" "$C_RESET"
        printf '        certbot --nginx -d %s\n' "$FQDN"
        printf '      then switch the node back to https in the admin area.\n'
    fi

    if [ "$SKIP_WINGS" -eq 0 ]; then
        printf '\n    Next: create a server in the admin area. Node %s is already registered,\n' "$NODE_NAME"
        printf '    and no eggs are imported — start by importing one.\n'
    fi
    printf '\n'
}

# --------------------------------------------------------------------------- main

cleanup() {
    [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
    return 0
}

main() {
    parse_args "$@"

    # Prompts read from the terminal, not from stdin: piping this script into a shell
    # leaves stdin pointing at the script itself, and every read would swallow a line of
    # code.
    #
    # Testing readability is not enough: /dev/tty exists and looks readable inside a
    # container or under `ssh host 'sh install.sh'`, and opening it still fails with
    # ENXIO. Under set -e that aborts the script before this fallback can run, so the
    # open is attempted in a subshell first.
    if (exec 3</dev/tty) 2>/dev/null; then
        exec 3</dev/tty
    else
        exec 3<&0
        if [ "$UNATTENDED" -eq 0 ]; then
            die "no terminal available. Download the script and run it (sh install.sh), or pass --unattended with every option."
        fi
    fi

    : >"$LOG_FILE" 2>/dev/null || die "cannot write $LOG_FILE (are you root?)"
    chmod 600 "$LOG_FILE"
    LOG_READY=1
    _log "wyvern-installer $INSTALLER_VERSION, args: $*"

    WORK_DIR=$(mktemp -d /tmp/wyvern-install.XXXXXX) || die "mktemp failed."
    trap cleanup EXIT HUP INT TERM

    printf '\n%s    W Y V E R N%s   installer %s\n' "$C_BOLD" "$C_RESET" "$INSTALLER_VERSION"
    printf '%s    panel, daemon and database, on this machine%s\n' "$C_DIM" "$C_RESET"

    preflight
    collect
    install_packages
    setup_database
    setup_redis
    install_panel
    setup_queue_and_cron
    setup_nginx
    install_pma
    [ "$SKIP_WINGS" -eq 0 ] && install_wings
    setup_firewall
    smoke_test
    summary
}

main "$@"
