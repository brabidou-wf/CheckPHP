# CheckPHP

`php-audit.sh` finds every PHP version installed on a Linux server and reports which nginx / Apache sites use each one. It's handy for spotting PHP versions nothing uses before you remove them, or for seeing which sites are still on an old version.

The script only reads. It changes nothing on the server.

## Run it

Run it straight from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/brabidou-wf/CheckPHP/main/php-audit.sh | sudo bash
```

Save the report to a file:

```bash
curl -fsSL https://raw.githubusercontent.com/brabidou-wf/CheckPHP/main/php-audit.sh | sudo bash > php-report.txt
```

Or download it and run it locally:

```bash
curl -fsSLO https://raw.githubusercontent.com/brabidou-wf/CheckPHP/main/php-audit.sh
sudo bash php-audit.sh
```

Run it as root (`sudo`) so it can read every config file and `nginx -T` works.

## What it checks

| Area | Where it looks |
|---|---|
| PHP binaries | `/usr/bin`, `/usr/sbin`, `/usr/local`, source builds in `/opt/php*`, Remi (`/opt/remi`), cPanel EA (`/opt/cpanel/ea-php*`), CloudLinux (`/opt/alt/php*`), Plesk (`/opt/plesk/php`), LiteSpeed (`/usr/local/lsws/lsphp*`) |
| PHP-FPM services | Every `systemctl` unit with php + fpm in its name. The version comes from the binary its `ExecStart` runs, not from the unit name, so a unit like `php8.4.27-fpm` running `/opt/php-8.4.27/sbin/php-fpm` is reported correctly |
| PHP-FPM pools | The `--fpm-config` each service starts with (or the install's own `etc/php-fpm.conf` when it starts without one, as Plesk's shared services do), plus its `include=` files, so each socket/port maps to the exact install that serves it. Relative sockets (`listen = php-fpm.sock`) are resolved against the pool's `prefix=`. Then any leftover pool files in the usual places |
| Running FPM processes | `php-fpm: master` processes systemd doesn't manage (started by hand, supervisor, a panel). Also flags a master whose binary was upgraded since it started (**STALE**: restart to load the new version) |
| nginx | `fastcgi_pass` in every file `nginx -T` loads (or `sites-enabled` / `conf.d`), including `upstream` blocks |
| Apache | `proxy:unix:` / `fcgi://` handlers, `mod_php` (`libphp*.so`), `x-httpd-(ea-\|alt-)phpNN` handlers, in every file Apache loads (`apache2ctl -t -D DUMP_INCLUDES`, so panel includes like Plesk's `plesk.conf.d/vhosts` count), or the usual config dirs if that fails |
| `.htaccess` | cPanel MultiPHP / CloudLinux handlers under `/home` and `/var/www` (4 levels deep) |

## Report

Versions are grouped by the full version number (e.g. `8.4.7` and `8.4.27` are listed separately), so two installs of the same branch never get merged.

1. **Installed PHP versions**: FPM services (with the binary each one runs), pools, binaries, and the number of config references for each.
2. **Usage by version**: each site (server name, config file, socket/port) grouped under its full PHP version. Versions nothing references are marked `not referenced`. Configs that point at a version with no installed binary are flagged. If a version can only be guessed from a name like `php8.4` and more than one 8.4 build is installed, it's shown as ambiguous rather than guessed.
3. **PHP references with unknown version**: handlers the script found but couldn't match to a version.
4. **Summary**: versions in use, and versions not used by any web server.

## Caveats

- Site names are matched to PHP sockets per config file. This is accurate when each site has its own config file. If one file holds several server blocks, every site in it is listed together.
- A version marked "not used by web server" may still be used by cron jobs or CLI scripts. Check before you remove it.
- Needs bash 4+ and GNU grep (`grep -P`). Both are standard on modern Linux distros.


