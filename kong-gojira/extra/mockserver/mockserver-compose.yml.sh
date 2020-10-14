#!/usr/bin/env bash

cat << EOF
version: '3.5'
services:
  mockserver:
    image: mockserver/mockserver
    labels:
      com.konghq.gojira: "True"
    networks:
      - gojira
    ports:
      - 1080:1080
    healthcheck:
      test: ["CMD", "curl", "-Ss", "mockserver:1080", "ping"]
      interval: 5s
      timeout: 10s
      retries: 5
    restart: on-failure
    volumes:
      - ${GOJIRA_HOME}/:/root/
EOF