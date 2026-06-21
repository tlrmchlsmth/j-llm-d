package main

import (
	"fmt"
	"math"
	"os"
	"os/exec"
	"sync"
	"time"
)

type CalibrationResult struct {
	PeakKV      float64
	MaxC        int
	SampleCount int
}

func calibrate(params SweepParams, env EnvConfig) (*CalibrationResult, error) {
	loadConfig := fmt.Sprintf(
		`{"load":{"concurrency":%d,"duration":"%ds","rampup":"30s"},"warmup":{"duration":"60s","stagger":true},"workload":{"type":"corpus","corpus_path":"%s/corpus/sharegpt.txt","isl":%d,"osl":%d,"turns":1}}`,
		params.CalibConcurrency,
		int(params.CalibDuration.Seconds()),
		env.LustreData,
		params.ISL, params.OSL,
	)

	cmd := exec.Command(env.NyannBenchPath, "generate",
		"--target", env.EvalBaseURL,
		"--config", loadConfig,
		"--workers", "auto",
		"--kube",
		"--kube.name", env.NamePrefix+"-sharegpt-load",
		"--kube.volume", "lustre",
		"--kube.image", env.NyannImageTag,
		"--kube.namespace", env.Namespace,
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("starting calibration load: %w", err)
	}
	fmt.Printf("Calibration load started (concurrency=%d, duration=%s)\n",
		params.CalibConcurrency, params.CalibDuration)

	var (
		mu      sync.Mutex
		peakKV  float64
		samples int
	)

	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(params.KVInterval)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				kv, err := queryKV(env.Namespace, env.DeployName)
				if err != nil {
					continue
				}
				mu.Lock()
				samples++
				if kv > peakKV {
					peakKV = kv
				}
				mu.Unlock()
			}
		}
	}()

	time.Sleep(params.CalibDuration)
	close(done)

	_ = cmd.Process.Kill()
	_ = cmd.Wait()

	mu.Lock()
	finalPeak := peakKV
	finalSamples := samples
	mu.Unlock()

	if finalSamples == 0 {
		return nil, fmt.Errorf("calibration collected 0 KV samples")
	}

	if finalPeak <= 0 {
		return nil, fmt.Errorf("peak KV is 0 — no load reached decode pods")
	}

	maxC := int(math.Floor(float64(params.CalibConcurrency) * 0.90 / finalPeak))

	result := &CalibrationResult{
		PeakKV:      finalPeak,
		MaxC:        maxC,
		SampleCount: finalSamples,
	}

	fmt.Printf("\n=== Calibration ===\n")
	fmt.Printf("ISL=%d OSL=%d concurrency=%d (%d samples)\n",
		params.ISL, params.OSL, params.CalibConcurrency, finalSamples)
	fmt.Printf("Peak KV utilization: %.1f%%\n", finalPeak*100)
	fmt.Printf("Estimated max concurrency at 90%% KV: %d\n", maxC)

	return result, nil
}
