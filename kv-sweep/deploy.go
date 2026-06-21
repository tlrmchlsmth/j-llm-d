package main

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
)

func deploy(cfg PDConfig, repoDir string) error {
	fmt.Printf("=== Deploying P%d/D%d ===\n",
		cfg.PrefillReplicas*cfg.PrefillSize, cfg.DecodeReplicas*cfg.DecodeSize)

	cmd := exec.Command("just", "start-pd",
		strconv.Itoa(cfg.PrefillReplicas), strconv.Itoa(cfg.PrefillSize),
		strconv.Itoa(cfg.DecodeReplicas), strconv.Itoa(cfg.DecodeSize),
	)
	cmd.Dir = repoDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func waitReady(repoDir string) error {
	fmt.Println("Waiting for stack readiness...")
	cmd := exec.Command("just", "ready")
	cmd.Dir = repoDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func teardown(repoDir string) error {
	fmt.Println("Tearing down...")
	cmd := exec.Command("just", "stop", "true")
	cmd.Dir = repoDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func waitForJob(namespace, jobName string) error {
	cmd := exec.Command("kubectl", "-n", namespace, "wait", "--for=condition=complete",
		"job", "-l", "app="+jobName, "--timeout=1800s")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func stopNyann(repoDir string) error {
	cmd := exec.Command("just", "stop-nyann")
	cmd.Dir = repoDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
