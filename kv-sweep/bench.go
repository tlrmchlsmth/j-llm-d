package main

import (
	"fmt"
	"os"
	"os/exec"
)

func runStairs(maxC int, params SweepParams, env EnvConfig) error {
	sweepMin := maxC / 10
	sweepMax := maxC
	steps := 8
	stepDuration := "120s"
	evalDuration := fmt.Sprintf("%ds", steps*120)

	fmt.Printf("\n=== Starting stairs benchmark ===\n")
	fmt.Printf("Sweep: %d → %d concurrency, %d steps × %s\n",
		sweepMin, sweepMax, steps, stepDuration)

	loadConfig := fmt.Sprintf(
		`{"load":{"concurrency":128},"warmup":{"duration":"60s","stagger":true},"sweep":{"min":%d,"max":%d,"steps":%d,"step_duration":"%s"},"workload":{"type":"corpus","corpus_path":"%s/corpus/sharegpt.txt","isl":%d,"osl":%d,"turns":1}}`,
		sweepMin, sweepMax, steps, stepDuration,
		env.LustreData, params.ISL, params.OSL,
	)

	loadCmd := exec.Command(env.NyannBenchPath, "generate",
		"--target", env.EvalBaseURL,
		"--config", loadConfig,
		"--workers", "auto",
		"--kube",
		"--kube.name", env.NamePrefix+"-sharegpt-load",
		"--kube.volume", "lustre",
		"--kube.image", env.NyannImageTag,
		"--kube.namespace", env.Namespace,
	)
	loadCmd.Stdout = os.Stdout
	loadCmd.Stderr = os.Stderr

	evalConfig := fmt.Sprintf(
		`{"load":{"concurrency":16,"duration":"%s"},"workload":{"type":"gsm8k","gsm8k_path":"%s/gsm8k_test.jsonl","gsm8k_train_path":"%s/gsm8k_train.jsonl"}}`,
		evalDuration, env.LustreData, env.LustreData,
	)

	evalCmd := exec.Command(env.NyannBenchPath, "generate",
		"--target", env.EvalBaseURL,
		"--config", evalConfig,
		"--kube",
		"--kube.name", env.NamePrefix+"-nyann-eval",
		"--kube.volume", "lustre",
		"--kube.image", env.NyannImageTag,
		"--kube.namespace", env.Namespace,
	)
	evalCmd.Stdout = os.Stdout
	evalCmd.Stderr = os.Stderr

	if err := loadCmd.Start(); err != nil {
		return fmt.Errorf("starting stairs load: %w", err)
	}
	if err := evalCmd.Start(); err != nil {
		_ = loadCmd.Process.Kill()
		return fmt.Errorf("starting eval: %w", err)
	}

	loadErr := loadCmd.Wait()
	evalErr := evalCmd.Wait()

	if loadErr != nil {
		return fmt.Errorf("stairs load submit: %w", loadErr)
	}
	if evalErr != nil {
		return fmt.Errorf("stairs eval submit: %w", evalErr)
	}

	fmt.Println("Jobs submitted. Waiting for completion...")
	if err := waitForJob(env.Namespace, env.NamePrefix+"-sharegpt-load"); err != nil {
		return fmt.Errorf("stairs load job: %w", err)
	}
	fmt.Println("Load job completed.")
	return nil
}
