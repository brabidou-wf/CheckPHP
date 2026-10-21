#!/usr/bin/env bash
# php-audit.sh - list installed PHP versions and report which nginx/apache sites use each one.
# Read-only. Run with sudo so every config file and `nginx -T` are readable:
#   sudo bash php-audit.sh            (or: sudo bash php-audit.sh > php-report.txt)
set -uo pipefail
shopt -s nullglob

declare -A BINS FULL FPM POOLS USES LISTEN UPS SEEN
UNRESOLVED=""

# Pull major.minor out of names like php8.1, php81, php-fpm8.1, ea-php74, alt-php82, lsphp81, /opt/plesk/php/8.1
norm() {
  [[ ${1:-} =~ php(-fpm)?[-/_]?([5-8])\.?([0-9]{1,2}) ]] && echo "${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
}

DEF=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
DEF_FULL=$(php -r 'echo PHP_VERSION;' 2>/dev/null)

# ---- 1. PHP binaries (Debian/Ubuntu, RHEL/Remi, cPanel EA, CloudLinux alt-php, Plesk, LiteSpeed, source builds)
for b in /usr/bin/php* /usr/sbin/php-fpm* /usr/local/bin/php* /usr/local/sbin/php-fpm* \
         /opt/remi/php*/root/usr/{bin/php,sbin/php-fpm} /opt/cpanel/ea-php*/root/usr/{bin/php,sbin/php-fpm} \
         /opt/alt/php*/usr/{bin/php,sbin/php-fpm} /opt/plesk/php/*/{bin/php,sbin/php-fpm} \
         /usr/local/lsws/lsphp*/bin/lsphp /usr/local/php*/{bin/php,sbin/php-fpm}; do
  [[ -f $b && -x $b ]] || continue
  [[ $(basename "$b") =~ ^(php|php-fpm|lsphp)[0-9.]*$ ]] || continue
  r=$(readlink -f "$b"); [[ -n ${SEEN[$r]:-} ]] && continue; SEEN[$r]=1
  out=$(timeout 5 "$r" -v 2>/dev/null | head -1)
  [[ $out =~ PHP\ ([0-9]+)\.([0-9]+)\.([0-9]+) ]] || continue
  v="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  full="$v.${BASH_REMATCH[3]}"
  # keep every patch level seen (CLI and FPM builds of one branch can differ)
  [[ " ${FULL[$v]:-} " == *" $full "* ]] || FULL[$v]+="${FULL[$v]:+ }$full"
  BINS[$v]+="$r ($full) "
done

# ---- 2. PHP-FPM pools: map each listen socket/port -> version
for f in /etc/php/*/fpm/pool.d/*.conf /etc/php-fpm.d/*.conf /etc/opt/remi/php*/php-fpm.d/*.conf \
         /opt/cpanel/ea-php*/root/etc/php-fpm.d/*.conf /opt/alt/php*/etc/php-fpm.d/*.conf \
         /opt/plesk/php/*/etc/php-fpm.d/*.conf /usr/local/etc/php-fpm.d/*.conf; do
  v=$(norm "$f"); v=${v:-$DEF}; [[ -z $v ]] && v="?"
  pool=$(grep -m1 -oP '^\s*\[\K[^]]+' "$f")
  while read -r l; do
    l=${l//\$pool/$pool}; l=${l/#\/var\/run\//\/run\/}
    LISTEN[$l]=$v
    [[ $l =~ ^([^:/]*:)?([0-9]+)$ ]] && LISTEN[port:${BASH_REMATCH[2]}]=$v
    POOLS[$v]+="${pool:-?} "
  done < <(grep -oP '^\s*listen\s*=\s*\K\S+' "$f")
done

# ---- 3. FPM services and their state
if command -v systemctl >/dev/null; then
  while read -r unit _ _ sub _; do
    v=$(norm "$unit"); v=${v:-${DEF:-?}}
    FPM[$v]+="${unit%.service}($sub) "
  done < <(systemctl list-units --type=service --all --no-legend --plain 2>/dev/null \
           | sed 's/^[^a-zA-Z0-9]*//' | grep -iE '^[^ ]*php[^ ]*fpm|^[^ ]*fpm[^ ]*php|^php-fpm')
fi

