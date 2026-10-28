package credmint

import (
    "bytes"
    "crypto/ed25519"
    "crypto/rand"
    "errors"
    "io"
    "net"
    "os"
    "strings"
    "sync"
    "testing"
    "time"

    "github.com/pkg/sftp"
    "golang.org/x/crypto/ssh"
)

// This is an in-memory SSH wire protocol server. It never reaches a phone or
// opens a listener. SFTP is served on a test-only temporary directory.
type mockSSHResult struct {
    command string
    stdin string
}
type mockSSH struct {
    client *ssh.Client
    events chan mockSSHResult
    done chan struct{}
    closeOnce sync.Once
}

func newMockSSH(t *testing.T, exitStatus uint32) *mockSSH {
    t.Helper()
    _, key, err := ed25519.GenerateKey(rand.Reader)
    if err != nil { t.Fatal(err) }
    signer, err := ssh.NewSignerFromKey(key)
    if err != nil { t.Fatal(err) }
    serverConfig := &ssh.ServerConfig{
        PasswordCallback: func(meta ssh.ConnMetadata, pw []byte) (*ssh.Permissions,error) {
            if meta.User() != "mobile" || !bytes.Equal(pw, []byte("mock-ssh-login")) {
                return nil, errors.New("invalid mock credentials")
            }
            return nil,nil
        },
    }
    serverConfig.AddHostKey(signer)
    clientConn, serverConn := net.Pipe()
    m := &mockSSH{events:make(chan mockSSHResult, 16),done:make(chan struct{})}
    go func(){
        defer close(m.done)
        defer serverConn.Close()
        server, channels, requests, err := ssh.NewServerConn(serverConn,serverConfig)
        if err != nil { return }
        defer server.Close()
        go ssh.DiscardRequests(requests)
        for newChannel := range channels {
            if newChannel.ChannelType() != "session" {
                newChannel.Reject(ssh.UnknownChannelType, "only session")
                continue
            }
            channel, reqs, err := newChannel.Accept()
            if err != nil { return }
            go func(){
                defer channel.Close()
                for req := range reqs {
                    switch req.Type {
                    case "exec":
                        var data struct{ Command string }
                        if ssh.Unmarshal(req.Payload, &data) != nil {
                            req.Reply(false,nil); return
                        }
                        req.Reply(true,nil)
                        input, _ := io.ReadAll(channel)
                        m.events <- mockSSHResult{command:data.Command,stdin:string(input)}
                        channel.Write([]byte("mock-output\n"))
                        channel.SendRequest("exit-status",false,ssh.Marshal(struct{ Status uint32 }{exitStatus}))
                        return
                    case "subsystem":
                        var data struct{ Name string }
                        if ssh.Unmarshal(req.Payload, &data) != nil || data.Name != "sftp" {
                            req.Reply(false,nil);return
                        }
                        req.Reply(true,nil)
                        srv, err := sftp.NewServer(channel)
                        if err != nil {return}
                        srv.Serve()
                        srv.Close()
                        return
                    default:
                        req.Reply(false,nil)
                    }
                }
            }()
        }
    }()
    config := &ssh.ClientConfig{
        User:"mobile",
        Auth:[]ssh.AuthMethod{ssh.Password("mock-ssh-login")},
        HostKeyCallback:ssh.FixedHostKey(signer.PublicKey()),
        Timeout:5*time.Second,
    }
    conn, chans, reqs, err := ssh.NewClientConn(clientConn,"mock:22",config)
    if err != nil {clientConn.Close();t.Fatal(err)}
    m.client=ssh.NewClient(conn,chans,reqs)
    t.Cleanup(func(){
        m.closeOnce.Do(func(){m.client.Close()})
        select {case <-m.done: case <-time.After(2*time.Second): t.Error("mock server did not close")}
    })
    return m
}

func TestMobileSudoSSHWireProtocolAndNoArgvSecret(t *testing.T) {
    m:=newMockSSH(t,0)
    d:=&sshDevice{ssh:m.client,sudoPassword:"FAKE_LOCAL_SUDO_SECRET"}
    out,err:=d.run("id -u",nil)
    if err!=nil || string(out)!="mock-output\n" {t.Fatalf("SSH exec failed: %v output=%q",err,out)}
    select {
    case e:=<-m.events:
        if strings.Contains(e.command,d.sudoPassword) {t.Fatal("sudo secret leaked to exec argv")}
        if !strings.Contains(e.command,"sudo -S") ||
           !strings.Contains(e.command,"sudo -n") {t.Fatalf("not sudo mediated: %q",e.command)}
        if e.stdin!="FAKE_LOCAL_SUDO_SECRET\n" {t.Fatalf("stdin mismatch, bytes=%d",len(e.stdin))}
    case <-time.After(time.Second):t.Fatal("missing remote exec")
    }
}

func TestMobileSFTPFileWriteReadAndMode(t *testing.T) {
    m:=newMockSSH(t,0)
    client,err:=sftp.NewClient(m.client)
    if err!=nil {t.Fatal(err)}
    d:=&sshDevice{ssh:m.client,sftp:client,dir:t.TempDir(),sudoPassword:"FAKE_LOCAL_SUDO_SECRET"}
    p,err:=d.writeFile("test.ios",[]byte("test-binary"),true)
    if err!=nil {t.Fatal(err)}
    got,err:=d.readFile(p)
    if err!=nil || string(got)!="test-binary" {t.Fatalf("SFTP read: %v %q",err,got)}
    info,err:=os.Stat(p)
    if err!=nil {t.Fatal(err)}
    if info.Mode().Perm()!=0700 {t.Fatalf("file mode %v",info.Mode())}
    if _,err:=d.writeFile("../escape",[]byte("bad"),false);err==nil {t.Fatal("traversal accepted")}
    d.close()
}

func TestSudoFailureSurfacedWithoutLeakingPassword(t *testing.T) {
    m:=newMockSSH(t,7)
    d:=&sshDevice{ssh:m.client,sudoPassword:"FAKE_DO_NOT_LOG"}
    _,err:=d.run("id -u",nil)
    if err==nil {t.Fatal("remote exit 7 treated as success")}
    if strings.Contains(err.Error(),d.sudoPassword) {t.Fatal("secret leaked into error")}
}

func TestSFTPPathReadIsConfined(t *testing.T) {
    d:=&sshDevice{dir:"/var/tmp/fp-retrieve-testing"}
    if _,err:=d.readFile("/etc/shadow");err==nil ||
       !strings.Contains(err.Error(),"approved") {t.Fatalf("out of scope read: %v",err)}
}
