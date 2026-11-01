// zurafa-tailscale is Zurafa's own Tailscale device, like Rex's: it joins the tailnet as
// HOSTNAME, serves HTTPS on :443 with the device's *.ts.net certificate, and forwards each
// caller to the daemon's Tailscale Serve socket with the login Tailscale vouches for in
// Tailscale-User-Login. The daemon decides who gets in; this helper only names callers.
//
// stdout: one JSON status line whenever the device's state changes.
// stdin: "logout" signs the device out. EOF (the daemon is gone) stops the helper.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"os"
	"strings"
	"sync"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/tsnet"
)

type status struct {
	State     string   `json:"state"`              // NeedsLogin, Starting, Running, …
	AuthURL   string   `json:"auth_url,omitempty"` // where to sign in while NeedsLogin
	Login     string   `json:"login,omitempty"`    // the device's owner; empty when tagged
	Name      string   `json:"name,omitempty"`     // e.g. my-mac-zurafa.tail1234.ts.net
	Tags      []string `json:"tags,omitempty"`
	Cert      bool     `json:"cert"`                 // the HTTPS certificate is ready
	CertError string   `json:"cert_error,omitempty"` // why it is not, e.g. HTTPS is off for the tailnet
}

var (
	mu   sync.Mutex
	last status
)

func publish(update func(*status)) {
	mu.Lock()
	defer mu.Unlock()
	next := last
	next.Tags = append([]string(nil), last.Tags...)
	update(&next)
	a, _ := json.Marshal(last)
	b, _ := json.Marshal(next)
	if string(a) != string(b) {
		last = next
		os.Stdout.Write(append(b, '\n'))
	}
}

func main() {
	dir := flag.String("dir", "", "state directory")
	hostname := flag.String("hostname", "zurafa", "Tailscale device name")
	socket := flag.String("socket", "", "daemon's Tailscale Serve socket")
	flag.Parse()
	if *dir == "" || *socket == "" {
		log.Fatal("usage: zurafa-tailscale -dir DIR -hostname NAME -socket PATH")
	}

	srv := &tsnet.Server{Dir: *dir, Hostname: *hostname, Logf: func(string, ...any) {}}
	defer srv.Close()
	lc, err := srv.LocalClient()
	if err != nil {
		log.Fatal(err)
	}
	if err := srv.Start(); err != nil {
		log.Fatal(err)
	}
	ctx := context.Background()

	go func() { // The daemon owns this process: stop when it closes stdin.
		in := bufio.NewScanner(os.Stdin)
		for in.Scan() {
			if strings.TrimSpace(in.Text()) == "logout" {
				if err := lc.Logout(ctx); err != nil {
					log.Printf("logout: %v", err)
				}
			}
		}
		srv.Close()
		os.Exit(0)
	}()

	go watch(ctx, lc)

	ln, err := srv.ListenTLS("tcp", ":443")
	if err != nil {
		log.Fatal(err)
	}
	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.Out.URL.Scheme, r.Out.URL.Host = "http", "zurafa"
			// Only this helper may vouch for a caller.
			for name := range r.Out.Header {
				if strings.HasPrefix(strings.ToLower(name), "tailscale-") {
					r.Out.Header.Del(name)
				}
			}
			who, err := lc.WhoIs(r.In.Context(), r.In.RemoteAddr)
			if err == nil && who.Node != nil && !who.Node.IsTagged() && who.UserProfile != nil {
				r.Out.Header.Set("Tailscale-User-Login", who.UserProfile.LoginName)
			}
		},
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", *socket)
		}},
		FlushInterval: -1,
	}
	log.Fatal(http.Serve(ln, proxy))
}

// watch reports the device's state, starts sign-in when it needs one, and fetches the certificate.
func watch(ctx context.Context, lc *local.Client) {
	loginStarted, certFor, certTried := false, "", time.Time{}
	for ; ; time.Sleep(time.Second) {
		st, err := lc.StatusWithoutPeers(ctx)
		if err != nil {
			continue
		}
		if st.BackendState == "NeedsLogin" && st.AuthURL == "" && !loginStarted {
			loginStarted = lc.StartLoginInteractive(ctx) == nil
		}
		if st.BackendState == "Running" {
			loginStarted = false
		}
		name, login, tags := "", "", []string(nil)
		if st.Self != nil {
			name = strings.TrimSuffix(st.Self.DNSName, ".")
			if st.Self.Tags != nil {
				tags = st.Self.Tags.AsSlice()
			}
			if u, ok := st.User[st.Self.UserID]; ok && len(tags) == 0 {
				login = u.LoginName
			}
		}
		publish(func(s *status) {
			s.State, s.AuthURL, s.Name, s.Login, s.Tags = st.BackendState, st.AuthURL, name, login, tags
			if st.BackendState != "Running" {
				s.Cert, s.CertError = false, ""
			}
		})
		if st.BackendState == "Running" && name != "" && certFor != name && time.Since(certTried) > time.Minute {
			certTried = time.Now()
			if _, _, err := lc.CertPair(ctx, name); err != nil {
				publish(func(s *status) { s.CertError = err.Error() })
			} else {
				certFor = name
				publish(func(s *status) { s.Cert, s.CertError = true, "" })
			}
		}
		if st.BackendState != "Running" {
			certFor, certTried = "", time.Time{}
		}
	}
}
