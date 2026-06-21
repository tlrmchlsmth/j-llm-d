package main

import (
	"encoding/csv"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type PDConfig struct {
	PrefillReplicas int
	PrefillSize     int
	DecodeReplicas  int
	DecodeSize      int
}

func (c PDConfig) Label() string {
	return fmt.Sprintf("P%d/D%d",
		c.PrefillReplicas*c.PrefillSize, c.DecodeReplicas*c.DecodeSize)
}

func (c PDConfig) TotalGPUs() int {
	return (c.PrefillReplicas*c.PrefillSize + c.DecodeReplicas*c.DecodeSize) * 4
}

type SweepParams struct {
	ISL              int
	OSL              int
	CalibConcurrency int
	CalibDuration    time.Duration
	KVInterval       time.Duration
	Output           string
	Configs          []PDConfig
}

type EnvConfig struct {
	NyannBenchDir string
	EvalBaseURL   string
	LustreData    string
	NyannImageTag string
	VLLMImage     string
	Namespace     string
	NamePrefix    string
	DeployName    string
	PokerPod      string
	RepoDir       string
}

type SweepResult struct {
	Config          PDConfig
	TotalGPUs       int
	CalibResult     *CalibrationResult
	StairsCompleted bool
	Error           string
	Timestamp       time.Time
}

func findRepoRoot() (string, error) {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", fmt.Errorf("finding git repo root: %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}

func parseConfigs(s string) ([]PDConfig, error) {
	var configs []PDConfig
	for _, part := range strings.Split(s, ";") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		fields := strings.Split(part, ",")
		if len(fields) != 4 {
			return nil, fmt.Errorf("config %q: expected 4 comma-separated values (pr,ps,dr,ds)", part)
		}
		var vals [4]int
		for i, f := range fields {
			v, err := strconv.Atoi(strings.TrimSpace(f))
			if err != nil {
				return nil, fmt.Errorf("config %q field %d: %w", part, i, err)
			}
			vals[i] = v
		}
		configs = append(configs, PDConfig{
			PrefillReplicas: vals[0], PrefillSize: vals[1],
			DecodeReplicas: vals[2], DecodeSize: vals[3],
		})
	}
	if len(configs) == 0 {
		return nil, fmt.Errorf("no configs provided")
	}
	return configs, nil
}

func loadEnv(namespace string) (EnvConfig, error) {
	required := map[string]*string{
		"NYANN_BENCH_DIR": nil,
		"EVAL_BASE_URL":   nil,
		"LUSTRE_DATA":     nil,
		"NYANN_IMAGE_TAG": nil,
	}
	for k := range required {
		v := os.Getenv(k)
		if v == "" {
			return EnvConfig{}, fmt.Errorf("required env var %s is not set", k)
		}
		s := v
		required[k] = &s
	}

	user := os.Getenv("USER")
	if user == "" {
		return EnvConfig{}, fmt.Errorf("USER env var is not set")
	}

	namePrefix := user
	deployName := namePrefix + "-wide-ep"

	pokerPod, err := findPokerPod(namespace)
	if err != nil {
		return EnvConfig{}, err
	}
	fmt.Printf("Using poker pod: %s\n", pokerPod)

	repoDir, err := findRepoRoot()
	if err != nil {
		return EnvConfig{}, err
	}

	return EnvConfig{
		NyannBenchDir: *required["NYANN_BENCH_DIR"],
		EvalBaseURL:   *required["EVAL_BASE_URL"],
		LustreData:    *required["LUSTRE_DATA"],
		NyannImageTag: *required["NYANN_IMAGE_TAG"],
		VLLMImage:     os.Getenv("VLLM_IMAGE"),
		Namespace:     namespace,
		NamePrefix:    namePrefix,
		DeployName:    deployName,
		PokerPod:      pokerPod,
		RepoDir:       repoDir,
	}, nil
}

