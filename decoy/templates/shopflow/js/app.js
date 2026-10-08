// ShopFlow Platform Interactive Engine (Client-side)
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

// 1. Live Order Stream Simulation
function initLiveOrderStream() {
  const streamContainer = document.getElementById('orderStreamList');
  if (!streamContainer) return;

  const sampleNodes = ['Tokyo', 'Frankfurt', 'Virginia', 'Singapore', 'London', 'Stockholm', 'São Paulo', 'Sydney'];
  const sampleStatuses = ['Fulfilled', 'Dispatched', 'Sync Completed', 'Payment Cleared', 'Inventory Locked'];

  function pushOrder() {
    const orderId = '#ORD-' + Math.floor(1000 + Math.random() * 9000);
    const node = sampleNodes[Math.floor(Math.random() * sampleNodes.length)];
    const status = sampleStatuses[Math.floor(Math.random() * sampleStatuses.length)];
    const latency = Math.floor(12 + Math.random() * 32);

    const entry = document.createElement('div');
    entry.className = 'order-log-entry';
    entry.innerHTML = `
      <div>
        <strong style="color:var(--text-main);">${orderId}</strong>
        <span style="color:var(--text-muted); margin-left: 0.5rem;">[${node}]</span>
      </div>
      <div>
        <span style="color:var(--accent-emerald); font-weight:600;">${status}</span>
        <span class="log-meta" style="margin-left: 0.75rem;">${latency}ms</span>
      </div>
    `;

    streamContainer.insertBefore(entry, streamContainer.firstChild);
    while (streamContainer.children.length > 5) {
      streamContainer.removeChild(streamContainer.lastChild);
    }
  }

  // Preload initial entries
  for (let i = 0; i < 4; i++) pushOrder();
  setInterval(pushOrder, 3200);
}

// 2. Interactive ROI / Cost Calculator
function initRoiCalculator() {
  const slider = document.getElementById('orderVolumeSlider');
  const volumeDisplay = document.getElementById('orderVolumeDisplay');
  const savingsDisplay = document.getElementById('savingsValueDisplay');
  const latencyDisplay = document.getElementById('latencyValueDisplay');

  if (!slider || !volumeDisplay || !savingsDisplay) return;

  function update() {
    const val = parseInt(slider.value, 10);
    volumeDisplay.textContent = Number(val).toLocaleString() + ' orders / mo';

    // Simulated savings: ~$0.042 per order processed through unified edge
    const savings = Math.round(val * 0.042);
    savingsDisplay.textContent = '$' + Number(savings).toLocaleString();

    if (latencyDisplay) {
      const avgLat = Math.max(14, Math.round(38 - (val / 500000) * 16));
      latencyDisplay.textContent = avgLat + 'ms avg';
    }
  }

  slider.addEventListener('input', update);
  update();
}

// 3. Pricing Toggle (Monthly vs Annual)
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
      if (starterPrice) starterPrice.textContent = '$39';
      if (growthPrice) growthPrice.textContent = '$159';
      if (enterprisePrice) enterprisePrice.textContent = '$559';
    } else {
      if (starterPrice) starterPrice.textContent = '$49';
      if (growthPrice) growthPrice.textContent = '$199';
      if (enterprisePrice) enterprisePrice.textContent = '$699';
    }
  });
}

// 4. Category Filter Tabs
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

// 5. Modals (Portal Login & Demo Request)
function initModals() {
  // Demo Modal
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
      const originalText = submitBtn.textContent;
      submitBtn.textContent = 'Submitting Request...';
      submitBtn.disabled = true;

      setTimeout(() => {
        const refId = '#REQ-' + Math.floor(10000 + Math.random() * 90000);
        demoForm.innerHTML = `
          <div style="text-align:center; padding: 2rem 0;">
            <div style="width: 52px; height: 52px; border-radius: 50%; background: rgba(16,185,129,0.15); border: 2px solid var(--accent-emerald); display:inline-flex; align-items:center; justify-content:center; color: var(--accent-emerald); margin-bottom: 1rem;">
              <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="20 6 9 17 4 12"/></svg>
            </div>
            <h3 style="margin-bottom:0.5rem;">Demo Request Confirmed</h3>
            <p style="color:var(--text-muted); font-size:0.95rem; margin-bottom:1.5rem;">Reference: <strong>${refId}</strong>. An enterprise solution architect will contact you within 2 business hours.</p>
            <button class="btn btn-secondary" onclick="document.getElementById('demoModal').classList.remove('active')">Close</button>
          </div>
        `;
      }, 900);
    });
  }

  // Portal Modal
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
      submitBtn.textContent = 'Verifying Security Token...';
      submitBtn.disabled = true;

      setTimeout(() => {
        submitBtn.textContent = 'Sign In to Portal';
        submitBtn.disabled = false;
        if (errBox) {
          errBox.style.display = 'block';
          errBox.textContent = 'Security Notice: Direct web console login requires hardware FIDO2 key or Single Sign-On (SSO) profile authentication.';
        }
      }, 1100);
    });
  }

  // Close modals on clicking overlay outside content
  window.addEventListener('click', (e) => {
    if (e.target === demoModal) demoModal.classList.remove('active');
    if (e.target === portalModal) portalModal.classList.remove('active');
  });
}

// 6. FAQ Accordion
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

// 7. Mobile Navigation Toggle
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

// 8. Live System Status Clock
function initSystemClock() {
  const clockEl = document.getElementById('systemClockUtc');
  if (!clockEl) return;

  function tick() {
    const now = new Date();
    clockEl.textContent = now.toUTCString().replace('GMT', 'UTC');
  }
  tick();
  setInterval(tick, 1000);
}
