#!/usr/bin/env bash
# php-audit.sh - list installed PHP versions and report which nginx/apache sites use each one.
# Read-only. Run with sudo so every config file, /proc and `nginx -T` are readable:
#   sudo bash php-audit.sh            (or: sudo bash php-audit.sh > php-report.txt)
set -uo pipefail
shopt -s nullglob
export LC_ALL=C.UTF-8 # grep -P refuses some locales

# Versions are keyed by full x.y.z (from running the binary), so two builds of one branch
# (e.g. Ubuntu's 8.4.7 and a source-built 8.4.27) are reported separately.
declare -A BINS FPM POOLS USES LISTEN UPS SEEN POOLFILE PIDSEEN
UNRESOLVED=""

# Pull major.minor out of names like php8.1, php81, php-fpm8.1, ea-php74, alt-php82, lsphp81, /opt/plesk/php/8.1
norm() {
  [[ ${1:-} =~ php(-fpm)?[-/_]?([5-8])\.?([0-9]{1,2}) ]] && echo "${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
}

# A major.minor guessed from a name -> the installed x.y.z it means, when exactly one matches
canon() {
  local v=${1:-} k m=()
  [[ $v =~ ^[0-9]+\.[0-9]+$ ]] || { echo "$v"; return; }
  for k in "${!BINS[@]}"; do [[ $k == "$v".* ]] && m+=("$k"); done
  if [[ ${#m[@]} -eq 1 ]]; then echo "${m[0]}"; else echo "$v"; fi
}

# Run a PHP binary's -v and record it. Sets BINV to its x.y.z ("" if it isn't PHP).
# (Sets a global rather than echoing, so the arrays survive - $(...) would run it in a subshell.)
add_bin() {
  local r out
  BINV=""
  r=$(readlink -f "$1" 2>/dev/null); [[ -f $r && -x $r ]] || return
  [[ -n ${SEEN[$r]+x} ]] && { BINV=${SEEN[$r]}; return; }
  SEEN[$r]=""
  out=$(timeout 5 "$r" -v 2>/dev/null | head -1)
  [[ $out =~ PHP\ ([0-9]+\.[0-9]+\.[0-9]+) ]] || return
  BINV=${BASH_REMATCH[1]}; SEEN[$r]=$BINV
  BINS[$BINV]+="$r "
}

# Record every [pool] in an FPM config file: listen socket/port -> version
scan_pool() { # file, version
  local f=$1 v=$2 pool l
  [[ -f $f && -z ${POOLFILE[$f]:-} ]] || return; POOLFILE[$f]=1
  while read -r pool l; do
    l=${l//\$pool/$pool}; l=${l/#\/var\/run\//\/run\/}
    LISTEN[$l]=$v
    [[ $l =~ ^([^:/]*:)?([0-9]+)$ ]] && LISTEN[port:${BASH_REMATCH[2]}]=$v
    POOLS[$v]+="$pool "
  done < <(awk -F= '/^[ \t]*\[/ {s=$0; gsub(/[][ \t]/,"",s); next}
                    /^[ \t]*listen[ \t]*=/ {l=$2; gsub(/[ \t]/,"",l); print (s?s:"?"), l}' "$f")
}

# A main php-fpm.conf: its own pools plus everything it include='s
scan_conf() { # conf, version, fpm binary
  local conf=$1 v=$2 exe=$3 inc p
  [[ -n $conf && -f $conf ]] || return
  scan_pool "$conf" "$v"
  while read -r inc; do # relative includes are relative to the install prefix
    [[ $inc == /* ]] || inc="$(dirname "$(dirname "$exe")")/$inc"
    for p in $inc; do scan_pool "$p" "$v"; done
  done < <(grep -oP '^\s*include\s*=\s*\K\S+' "$conf")
}

# Note for a running FPM master whose binary on disk was replaced after it started
stale() { # pid
  [[ $(readlink "/proc/$1/exe" 2>/dev/null) == *"(deleted)" ]] && echo " - STALE: binary upgraded since start, restart it"
}

DEF=$(php -r 'echo PHP_VERSION;' 2>/dev/null)

# ---- 1. PHP binaries (Debian/Ubuntu, RHEL/Remi, cPanel EA, CloudLinux alt-php, Plesk, LiteSpeed, source builds)
for b in /usr/bin/php* /usr/sbin/php-fpm* /usr/local/bin/php* /usr/local/sbin/php-fpm* \
         /opt/remi/php*/root/usr/{bin/php,sbin/php-fpm} /opt/cpanel/ea-php*/root/usr/{bin/php,sbin/php-fpm} \
         /opt/alt/php*/usr/{bin/php,sbin/php-fpm} /opt/plesk/php/*/{bin/php,sbin/php-fpm} \
         /usr/local/lsws/lsphp*/bin/lsphp /usr/local/php*/{bin/php,sbin/php-fpm} /opt/php*/{bin/php,sbin/php-fpm}; do
  [[ $(basename "$b") =~ ^(php|php-fpm|lsphp)[0-9.]*$ ]] && add_bin "$b"
done

# ---- 2. FPM services: the version is whatever binary the unit's ExecStart runs (not the unit name),
#         and its pools come from the --fpm-config it's started with
if command -v systemctl >/dev/null; then
  while read -r unit _ _ sub _; do
    exec_line=$(systemctl show -p ExecStart --value "$unit" 2>/dev/null | head -1)
    exe=$(sed -n 's/.*path=\([^ ;]*\).*/\1/p' <<<"$exec_line")
    v=""; [[ -n $exe ]] && { add_bin "$exe"; v=$BINV; }
    [[ -z $v ]] && v=$(canon "$(norm "$unit")"); v=${v:-${DEF:-?}}
    pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null)
    note=""; [[ $pid =~ ^[1-9][0-9]*$ ]] && { PIDSEEN[$pid]=1; note=$(stale "$pid"); }
    FPM[$v]+="${unit%.service} ($sub${exe:+, $exe}$note); "
    scan_conf "$(grep -oP '(--fpm-config|-y)[ =]\K[^ ;]+' <<<"$exec_line" | head -1)" "$v" "$exe"
  done < <(systemctl list-units --type=service --all --no-legend --plain 2>/dev/null \
           | sed 's/^[^a-zA-Z0-9]*//' | grep -iE '^[^ ]*php[^ ]*fpm|^[^ ]*fpm[^ ]*php|^php-fpm')
fi

# ---- 2b. Running FPM masters systemd doesn't manage (started by hand, supervisor, a panel...)
for pid in $(pgrep -f '^php-fpm: master process' 2>/dev/null); do
  [[ -n ${PIDSEEN[$pid]:-} ]] && continue
  if [[ $(readlink "/proc/$pid/ns/mnt" 2>/dev/null) != "$(readlink /proc/self/ns/mnt)" ]]; then
    FPM["?"]+="pid $pid (in a container - not checked); "; continue
  fi
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null); exe=${exe% (deleted)}
  add_bin "$exe"; v=${BINV:-?}
  FPM[$v]+="pid $pid (not a systemd service, $exe$(stale "$pid")); "
  scan_conf "$(tr '\0' ' ' <"/proc/$pid/cmdline" | grep -oP '\(\K[^)]+')" "$v" "$exe"
done

# ---- 3. Any remaining FPM pool files in the usual places (version guessed from the path)
for f in /etc/php/*/fpm/pool.d/*.conf /etc/php-fpm.d/*.conf /etc/opt/remi/php*/php-fpm.d/*.conf \
         /opt/cpanel/ea-php*/root/etc/php-fpm.d/*.conf /opt/alt/php*/etc/php-fpm.d/*.conf \
         /opt/plesk/php/*/etc/php-fpm.d/*.conf /usr/local/etc/php-fpm.d/*.conf /opt/php*/etc/php-fpm.d/*.conf; do
  v=$(canon "$(norm "$f")"); v=${v:-$DEF}
  scan_pool "$f" "${v:-?}"
done

resolve() { # fastcgi target (socket path, host:port, port) -> version
  local t=${1#unix:} v
  t=${t/#\/var\/run\//\/run\/}
  v=${LISTEN[$t]:-}
  [[ -z $v && $t =~ (^|:)([0-9]+)$ ]] && v=${LISTEN[port:${BASH_REMATCH[2]}]:-}
  [[ -z $v ]] && v=$(norm "$t")
  echo "${v:-?}"
}
record() { # version, description
  local v; v=$(canon "${1:-}"); v=${v:-?}; shift
  if [[ $v == "?" ]]; then UNRESOLVED+="  $*"$'\n'; else USES[$v]+="  $*"$'\n'; fi
}
# directive values, at line start or after { / ; so one-line blocks count but # comments don't
names_in() { grep -oiP "(^|[;{])\s*($1)\s+\K[^;#}]+" "$2" | tr -s ' \n' ' ' | sed 's/ $//'; }

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
    done < <(grep -oP '(^|[;{])\s*fastcgi_pass\s+\K[^;]+' "$f" | sort -u)
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
label() { # how to print a version key
  local v=$1 k m=()
  [[ -n ${BINS[$v]:-} ]] && { echo "$v"; return; }
  for k in "${!BINS[@]}"; do [[ $k == "$v".* ]] && m+=("$k"); done
  if [[ ${#m[@]} -gt 1 ]]; then echo "$v (ambiguous - could be ${m[*]})"; else echo "$v (no binary found)"; fi
}
mapfile -t ALL < <(printf '%s\n' "${!BINS[@]}" "${!FPM[@]}" "${!POOLS[@]}" "${!USES[@]}" | grep -v '^?*$' | sort -uV)

echo "PHP audit: $(hostname) - $(date '+%F %T')"
echo "Web servers found: ${WEB:-none}"
echo "Default CLI php:   ${DEF:-none}$(p=$(command -v php) && echo " ($(readlink -f "$p"))")"

hr "Installed PHP versions"
for v in "${ALL[@]}"; do
  refs=$(printf '%s' "${USES[$v]:-}" | grep -c .)
  printf 'PHP %s - %s config reference(s)\n' "$(label "$v")" "$refs"
  printf '    fpm:      %s\n' "${FPM[$v]:-none}"
  [[ -n ${POOLS[$v]:-} ]] && printf '    pools:    %s\n' "${POOLS[$v]}"
  [[ -n ${BINS[$v]:-}  ]] && printf '    binaries: %s\n' "${BINS[$v]}"
done
[[ -n ${FPM["?"]:-} ]] && printf 'Other FPM: %s\n' "${FPM["?"]}"

hr "Usage by version"
USED=() UNUSED=()
for v in "${ALL[@]}"; do
  if [[ -n ${USES[$v]:-} ]]; then
    USED+=("$(label "$v")"); echo "PHP $(label "$v"):"; printf '%s' "${USES[$v]}"
    [[ -z ${BINS[$v]:-} ]] && echo "  !! no PHP binary matching $v was found"
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
