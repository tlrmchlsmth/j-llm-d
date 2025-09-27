#!/usr/bin/env bash

while true; do
  backoff=1
  echo "Starting port-forward..."
  if kubectl port-forward -n llm-d-monitoring svc/prometheus-llm-d-monitoring-grafana 3000:80; then
    echo "Port-forward exited normally. Restarting..."
    backoff=1
  else
    echo "Port-forward failed. Retrying in $backoff seconds..."
    sleep $backoff
    backoff=$(( backoff * 2 ))
    [ $backoff -gt 300 ] && backoff=300
  fi
done

