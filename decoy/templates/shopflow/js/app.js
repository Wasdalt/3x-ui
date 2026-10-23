// Интерактивный движок платформы ShopFlow (Клиентская часть)
document.addEventListener('DOMContentLoaded', () => {
  initLiveOrderStream();
  initRoiCalculator();
  initPricingToggle();
  initCategoryTabs();
  initModals();
  initFaqAccordion();
  initMobileNav();
  initSystemClock();
  document.querySelectorAll('[data-site-origin]').forEach(el => {
    el.textContent = window.location.origin;
  });
});

// 1. Симуляция потока заказов в реальном времени
function initLiveOrderStream() {
  const streamContainer = document.getElementById('orderStreamList');
  if (!streamContainer) return;

  const sampleNodes = ['Москва', 'Санкт-Петербург', 'Хельсинки', 'Таллин', 'Франкфурт', 'Алматы', 'Минск', 'Екатеринбург'];
  const sampleStatuses = ['Оплачен', 'Передан в доставку', 'Склад зарезервирован', 'Чек сформирован', 'Синхронизация завершена'];

  function pushOrder() {
    const orderId = '#ЗАКАЗ-' + Math.floor(1000 + Math.random() * 9000);
    const node = sampleNodes[Math.floor(Math.random() * sampleNodes.length)];
    const status = sampleStatuses[Math.floor(Math.random() * sampleStatuses.length)];
    const latency = Math.floor(8 + Math.random() * 24);

    const entry = document.createElement('div');
    entry.className = 'order-log-entry';
    entry.innerHTML = `
      <div>
        <strong style="color:var(--text-main);">${orderId}</strong>
        <span style="color:var(--text-muted); margin-left: 0.5rem;">[${node}]</span>
      </div>
      <div>
        <span style="color:var(--accent-emerald); font-weight:600;">${status}</span>
        <span class="log-meta" style="margin-left: 0.75rem;">${latency} мс</span>
      </div>
    `;

    streamContainer.insertBefore(entry, streamContainer.firstChild);
    while (streamContainer.children.length > 5) {
      streamContainer.removeChild(streamContainer.lastChild);
    }
  }

  for (let i = 0; i < 4; i++) pushOrder();
  setInterval(pushOrder, 3000);
}

// 2. Интерактивный калькулятор окупаемости и экономии
function initRoiCalculator() {
  const slider = document.getElementById('orderVolumeSlider');
  const volumeDisplay = document.getElementById('orderVolumeDisplay');
  const savingsDisplay = document.getElementById('savingsValueDisplay');
  const latencyDisplay = document.getElementById('latencyValueDisplay');

  if (!slider || !volumeDisplay || !savingsDisplay) return;

  function update() {
    const val = parseInt(slider.value, 10);
    volumeDisplay.textContent = Number(val).toLocaleString('ru-RU') + ' заказов / мес';

    // Экономия: ~4.2 руб на заказе за счет оптимизации маршрутизации
    const savings = Math.round(val * 4.2);
    savingsDisplay.textContent = Number(savings).toLocaleString('ru-RU') + ' ₽';

    if (latencyDisplay) {
      const avgLat = Math.max(12, Math.round(34 - (val / 500000) * 16));
      latencyDisplay.textContent = avgLat + ' мс в среднем';
    }
  }

  slider.addEventListener('input', update);
  update();
}

// 3. Переключатель тарифов (Помесячно / За год со скидкой)
function initPricingToggle() {
  const toggle = document.getElementById('billingToggle');
  if (!toggle) return;

  const starterPrice = document.getElementById('starterPrice');
  const growthPrice = document.getElementById('growthPrice');
  const enterprisePrice = document.getElementById('enterprisePrice');

  let isAnnual = false;

  toggle.addEventListener('click', () => {
    isAnnual = !isAnnual;
    toggle.classList.toggle('active', isAnnual);

    if (isAnnual) {
      if (starterPrice) starterPrice.textContent = '3 900 ₽';
      if (growthPrice) growthPrice.textContent = '15 900 ₽';
      if (enterprisePrice) enterprisePrice.textContent = '49 000 ₽';
    } else {
      if (starterPrice) starterPrice.textContent = '4 900 ₽';
      if (growthPrice) growthPrice.textContent = '19 900 ₽';
      if (enterprisePrice) enterprisePrice.textContent = '59 000 ₽';
    }
  });
}

// 4. Фильтр модулей платформы
function initCategoryTabs() {
  const tabs = document.querySelectorAll('.tab-btn');
  const cards = document.querySelectorAll('.feature-filterable');

  if (!tabs.length || !cards.length) return;

  tabs.forEach(tab => {
    tab.addEventListener('click', () => {
      tabs.forEach(t => t.classList.remove('active'));
      tab.classList.add('active');

      const category = tab.dataset.category || 'all';

      cards.forEach(card => {
        if (category === 'all' || card.dataset.category === category) {
          card.style.display = 'block';
          card.style.animation = 'fadeIn 0.3s ease';
        } else {
          card.style.display = 'none';
        }
      });
    });
  });
}

