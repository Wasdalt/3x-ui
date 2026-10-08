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

// 5. Модальные окна (Запрос демо и Вход в кабинет)
function initModals() {
  // Модалка Демо
  const demoModal = document.getElementById('demoModal');
  const demoButtons = document.querySelectorAll('.btn-trigger-demo');
  const closeDemo = document.getElementById('closeDemoModal');
  const demoForm = document.getElementById('demoForm');

  demoButtons.forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.preventDefault();
      if (demoModal) demoModal.classList.add('active');
    });
  });

  if (closeDemo && demoModal) {
    closeDemo.addEventListener('click', () => demoModal.classList.remove('active'));
  }

  if (demoForm) {
    demoForm.addEventListener('submit', (e) => {
      e.preventDefault();
      const submitBtn = demoForm.querySelector('button[type="submit"]');
      submitBtn.textContent = 'Отправка заявки...';
      submitBtn.disabled = true;

      setTimeout(() => {
        const refId = '#ЗАЯВКА-' + Math.floor(10000 + Math.random() * 90000);
        demoForm.innerHTML = `
          <div style="text-align:center; padding: 2rem 0;">
            <div style="width: 52px; height: 52px; border-radius: 50%; background: rgba(16,185,129,0.15); border: 2px solid var(--accent-emerald); display:inline-flex; align-items:center; justify-content:center; color: var(--accent-emerald); margin-bottom: 1rem;">
              <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="20 6 9 17 4 12"/></svg>
            </div>
            <h3 style="margin-bottom:0.5rem;">Заявка успешно принята</h3>
            <p style="color:var(--text-muted); font-size:0.95rem; margin-bottom:1.5rem;">Номер обращения: <strong>${refId}</strong>. Наш инженер по интеграции свяжется с вами в течение 2 часов.</p>
            <button class="btn btn-secondary" onclick="document.getElementById('demoModal').classList.remove('active')">Закрыть</button>
          </div>
        `;
      }, 800);
    });
  }

  // Модалка Личного кабинета
  const portalModal = document.getElementById('portalModal');
  const portalButtons = document.querySelectorAll('.btn-trigger-portal');
  const closePortal = document.getElementById('closePortalModal');
  const portalForm = document.getElementById('portalForm');

  portalButtons.forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.preventDefault();
      if (portalModal) portalModal.classList.add('active');
    });
  });

  if (closePortal && portalModal) {
    closePortal.addEventListener('click', () => portalModal.classList.remove('active'));
  }

  if (portalForm) {
    portalForm.addEventListener('submit', (e) => {
      e.preventDefault();
      const errBox = document.getElementById('portalErrorBox');
      const submitBtn = portalForm.querySelector('button[type="submit"]');
      submitBtn.textContent = 'Проверка ключа доступа...';
      submitBtn.disabled = true;

      setTimeout(() => {
        submitBtn.textContent = 'Войти в кабинет';
        submitBtn.disabled = false;
        if (errBox) {
          errBox.style.display = 'block';
          errBox.textContent = 'Уведомление безопасности: Прямой доступ к панели тенанта требует аппаратного FIDO2-ключа или профиля корпоративного SSO.';
        }
      }, 1000);
    });
  }

  window.addEventListener('click', (e) => {
    if (e.target === demoModal) demoModal.classList.remove('active');
    if (e.target === portalModal) portalModal.classList.remove('active');
  });
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
