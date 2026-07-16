package main

import (
	"errors"
	"os/exec"
	"sync"
	"time"
)

const (
	maxJobOutput  = 512 * 1024
	maxJobHistory = 30
)

var errBusy = errors.New("já existe um job em execução")

type job struct {
	id      int
	kind    string
	started time.Time
	done    chan struct{}

	mu     sync.Mutex
	status string // executando | ok | erro
	ended  *time.Time
	out    []byte
}

type jobView struct {
	ID      int        `json:"id"`
	Kind    string     `json:"kind"`
	Status  string     `json:"status"`
	Started time.Time  `json:"started"`
	Ended   *time.Time `json:"ended,omitempty"`
}

// job implementa io.Writer: stdout+stderr do script caem direto aqui.
func (j *job) Write(p []byte) (int, error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.out = append(j.out, p...)
	if len(j.out) > maxJobOutput {
		// mantém só o final; o começo do log é o menos útil num job longo
		j.out = append([]byte("[... saída truncada ...]\n"), j.out[len(j.out)-maxJobOutput/2:]...)
	}
	return len(p), nil
}

func (j *job) view() jobView {
	j.mu.Lock()
	defer j.mu.Unlock()
	return jobView{ID: j.id, Kind: j.kind, Status: j.status, Started: j.started, Ended: j.ended}
}

func (j *job) output() string {
	j.mu.Lock()
	defer j.mu.Unlock()
	return string(j.out)
}

func (j *job) ok() bool {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.status == "ok"
}

// Um job por vez: backups e restores concorrentes disputariam disco, rede e o
// próprio servidor de origem — serializar é a proteção mais simples.
type jobManager struct {
	mu      sync.Mutex
	seq     int
	jobs    []*job // mais novo primeiro
	current *job
}

func newJobManager() *jobManager { return &jobManager{} }

func (m *jobManager) start(kind string, cmd *exec.Cmd) (*job, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.current != nil {
		return nil, errBusy
	}

	m.seq++
	j := &job{id: m.seq, kind: kind, status: "executando", started: time.Now(), done: make(chan struct{})}
	cmd.Stdout = j
	cmd.Stderr = j
	if err := cmd.Start(); err != nil {
		return nil, err
	}

	m.current = j
	m.jobs = append([]*job{j}, m.jobs...)
	if len(m.jobs) > maxJobHistory {
		m.jobs = m.jobs[:maxJobHistory]
	}

	go func() {
		err := cmd.Wait()
		now := time.Now()
		j.mu.Lock()
		j.ended = &now
		if err != nil {
			j.status = "erro"
			j.out = append(j.out, []byte("\n[job] "+err.Error()+"\n")...)
		} else {
			j.status = "ok"
		}
		j.mu.Unlock()

		m.mu.Lock()
		m.current = nil
		m.mu.Unlock()
		close(j.done)
	}()
	return j, nil
}

func (m *jobManager) get(id int) *job {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, j := range m.jobs {
		if j.id == id {
			return j
		}
	}
	return nil
}

func (m *jobManager) list() []jobView {
	m.mu.Lock()
	jobs := make([]*job, len(m.jobs))
	copy(jobs, m.jobs)
	m.mu.Unlock()

	out := make([]jobView, len(jobs))
	for i, j := range jobs {
		out[i] = j.view()
	}
	return out
}

func (m *jobManager) running() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.current != nil
}
