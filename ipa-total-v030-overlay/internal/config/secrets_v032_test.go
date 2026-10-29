package config

import (
    "encoding/json"
    "os"
    "path/filepath"
    "strings"
    "testing"
)

func TestV032NoPlaintextSecretsInSavedConfig(t *testing.T) {
    location := filepath.Join(t.TempDir(),"config.json")
    cfg := New(location)
    cfg.Apple.Email = "test@example.invalid"
    cfg.Apple.Password = "FAKE_APPLE_PASSWORD_NOT_TO_STORE"
    cfg.Apple.PasswordToken = "FAKE_ACCOUNT_TOKEN_TO_KEEP_FOR_ACCOUNT"
    cfg.Device.User = "mobile"
    cfg.Device.TriggerBundleID = "com.openai.chat"
    cfg.Device.SudoPassword = "FAKE_SUDO_SECRET_NOT_TO_STORE"
    cfg.Device.ApproveRestart = true
    cfg.Device.Auth.Kind = "key"
    cfg.Device.Auth.Password = "FAKE_SSH_PASSWORD_NOT_TO_STORE"
    cfg.Device.Auth.KeyPassphrase = "FAKE_KEY_PASSPHRASE_NOT_TO_STORE"
    if err := cfg.Save(); err != nil { t.Fatal(err) }
    data, err := os.ReadFile(location)
    if err != nil { t.Fatal(err) }
    for _, secret := range []string{
        cfg.Apple.Password, cfg.Device.SudoPassword,
        cfg.Device.Auth.Password, cfg.Device.Auth.KeyPassphrase,
    } {
        if strings.Contains(string(data),secret) {
            t.Fatal("config persisted plaintext secret")
        }
    }
    var persisted map[string]any
    if err := json.Unmarshal(data,&persisted);err != nil {t.Fatal(err)}
    loaded,err:=Load(location)
    if err != nil {t.Fatal(err)}
    if loaded.Device.User!="mobile" || loaded.Device.TriggerBundleID!="com.openai.chat" ||
       loaded.Apple.Email!="test@example.invalid" {
        t.Fatalf("non-secret profile identity not retained")
    }
    if loaded.Apple.Password!="" || loaded.Device.Auth.Password!="" ||
       loaded.Device.Auth.KeyPassphrase!="" || loaded.Device.SudoPassword!="" || loaded.Device.ApproveRestart {
        t.Fatal("secret survived config reload")
    }
}
