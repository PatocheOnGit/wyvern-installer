# wyvern-installer

One script that turns a fresh Debian or Ubuntu VPS into a working
[Wyvern Panel](https://github.com/PatocheOnGit/wyvern-panel-next) host: the panel, the
[daemon](https://github.com/PatocheOnGit/wyvern-wings), a database, a cache, a web server,
a queue worker, a scheduler, a firewall, and optionally phpMyAdmin.

Wyvern is a personal project. This installer is published so its own installs are
reproducible and auditable — not as a product. It makes large changes to a machine, so
read it before you run it, and run it on a host you are willing to dedicate to Wyvern.

```sh
wget https://raw.githubusercontent.com/PatocheOnGit/wyvern-installer/main/install.sh
sudo sh install.sh
```

It asks a handful of questions, then takes five to fifteen minutes depending on the VPS.
Everything it does is logged to `/var/log/wyvern-install.log`; only decisions and failures
reach the screen.

**Do not pipe it into a shell.** `curl … | sh` leaves stdin pointing at the script itself,
so every prompt would eat a line of code. The script detects this and refuses rather than
misbehaving — download it, then run it.

## What it needs

| | |
|---|---|
| OS | Debian 12+ or Ubuntu 22.04+, or a derivative of either. Anything else is refused, not attempted. |
| Init | systemd. The daemon and the queue worker are systemd units. |
| Arch | amd64 or arm64 — the two the daemon is published for. |
| RAM | 2 GB to be comfortable. Less works, and is warned about: the panel leaves little for game servers. |
| Disk | 10 GB free on `/var` before the first game server. |
| Ports | 80 and 443 free, plus 8080 and 2022 for the daemon. Checked before anything is installed. |
| Network | Reachable `api.github.com`, where the panel and the daemon come from. |

A domain already pointed at the host gets HTTPS from Let's Encrypt. An IP address gets
HTTP, because no certificate authority will certify an IP.

## Unattended

Give every answer as a flag and it asks nothing:

```sh
sudo sh install.sh --unattended \
  --fqdn panel.example.com --ssl \
  --email you@example.com --username admin \
  --node-name node-01 --with-pma
```

`sh install.sh --help` lists them all. With `--password` omitted, one is generated and
written to `/root/wyvern-credentials.txt` along with every other credential.

Environment variables, for the unusual cases:

| | |
|---|---|
| `WYVERN_GITHUB_TOKEN` | Any token. Anonymous GitHub API calls are capped at 60 per hour per IP, and a busy or shared address can exhaust that before the installer starts. |
| `WYVERN_PANEL_REPO`, `WYVERN_WINGS_REPO` | Install from a fork. |
| `WYVERN_PANEL_DIR` | Somewhere other than `/var/www/wyvern`. |
| `WYVERN_LOCALE` | Panel language. Defaults to `en`. |

## What ends up where

| | |
|---|---|
| Panel | `/var/www/wyvern`, owned by `www-data` |
| Panel config | `/var/www/wyvern/.env`, mode 640 |
| Daemon | `/usr/local/bin/wings`, config `/etc/wyvern/config.yml` |
| Game server data | `/var/lib/wyvern/volumes` |
| nginx | `/etc/nginx/sites-available/wyvern.conf` |
| Queue worker | `wyvernq.service` |
| Daemon | `wyvern-wings.service` |
| Scheduler | `/etc/cron.d/wyvern`, every minute |
| Credentials | `/root/wyvern-credentials.txt`, mode 600 |
| Log | `/var/log/wyvern-install.log` |

The database and the cache are the distribution's own `mariadb-server` and `redis-server`,
both bound to `127.0.0.1`. Nothing runs in a container except game servers.

Two database accounts are created. `wyvern` owns the panel's schema and nothing else.
`wyvernhost` can create databases and users, which is what the panel's per-server database
feature needs — and it is **registered in the panel for you**, as a database host called
"Local MariaDB" attached to the node. Creating a node without the host it will serve
databases from leaves the install half-made: the account would exist, with exactly the right
grants, and "give this server a database" would still be a dead button.

### Sessions and the cache do not share a database

The panel is configured with sessions on redis database 1 and the cache on database 0.
This is not cosmetic: Laravel clears a redis cache with `FLUSHDB`, so with both on one
database, `php artisan cache:clear` — and therefore `optimize:clear` — signs every user
out, including whoever ran it. The panel now defaults to the separated connection, and the
installer inherits it.

## phpMyAdmin

Optional, off by default. It is not a bare phpMyAdmin bolted onto the side: `/pma` is a
page of the panel, and phpMyAdmin itself lives behind it at `/pma/app`.

```
/pma       →  panel page: the databases you can reach, pick one, give its password
/pma/app   →  phpMyAdmin, already signed in as that database's MySQL user
```

Not signed in to the panel, you are sent to the login page. Signed in, you see your own
databases — the ones created on your servers' Databases pages — and nothing else. Pick one,
give **that database's** password, and phpMyAdmin opens as its MySQL user.

Three things follow, and each is deliberate:

- **The password is asked for, never taken.** The panel stores it encrypted and could sign
  you in silently, but then any open panel tab would be an open shell on every database its
  owner has.
- **Scoping is left to MySQL.** Each database user has rights over its own schema and
  nothing else, so phpMyAdmin shows exactly that much without being told to hide anything.
  A filter in the UI would be a weaker second copy of a rule the database already enforces.
- **The handover is bound to the panel session.** phpMyAdmin asks its signon source who to
  log in as on *every* request, so anything consumed by reading it works for one page and
  then throws you back to the picker — which is exactly what the first version of this did.
  The selection lives against the session instead, and the signon script forwards your
  cookies so the panel resolves the same person it would anywhere else.

nginx still asks the panel, on every `/pma/app` request, whether the visitor is signed in at
all. That is the outer door; the picker and the MySQL grants are what decide the rest.

### Made to look like the panel

Not just darkened. The theme is built at install time from what the panel already has on
the host:

- **Its typefaces.** Instrument Sans and JetBrains Mono are copied out of the panel's build
  — copied, not linked, because Vite names its output with a content hash that changes on
  every rebuild.
- **Its icons.** phpMyAdmin draws every icon as a transparent gif with the image applied by
  a `.ic_*` class, so the whole set is replaceable in CSS. Each class becomes a mask over a
  solid colour, generated from the same Tabler icons the panel uses, so an icon means the
  same thing on both sides of the link. Colour follows the panel's rule: grey by default,
  accent for the action you came to perform, red only for what destroys something.
- **Its measurements.** 13px base, 8px cards, 6px controls, one hairline, no shadows,
  monospaced data cells.

The colours themselves are a variable override on a copy of the Bootstrap theme, since
every phpMyAdmin theme is compiled Bootstrap 5 with the full set of `--bs-*` properties.

What was left light was found by walking the DOM of phpMyAdmin's own pages and asking which
elements actually compute to a light background or dark text — the SQL console, the query
box, CodeMirror's purple-on-white syntax theme and a dozen black labels all survived a pass
done by looking at screenshots. It is still a skin: phpMyAdmin's layout is its own.

It is also pinned to English, which it otherwise picks from `Accept-Language`, and its logo
links back to the picker rather than to phpmyadmin.net.

This needs panel **0.3.1 or newer**. Against anything older the page does not exist and
`/pma` simply 404s — closed, not open, which is the right way for that to fail.

## After it finishes

The panel is up, the node is registered, the daemon is running. Two things are deliberately
left to you:

- **No eggs are imported.** Pelican ships none, and neither does this. Import from
  [wyvern-eggs](https://github.com/PatocheOnGit/wyvern-eggs) or any
  [pelican-eggs](https://github.com/pelican-eggs) collection from the admin area.
- **Game server ports are not opened.** The firewall allows SSH, 80, 443, 8080 and 2022.
  Open each game port as you create its allocation — a blanket range would be a guess at
  what you are running.

## What it will not do

- **Install over an existing panel.** If `$PANEL_DIR/artisan` exists it stops. Reconciling
  a database, an `.env` and a node token it did not create is not something a script should
  improvise.
- **Upgrade.** There is no `--upgrade`. Panel upgrades are `git`/tarball plus
  `php artisan migrate --force`, and they deserve their own tool.
- **Set up mail.** `MAIL_MAILER=log`, so password resets land in the panel's log instead of
  a mailbox. Configure SMTP in the admin area when you need it.
- **Touch a machine it does not understand.** Not Debian or Ubuntu, no systemd, wrong
  architecture, occupied ports, too little disk: it refuses up front rather than failing
  halfway through.

## contrib/rebind.sh

Not part of the install. It points an existing panel at a different address — `APP_URL`,
nginx's `server_name`, the node's FQDN, the daemon's config and phpMyAdmin's back-link, all
of which are written once at install time and none of which notice when the address moves.

Written for a panel on WSL, where the IP changes on most restarts, but it applies to any
host that has moved:

```sh
sudo rebind.sh              # to whatever IP this host has now
sudo rebind.sh localhost    # to a name that never changes
sudo rebind.sh panel.example.com
```

It does nothing when the address is already right, so it is safe to run on every boot.

## Removing it, to install again

There is no uninstaller. Reinstalling means taking the old one apart first, and one step is
easy to miss:

```sh
systemctl disable --now wyvern-wings wyvernq
rm -f /etc/systemd/system/wyvern-wings.service /etc/systemd/system/wyvernq.service
systemctl daemon-reload

mariadb -e "DROP DATABASE IF EXISTS wyvern;
            DROP USER IF EXISTS 'wyvern'@'127.0.0.1';
            DROP USER IF EXISTS 'wyvernhost'@'127.0.0.1';"

rm -rf /var/www/wyvern /var/www/wyvern-pma /etc/wyvern /var/lib/wyvern
rm -f  /etc/nginx/sites-{available,enabled}/wyvern.conf /etc/cron.d/wyvern
rm -f  /etc/php/*/fpm/pool.d/wyvern.conf /root/wyvern-credentials.txt
systemctl restart nginx php*-fpm

# The step people miss. The daemon creates a docker network on the pelican0 bridge, and a
# leftover one makes the new daemon exit on startup with "networks have same bridge name".
docker ps -aq | xargs -r docker rm -f
docker network ls
docker network rm <the network whose bridge is pelican0>
```

`docker network inspect <name> --format '{{index .Options "com.docker.network.bridge.name"}}'`
tells you which one that is; it will not necessarily be called `pelican0` itself.

Then stop nginx, so the port check sees 80 free, and run the installer again.

## If something breaks

```sh
tail -n 50 /var/log/wyvern-install.log
systemctl status wyvern-wings wyvernq nginx mariadb redis-server
journalctl -u wyvern-wings -n 40
```

The two failures worth naming in advance:

- **certbot failed.** Almost always a domain that does not point at this host yet, or a
  filtered port 80. The install continues over HTTP and tells you the one command to run
  afterwards.
- **The node shows offline in the panel.** The daemon is reachable on 8080 over the scheme
  the node was created with. If you obtained a certificate after creating the node, the
  node is still `http` — change it in the admin area and restart `wyvern-wings`.

## Licence and derivation

MIT, see [`LICENSE`](LICENSE).

The things it installs are derivatives themselves, and say so: the panel comes from
[Pelican](https://pelican.dev) (AGPL-3.0), and the daemon from Pelican's Wings, itself from
[Pterodactyl](https://pterodactyl.io) Wings (MIT). Wyvern is not affiliated with, endorsed
by, or sponsored by either project.
