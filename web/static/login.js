const msgs = {
  cred: 'Usuário ou senha incorretos.',
  lock: 'Muitas tentativas. Aguarde 15 minutos e tente de novo.',
};
const e = new URLSearchParams(location.search).get('e');
if (e && msgs[e]) {
  const el = document.getElementById('err');
  el.textContent = msgs[e];
  el.classList.remove('hidden');
}
