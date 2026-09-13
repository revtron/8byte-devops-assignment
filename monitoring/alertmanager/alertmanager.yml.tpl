# Alertmanager configuration TEMPLATE. scripts/bootstrap/mon.sh renders it with
#   envsubst '${SNS_TOPIC_ARN} ${AWS_REGION}' < alertmanager.yml.tpl > alertmanager.yml
# and docker-compose mounts the rendered alertmanager.yml (gitignored).
#
# Every alert goes to one SNS topic (email subscription managed by Terraform).
# No static AWS credentials: the mon instance role grants sns:Publish and the
# SDK credential chain picks it up from the instance metadata service.

global:
  resolve_timeout: 5m

route:
  receiver: sns-email
  group_by: ["alertname", "env", "host"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: sns-email
    sns_configs:
      - topic_arn: ${SNS_TOPIC_ARN}
        sigv4:
          region: ${AWS_REGION}
        send_resolved: true
        subject: '[8byte] {{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }} {{ .GroupLabels.alertname }}'
        message: |
          {{ range .Alerts -}}
          [{{ .Status | toUpper }}] {{ .Labels.alertname }} ({{ .Labels.severity }})
          {{ .Annotations.summary }}
          {{ .Annotations.description }}
          Labels: {{ range .Labels.SortedPairs }}{{ .Name }}={{ .Value }} {{ end }}
          Started: {{ .StartsAt.Format "2006-01-02 15:04:05 UTC" }}

          {{ end }}

inhibit_rules:
  # When a scrape target is down, suppress derived alerts for the same instance.
  - source_matchers: ["alertname = InstanceDown"]
    target_matchers: ["alertname =~ HighErrorRate|HighLatency|HighMemory|HighCpu|DiskAlmostFull"]
    equal: ["instance"]
