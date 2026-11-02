package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

type replicas struct{ desired, current, available int }
type cluster interface {
	replicas(context.Context) (replicas, error)
	pods(context.Context) ([]string, error)
	scale(context.Context, int) error
}

type kubectl struct{ cfg config }

func (k *kubectl) run(ctx context.Context, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, k.cfg.waitTimeout)
	defer cancel()
	// Bound the process with the context: --request-timeout prevents kubectl
	// from falling back to the Pod's in-cluster credentials.
	command := exec.CommandContext(ctx, "kubectl", append([]string{"--namespace", k.cfg.namespace}, args...)...)
	output, err := command.Output()
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if exit, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("kubectl: %s: %w", strings.TrimSpace(string(exit.Stderr)), err)
		}
		return nil, fmt.Errorf("kubectl: %w", err)
	}
	return output, nil
}

func (k *kubectl) replicas(ctx context.Context) (replicas, error) {
	output, err := k.run(ctx, "get", "deployment", k.cfg.deployment, "--output", "json")
	if err != nil {
		return replicas{}, err
	}
	return decodeReplicas(output)
}

func decodeReplicas(data []byte) (replicas, error) {
	var deployment struct {
		Spec struct {
			Replicas *int `json:"replicas"`
		} `json:"spec"`
		Status struct {
			Replicas  int `json:"replicas"`
			Available int `json:"availableReplicas"`
		} `json:"status"`
	}
	if err := json.Unmarshal(data, &deployment); err != nil {
		return replicas{}, fmt.Errorf("invalid Deployment response: %w", err)
	}
	if deployment.Spec.Replicas == nil || *deployment.Spec.Replicas < 0 || deployment.Status.Replicas < 0 || deployment.Status.Available < 0 {
		return replicas{}, fmt.Errorf("invalid Deployment replica counts")
	}
	return replicas{*deployment.Spec.Replicas, deployment.Status.Replicas, deployment.Status.Available}, nil
}

func (k *kubectl) pods(ctx context.Context) ([]string, error) {
	output, err := k.run(ctx, "get", "pods", "--selector", k.cfg.selector, "--output", "name")
	return strings.Fields(string(output)), err
}

func (k *kubectl) scale(ctx context.Context, n int) error {
	_, err := k.run(ctx, "scale", "deployment", k.cfg.deployment, "--replicas", strconv.Itoa(n))
	return err
}

func (a *app) assertStopped(ctx context.Context, message string) error {
	state, err := a.cluster.replicas(ctx)
	if err != nil {
		return err
	}
	pods, err := a.cluster.pods(ctx)
	if err != nil {
		return err
	}
	if state.desired != 0 || state.available != 0 || len(pods) != 0 {
		return fmt.Errorf("%s", message)
	}
	return nil
}

func (a *app) status(ctx context.Context) error {
	state, err := a.cluster.replicas(ctx)
	if err != nil {
		return err
	}
	fmt.Fprintf(a.out, "Deployment: %s/%s\nDesired replicas: %d\nAvailable replicas: %d\n", a.cfg.namespace, a.cfg.deployment, state.desired, state.available)
	return nil
}

func (a *app) wait(ctx context.Context, description string, ready func(context.Context) (bool, error)) error {
	ctx, cancel := context.WithTimeout(ctx, a.cfg.waitTimeout)
	defer cancel()
	for {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("waiting for %s: %w", description, err)
		}
		ok, err := ready(ctx)
		if err != nil {
			return err
		}
		if ok {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("waiting for %s: %w", description, ctx.Err())
		case <-time.After(2 * time.Second):
		}
	}
}

func (a *app) stop(ctx context.Context) error {
	state, err := a.cluster.replicas(ctx)
	if err != nil {
		return err
	}
	if state.desired != 0 {
		if err := a.cluster.scale(ctx, 0); err != nil {
			return err
		}
	}
	if err := a.wait(ctx, a.cfg.deployment+" replicas to become 0", func(ctx context.Context) (bool, error) {
		state, err := a.cluster.replicas(ctx)
		return state.current == 0, err
	}); err != nil {
		return err
	}
	if err := a.wait(ctx, a.cfg.deployment+" Pods to terminate", func(ctx context.Context) (bool, error) {
		pods, err := a.cluster.pods(ctx)
		return len(pods) == 0, err
	}); err != nil {
		return err
	}
	fmt.Fprintf(a.out, "%s is stopped\n", a.cfg.deployment)
	return nil
}

func (a *app) start(ctx context.Context) error {
	if err := a.assertComplete(); err != nil {
		return err
	}
	state, err := a.cluster.replicas(ctx)
	if err != nil {
		return err
	}
	if state.desired != 1 {
		if err := a.cluster.scale(ctx, 1); err != nil {
			return err
		}
	}
	if err := a.wait(ctx, a.cfg.deployment+" to become available", func(ctx context.Context) (bool, error) {
		state, err := a.cluster.replicas(ctx)
		return state.available == 1, err
	}); err != nil {
		return err
	}
	fmt.Fprintf(a.out, "%s is available\n", a.cfg.deployment)
	return nil
}
