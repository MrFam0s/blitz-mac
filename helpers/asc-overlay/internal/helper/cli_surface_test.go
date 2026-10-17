package helper

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/peterbourgon/ff/v3/ffcli"

	"github.com/rudrankriyam/App-Store-Connect-CLI/cmd"
	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/cli/shared"
)

func TestCLIExecMatchesDirectRunForEntireCommandTree(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping full CLI-surface compatibility walk in short mode")
	}

	t.Setenv("ASC_SKILLS_AUTO_CHECK", "0")
	t.Setenv("CI", "1")

	const version = "test-version"

	cases := collectCLICompatibilityCases(rootCommandForCompatibility(version))
	if len(cases) < 200 {
		t.Fatalf("expected broad CLI surface coverage, got %d compatibility cases", len(cases))
	}
	t.Logf("verifying %d CLI compatibility cases", len(cases))

	service := NewService(version)

	for _, args := range cases {
		args := append([]string(nil), args...)
		name := compatibilityCaseName(args)

		t.Run(name, func(t *testing.T) {
			direct, err := runDirectCLI(args, version)
			if err != nil {
				t.Fatalf("runDirectCLI(%q) error: %v", strings.Join(args, " "), err)
			}

			helperResult, helperErr := runHelperCLI(service, args)
			if helperErr != nil {
				t.Fatalf("helper cli.exec returned error for %q: %#v", strings.Join(args, " "), helperErr)
			}

			if helperResult.ExitCode != direct.ExitCode {
				t.Fatalf("exit code mismatch for %q: helper=%d direct=%d", strings.Join(args, " "), helperResult.ExitCode, direct.ExitCode)
			}
			if helperResult.Stdout != direct.Stdout {
				t.Fatalf("stdout mismatch for %q\nhelper:\n%s\ndirect:\n%s", strings.Join(args, " "), helperResult.Stdout, direct.Stdout)
			}
			if helperResult.Stderr != direct.Stderr {
				t.Fatalf("stderr mismatch for %q\nhelper:\n%s\ndirect:\n%s", strings.Join(args, " "), helperResult.Stderr, direct.Stderr)
			}
		})
	}
}

func runDirectCLI(args []string, version string) (CLIExecResult, error) {
	executable, err := os.Executable()
	if err != nil {
		return CLIExecResult{}, fmt.Errorf("resolve test executable: %w", err)
	}

	command := exec.Command(executable, append([]string{CLISubprocessModeArg}, args...)...)
	command.Env = append(os.Environ(), fmt.Sprintf("%s=%s", CLIVersionEnvVar, version))

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr

	exitCode := 0
	if err := command.Run(); err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			return CLIExecResult{}, err
		}
		exitCode = exitErr.ExitCode()
	}

	return CLIExecResult{
		ExitCode: exitCode,
		Stdout:   stdout.String(),
		Stderr:   stderr.String(),
	}, nil
}

func runHelperCLI(service *Service, args []string) (CLIExecResult, *ResponseError) {
	shared.SetSelectedProfile("")
	shared.ResetDefaultOutputFormat()
	shared.CleanupTempPrivateKeys()

	response := service.Handle(context.Background(), Request{
		ID:     "compat",
		Method: "cli.exec",
		Params: mustJSONForCompatibility(CLIExecParams{Args: args}),
	})
	if response.Error != nil {
		return CLIExecResult{}, response.Error
	}

	result, ok := response.Result.(CLIExecResult)
	if !ok {
		panic("unexpected cli.exec result type")
	}
	return result, nil
}

func collectCLICompatibilityCases(root *ffcli.Command) [][]string {
	cases := [][]string{
		{},
		{"--help"},
		{"--version"},
	}

	var walk func(path []string, command *ffcli.Command)
	walk = func(path []string, command *ffcli.Command) {
		for _, subcommand := range command.Subcommands {
			next := append(append([]string(nil), path...), subcommand.Name)
			cases = append(cases, append(append([]string(nil), next...), "--help"))
			walk(next, subcommand)
		}
	}

	walk(nil, root)
	return cases
}

func rootCommandForCompatibility(version string) *ffcli.Command {
	shared.SetSelectedProfile("")
	shared.ResetDefaultOutputFormat()
	return cmd.RootCommand(version)
}

func compatibilityCaseName(args []string) string {
	if len(args) == 0 {
		return "root"
	}
	return strings.Join(args, " ")
}

func mustJSONForCompatibility(value any) []byte {
	data, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return data
}
