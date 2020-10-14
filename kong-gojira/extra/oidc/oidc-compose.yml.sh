#!/usr/bin/env bash

cat << EOF
version: '3.5'
services:
  oidc:
    depends_on:
      - ${GOJIRA_TARGET}
    environment:
      - REDIRECTS=${OIDC_REDIRECT_URI}
      - PORT=${OIDC_PORT}
      - IDP_NAME=${OIDC_IDP_NAME}
    image: gojira-oidc
    labels:
      com.konghq.gojira: "True"
    networks:
      - gojira
    ports:
      - ${OIDC_PORT}:${OIDC_PORT}
    restart: on-failure
    volumes:
      - ${GOJIRA_HOME}/:/root/
EOF