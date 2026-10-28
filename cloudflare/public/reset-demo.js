// A fictional, in-page preview. Never asks for OS notifications or contacts a feed.
(() => {
 const root = document.querySelector('[data-reset-demo]');
 if (!root) return;
 const en = document.documentElement.lang === 'en';
 const copy = (zh, english) => en ? english : zh;
 const scene = root.querySelector('[data-reset-scene]');
 const banner = root.querySelector('[data-demo-notification]');
 const inbox = root.querySelector('[data-demo-inbox]');
 const count = root.querySelector('[data-demo-unread]');
 const status = root.querySelector('[data-demo-status]');
 const bell = root.querySelector('.hero-alert-bell');
 const pause = root.querySelector('[data-pause-motion]');
 const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
 let unread = false, mode = 'reset', timer;
 const cancelArrival = () => { clearTimeout(timer); timer = undefined; };
 function paint() {
  root.dataset.unread = String(unread);
  bell.hidden = !unread || mode !== 'reset';
  count.textContent = unread ? copy('1 条未读', '1 unread') : copy('已确认', 'Read');
  inbox.querySelector('[data-read-alert]').disabled = !unread;
  inbox.querySelector('[data-read-alert]').textContent = unread ? copy('确认已读', 'Mark as read') : copy('已确认 ✓', 'Read ✓');
 }
 function deliver() {
  cancelArrival(); unread = true; paint(); banner.hidden = false;
  status.textContent = copy('试着关掉通知：铃铛仍会提醒。确认已读，才会停止。', 'Try dismissing the notification: the bell stays on. Mark it read to stop.');
  root.dataset.demoState = 'unread';
 }
 function acknowledge() {
  cancelArrival(); unread = false; banner.hidden = true; paint();
  status.textContent = copy('已确认。闪烁和重复提醒停止，最新线索仍留在这里。', 'Read. Blinking and repeat reminders stop. The latest signal stays here.');
  root.dataset.demoState = 'read';
 }
 function openInbox() {
  inbox.focus({preventScroll: true});
  status.textContent = copy('查看消息不等于已读；点击「确认已读」才会停止提醒。', 'Viewing is not acknowledgement. Choose “Mark as read” to stop reminders.');
 }
 root.querySelectorAll('[data-read-alert]').forEach(button => button.addEventListener('click', acknowledge));
 root.querySelectorAll('[data-open-inbox]').forEach(button => button.addEventListener('click', openInbox));
 root.querySelector('[data-dismiss-alert]').addEventListener('click', () => {
  banner.hidden = true;
  status.textContent = copy('通知已关闭，消息仍未读。应用会每 5 分钟再次提醒。', 'Notification dismissed; still unread. The app reminds you again every 5 minutes.');
  root.dataset.demoState = 'dismissed';
 });
 root.querySelector('[data-replay-alert]').addEventListener('click', deliver);
 pause.addEventListener('click', () => {
  const paused = root.classList.toggle('demo-motion-paused');
  pause.setAttribute('aria-pressed', String(paused));
  pause.textContent = paused ? copy('继续动画', 'Resume motion') : copy('暂停动画', 'Pause motion');
 });
 root.querySelectorAll('[data-demo-mode-button]').forEach(button => button.addEventListener('click', () => {
  mode = button.dataset.demoModeButton;
  root.dataset.demoMode = mode;
  scene.hidden = mode !== 'reset';
  root.querySelector('[data-reset-footer]').hidden = mode !== 'reset';
  root.querySelector('.hero-menus').hidden = mode !== 'quota';
  root.querySelectorAll('[data-demo-mode-button]').forEach(b => b.setAttribute('aria-pressed', String(b === button)));
  paint();
 }));
 document.querySelector('.hero-copy a[href="#hero-reset-experience"]')?.addEventListener('click', () => {
  root.querySelector('[data-demo-mode-button="reset"]').click();
  deliver();
 });
 // One arrival only, never an endless autoplay carousel. Unread stays until acknowledged.
 banner.hidden = true; paint();
 root.dataset.demoState = 'waiting';
 status.textContent = copy('正在留意公开重置消息……', 'Keeping watch for public reset announcements…');
 timer = setTimeout(deliver, reducedMotion.matches ? 0 : 1100);
 if ('IntersectionObserver' in window) {
  new IntersectionObserver(entries => {
   root.classList.toggle('demo-offscreen', !entries[0].isIntersecting);
  }).observe(root);
 }
 document.addEventListener('visibilitychange', () => root.classList.toggle('demo-page-hidden', document.hidden));
 window.addEventListener('pagehide', cancelArrival, {once:true});
})();
