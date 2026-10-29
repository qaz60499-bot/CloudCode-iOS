package main

import (
    "strings"
    "testing"
)

func TestV033AccountAndDeviceStagesAreExclusive(t *testing.T) {
    for _, tc := range []struct{auth,mint,want string; fail bool}{
        {"","","",true},
        {"0","0","",true},
        {"1","","auth-only",false},
        {"","1","mint-only",false},
        {"1","0","auth-only",false},
        {"0","1","mint-only",false},
        {"1","1","",true},
        {"x","x","",true},
        {"x","","",true},
        {"","bad","",true},
    } {
        t.Setenv("IPADECRYPT_ACCOUNT_AUTH_ONLY",tc.auth)
        t.Setenv("IPADECRYPT_ACCOUNT_MINT_ONLY",tc.mint)
        got,err:=bootstrapMode()
        if (err!=nil)!=tc.fail || got!=tc.want {
            t.Fatalf("account mode mismatch got=%q err=%v",got,err)
        }
    }
}

func TestV031MintLeaseFailClosed(t *testing.T) {
    cases := []struct{
        label string
        input string
        allow bool
    }{
        {"remoteai active", `{"status":"BLOCKED_REMOTEAI_PRIMARY_HAS_PRIORITY","exclusive_control_proven":false}`, false},
        {"idle is not lease", `{"status":"NO_DETECTED_ACTIVE_DEVICE_CONTROLLER","exclusive_control_proven":false}`, false},
        {"false green", `{"status":"BLOCKED_REMOTEAI_PRIMARY_HAS_PRIORITY","exclusive_control_proven":true}`, false},
        {"missing boolean", `{"status":"NO_DETECTED_ACTIVE_DEVICE_CONTROLLER"}`, false},
        {"invalid JSON", `not json`, false},
        {"explicit valid lease", `{"status":"NO_DETECTED_ACTIVE_DEVICE_CONTROLLER","exclusive_control_proven":true}`, true},
    }
    for _, tc := range cases {
        t.Run(tc.label, func(t *testing.T) {
            err := validateLeaseJSON([]byte(tc.input))
            if (err == nil) != tc.allow {
                t.Fatalf("lease acceptance mismatch: allow=%v err=%v", tc.allow, err)
            }
        })
    }
}

func TestV031MintGateUnavailableIsNotAuthorization(t *testing.T) {
    err := requireExclusiveLeaseForMint()
    if err == nil { t.Skip("gate granted an actual exclusive lease: verify environment manually") }
    if !strings.Contains(err.Error(),"gate") && !strings.Contains(err.Error(),"RemoteAI") {
        t.Fatalf("unexpected gate result: %v",err)
    }
}
