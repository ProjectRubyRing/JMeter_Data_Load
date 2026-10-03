#!/bin/bash
# RHEL 9.8 コンテナ内で dbtool を実行するための準備 (tests/docker から呼び出す)
#   /src  : リポジトリ (読取り専用でマウント)
#   /opt  : tmpfs (dbtool をコピーして実行。ホストのディスクを使わない)
set -euo pipefail
rm -rf /opt/dbtool
cp -r /src/dbtool /opt/dbtool
find /opt/dbtool -type d -exec chmod 755 {} +
find /opt/dbtool -type f -exec chmod 644 {} +
chmod 755 /opt/dbtool/dbtool.sh
install -m 600 /src/tests/docker/client.cnf /opt/dbtool/conf/client.cnf
cd /opt/dbtool
if [[ $# -gt 0 ]]; then exec bash "$@"; fi
