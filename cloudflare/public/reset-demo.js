// Fictional messages in the real menu structure. No OS notifications or feed requests.
(() => {
 const root = document.querySelector('[data-reset-demo]');
 if (!root) return;
 const en = document.documentElement.lang === 'en';
 const copy = (zh, english) => en ? english : zh;
 const banner = root.querySelector('[data-demo-notification]');
 const inbox = root.querySelector('[data-demo-inbox]');
 const count = root.querySelector('[data-demo-unread]');
 const status = root.querySelector('[data-demo-status]');
 const bell = root.querySelector('.hero-alert-bell');
 const pause = root.querySelector('[data-pause-motion]');
 const history = root.querySelector('[data-reset-history]');
 const historyButton = root.querySelector('[data-demo-history]');
 let unread = false, timer, exitAnimation;
 const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
 const cancelArrival = () => { clearTimeout(timer); timer = undefined; };
 function paint() {
  root.dataset.unread = String(unread);
  bell.hidden = !unread;
  count.textContent = unread ? '1' : '';
  count.hidden = !unread;
  root.querySelector('[data-read-all-alert]').hidden = !unread;
  inbox.querySelector('[data-read-alert]').hidden = !unread;
  inbox.querySelector('[data-row-read]').hidden = unread;
 }
 function retractNotification() {
  if (banner.hidden) return;
  exitAnimation?.cancel();
  if (reducedMotion.matches || root.classList.contains('demo-motion-paused') || !banner.animate) {
   banner.hidden = true; return;
  }
  const motion = banner.animate([
   {opacity:1, transform:'translateX(0)'},
   {opacity:0, transform:'translateX(20px)'}
  ], {duration:160, easing:'cubic-bezier(.25,1,.5,1)'});
  exitAnimation = motion;
  motion.finished.then(() => {
   if (exitAnimation === motion) { banner.hidden = true; exitAnimation = undefined; }
  }).catch(() => {});
 }
 function openInbox() {
  root.classList.remove('hero-menu-closed');
  inbox.focus({preventScroll:true});
  status.textContent = copy('左键菜单已打开。查看消息不算已读；确认后菜单保持打开。', 'Left-click menu open. Viewing is not acknowledgement; marking read keeps it open.');
 }
 function deliver() {
  cancelArrival(); exitAnimation?.cancel(); exitAnimation = undefined; unread = true; paint(); banner.hidden = false;
  root.classList.remove('hero-menu-closed');
  status.textContent = copy('重置消息出现在左键菜单顶部。关闭通知仍未读；确认后停止提醒。', 'Reset updates appear at the top of the left-click menu. Dismiss keeps unread; mark read to stop.');
  root.dataset.demoState = 'unread';
 }
 function acknowledge() {
  cancelArrival(); unread = false; retractNotification(); paint();
  status.textContent = copy('已确认。左键菜单保持打开，最新线索常驻；额度、任务与连接继续显示。', 'Read. The menu stays open with the latest signal. Quotas, tasks and connections remain visible.');
  root.dataset.demoState = 'read';
 }
 root.querySelectorAll('[data-read-alert], [data-read-all-alert]').forEach(button => button.addEventListener('click', acknowledge));
 function viewNotification() {
  retractNotification();
  openInbox();
  root.dataset.demoState = 'viewed';
 }
 root.querySelectorAll('[data-open-inbox]').forEach(button => button.addEventListener('click', () => {
  if (banner.contains(button)) viewNotification(); else openInbox();
 }));
 banner.addEventListener('click', event => {
  if (!event.target.closest('button, a')) viewNotification();
 });
 banner.addEventListener('keydown', event => {
  if (event.target === banner && ['Enter', ' '].includes(event.key)) {
   event.preventDefault(); viewNotification();
  }
 });
 root.querySelectorAll('[data-view-reset-source]').forEach(link => link.addEventListener('click', () => {
  root.classList.add('hero-menu-closed');
  status.textContent = copy('原文在新标签打开，左键菜单已关闭；已读状态不变。点菜单栏图标可重新打开。', 'Source opens in a new tab and closes the menu; read state is unchanged. Click the menu-bar icon to reopen.');
 }));
 historyButton.addEventListener('click', () => {
  history.hidden = !history.hidden;
  historyButton.setAttribute('aria-expanded', String(!history.hidden));
 });
 root.querySelector('[data-refresh-alert]').addEventListener('click', () => {
  status.textContent = copy('已检查两个示例来源，消息未变；刷新不自动确认已读。', 'Both sample sources checked. No change; refreshing does not mark messages read.');
 });
 root.querySelector('[data-dismiss-alert]').addEventListener('click', () => {
  retractNotification();
  status.textContent = copy('通知已关闭，左键菜单仍有未读；应用会每 5 分钟再次提醒。', 'Notification dismissed; the menu still has unread updates. The app reminds you every 5 minutes.');
  root.dataset.demoState = 'dismissed';
 });
 root.querySelector('[data-replay-alert]').addEventListener('click', deliver);
 pause.addEventListener('click', () => {
  const paused = root.classList.toggle('demo-motion-paused');
  pause.setAttribute('aria-pressed', String(paused));
  pause.textContent = paused ? copy('继续动画', 'Resume motion') : copy('暂停动画', 'Pause motion');
 });
 document.querySelector('.hero-copy a[href="#hero-reset-experience"]')?.addEventListener('click', deliver);
 banner.hidden = true; paint();
 root.dataset.demoState = 'waiting';
 status.textContent = copy('额度、任务与连接实时可见，正在留意重置消息……', 'Quotas, tasks and connections in view. Watching for reset announcements…');
 timer = setTimeout(deliver, reducedMotion.matches ? 0 : 1100);
 if ('IntersectionObserver' in window) {
  new IntersectionObserver(entries => root.classList.toggle('demo-offscreen', !entries[0].isIntersecting)).observe(root);
 }
 document.addEventListener('visibilitychange', () => root.classList.toggle('demo-page-hidden', document.hidden));
 window.addEventListener('pagehide', cancelArrival, {once:true});
})();
