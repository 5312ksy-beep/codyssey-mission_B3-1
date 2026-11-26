#!/bin/bash
set -euo pipefail
exec > >(tee -a /var/log/codyssey-b3-1.log) 2>&1

retry() {
    for attempt in {1..12}; do
        if "$@"; then
            return 0
        fi
        echo "Attempt ${attempt}/12 failed: $*"
        sleep 10
    done
    return 1
}

install -d -m 0755 /opt/codyssey-b3-1
printf '%s' '__INDEX_BASE64__' | base64 -d > /opt/codyssey-b3-1/index.html
printf '%s' '__NGINX_BASE64__' | base64 -d > /opt/codyssey-b3-1/default.conf
chmod 0644 /opt/codyssey-b3-1/{index.html,default.conf}

# CloudFormation associates the Elastic IP just after launching the instance.
retry timeout 45 dnf -y --setopt=timeout=12 --setopt=retries=1 install docker
systemctl enable --now docker

image=docker.io/library/nginx:stable-alpine
retry timeout 90 docker pull "$image"
docker run -d --name codyssey-b3-1 \
    --restart unless-stopped \
    --publish 80:80 \
    --log-opt max-size=5m --log-opt max-file=2 \
    --mount type=bind,src=/opt/codyssey-b3-1/index.html,dst=/usr/share/nginx/html/index.html,readonly \
    --mount type=bind,src=/opt/codyssey-b3-1/default.conf,dst=/etc/nginx/conf.d/default.conf,readonly \
    --health-cmd 'test "$(wget -qO- http://127.0.0.1/health)" = OK' \
    --health-interval 15s --health-timeout 3s --health-retries 3 \
    "$image"
retry curl --fail --silent --show-error --max-time 5 http://localhost/health
