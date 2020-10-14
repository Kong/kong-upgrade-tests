#!/usr/bin/env bash

cat << EOF
version: '3.5'
services:
  kong-migrations:
    image: ${GOJIRA_IMAGE}
    depends_on:
      - db
    volumes:
      - ${DOCKER_CTX}/42-kong-envs.sh:/etc/profile.d/42-kong-envs.sh
    environment:
      - KONG_PASSWORD=${KONG_PASSWORD:-handyshake}
      - KONG_DATABASE=${GOJIRA_DATABASE:-${KONG_DATABASE:-postgres}}
      - KONG_PG_DATABASE=${KONG_PG_DATABASE:-kong}
      - KONG_PG_HOST=${KONG_PG_HOST:-db}
      - KONG_PG_USER=${KONG_PG_USER:-kong}
      - KONG_CASSANDRA_CONTACT_POINTS=${KONG_CASSANDRA_CONTACT_POINTS:-db}
      - KONG_LICENSE_DATA=${KONG_LICENSE_DATA}
    command: kong migrations bootstrap
    restart: on-failure
    networks:
      - gojira
    labels:
      com.konghq.gojira: True

  ${GOJIRA_TARGET:-kong}:
    command: kong start
    restart: always
    healthcheck:
      test: ["CMD-SHELL", "kong health"]
      interval: 5s
      retries: 10
    volumes:
      - ${DOCKER_CTX}/42-kong-envs.sh:/etc/profile.d/42-kong-envs.sh
    environment:
      - KONG_PROXY_ACCESS_LOG=/dev/stdout
      - KONG_ADMIN_ACCESS_LOG=/dev/stdout
      - KONG_PROXY_ERROR_LOG=/dev/stderr
      - KONG_ADMIN_ERROR_LOG=/dev/stderr
      - KONG_ANONYMOUS_REPORTS=${KONG_ANONYMOUS_REPORTS:-off}
      - KONG_PROXY_LISTEN=0.0.0.0:8000, 0.0.0.0:8443 ssl
      - KONG_ADMIN_LISTEN=0.0.0.0:8001, 0.0.0.0:8444 ssl
      - KONG_ADMIN_GUI_LISTEN=0.0.0.0:8002, 0.0.0.0:8445 ssl
      - KONG_PORTAL_GUI_LISTEN=0.0.0.0:8003, 0.0.0.0:8446 ssl
      - KONG_PORTAL_API_LISTEN=0.0.0.0:8004, 0.0.0.0:8447 ssl
      - KONG_ADMIN_GUI_AUTH=${KONG_ADMIN_GUI_AUTH:-basic-auth}
      - KONG_ADMIN_GUI_AUTH_CONF=${KONG_ADMIN_GUI_AUTH_CONF_POSTGRES:-"{\}"}
      - KONG_ADMIN_GUI_AUTH_PASSWORD_COMPLEXITY=${KONG_ADMIN_GUI_AUTH_PASSWORD_COMPLEXITY}
      - KONG_ADMIN_GUI_URL=http://localhost:8002
      - KONG_ADMIN_GUI_SESSION_CONF={"secret":"Y29vbGJlYW5z","storage":"kong","cookie_secure":false}
      - KONG_ENFORCE_RBAC=on
      - KONG_PLUGINS=bundled
      - KONG_VITALS=on
      - KONG_PORTAL=on
      - KONG_PORTAL_AUTH=basic-auth
      - KONG_PORTAL_AUTH_CONF={}
      - KONG_PORTAL_AUTH_PASSWORD_COMPLEXITY=
      - KONG_PORTAL_AUTO_APPROVE=off
      - KONG_PORTAL_EMAIL_VERIFICATION=off
      - KONG_PORTAL_EMAILS_FROM=noreply@konghq.com
      - KONG_PORTAL_EMAILS_REPLY_TO=noreply@konghq.com
      - KONG_PORTAL_GUI_PROTOCOL=http
      - KONG_PORTAL_GUI_HOST=localhost:8003
      - KONG_PORTAL_SESSION_CONF={"cookie_name":"portal_session","secret":"super-secret","cookie_secure":false,"storage":"kong"}
      - KONG_PORTAL_IS_LEGACY=off
      - KONG_SMTP_MOCK=off
      - KONG_SMTP_HOST=smtp.gmail.com
      - KONG_SMTP_PORT=587
      - KONG_SMTP_AUTH_TYPE=plain
      - KONG_SMTP_STARTTLS=on
      - KONG_SMTP_USERNAME=kongemailtest@gmail.com
      - KONG_SMTP_PASSWORD=jNzjktjjzhzwYiQdpd2jymXV
      - KONG_SMTP_ADMIN_EMAILS=noreply@konghq.com
      - KONG_ADMIN_GUI_FLAGS={"IMMUNITY_ENABLED":true}
      - KONG_PASSWORD=${KONG_PASSWORD:-handyshake}
    ports:
      - "8000:8000"
      - "8001:8001"
      - "8002:8002"
      - "8003:8003"
      - "8004:8004"
      - "8443:8443"
      - "8444:8444"
      - "8445:8445"
      - "8446:8446"
      - "8447:8447"
EOF
