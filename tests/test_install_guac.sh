#!/usr/bin/env bash
set -Eeuo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install_guac.sh"
bash -n "$script"
grep -Fq 'GUACVERSION="1.6.0"' "$script"
grep -Fq 'TOMCAT_VER=9.0.124' "$script"
grep -Fq 'guacd_is_current' "$script"
grep -Fq 'version ${GUACVERSION}' "$script"
grep -Fq 'fresh_install_guard' "$script"
grep -Fq 'Fresh-install only' "$script"
grep -Fq 'ln -sfn "apache-tomcat-${TOMCAT_VER}" /opt/tomcat9' "$script"
if grep -Fq 'GUACVERSION="1.5.5"' "$script" || grep -Fq 'TOMCAT_VER=9.0.109' "$script"; then
  printf 'stale Guacamole/Tomcat version remains\n' >&2
  exit 1
fi
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

GUAC_STATE_ROOT="$tmp_root" GUAC_TEST_ONLY=1 bash "$script"
mkdir -p "$tmp_root/etc/guacamole"
if GUAC_STATE_ROOT="$tmp_root" GUAC_TEST_ONLY=1 bash "$script" 2>"$tmp_root/existing.log"; then
  printf 'existing Guacamole state was not rejected\n' >&2
  exit 1
fi
grep -Fq 'Fresh-install only' "$tmp_root/existing.log"
rm -rf "$tmp_root/etc/guacamole"
mkdir -p "$tmp_root/bin"
cat > "$tmp_root/bin/guacd" <<'EOF'
#!/bin/sh
echo 'guacd version 1.5.5'
EOF
chmod +x "$tmp_root/bin/guacd"
if PATH="$tmp_root/bin:$PATH" GUAC_STATE_ROOT="$tmp_root" GUAC_TEST_ONLY=1 bash "$script" 2>"$tmp_root/old.log"; then
  printf 'old guacd was not rejected\n' >&2
  exit 1
fi
grep -Fq 'guacd (guacd version 1.5.5)' "$tmp_root/old.log"
perl -0pi -e 's/1\.5\.5/1.6.0/' "$tmp_root/bin/guacd"
if PATH="$tmp_root/bin:$PATH" GUAC_STATE_ROOT="$tmp_root" GUAC_TEST_ONLY=1 bash "$script" 2>"$tmp_root/current.log"; then
  printf 'current guacd was not rejected\n' >&2
  exit 1
fi
grep -Fq 'guacd (guacd version 1.6.0)' "$tmp_root/current.log"
printf 'Guacamole/Tomcat version and upgrade-guard checks passed\n'
