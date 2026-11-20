# Bundle de deploy de dev: el compose, la config y el script del mismo commit que
# el workflow. Contexto de build: notifai/deploy/dev-ec2/. El documento de SSM
# copia /bundle a /opt/notifai/litellm/releases/<sha>/.
FROM scratch
COPY docker-compose.yml /bundle/docker-compose.yml
COPY litellm-config.yaml /bundle/litellm-config.yaml
COPY upstream-image.env /bundle/upstream-image.env
COPY deploy.sh /bundle/deploy.sh
