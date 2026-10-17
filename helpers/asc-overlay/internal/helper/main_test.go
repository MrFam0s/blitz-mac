package helper

import (
	"os"
	"strings"
	"testing"

	"github.com/rudrankriyam/App-Store-Connect-CLI/cmd"
)

func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == CLISubprocessModeArg {
		version := strings.TrimSpace(os.Getenv(CLIVersionEnvVar))
		if version == "" {
			version = "test-version"
		}
		os.Exit(cmd.Run(os.Args[2:], version))
	}

	os.Exit(m.Run())
}
