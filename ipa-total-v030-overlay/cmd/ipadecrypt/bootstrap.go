package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
	"strings"

	"github.com/londek/ipadecrypt/internal/appstore"
	"github.com/londek/ipadecrypt/internal/config"
	"github.com/londek/ipadecrypt/internal/credmint"
	"github.com/londek/ipadecrypt/internal/device"
	"github.com/londek/ipadecrypt/internal/tui"
	"github.com/londek/ipadecrypt/internal/updater"
	"github.com/spf13/cobra"
)

func bootstrapHandler(cmd *cobra.Command, args []string) {
	cfg, paths, err := loadConfigOrDefault(rootDirOverride)
	if err != nil {
		tui.Err("%v", err)
		return
	}

	// Treat any legacy persisted plaintext passwords as untrusted. Never use
	// or persist them during an isolated candidate bootstrap.
	cfg.Apple.Password = ""
	cfg.Device.Auth.Password = ""
	upd := updater.Start(context.Background(), resolveVersion(), cfg)
	defer upd.Wait()

	if bootstrapReset {
		cfg.Apple = config.Apple{}
		cfg.Device = config.Device{Port: 22, User: "mobile"}

		if err := cfg.Save(); err != nil {
			tui.Err("reset config: %v", err)
			return
		}
	}

	// ---- Step 1: App Store sign-in -----------------------------------

	if bootstrapSkipLogin {
		tui.Step(1, 3, "Sign in to the App Store (skipped)")
		tui.Info("skipped - App Store downloads and credential minting are disabled.\nYou can still decrypt a local .ipa if a credential is already cached.")

		tui.Spacer()
		tui.OK("bootstrap complete")

		return
	}

	tui.Step(1, 3, "Sign in to the App Store")
	tui.Info("ipadecrypt needs an Apple ID to download .ipas and to mint your\ndecryption credential. Use the same Apple ID that owns apps on your\njailbroken device. Credentials are stored locally on this machine.")

	account, err := bootstrapSignIn(cfg, paths)
	if err != nil {
		tui.Err("%v", err)
		return
	}

	if account == nil {
		return
	}

	// ---- Step 2: one-time credential mint ----------------------------

	tui.Step(2, 3, "Mint your decryption credential (one-time)")

	dsid := cfg.Apple.DirectoryServicesIdentifier
	if dsid == "" {
		tui.Err("sign-in did not return an account identifier; cannot mint")
		return
	}

	if credentialCached(paths, dsid) && !bootstrapRemint {
		tui.OK("credential already cached for this account")
		tui.Info("pass --remint to replace it")
	} else {
		tui.Info("This connects once to your jailbroken device to extract a reusable\n16-byte account key. After this, every decrypt runs offline - no device.")
		tui.Info("Requirements on the device:")
		tui.Bullet("root SSH (OpenSSH from Sileo), reachable over the network or USB")
		tui.Bullet("at least one App Store app bought with this Apple ID, installed")

		if err := requireExclusiveLeaseForMint(); err != nil {
			tui.Err("device maintenance window not verified: %v", err)
			return
		}
		if os.Getenv("IPADECRYPT_KNOWN_HOSTS_FILE") == "" {
			tui.Err("missing strict IPADECRYPT_KNOWN_HOSTS_FILE; use the trusted Windows OpenSSH known_hosts")
			return
		}
		if err := promptMintDevice(cfg); err != nil {
			return
		}

		// Config is for an isolated E: profile; never serialize Apple/SSH password.
		// Keep the SSH password only in the local in-memory Mint argument.
		mintDevice := cfg.Device
		cfg.Apple.Password = ""
		cfg.Device.Auth.Password = ""
		if err := cfg.Save(); err != nil {
			tui.Err("save sanitized config: %v", err)
			return
		}

		live := tui.NewLive()
		live.Spin("minting credential (one-time)")

		credential, err := credmint.Mint(context.Background(), mintDevice)
		if err != nil {
			if errors.Is(err, credmint.ErrBinariesUnavailable) {
				live.Fail("this build cannot mint credentials")
				tui.Info("the device binaries aren't compiled into this build; install an official release")

				return
			}

			live.Fail("mint failed: %v", err)

			return
		}

		if err := saveCredential(paths, dsid, credential); err != nil {
			live.Fail("cache credential: %v", err)
			return
		}

		live.OK("credential minted and cached")
	}

	// ---- Step 3: on-device decrypt fallback readiness ----------------

	// No device fallback probe here: it may push binaries, scan services and
	// collide with the RemoteAI primary controller even after a successful mint.
	tui.Info("on-device decrypt fallback deliberately disabled for this isolated offline build")

	tui.Spacer()
	tui.OK("bootstrap complete - run `ipadecrypt decrypt <bundle-id|app-store-id|app-store-url|path-to-local-ipa>`")
}

