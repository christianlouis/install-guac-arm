#!/usr/bin/env bash
set -Eeuo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install_guac.sh"
bash -n "$script"
grep -Fq 'GUACVERSION="1.6.0"' "$script"
grep -Fq 'TOMCAT_VER=9.0.124' "$script"
grep -Fq 'guacd_is_current' "$script"
grep -Fq 'version ${GUACVERSION}' "$script"
grep -Fq 'ln -sfn "apache-tomcat-${TOMCAT_VER}" /opt/tomcat9' "$script"
if grep -Fq 'GUACVERSION="1.5.5"' "$script" || grep -Fq 'TOMCAT_VER=9.0.109' "$script"; then
  printf 'stale Guacamole/Tomcat version remains\n' >&2
  exit 1
fi
printf 'Guacamole/Tomcat version and upgrade-guard checks passed\n'
