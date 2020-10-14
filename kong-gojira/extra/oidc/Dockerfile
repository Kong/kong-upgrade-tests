FROM qlik/simple-oidc-provider

# Install extra for performing health checks
USER root
RUN apk add httpie

# Ensure the OIDC provider has the configuration file available
USER node
COPY ./.oidc-config.json /usr/src/app/oidc-config.json
ENV CONFIG_FILE=/usr/src/app/oidc-config.json

HEALTHCHECK --interval=30s --timeout=30s --retries=3 \
                CMD http --body :9000/health || exit 1