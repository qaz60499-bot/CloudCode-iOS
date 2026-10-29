package main

import (
    "strings"
    "testing"
)

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