resolve() { # fastcgi target (socket path, host:port, port) -> version
  local t=${1#unix:} v
  t=${t/#\/var\/run\//\/run\/}
  v=${LISTEN[$t]:-}
  [[ -z $v && $t =~ (^|:)([0-9]+)$ ]] && v=${LISTEN[port:${BASH_REMATCH[2]}]:-}
  [[ -z $v ]] && v=$(norm "$t")
  echo "${v:-?}"
}
record() { # version, description
  local v=${1:-?}; shift
  if [[ $v == "?" ]]; then UNRESOLVED+="  $*"$'\n'; else USES[$v]+="  $*"$'\n'; fi
}
names_in() { grep -oiP "^\s*($1)\s+\K[^;#]+" "$2" | tr -s ' \n' ' ' | sed 's/ $//'; }

# ---- 4. nginx
WEB=""
if [[ -d /etc/nginx ]]; then
  WEB+="nginx "
  if command -v nginx >/dev/null && nginx -T >/dev/null 2>&1; then
    mapfile -t NGX < <(nginx -T 2>/dev/null | sed -n 's/^# configuration file \(.*\):$/\1/p' | sort -u)
  else
    NGX=(/etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*)
  fi
  # upstream blocks: name -> server targets
  while read -r name tgt; do UPS[$name]+="$tgt "; done < <(awk '
    $1=="upstream" {u=$2; sub(/\{.*/,"",u); next}
    u && $1=="server" {sub(/;.*/,"",$2); print u, $2}
    u && /}/ {u=""}' "${NGX[@]}" 2>/dev/null)
  for f in "${NGX[@]}"; do
    [[ -f $f ]] || continue
    names=$(names_in server_name "$f")
    while read -r t; do
      for x in ${UPS[$t]:-$t}; do
        record "$(resolve "$x")" "nginx   [${names:-no server_name}]  $f -> $x"
      done
    done < <(grep -oP '^\s*fastcgi_pass\s+\K[^;]+' "$f" | sort -u)
  done
fi

# ---- 5. apache (Debian, RHEL, cPanel)
APA=(/etc/apache2/apache2.conf /etc/apache2/sites-enabled/* /etc/apache2/conf-enabled/* /etc/apache2/mods-enabled/*
     /etc/apache2/conf.d/*.conf /etc/httpd/conf/*.conf /etc/httpd/conf.d/*.conf /etc/httpd/conf.modules.d/*.conf
     /usr/local/apache/conf/*.conf /etc/apache2/conf.d/userdata/*/*/*/*.conf)
[[ -d /etc/apache2 || -d /etc/httpd || -d /usr/local/apache ]] && WEB+="apache "
for f in "${APA[@]}"; do
  [[ -f $f ]] || continue
  names=$(names_in 'ServerName|ServerAlias' "$f")
  while read -r t; do
    case $t in
      proxy:unix:*) x=${t#proxy:}; v=$(resolve "$x") ;;
      fcgi://*)     x=${t#fcgi://}; x=${x%%/*}; v=$(resolve "$x") ;;
      *libphp*)     x="mod_php $t"; v=$(norm "$t"); [[ -z $v ]] && v=$(norm "$f"); v=${v:-$DEF} ;;
      *)            x=$t; v=$(norm "$t") ;;
    esac
    record "$v" "apache  [${names:-global}]  $f -> $x"
  done < <(grep -v '^\s*#' "$f" | sed -E 's#\|fcgi://[^" ]*##g' \
           | grep -oiE 'proxy:unix:[^|" ]+|fcgi://[^/" ]+|libphp[0-9.]*\.so|x-httpd-(ea-|alt-)?php[0-9]+' | sort -u)
done

# ---- 6. .htaccess handlers (cPanel MultiPHP / CloudLinux selector)
while read -r f; do
  while read -r t; do record "$(norm "$t")" "htaccess  $f -> $t"; done \
    < <(grep -v '^\s*#' "$f" | grep -oiE 'x-httpd-(ea-|alt-)?php[0-9]+' | sort -u)
done < <(find /home /var/www -maxdepth 4 -name .htaccess 2>/dev/null)

# ---- Report
hr() { printf '\n== %s ==\n' "$1"; }
label() { local f=${FULL[$1]:-}; if [[ -n $f ]]; then echo "${f// /, }"; else echo "$1 (no binary found)"; fi; } # 7.2 -> 7.2.34
mapfile -t ALL < <(printf '%s\n' "${!BINS[@]}" "${!FPM[@]}" "${!POOLS[@]}" "${!USES[@]}" | grep -v '^?*$' | sort -uV)

echo "PHP audit: $(hostname) - $(date '+%F %T')"
echo "Web servers found: ${WEB:-none}"
echo "Default CLI php:   ${DEF_FULL:-none}"

hr "Installed PHP versions"
for v in "${ALL[@]}"; do
  refs=$(printf '%s' "${USES[$v]:-}" | grep -c .)
  printf 'PHP %s - %s config reference(s)\n' "$(label "$v")" "$refs"
  printf '    fpm services: %s\n' "${FPM[$v]:-none}"
  [[ -n ${POOLS[$v]:-} ]] && printf '    fpm pools:    %s\n' "${POOLS[$v]}"
  [[ -n ${BINS[$v]:-}  ]] && printf '    binaries:     %s\n' "${BINS[$v]}"
done

hr "Usage by version"
USED=() UNUSED=()
for v in "${ALL[@]}"; do
  if [[ -n ${USES[$v]:-} ]]; then
    USED+=("$(label "$v")"); echo "PHP $(label "$v"):"; printf '%s' "${USES[$v]}"
    [[ -z ${FULL[$v]:-} ]] && echo "  !! referenced in config but no PHP $v binary was found"
  else
    UNUSED+=("$(label "$v")"); echo "PHP $(label "$v"): not referenced by any web server config"
  fi
done

[[ -n $UNRESOLVED ]] && { hr "PHP references with unknown version"; printf '%s' "$UNRESOLVED"; }

hr "Summary"
join() { local IFS=';'; local s="$*"; s=${s//;/ | }; echo "${s:-none}"; }
echo "In use by web server:   $(join "${USED[@]}")"
echo "Not used by web server: $(join "${UNUSED[@]}")"
[[ ${#UNUSED[@]} -gt 0 ]] && echo "(Unused versions may still be used by cron jobs or CLI scripts - check before removing.)"