func appendResult(outputPath string, r SweepResult) error {
	writeHeader := false
	if _, err := os.Stat(outputPath); os.IsNotExist(err) {
		writeHeader = true
	}

	f, err := os.OpenFile(outputPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer f.Close()

	w := csv.NewWriter(f)
	defer w.Flush()

	if writeHeader {
		w.Write([]string{
			"timestamp", "config",
			"prefill_replicas", "prefill_size", "decode_replicas", "decode_size",
			"total_gpus", "peak_kv_pct", "est_max_c_90pct",
			"stairs_completed", "error",
		})
	}

	peakKV := ""
	maxC := ""
	if r.CalibResult != nil {
		peakKV = fmt.Sprintf("%.2f", r.CalibResult.PeakKV*100)
		maxC = strconv.Itoa(r.CalibResult.MaxC)
	}

	return w.Write([]string{
		r.Timestamp.Format(time.RFC3339),
		r.Config.Label(),
		strconv.Itoa(r.Config.PrefillReplicas),
		strconv.Itoa(r.Config.PrefillSize),
		strconv.Itoa(r.Config.DecodeReplicas),
		strconv.Itoa(r.Config.DecodeSize),
		strconv.Itoa(r.TotalGPUs),
		peakKV,
		maxC,
		strconv.FormatBool(r.StairsCompleted),
		r.Error,
	})
}

func runSweep(params SweepParams, env EnvConfig) {
	outputAbs, _ := filepath.Abs(params.Output)
	fmt.Printf("\nSweep: %d configs, results → %s\n\n", len(params.Configs), outputAbs)

	for i, cfg := range params.Configs {
		fmt.Printf("\n========================================\n")
		fmt.Printf("Config %d/%d: %s (%d GPUs)\n",
			i+1, len(params.Configs), cfg.Label(), cfg.TotalGPUs())
		fmt.Printf("========================================\n\n")

		result := SweepResult{
			Config:    cfg,
			TotalGPUs: cfg.TotalGPUs(),
			Timestamp: time.Now(),
		}

		func() {
			defer func() {
				fmt.Println("\nTearing down before next config...")
				if err := teardown(env.RepoDir); err != nil {
					fmt.Printf("Warning: teardown error: %v\n", err)
				}
			}()

			if err := deploy(cfg, env.RepoDir); err != nil {
				result.Error = fmt.Sprintf("deploy: %v", err)
				fmt.Printf("ERROR: %s\n", result.Error)
				return
			}

			if err := waitReady(env.RepoDir); err != nil {
				result.Error = fmt.Sprintf("wait ready: %v", err)
				fmt.Printf("ERROR: %s\n", result.Error)
				return
			}

			calibResult, err := calibrate(params, env)
			if err != nil {
				result.Error = fmt.Sprintf("calibrate: %v", err)
				fmt.Printf("ERROR: %s\n", result.Error)
				return
			}
			result.CalibResult = calibResult

			fmt.Println("\nStopping calibration load...")
			if err := stopNyann(env.RepoDir); err != nil {
				fmt.Printf("Warning: stop-nyann error: %v\n", err)
			}
			fmt.Println("Waiting 30s for requests to drain...")
			time.Sleep(30 * time.Second)

			if err := runStairs(calibResult.MaxC, params, env); err != nil {
				result.Error = fmt.Sprintf("stairs: %v", err)
				fmt.Printf("ERROR: %s\n", result.Error)
				return
			}
			result.StairsCompleted = true

			fmt.Println("\nStopping stairs...")
			if err := stopNyann(env.RepoDir); err != nil {
				fmt.Printf("Warning: stop-nyann error: %v\n", err)
			}
		}()

		if err := appendResult(params.Output, result); err != nil {
			fmt.Printf("Warning: failed to write result: %v\n", err)
		}
	}

	fmt.Printf("\n========================================\n")
	fmt.Printf("Sweep complete. Results: %s\n", outputAbs)
	fmt.Printf("========================================\n")
}

func main() {
	var (
		isl              = flag.Int("isl", 0, "Input sequence length")
		osl              = flag.Int("osl", 0, "Output sequence length")
		calibConcurrency = flag.Int("calibration-concurrency", 0, "Concurrency for calibration load")
		calibDuration    = flag.Duration("calibration-duration", 60*time.Second, "Duration of calibration phase")
		kvInterval       = flag.Duration("kv-interval", 500*time.Millisecond, "KV sampling interval")
		configsStr       = flag.String("configs", "", "P/D configs: pr,ps,dr,ds separated by ;")
		output           = flag.String("output", "kv-sweep-results.csv", "Output CSV file")
		namespace        = flag.String("namespace", "vllm", "Kubernetes namespace")
	)
	flag.Parse()

	if *isl == 0 || *osl == 0 || *calibConcurrency == 0 || *configsStr == "" {
		fmt.Fprintln(os.Stderr, "Required flags: --isl, --osl, --calibration-concurrency, --configs")
		flag.Usage()
		os.Exit(1)
	}

	configs, err := parseConfigs(*configsStr)
	if err != nil {
		log.Fatalf("Parsing configs: %v", err)
	}

	env, err := loadEnv(*namespace)
	if err != nil {
		log.Fatalf("Environment: %v", err)
	}

	params := SweepParams{
		ISL:              *isl,
		OSL:              *osl,
		CalibConcurrency: *calibConcurrency,
		CalibDuration:    *calibDuration,
		KVInterval:       *kvInterval,
		Output:           *output,
		Configs:          configs,
	}

	fmt.Printf("KV Sweep\n")
	fmt.Printf("  ISL: %d  OSL: %d\n", params.ISL, params.OSL)
	fmt.Printf("  Calibration: concurrency=%d duration=%s interval=%s\n",
		params.CalibConcurrency, params.CalibDuration, params.KVInterval)
	fmt.Printf("  Configs: %d\n", len(params.Configs))
	for _, c := range params.Configs {
		fmt.Printf("    %s (%d GPUs)\n", c.Label(), c.TotalGPUs())
	}

	runSweep(params, env)
}
