package credmint

import (
    "io"
    "strings"
    "testing"

    "github.com/londek/ipadecrypt/internal/config"
)

func TestIsolatedSudoCommandKeepsPasswordOutOfShellArgs(t *testing.T) {
    d := &sshDevice{sudoPassword: "FAKE_SECRET_NEVER_LOG"}
    command, source := d.rootCommand("id -u")
    if strings.Contains(command, d.sudoPassword) { t.Fatal("password in remote command") }
    if !strings.Contains(command, "sudo -S -p '' -v") ||
       !strings.Contains(command, "sudo -n") ||
       !strings.Contains(command, "</dev/null") {
        t.Fatalf("unsafe sudo command shape: %q", command)
    }
    data, err := io.ReadAll(source)
    if err != nil || string(data) != d.sudoPassword+"\n" {
        t.Fatal("private input transport is incorrect")
    }
}

func TestDirectRootSSHRejectedWithoutConnecting(t *testing.T) {
    _, err := dial(t.Context(), config.Device{User: "root"})
    if err == nil || !strings.Contains(err.Error(), "mobile") {
        t.Fatalf("direct root connection must be denied, got %v", err)
    }
}

func TestSudoPasswordRequiredBeforeSSH(t *testing.T) {
    _, err := dial(t.Context(), config.Device{User: "mobile"})
    if err == nil || !strings.Contains(err.Error(), "transient") {
        t.Fatalf("unset sudo auth must fail locally, got %v", err)
    }
}

func TestExplicitTriggerOnlyBeforeAnyDeviceIO(t *testing.T) {
    _, _, _, err := triggerApp(&sshDevice{}, "")
    if err == nil || !strings.Contains(err.Error(), "explicit") {
        t.Fatalf("unexpected anonymous trigger: %v", err)
    }
}
