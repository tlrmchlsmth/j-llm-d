package main

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

type promResponse struct {
	Data struct {
		Result []struct {
			Value []json.RawMessage `json:"value"`
		} `json:"result"`
	} `json:"data"`
}

func findPokerPod(namespace string) (string, error) {
	out, err := exec.Command("kubectl", "-n", namespace, "get", "pod", "-l", "app=poker", "-o", "jsonpath={.items[0].metadata.name}").Output()
	if err != nil {
		return "", fmt.Errorf("finding poker pod: %w", err)
	}
	name := strings.TrimSpace(string(out))
	if name == "" {
		return "", fmt.Errorf("no poker pod found in namespace %s", namespace)
	}
	return name, nil
}

func queryKV(namespace, pokerPod, deployName string) (float64, error) {
	promURL := fmt.Sprintf("http://prometheus-server.%s.svc.cluster.local:80/api/v1/query", namespace)
	query := fmt.Sprintf("max(vllm:kv_cache_usage_perc{pod=~\"%s-decode.*\"})", deployName)

	out, err := exec.Command(
		"kubectl", "-n", namespace, "exec", pokerPod, "--",
		"curl", "-s", "--max-time", "5", promURL,
		"--data-urlencode", fmt.Sprintf("query=%s", query),
	).Output()
	if err != nil {
		return 0, fmt.Errorf("prometheus query: %w", err)
	}

	var resp promResponse
	if err := json.Unmarshal(out, &resp); err != nil {
		return 0, fmt.Errorf("parsing prometheus response: %w", err)
	}

	if len(resp.Data.Result) == 0 || len(resp.Data.Result[0].Value) < 2 {
		return 0, fmt.Errorf("no KV data in prometheus response")
	}

	var valStr string
	if err := json.Unmarshal(resp.Data.Result[0].Value[1], &valStr); err != nil {
		return 0, fmt.Errorf("parsing KV value: %w", err)
	}

	val, err := strconv.ParseFloat(valStr, 64)
	if err != nil {
		return 0, fmt.Errorf("parsing KV float: %w", err)
	}
	return val, nil
}
