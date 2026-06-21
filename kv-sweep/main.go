package main

import (
	"encoding/csv"
	"flag"
	"fmt"
	"log"
	"os"
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
	NyannBenchPath string
	ManifestsDir   string
	EvalBaseURL    string
	LustreData     string
	NyannImageTag  string
	VLLMImage      string
	Namespace      string
	NamePrefix     string
	DeployName     string
}

type SweepResult struct {
	Config          PDConfig
	TotalGPUs       int
	CalibResult     *CalibrationResult
	CalibStart      time.Time
	CalibEnd        time.Time
	StairsStart     time.Time
	StairsEnd       time.Time
	StairsCompleted bool
	Error           string
	Timestamp       time.Time
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

func readManifest(dir, name string) (string, error) {
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return "", fmt.Errorf("reading manifest %s: %w", name, err)
	}
	return string(data), nil
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
			"calib_start", "calib_end",
			"stairs_start", "stairs_end",
			"stairs_completed", "error",
		})
	}

	peakKV := ""
	maxC := ""
	if r.CalibResult != nil {
		peakKV = fmt.Sprintf("%.2f", r.CalibResult.PeakKV*100)
		maxC = strconv.Itoa(r.CalibResult.MaxC)
	}

	fmtTime := func(t time.Time) string {
		if t.IsZero() {
			return ""
		}
		return t.Format(time.RFC3339)
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
		fmtTime(r.CalibStart),
		fmtTime(r.CalibEnd),
		fmtTime(r.StairsStart),
		fmtTime(r.StairsEnd),
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
				if err := teardown(env); err != nil {
					fmt.Printf("Warning: teardown error: %v\n", err)
				}
			}()

			if err := deploy(cfg, env); err != nil {
				result.Error = fmt.Sprintf("deploy: %v", err)
				fmt.Printf("ERROR: %s\n", result.Error)
				return
			}

			if err := waitReady(env); err != nil {
				result.Error = fmt.Sprintf("wait ready: %v", err)
				fmt.Printf("ERROR: %s\n", result.Error)
				return
			}

			result.CalibStart = time.Now()
			calibResult, err := calibrate(params, env)
			result.CalibEnd = time.Now()
			if err != nil {
				result.Error = fmt.Sprintf("calibrate: %v", err)
				fmt.Printf("ERROR: %s\n", result.Error)
				return
			}
			result.CalibResult = calibResult

			fmt.Println("\nStopping calibration load...")
			if err := stopNyann(env); err != nil {
				fmt.Printf("Warning: stop-nyann error: %v\n", err)
			}
			fmt.Println("Waiting 30s for requests to drain...")
			time.Sleep(30 * time.Second)

			result.StairsStart = time.Now()
			if err := runStairs(calibResult.MaxC, params, env); err != nil {
				result.StairsEnd = time.Now()
				result.Error = fmt.Sprintf("stairs: %v", err)
				fmt.Printf("ERROR: %s\n", result.Error)
				return
			}
			result.StairsEnd = time.Now()
			result.StairsCompleted = true

			fmt.Println("\nStopping stairs...")
			if err := stopNyann(env); err != nil {
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
		calibDuration    = flag.Duration("calibration-duration", 180*time.Second, "Duration of calibration phase")
		kvInterval       = flag.Duration("kv-interval", 500*time.Millisecond, "KV sampling interval")
		configsStr       = flag.String("configs", "", "P/D configs: pr,ps,dr,ds separated by ;")
		output           = flag.String("output", "kv-sweep-results.csv", "Output CSV file")
		namespace        = flag.String("namespace", "vllm", "Kubernetes namespace")
		nyannBench       = flag.String("nyann-bench", "./nyann-bench", "Path to nyann-bench binary")
		manifestsDir     = flag.String("manifests", "./manifests", "Path to manifests directory")
		deployName       = flag.String("deploy-name", "", "Deploy name (default: $USER-wide-ep)")
		namePrefix       = flag.String("name-prefix", "", "Name prefix (default: $USER)")
		vllmImage        = flag.String("vllm-image", "", "vLLM container image")
		evalBaseURL      = flag.String("eval-base-url", "", "Gateway endpoint URL (default: from EVAL_BASE_URL env)")
		lustreData       = flag.String("lustre-data", "", "Lustre data path (default: from LUSTRE_DATA env)")
		nyannImageTag    = flag.String("nyann-image-tag", "", "nyann-bench worker image (default: from NYANN_IMAGE_TAG env)")
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

	// Resolve defaults from env
	resolve := func(flagVal, envKey string) string {
		if flagVal != "" {
			return flagVal
		}
		return os.Getenv(envKey)
	}

	prefix := resolve(*namePrefix, "USER")
	if prefix == "" {
		log.Fatal("--name-prefix or USER env var required")
	}
	dName := *deployName
	if dName == "" {
		dName = prefix + "-wide-ep"
	}

	ebURL := resolve(*evalBaseURL, "EVAL_BASE_URL")
	if ebURL == "" {
		log.Fatal("--eval-base-url or EVAL_BASE_URL env var required")
	}
	ld := resolve(*lustreData, "LUSTRE_DATA")
	if ld == "" {
		log.Fatal("--lustre-data or LUSTRE_DATA env var required")
	}
	nit := resolve(*nyannImageTag, "NYANN_IMAGE_TAG")
	if nit == "" {
		log.Fatal("--nyann-image-tag or NYANN_IMAGE_TAG env var required")
	}
	vi := resolve(*vllmImage, "VLLM_IMAGE")

	env := EnvConfig{
		NyannBenchPath: *nyannBench,
		ManifestsDir:   *manifestsDir,
		EvalBaseURL:    ebURL,
		LustreData:     ld,
		NyannImageTag:  nit,
		VLLMImage:      vi,
		Namespace:      *namespace,
		NamePrefix:     prefix,
		DeployName:     dName,
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
	fmt.Printf("  Deploy: %s (prefix=%s)\n", env.DeployName, env.NamePrefix)
	fmt.Printf("  vLLM image: %s\n", env.VLLMImage)
	fmt.Printf("  Manifests: %s\n", env.ManifestsDir)
	fmt.Printf("  nyann-bench: %s\n", env.NyannBenchPath)
	fmt.Printf("  Configs: %d\n", len(params.Configs))
	for _, c := range params.Configs {
		fmt.Printf("    %s (%d GPUs)\n", c.Label(), c.TotalGPUs())
	}

	runSweep(params, env)
}
