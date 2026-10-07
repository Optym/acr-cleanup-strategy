#!/usr/bin/env bash
#
# Stage 7 - opt-in email of the report through SendGrid.
#
#   reads   config email_report, <work-dir>/result.json, <work-dir>/report-summary.html,
#           the API key from the environment variable named by
#           email_report.api_key_variable
#   writes  nothing
#   mutates nothing in Azure
#
# Failures here only warn: a lost email must never fail a run whose report is
# already published as a pipeline artifact.

# shellcheck shell=bash

SENDGRID_URL="${SENDGRID_URL:-https://api.sendgrid.com/v3/mail/send}"

# notify_sendgrid_run <work-dir>
notify_sendgrid_run() {
  local work_dir="$1"

  if [[ "$(config_get '.email_report.enabled')" != "true" ]]; then
    log "notify: email_report.enabled is false, skipping"
    return 0
  fi

  local result_file="${work_dir}/result.json" html_file="${work_dir}/report-summary.html"
  [[ -f "$result_file" && -f "$html_file" ]] || { warn "notify: report not found, nothing to send"; return 1; }

  local key_var api_key
  key_var="$(config_get '.email_report.api_key_variable')"
  api_key="${!key_var:-}"
  [[ -n "$api_key" ]] || { warn "notify: environment variable ${key_var} is empty; email not sent"; return 1; }

  local subject
  subject="$(jq -r '
    "[ACR cleanup] \(.run.registry) \(.run.operation)"
    + (if .run.dry_run then " (dry run)" else "" end)
    + ": \(.deleted.count) deleted, \(.candidates.untag) untag / \(.candidates.manifests) sweep candidate(s)"
    + (if .run.status != "ok" then " - FAILED" else "" end)
  ' "$result_file")"

  local payload_file
  payload_file="$(mktemp)"

  # The HTML is the body; result.json rides along as an attachment so the
  # recovery catalogue is in the recipient's mailbox too.
  jq -n \
    --arg from "$(config_get '.email_report.from')" \
    --argjson to "$(config_get_json '.email_report.to')" \
    --arg subject "$subject" \
    --rawfile html "$html_file" \
    --argjson attach "$(config_get '.email_report.attach_json')" \
    --arg json_b64 "$(if [[ "$(config_get '.email_report.attach_json')" == "true" ]]; then base64 < "$result_file" | tr -d '\n'; fi)" \
    --arg filename "acr-cleanup-$(jq -r '.run.registry' "$result_file")-$(jq -r '.run.operation' "$result_file")-$(date -u +%Y%m%d).json" \
    '{
       personalizations: [ { to: [ $to[] | { email: . } ] } ],
       from: { email: $from },
       subject: $subject,
       content: [ { type: "text/html", value: $html } ]
     }
     + (if $attach then
          { attachments: [ { content: $json_b64, type: "application/json", filename: $filename, disposition: "attachment" } ] }
        else {} end)' > "$payload_file"

  local status
  status="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "$SENDGRID_URL" \
    -H "Authorization: Bearer ${api_key}" \
    -H "Content-Type: application/json" \
    --data-binary "@${payload_file}" \
    --connect-timeout 15 --max-time 60 2>/dev/null || printf '000')"
  rm -f "$payload_file"

  if [[ "$status" =~ ^2 ]]; then
    log "notify: email sent to $(config_get '.email_report.to | join(", ")') (HTTP ${status})"
    return 0
  fi
  warn "notify: SendGrid returned HTTP ${status}; email not sent. The report is still published as an artifact"
  return 1
}
