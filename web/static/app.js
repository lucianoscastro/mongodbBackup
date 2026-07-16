// Dashboard: pinta o estado vindo de /api/state e dispara backup/restore.
// Poll de 5s no idle, 2s com job rodando.

let watching = null; // id do job cujo log está aberto

async function api(path, opts) {
  const res = await fetch(path, opts);
  if (res.status === 401) { location.href = '/login'; throw new Error('sessão expirada'); }
  return res;
}

function fmtSize(bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (bytes >= 1024 && i < units.length - 1) { bytes /= 1024; i++; }
  return bytes.toFixed(i === 0 ? 0 : 1) + ' ' + units[i];
}

function fmtDate(iso) {
  return iso ? new Date(iso).toLocaleString('pt-BR') : '—';
}

function el(tag, text, cls) {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  if (cls) e.className = cls;
  return e;
}

function badge(text, cls) {
  return el('span', text, 'badge ' + cls);
}

async function startBackup(engine) {
  const res = await api('/api/backup', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ engine }),
  });
  if (res.status === 409) { alert('Já existe um job em execução. Aguarde.'); return; }
  if (!res.ok) { alert('Falha ao iniciar o backup: ' + await res.text()); return; }
  watching = (await res.json()).job;
  refresh();
}

async function startRestore(b) {
  const typed = prompt(
    `RESTORE de "${b.db}" (${b.engine}) a partir de:\n${b.file}\n\n` +
    'Isso SOBRESCREVE os dados atuais da base. Digite o nome da base para confirmar:');
  if (typed === null) return;
  if (typed !== b.db) { alert('Nome não confere. Restore cancelado.'); return; }

  let drop = false;
  if (b.engine === 'mongo') {
    drop = confirm('Apagar as coleções antes de restaurar (--drop)?\nOK = sim, Cancelar = não');
  }

  const res = await api('/api/restore', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ engine: b.engine, db: b.db, file: b.file, drop }),
  });
  if (res.status === 409) { alert('Já existe um job em execução. Aguarde.'); return; }
  if (!res.ok) { alert('Falha ao iniciar o restore: ' + await res.text()); return; }
  watching = (await res.json()).job;
  refresh();
}

async function showJob(id) {
  watching = id;
  const res = await api('/api/jobs/' + id);
  if (!res.ok) return;
  const j = await res.json();
  const out = document.getElementById('job-output');
  out.textContent = `— job #${j.id} (${j.kind}) · ${j.status} —\n\n` + (j.output || '(sem saída)');
  out.classList.remove('hidden');
}

function render(state) {
  document.getElementById('running-badge').classList.toggle('hidden', !state.running);

  const engines = document.querySelector('#engines tbody');
  engines.replaceChildren(...state.engines.map((e) => {
    const tr = el('tr');
    tr.append(el('td', e.label));
    tr.append(el('td', e.host || '—'));
    const st = el('td');
    if (e.reachable === null) st.append(badge('configurado', 'badge-idle'));
    else if (e.reachable) st.append(badge('online', 'badge-ok'));
    else st.append(badge('inacessível', 'badge-err'));
    tr.append(st);
    const act = el('td');
    const btn = el('button', 'Backup agora');
    btn.addEventListener('click', () => startBackup(e.name));
    act.append(btn);
    tr.append(act);
    return tr;
  }));

  const backups = document.querySelector('#backups tbody');
  document.getElementById('no-backups').classList.toggle('hidden', state.backups.length > 0);
  backups.replaceChildren(...state.backups.map((b) => {
    const tr = el('tr');
    tr.append(el('td', b.engine), el('td', b.db), el('td', b.file, 'mono'),
      el('td', fmtSize(b.size)), el('td', fmtDate(b.mtime)));
    const act = el('td');
    const btn = el('button', 'Restaurar', 'btn-danger');
    btn.addEventListener('click', () => startRestore(b));
    act.append(btn);
    tr.append(act);
    return tr;
  }));

  const jobs = document.querySelector('#jobs tbody');
  document.getElementById('no-jobs').classList.toggle('hidden', state.jobs.length > 0);
  jobs.replaceChildren(...state.jobs.map((j) => {
    const tr = el('tr');
    tr.append(el('td', '#' + j.id), el('td', j.kind));
    const st = el('td');
    st.append(badge(j.status,
      j.status === 'ok' ? 'badge-ok' : j.status === 'erro' ? 'badge-err' : 'badge-run'));
    tr.append(st);
    tr.append(el('td', fmtDate(j.started)), el('td', fmtDate(j.ended)));
    const act = el('td');
    const btn = el('button', 'Log', 'btn-ghost');
    btn.addEventListener('click', () => showJob(j.id));
    act.append(btn);
    tr.append(act);
    return tr;
  }));
}

let timer = null;

async function refresh() {
  try {
    const res = await api('/api/state');
    if (!res.ok) return;
    const state = await res.json();
    render(state);
    if (watching !== null) await showJob(watching);
    clearTimeout(timer);
    timer = setTimeout(refresh, state.running ? 2000 : 5000);
  } catch {
    clearTimeout(timer);
    timer = setTimeout(refresh, 5000);
  }
}

document.getElementById('backup-all').addEventListener('click', () => startBackup('all'));
refresh();
