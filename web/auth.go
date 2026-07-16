package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"strconv"
	"strings"
	"sync"
	"time"
)

// --- Sessão: token stateless assinado, base64(user|exp) + "." + base64(hmac) ---

func signToken(secret []byte, user string, exp time.Time) string {
	payload := user + "|" + strconv.FormatInt(exp.Unix(), 10)
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(payload))
	return base64.RawURLEncoding.EncodeToString([]byte(payload)) + "." +
		base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func verifyToken(secret []byte, token string) bool {
	p, sig, found := strings.Cut(token, ".")
	if !found {
		return false
	}
	payload, err := base64.RawURLEncoding.DecodeString(p)
	if err != nil {
		return false
	}
	want, err := base64.RawURLEncoding.DecodeString(sig)
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write(payload)
	if !hmac.Equal(mac.Sum(nil), want) {
		return false
	}
	// LastIndex, não Cut: o nome de usuário pode conter '|'
	i := strings.LastIndexByte(string(payload), '|')
	if i < 0 {
		return false
	}
	exp, err := strconv.ParseInt(string(payload)[i+1:], 10, 64)
	return err == nil && time.Now().Unix() < exp
}

// --- Rate limit de login por IP: 5 falhas → 15 min de bloqueio ---
//
// O IP vem de RemoteAddr, nunca de X-Forwarded-For (forjável). Atrás de um
// reverse proxy todos os clientes dividem o IP do proxy e o bloqueio vira
// global — para uma UI de um único admin, é o trade-off seguro.

const (
	maxLoginFails = 5
	lockDuration  = 15 * time.Minute
)

type failEntry struct {
	count     int
	lockedTil time.Time
	last      time.Time
}

type loginLimiter struct {
	mu    sync.Mutex
	fails map[string]*failEntry
}

func newLoginLimiter() *loginLimiter { return &loginLimiter{fails: map[string]*failEntry{}} }

func (l *loginLimiter) blocked(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	e := l.fails[ip]
	return e != nil && time.Now().Before(e.lockedTil)
}

func (l *loginLimiter) fail(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.gc()
	e := l.fails[ip]
	if e == nil {
		e = &failEntry{}
		l.fails[ip] = e
	}
	e.count++
	e.last = time.Now()
	if e.count >= maxLoginFails {
		e.lockedTil = time.Now().Add(lockDuration)
		e.count = 0
	}
}

func (l *loginLimiter) success(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.fails, ip)
}

// Chamar com l.mu já em posse. Só limpa quando o mapa cresce demais, para a
// memória não ser refém de um scanner de internet.
func (l *loginLimiter) gc() {
	if len(l.fails) < 1000 {
		return
	}
	for ip, e := range l.fails {
		if time.Since(e.last) > time.Hour {
			delete(l.fails, ip)
		}
	}
}
