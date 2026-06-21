package main

import (
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

func deploy(cfg PDConfig, env EnvConfig) error {
	fmt.Printf("=== Deploying %s ===\n", cfg.Label())

	ts := time.Now().Format("20060102-150405")

	// 1. Apply LWS manifests (pre-rendered kustomize with placeholder substitution)
	lws, err := readManifest(env.ManifestsDir, "lws.yaml")
	if err != nil {
		return err
	}
	lws = strings.ReplaceAll(lws, "NAME_PREFIX_PLACEHOLDER-", env.NamePrefix+"-")
	lws = strings.ReplaceAll(lws, "DEPLOY_TS_PLACEHOLDER", ts)
	lws = strings.ReplaceAll(lws, "OWNER_PLACEHOLDER", env.NamePrefix)
	lws = strings.ReplaceAll(lws, "VLLM_IMAGE_PLACEHOLDER", env.VLLMImage)
	lws = strings.ReplaceAll(lws, "LUSTRE_PREFIX_PLACEHOLDER", "/mnt/lustre/"+env.NamePrefix)
	lws = strings.ReplaceAll(lws, "VLLM_DEV_VENV_PLACEHOLDER", "")
	lws = strings.ReplaceAll(lws, "FORK_REPO_PLACEHOLDER", "")
	lws = strings.ReplaceAll(lws, "FORK_BRANCH_PLACEHOLDER", "")
	lws = strings.ReplaceAll(lws, "PREFILL_REPLICAS_PLACEHOLDER", strconv.Itoa(cfg.PrefillReplicas))
	lws = strings.ReplaceAll(lws, "PREFILL_SIZE_PLACEHOLDER", strconv.Itoa(cfg.PrefillSize))
	lws = strings.ReplaceAll(lws, "DECODE_REPLICAS_PLACEHOLDER", strconv.Itoa(cfg.DecodeReplicas))
	lws = strings.ReplaceAll(lws, "DECODE_SIZE_PLACEHOLDER", strconv.Itoa(cfg.DecodeSize))

	if err := kubectlApplyStdin(env.Namespace, lws); err != nil {
		return fmt.Errorf("applying LWS manifests: %w", err)
	}

	// 2. Apply gateway
	gw, err := readManifest(env.ManifestsDir, "gateway.yaml")
	if err != nil {
		return err
	}
	gw = strings.ReplaceAll(gw, "${DEPLOY_NAME}", env.DeployName)
	if err := kubectlApplyStdin(env.Namespace, gw); err != nil {
		return fmt.Errorf("applying gateway: %w", err)
	}

	// 3. Deploy InferencePool via helm
	if err := deployInferencePool(env); err != nil {
		return fmt.Errorf("deploying inferencepool: %w", err)
	}

	// 4. Apply HTTPRoute
	hr, err := readManifest(env.ManifestsDir, "httproute.yaml")
	if err != nil {
		return err
	}
	hr = strings.ReplaceAll(hr, "${DEPLOY_NAME}", env.DeployName)
	if err := kubectlApplyStdin(env.Namespace, hr); err != nil {
		return fmt.Errorf("applying httproute: %w", err)
	}

	fmt.Printf("Deployed %s at %s\n", cfg.Label(), ts)
	return nil
}

func deployInferencePool(env EnvConfig) error {
	vals, err := readManifest(env.ManifestsDir, "inferencepool-pd.values.yaml")
	if err != nil {
		return err
	}
	vals = strings.ReplaceAll(vals, "${DEPLOY_NAME}", env.DeployName)
	vals = strings.ReplaceAll(vals, "${OWNER}", env.NamePrefix)

	tmpFile, err := os.CreateTemp("", "infpool-values-*.yaml")
	if err != nil {
		return err
	}
	defer os.Remove(tmpFile.Name())
	tmpFile.WriteString(vals)
	tmpFile.Close()

	cmd := exec.Command("helm", "upgrade", "--install",
		env.DeployName+"-infpool",
		"oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool",
		"--version", "v1.3.0",
		"-f", tmpFile.Name(),
		"-n", env.Namespace,
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return err
	}

	// Restart EPP pod to pick up config
	kubectlRun(env.Namespace, "delete", "pod", "-l",
		"inferencepool="+env.DeployName+"-infpool-epp", "--ignore-not-found=true")

	// Wait for infpool-ip service and apply DestinationRule
	var infpoolSvc string
	for i := 0; i < 30; i++ {
		out, err := exec.Command("kubectl", "-n", env.Namespace, "get", "svc",
			"-l", "istio.io/inferencepool-name="+env.DeployName+"-infpool",
			"-o", "jsonpath={.items[0].metadata.name}").Output()
		if err == nil && len(strings.TrimSpace(string(out))) > 0 {
			infpoolSvc = strings.TrimSpace(string(out))
			break
		}
		fmt.Printf("Waiting for infpool-ip service... (%d/30)\n", i+1)
		time.Sleep(2 * time.Second)
	}

	if infpoolSvc == "" {
		fmt.Println("WARNING: infpool-ip service not found after 60s — skipping DestinationRule")
	} else {
		dr, err := readManifest(env.ManifestsDir, "infpool-backend-dr.yaml")
		if err == nil {
			dr = strings.ReplaceAll(dr, "${DEPLOY_NAME}", env.DeployName)
			dr = strings.ReplaceAll(dr, "${INFPOOL_IP_SVC}", infpoolSvc)
			kubectlApplyStdin(env.Namespace, dr)
		}
	}

	return nil
}

func waitReady(env EnvConfig) error {
	fmt.Println("Waiting for stack readiness...")

	type waitResult struct {
		name string
		err  error
	}
	ch := make(chan waitResult, 3)

	go func() {
		ch <- waitResult{"decode", kubectlRun(env.Namespace, "wait", "--for=condition=Ready",
			"pod", "-l", "llm-d.ai/role=decode,llm-d.ai/owner="+env.NamePrefix, "--timeout=1200s")}
	}()
	go func() {
		err := kubectlRun(env.Namespace, "wait", "--for=condition=Ready",
			"pod", "-l", "llm-d.ai/role=prefill,llm-d.ai/owner="+env.NamePrefix, "--timeout=1200s")
		ch <- waitResult{"prefill", err}
	}()
	go func() {
		ch <- waitResult{"epp", kubectlRun(env.Namespace, "wait", "--for=condition=Ready",
			"pod", "-l", "inferencepool="+env.DeployName+"-infpool-epp", "--timeout=120s")}
	}()

	for i := 0; i < 3; i++ {
		r := <-ch
		if r.err != nil && r.name != "prefill" {
			return fmt.Errorf("waiting for %s: %w", r.name, r.err)
		}
	}

	// Poll gateway health
	fmt.Println("Checking gateway...")
	gwURL := fmt.Sprintf("http://%s-inference-gateway-istio.%s.svc.cluster.local:80/v1/models",
		env.DeployName, env.Namespace)
	for i := 0; i < 300; i++ {
		resp, err := http.Get(gwURL)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				fmt.Println("Ready.")
				return nil
			}
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("gateway not ready after 10 minutes")
}

func teardown(env EnvConfig) error {
	fmt.Println("Tearing down...")
	errs := make(chan error, 10)

	cmds := [][]string{
		{"delete", "lws", env.DeployName + "-decode", "--ignore-not-found=true", "--grace-period=0", "--force"},
		{"delete", "lws", env.DeployName + "-prefill", "--ignore-not-found=true", "--grace-period=0", "--force"},
		{"delete", "httproute", env.DeployName + "-route", "--ignore-not-found=true"},
		{"delete", "gateway", env.DeployName + "-inference-gateway", "--ignore-not-found=true"},
		{"delete", "service", env.DeployName + "-inference-gateway-istio", "--ignore-not-found=true"},
		{"delete", "configmap", env.DeployName + "-gateway-options", "--ignore-not-found=true"},
		{"delete", "destinationrule", env.DeployName + "-infpool-backend", "--ignore-not-found=true"},
		{"delete", "job", "-l", "app=" + env.NamePrefix + "-sharegpt-load", "--ignore-not-found=true"},
		{"delete", "job", "-l", "app=" + env.NamePrefix + "-nyann-eval", "--ignore-not-found=true"},
	}

	for _, args := range cmds {
		args := args
		go func() { errs <- kubectlRun(env.Namespace, args...) }()
	}

	// Helm uninstall in parallel
	go func() {
		cmd := exec.Command("helm", "uninstall", env.DeployName+"-infpool", "-n", env.Namespace)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		errs <- cmd.Run()
	}()

	for i := 0; i < len(cmds)+1; i++ {
		<-errs
	}

	kubectlRun(env.Namespace, "delete", "sa", env.DeployName, "--ignore-not-found=true")
	return nil
}

func stopNyann(env EnvConfig) error {
	ch := make(chan error, 2)
	go func() {
		ch <- kubectlRun(env.Namespace, "delete", "job", "-l",
			"app="+env.NamePrefix+"-sharegpt-load", "--ignore-not-found=true")
	}()
	go func() {
		ch <- kubectlRun(env.Namespace, "delete", "job", "-l",
			"app="+env.NamePrefix+"-nyann-eval", "--ignore-not-found=true")
	}()
	<-ch
	<-ch
	return nil
}

func waitForJob(namespace, jobLabel string) error {
	cmd := exec.Command("kubectl", "-n", namespace, "wait", "--for=condition=complete",
		"job", "-l", "app="+jobLabel, "--timeout=1800s")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func kubectlApplyStdin(namespace, manifest string) error {
	cmd := exec.Command("kubectl", "-n", namespace, "apply", "-f", "-")
	cmd.Stdin = strings.NewReader(manifest)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func kubectlRun(namespace string, args ...string) error {
	fullArgs := append([]string{"-n", namespace}, args...)
	cmd := exec.Command("kubectl", fullArgs...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
