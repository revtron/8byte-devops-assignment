# promtail 3.1 configuration TEMPLATE, used on BOTH the backend and mon hosts.
# scripts/install-promtail.sh renders it with
#   envsubst '${MON_PRIVATE_IP} ${HOSTNAME_LABEL}' < promtail-config.yml.tpl > /etc/promtail/config.yml
# where MON_PRIVATE_IP comes from /etc/8byte/env and HOSTNAME_LABEL = $ROLE
# (backend | mon). promtail runs as root (systemd) because it needs
# /var/run/docker.sock and /var/log/*.

server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://${MON_PRIVATE_IP}:3100/loki/api/v1/push
    backoff_config:
      min_period: 500ms
      max_period: 5m
      max_retries: 10

scrape_configs:
  # (a) Every Docker container on this host, discovered via the Docker socket.
  # Labels kept deliberately small: job, host, container, env (+ level from
  # the JSON log line). Nothing per-request becomes a label.
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
    relabel_configs:
      - source_labels: ["__meta_docker_container_name"]
        regex: "/(.*)"
        target_label: container
      - source_labels: ["__meta_docker_container_label_env"]
        target_label: env
      - target_label: job
        replacement: docker
      - target_label: host
        replacement: ${HOSTNAME_LABEL}
    pipeline_stages:
      # Only the app containers log pino JSON ({"level":30,"time":...,"env":"prod",
      # "req":{...},...}); the monitoring containers log logfmt and are shipped
      # unchanged. pino levels are numeric, so map them to names for the label.
      - match:
          selector: '{container=~"todo-.*"}'
          stages:
            - json:
                expressions:
                  level: level
            - template:
                source: level
                template: '{{ if eq .Value "10" }}trace{{ else if eq .Value "20" }}debug{{ else if eq .Value "30" }}info{{ else if eq .Value "40" }}warn{{ else if eq .Value "50" }}error{{ else if eq .Value "60" }}fatal{{ else }}{{ .Value }}{{ end }}'
            - labels:
                level:

  # (b) Host system logs.
  - job_name: system
    static_configs:
      - targets: ["localhost"]
        labels:
          job: system
          host: ${HOSTNAME_LABEL}
          __path__: /var/log/messages
      - targets: ["localhost"]
        labels:
          job: system
          host: ${HOSTNAME_LABEL}
          __path__: /var/log/secure
      - targets: ["localhost"]
        labels:
          job: system
          host: ${HOSTNAME_LABEL}
          __path__: /var/log/cloud-init-output.log
      - targets: ["localhost"]
        labels:
          job: system
          host: ${HOSTNAME_LABEL}
          __path__: /var/log/8byte-bootstrap.log