// requireExclusiveLeaseForMint uses the project's existing fail-closed
// controller gate. A quiet process list is not an exclusive device lease.
// This command never connects to the iPhone or changes any device setting.
func requireExclusiveLeaseForMint() error {
	ctx, cancel := context.WithTimeout(context.Background(), 18*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "D:\\Python314\\python.exe", "-B",
		"E:\\google\\IPA-Total-20261026\\ios166_device_control_gate.py")
	result, err := cmd.Output()
	if err != nil { return errors.New("controller gate unavailable or failed") }
	return validateLeaseJSON(result)
}

func validateLeaseJSON(result []byte) error {
	var state struct {
		Status string `json:"status"`
		Exclusive bool `json:"exclusive_control_proven"`
	}
	if err := json.Unmarshal(result, &state); err != nil {
		return errors.New("controller gate returned invalid status")
	}
	if state.Status != "NO_DETECTED_ACTIVE_DEVICE_CONTROLLER" || !state.Exclusive {
		return errors.New("RemoteAI has priority or no verifiable exclusive lease exists")
	}
	return nil
}

// verifyDeviceDecryptReady checks that the configured device can serve the
// on-device decrypt fallback - the path that handles old apps still shipping a
// 32-bit slice, which the arm64-only offline decryptor can't. It confirms
// AppSync Unified + appinst are present and that the embedded helper uploads
// and execs. It is best-effort: offline decryption works regardless, so a
// missing prerequisite only disables the fallback and never fails bootstrap.
func verifyDeviceDecryptReady(cfg *config.Config) {
	tui.Step(3, 3, "Verify on-device decrypt fallback")

	if cfg.Device.Host == "" && !cfg.Device.USB {
		tui.Info("no device configured - skipping; old apps that ship a 32-bit slice won't be decryptable until you set one up")
		return
	}

	tui.Info("Old apps that still ship a 32-bit slice can't be decrypted offline;\nipadecrypt falls back to decrypting them on this device. That needs two\nSileo packages - offline decryption works without them:")
	tui.Bullet("AppSync Unified   bypasses installd's signature check (repo: https://lukezgd.github.io/repo)")
	tui.Bullet("appinst           installs the patched IPA on the device")

	live := tui.NewLive()
	live.Spin("connecting to the device")

	dev, err := device.Connect(context.Background(), cfg.Device)
	if err != nil {
		live.Fail("connect failed: %v", err)
		tui.Info("the on-device fallback won't work until the device is reachable; offline decryption is unaffected")

		return
	}

	defer dev.Close()

	live.OK("connected")

	missing := 0

	checks := []struct {
		name  string
		probe func() (string, error)
	}{
		{"AppSync Unified", dev.LocateAppSync},
		{"appinst", dev.LocateAppinst},
	}
	for _, c := range checks {
		p, err := c.probe()
		switch {
		case err != nil:
			tui.Err("%s - %v", c.name, err)

			missing++
		case p == "":
			tui.Err("%s - not found", c.name)

			missing++
		default:
			tui.OK("%s → %s", c.name, p)
		}
	}

	live = tui.NewLive()
	live.Spin("uploading decrypt helper")

	helperPath, err := dev.EnsureHelper()
	if err != nil {
		live.Fail("helper upload failed: %v", err)

		missing++
	} else {
		live.Spin("verifying helper can exec")

		if err := dev.VerifyHelper(helperPath); err != nil {
			live.Fail("helper verify failed: %v", err)

			missing++
		} else {
			live.OK("helper ready at %s", helperPath)
		}
	}

	if missing > 0 {
		tui.Warn("on-device fallback not ready (%d issue(s)) - old 32-bit apps will fail until it's fixed", missing)
		tui.Info("offline decryption is unaffected; this only matters for old apps that ship a 32-bit slice")

		return
	}

	tui.OK("on-device fallback ready")
}

