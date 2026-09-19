#!/bin/bash
#
# Point the panel at an address.
#
# WSL hands this distro a new IP on most restarts. The panel does not notice: APP_URL,
# nginx's server_name and the node's FQDN were all written once, at install time, and a
# stale one of those means the panel redirects to an address that no longer exists and the
# console websocket connects to nobody. This reconciles all three.
#
#   rebind.sh              # to whatever IP WSL has given us right now
#   rebind.sh localhost    # to a name that never changes (simpler, if you only use it here)
#   rebind.sh 192.168.1.5  # to anything else
#
# It does nothing at all when the address is already correct, so it is cheap to run on
# every boot.

set -euo pipefail

PANEL_DIR=/var/www/wyvern
CONF_DIR=/etc/wyvern
NGINX_SITE=/etc/nginx/sites-available/wyvern.conf

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

target="${1:-}"
if [ -z "$target" ]; then
    target=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ { for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')
fi
[ -n "$target" ] || { echo "rebind: could not work out an address" >&2; exit 1; }

[ -f "$PANEL_DIR/artisan" ] || { echo "rebind: no panel in $PANEL_DIR" >&2; exit 1; }

current=$(grep -E '^APP_URL=' "$PANEL_DIR/.env" | cut -d= -f2- | sed 's#^https\?://##; s#/$##')

if [ "$current" = "$target" ]; then
    echo "  panel already bound to $target"
    exit 0
fi

echo "  rebinding $current -> $target"

# 1. The panel's own idea of where it lives. Everything absolute comes from this: redirects
#    after login, asset URLs, and the `remote` the daemon is handed.
sed -i "s#^APP_URL=.*#APP_URL=http://$target#" "$PANEL_DIR/.env"

# 2. nginx. A single server block answers whatever Host it is given, so this is cosmetic
#    today — but it stops being cosmetic the moment a second site is added.
sed -i "s#^\( *server_name \).*#\1$target;#" "$NGINX_SITE"

# 3. The node. This one is not cosmetic: the browser opens the console websocket straight
#    to this address, so a stale FQDN is a console that never connects.
sudo -u www-data php -r '
require "'"$PANEL_DIR"'/vendor/autoload.php";
$app = require "'"$PANEL_DIR"'/bootstrap/app.php";
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$node = App\Models\Node::first();
if ($node) {
    $node->fqdn = "'"$target"'";
    $node->save();
    echo "  node ", $node->name, " -> ", $node->fqdn, PHP_EOL;
}
'

# The panel caches config in production, so the new APP_URL is invisible until this runs.
( cd "$PANEL_DIR" && sudo -u www-data php artisan config:clear >/dev/null )

# 4. The daemon's config carries both the remote URL and the certificate paths, and it is
#    generated from the node — so it has to be rewritten, not edited.
if [ -f "$CONF_DIR/config.yml" ]; then
    node_id=$(cd "$PANEL_DIR" && sudo -u www-data php artisan p:node:list 2>/dev/null \
        | awk -F'|' '/^\| *[0-9]+ *\|/ { gsub(/ /, "", $2); print $2; exit }')
    if [ -n "$node_id" ]; then
        app_name=$(grep -E '^app_name:' "$CONF_DIR/config.yml" 2>/dev/null || echo 'app_name: Wyvern')
        ( cd "$PANEL_DIR" && sudo -u www-data php artisan p:node:configuration "$node_id" --format=yaml ) >"$CONF_DIR/config.yml.new"
        if [ -s "$CONF_DIR/config.yml.new" ]; then
            grep -q '^app_name:' "$CONF_DIR/config.yml.new" || printf '%s\n' "$app_name" >>"$CONF_DIR/config.yml.new"
            mv "$CONF_DIR/config.yml.new" "$CONF_DIR/config.yml"
            chmod 600 "$CONF_DIR/config.yml"
        else
            rm -f "$CONF_DIR/config.yml.new"
            echo "  ! could not regenerate the daemon config; left the old one alone" >&2
        fi
    fi
fi

# 5. phpMyAdmin's "back to Wyvern" link has to be an absolute URL, because phpMyAdmin
#    rejects a relative one and silently falls back to its own index page. So it moves too.
pma_config=/var/www/wyvern-pma/pma/app/config.inc.php
if [ -f "$pma_config" ]; then
    sed -i "s#\(\\$cfg\['NavigationLogoLink'\] = '\)[^']*\(';\)#http://$target/pma#" "$pma_config"
    rm -rf /var/www/wyvern-pma/pma/app/tmp/twig
    echo "  phpMyAdmin back-link -> http://$target/pma"
fi

systemctl reload nginx
systemctl restart php8.3-fpm
systemctl is-active --quiet wyvern-wings && systemctl restart wyvern-wings || true

echo "  panel now on http://$target"