// 5. Локальное демо: без отправки заявок, учётных данных и сетевых запросов.
function initModals() {
  const demoModal = document.getElementById('demoModal');
  const portalModal = document.getElementById('portalModal');
  const demoForm = document.getElementById('demoForm');
  let previousFocus = null;

  function close(modal) {
    if (!modal) return;
    modal.classList.remove('active');
    modal.setAttribute('aria-hidden', 'true');
    if (previousFocus) previousFocus.focus();
  }

  function open(modal, view) {
    if (!modal) {
      window.location.assign('/?view=' + view);
      return;
    }
    previousFocus = document.activeElement;
    modal.classList.add('active');
    modal.setAttribute('aria-hidden', 'false');
    const first = modal.querySelector('button, input, a');
    if (first) first.focus();
  }

  [[demoModal, 'closeDemoModal'], [portalModal, 'closePortalModal']].forEach(([modal, id]) => {
    if (!modal) return;
    modal.setAttribute('role', 'dialog');
    modal.setAttribute('aria-modal', 'true');
    modal.setAttribute('aria-label', modal === demoModal ? 'Интерактивный расчёт' : 'Доступ к кабинету');
    modal.setAttribute('aria-hidden', 'true');
    const button = document.getElementById(id);
    if (button) button.addEventListener('click', () => close(modal));
    modal.addEventListener('click', e => { if (e.target === modal) close(modal); });
  });

  [['.btn-trigger-demo', demoModal, 'demo'], ['.btn-trigger-portal', portalModal, 'portal']].forEach(([selector, modal, view]) => {
    document.querySelectorAll(selector).forEach(button => {
      button.addEventListener('click', e => { e.preventDefault(); open(modal, view); });
    });
  });

  if (demoForm) {
    demoForm.addEventListener('submit', e => {
      e.preventDefault();
      const count = Number(document.getElementById('demoOrderCount').value);
      const result = document.getElementById('demoResult');
      if (!Number.isInteger(count) || count < 1 || count > 10000000) {
        result.textContent = 'Введите целое число заказов от 1 до 10 000 000.';
        return;
      }
      result.textContent = 'Ориентировочная экономия: ' + Math.round(count * 4.2).toLocaleString('ru-RU') + ' ₽ / мес. Это локальный расчёт, заявка не отправлена.';
    });
  }

  document.addEventListener('keydown', e => {
    const active = [demoModal, portalModal].find(modal => modal && modal.classList.contains('active'));
    if (!active) return;
    if (e.key === 'Escape') close(active);
    if (e.key === 'Tab') {
      const items = active.querySelectorAll('button, input, a');
      const first = items[0], last = items[items.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    }
  });
  const view = new URLSearchParams(window.location.search).get('view');
  if (view === 'demo' && demoModal) open(demoModal, view);
  if (view === 'portal' && portalModal) open(portalModal, view);
}

// 6. Аккордеон FAQ
function initFaqAccordion() {
  const faqItems = document.querySelectorAll('.faq-item');
  faqItems.forEach(item => {
    const q = item.querySelector('.faq-question');
    if (!q) return;
    q.addEventListener('click', () => {
      const isOpen = item.classList.contains('open');
      faqItems.forEach(i => i.classList.remove('open'));
      if (!isOpen) item.classList.add('open');
    });
  });
}

// 7. Мобильное меню
function initMobileNav() {
  const toggle = document.querySelector('.mobile-toggle');
  const nav = document.querySelector('.nav-links');
  if (!toggle || !nav) return;

  toggle.addEventListener('click', () => {
    const visible = nav.style.display === 'flex';
    nav.style.display = visible ? 'none' : 'flex';
    if (!visible) {
      nav.style.flexDirection = 'column';
      nav.style.position = 'absolute';
      nav.style.top = '100%';
      nav.style.left = '0';
      nav.style.right = '0';
      nav.style.background = 'rgba(11, 15, 25, 0.98)';
      nav.style.padding = '1.5rem';
      nav.style.borderBottom = '1px solid var(--border-subtle)';
    }
  });
}

// 8. Системные часы сервера
function initSystemClock() {
  const clockEl = document.getElementById('systemClockUtc');
  if (!clockEl) return;

  function tick() {
    const now = new Date();
    clockEl.textContent = 'Время кластера: ' + now.toLocaleTimeString('ru-RU') + ' MSK';
  }
  tick();
  setInterval(tick, 1000);
}