// bootstrapSignIn runs the interactive App Store login, persisting the
// account into cfg. Returns (nil, nil) when the user aborted a prompt.
func bootstrapSignIn(cfg *config.Config, paths *config.Paths) (*appstore.Account, error) {
	email := cfg.Apple.Email
	password := cfg.Apple.Password

	if email == "" {
		s, err := tui.Prompt("Apple ID email")
		if err != nil {
			return nil, nil
		}

		email = strings.TrimSpace(s)
	}

	if password == "" {
		s, err := tui.PromptPassword("Apple ID password")
		if err != nil {
			return nil, nil
		}

		password = s
	}

	as, err := appstore.New(filepath.Join(paths.Root, "cookies"))
	if err != nil {
		return nil, fmt.Errorf("appstore client: %w", err)
	}

	tui.Info("The first sign-in runs a one-time machine-signing step and can take a few minutes.")

	var (
		account  *appstore.Account
		authCode string
	)

	for attempt := 0; attempt < 3 && account == nil; attempt++ {
		live := tui.NewLive()
		live.Spin("authenticating")

		account, err = as.Login(email, password, authCode)
		switch {
		case errors.Is(err, appstore.ErrAuthCodeRequired):
			live.Stop()

			code, perr := tui.Prompt("Apple sent a 6-digit code - enter it")
			if perr != nil {
				return nil, nil
			}

			authCode = strings.TrimSpace(code)

		case err != nil:
			live.Fail("login failed: %v", err)
			return nil, err

		default:
			live.OK("authenticated")
		}
	}

	if account == nil {
		return nil, errors.New("login: 3 two-factor attempts failed")
	}

	cfg.Apple.SetAccount(account)
	cfg.Apple.Password = "" // App Store password must never be serialized

	appStoreCountry, err := appstore.CountryCodeFromStoreFront(account.StoreFront)
	if err != nil {
		return nil, fmt.Errorf("resolve appstore country code: %w", err)
	}

	tui.Fields(
		"Apple ID", redact(account.Email),
		"Name", account.Name,
		"Storefront", fmt.Sprintf("%s (%s)", redact(account.StoreFront), redact(appStoreCountry)),
	)

	if err := cfg.Save(); err != nil {
		return nil, fmt.Errorf("save config: %w", err)
	}

	return account, nil
}

// promptMintDevice fills in cfg.Device for the one-time credential mint.
// Returns a non-nil error only to signal a user abort (callers just return).
func promptMintDevice(cfg *config.Config) error {
	if cfg.Device.Host == "" && !cfg.Device.USB {
		idx, err := tui.Select("how is the device connected?", []string{
			"Network (device IP over Wi-Fi)",
			"USB (via iproxy)",
		})
		if err != nil {
			return err
		}

		cfg.Device.USB = idx == 1
	}

	if cfg.Device.USB {
		if cfg.Device.UDID == "" {
			u, err := tui.PromptDefault("device UDID (leave empty if only one is connected)", "")
			if err != nil {
				return err
			}

			cfg.Device.UDID = strings.TrimSpace(u)
		}

		if cfg.Device.Port == 0 {
			cfg.Device.Port = 2222
		}
	} else if cfg.Device.Host == "" {
		s, err := tui.Prompt("device IP/host")
		if err != nil {
			return err
		}

		cfg.Device.Host = strings.TrimSpace(s)
	}

	if cfg.Device.User == "" {
		u, err := tui.PromptDefault("device SSH user (mobile with transient sudo)", "mobile")
		if err != nil {
			return err
		}

		cfg.Device.User = strings.TrimSpace(u)
	}

	if cfg.Device.Auth.Kind == "" {
		idx, err := tui.Select("authentication method", []string{
			"password",
			"SSH public key",
		})
		if err != nil {
			return err
		}

		if idx == 1 {
			cfg.Device.Auth.Kind = "key"
		} else {
			cfg.Device.Auth.Kind = "password"
		}
	}

	switch cfg.Device.Auth.Kind {
	case "key":
		if cfg.Device.Auth.KeyPath == "" {
			p, err := tui.PromptDefault("SSH private key path", "~/.ssh/id_ed25519")
			if err != nil {
				return err
			}

			cfg.Device.Auth.KeyPath = strings.TrimSpace(p)
		}

		if cfg.Device.Auth.KeyPassphrase == "" {
			pass, err := tui.PromptPassword("key passphrase (leave empty if unencrypted)")
			if err != nil {
				return err
			}

			cfg.Device.Auth.KeyPassphrase = pass
		}

	default:
		if cfg.Device.Auth.Password == "" {
			pw, err := tui.PromptPassword("device SSH password")
			if err != nil {
				return err
			}

			cfg.Device.Auth.Password = pw
		}
	}

	if cfg.Device.Port == 0 { cfg.Device.Port = 22 }
	if cfg.Device.USB { return errors.New("USB mint disabled; RemoteAI controls USB") }
	if cfg.Device.Port != 22 && cfg.Device.Port != 2222 { return errors.New("mint requires existing SSH port 22 or 2222") }
	if cfg.Device.User != "mobile" { return errors.New("isolated mint requires mobile + sudo") }
	if cfg.Device.TriggerBundleID == "" {
		bundleID, err := tui.PromptDefault("explicitly authorized App Store trigger bundle ID", "com.openai.chat")
		if err != nil { return err }
		cfg.Device.TriggerBundleID = strings.TrimSpace(bundleID)
	}
	if cfg.Device.TriggerBundleID == "" { return errors.New("trigger bundle ID required") }
	if cfg.Device.SudoPassword == "" {
		pw, err := tui.PromptPassword("device sudo password (in memory only, never saved)")
		if err != nil { return err }
		if pw == "" { return errors.New("empty sudo password not accepted") }
		cfg.Device.SudoPassword = pw
	}
	return nil
}
