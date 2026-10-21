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
| PHP binaries | `/usr/bin`, `/usr/sbin`, `/usr/local`, Remi (`/opt/remi`), cPanel EA (`/opt/cpanel/ea-php*`), CloudLinux (`/opt/alt/php*`), Plesk (`/opt/plesk/php`), LiteSpeed (`/usr/local/lsws/lsphp*`) |
| PHP-FPM pools | `listen =` in pool configs, so each socket/port maps to a version |
| PHP-FPM services | `systemctl` units with php + fpm in the name, and their state |
| nginx | `fastcgi_pass` in every file `nginx -T` loads (or `sites-enabled` / `conf.d`), including `upstream` blocks |
| Apache | `proxy:unix:` / `fcgi://` handlers, `mod_php` (`libphp*.so`), `x-httpd-(ea-\|alt-)phpNN` handlers |
| `.htaccess` | cPanel MultiPHP / CloudLinux handlers under `/home` and `/var/www` (4 levels deep) |

## Report

1. **Installed PHP versions**: full version (e.g. `7.2.34`; several if CLI and FPM builds differ), FPM services, pools, binaries, and the number of config references for each.
2. **Usage by version**: each site, under its full PHP version, (server name, config file, socket/port) grouped by PHP version. Versions nothing references are marked `not referenced`. Configs that point at a version with no installed binary are flagged.
3. **PHP references with unknown version**: handlers the script found but couldn't match to a version.
4. **Summary**: versions in use, and versions not used by any web server.

## Caveats

- Site names are matched to PHP sockets per config file. This is accurate when each site has its own config file. If one file holds several server blocks, every site in it is listed together.
- A version marked "not used by web server" may still be used by cron jobs or CLI scripts. Check before you remove it.
- Needs bash 4+ and GNU grep (`grep -P`). Both are standard on modern Linux distros.
