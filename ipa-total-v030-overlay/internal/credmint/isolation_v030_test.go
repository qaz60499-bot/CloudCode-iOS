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

func TestV031KnownHostsMustBeExplicitInIsolatedProfile(t *testing.T) {
    t.Setenv("IPADECRYPT_KNOWN_HOSTS_FILE", "")
    _, err := dial(t.Context(), config.Device{
        User:"mobile", Host:"192.168.1.4", Port:22,
        SudoPassword:"FAKE_SUDO_ONLY",
        Auth: config.DeviceAuth{Kind:"password", Password:"FAKE_LOGIN_ONLY"},
    })
    if err == nil || !strings.Contains(err.Error(), "IPADECRYPT_KNOWN_HOSTS_FILE") {
        t.Fatalf("must fail before network when host trust is unspecified: %v",err)
    }
}

func TestV032MintRequiresExplicitFairplayMaintenanceApproval(t *testing.T) {
    _, err := Mint(t.Context(), config.Device{User:"mobile",TriggerBundleID:"com.openai.chat"})
    if err == nil || !strings.Contains(err.Error(),"not explicitly approved") {
        t.Fatalf("unexpected service restart authorization: %v",err)
    }
}

func TestV032PrivilegedPayloadFailClosedBeforeSSH(t *testing.T) {
    d := &sshDevice{}
    _, err := d.run("cat >/tmp/must-not-run", []byte("unexpected payload"))
    if err == nil || !strings.Contains(err.Error(),"privileged stdin payload") {
        t.Fatalf("unintended privileged payload accepted: %v",err)
    }
}

func TestV031CleanupRefusesUnsafeAndMalformedPaths(t *testing.T) {
    for _, tc := range []struct{path, prefix string; allow bool}{
        {"/var/tmp/fp-retrieve-abcd123", "fp-retrieve-", true},
        {"/var/jb/var/tmp/fp-trigger-abcd123", "fp-trigger-", true},
        {"/", "fp-retrieve-", false},
        {"", "fp-retrieve-", false},
        {"/etc", "fp-retrieve-", false},
        {"/var/tmp/fp-retrieve-", "fp-retrieve-", false},
        {"/var/tmp/fp-retrieve-../foo", "fp-retrieve-", false},
        {"/var/tmp/fp-trigger-abcd", "fp-retrieve-", false},
    } {
        if got := validStagingDir(tc.path,tc.prefix); got!=tc.allow {
            t.Fatalf("cleanup acceptance mismatch path=%q got=%v want=%v",tc.path,got,tc.allow)
        }
    }
}

func TestV031USBModeDeniedBeforeTunnel(t *testing.T) {
    _, err := dial(t.Context(), config.Device{
        User:"mobile", SudoPassword:"FAKE_SUDO_ONLY", USB:true,
    })
    if err == nil || !strings.Contains(err.Error(), "USB") {
        t.Fatalf("USB mode must fail without port or tunnel effects: %v",err)
    }
}

func TestExplicitTriggerOnlyBeforeAnyDeviceIO(t *testing.T) {
    _, _, _, err := triggerApp(&sshDevice{}, "")
    if err == nil || !strings.Contains(err.Error(), "explicit") {
        t.Fatalf("unexpected anonymous trigger: %v", err)
    }
}
