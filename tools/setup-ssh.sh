#!/usr/bin/env bash
# 写入 ~/.ssh/config 里的 venus 条目（ssh-agent 会让 dropbear/openssh 认证卡住，故 IdentityAgent none）
set -euo pipefail
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cfg=~/.ssh/config
touch "$cfg"
python3 - "$cfg" <<'PY'
import sys, re
p = sys.argv[1]
block = """Host venus
    HostName <LAN_PHONE_IP>
    User root
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    IdentityAgent none
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ConnectTimeout 10
"""
s = open(p).read()
s = re.sub(r'(?ms)^Host venus\n(?:[ \t]+.*\n)*', '', s)
open(p, 'w').write(s.rstrip('\n') + ('\n\n' if s.strip() else '') + block)
PY
chmod 600 "$cfg"
echo "已写入 $cfg"
