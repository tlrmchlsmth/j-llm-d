package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

type promResponse struct {
	Data struct {
		Result []struct {
			Value []json.RawMessage `json:"value"`
		} `json:"result"`
	} `json:"data"`
}

func queryKV(namespace, deployName string) (float64, error) {
	promURL := fmt.Sprintf("http://prometheus-server.%s.svc.cluster.local:80/api/v1/query", namespace)
	query := fmt.Sprintf("max(vllm:kv_cache_usage_perc{pod=~\"%s-decode.*\"})", deployName)

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(promURL + "?query=" + url.QueryEscape(query))
	if err != nil {
		return 0, fmt.Errorf("prometheus query: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, fmt.Errorf("reading prometheus response: %w", err)
	}

	var promResp promResponse
	if err := json.Unmarshal(body, &promResp); err != nil {
		return 0, fmt.Errorf("parsing prometheus response: %w", err)
	}

	if len(promResp.Data.Result) == 0 || len(promResp.Data.Result[0].Value) < 2 {
		return 0, fmt.Errorf("no KV data in prometheus response")
	}

	var valStr string
	if err := json.Unmarshal(promResp.Data.Result[0].Value[1], &valStr); err != nil {
		return 0, fmt.Errorf("parsing KV value: %w", err)
	}

	val, err := strconv.ParseFloat(valStr, 64)
	if err != nil {
		return 0, fmt.Errorf("parsing KV float: %w", err)
	}
	return val, nil
}
