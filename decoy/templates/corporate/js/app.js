// Интерактивный движок консалтинговой практики Apex Advisory
document.addEventListener('DOMContentLoaded', () => {
  initMaturityQuiz();
  initProjectEstimator();
  initRfpForm();
});

// 1. Опросник цифровой зрелости IT
function initMaturityQuiz() {
  const steps = document.querySelectorAll('.quiz-step');
  const bar = document.getElementById('quizBar');
  let currentStep = 0;
  let score = 0;

  document.querySelectorAll('.quiz-opt').forEach(opt => {
    opt.addEventListener('click', () => {
      const parent = opt.closest('.quiz-step');
      parent.querySelectorAll('.quiz-opt').forEach(o => o.classList.remove('selected'));
      opt.classList.add('selected');

      const points = parseInt(opt.dataset.points || '20', 10);
      score += points;

      currentStep++;
      if (bar) bar.style.width = `${((currentStep + 1) / steps.length) * 100}%`;

      setTimeout(() => {
        steps.forEach(s => s.classList.remove('active'));
        if (steps[currentStep]) {
          steps[currentStep].classList.add('active');
        } else {
          showResult(score);
        }
      }, 350);
    });
  });

  function showResult(finalScore) {
    const resultPanel = document.getElementById('quizResultPanel');
    const scoreDisplay = document.getElementById('maturityScoreDisplay');
    const verdictDisplay = document.getElementById('maturityVerdictDisplay');

    steps.forEach(s => s.classList.remove('active'));
    if (resultPanel) {
      resultPanel.classList.add('active');
      const normalized = Math.min(96, Math.max(48, finalScore));
      if (scoreDisplay) scoreDisplay.textContent = `${normalized} / 100`;

      if (verdictDisplay) {
        if (normalized > 75) {
          verdictDisplay.textContent = 'Стратегический лидер (Готовность к распределенному масштабированию)';
        } else {
          verdictDisplay.textContent = 'Трансформируемый контур (Рекомендуется архитектурный спринт)';
        }
      }
    }
  }

  const restartBtn = document.getElementById('restartQuizBtn');
  if (restartBtn) {
    restartBtn.addEventListener('click', () => {
      currentStep = 0;
      score = 0;
      if (bar) bar.style.width = '25%';
      document.querySelectorAll('.quiz-opt').forEach(o => o.classList.remove('selected'));
      document.getElementById('quizResultPanel').classList.remove('active');
      steps[0].classList.add('active');
    });
  }
}

// 2. Калькулятор бюджета проекта
function initProjectEstimator() {
  const scopeSelect = document.getElementById('estScope');
  const sizeSelect = document.getElementById('estSize');
  const budgetDisplay = document.getElementById('estBudget');
  const timelineDisplay = document.getElementById('estTimeline');

  if (!scopeSelect || !sizeSelect) return;

  function update() {
    const scope = scopeSelect.value;
    const size = sizeSelect.value;

    let baseRub = 2500000;
    let weeks = 6;

    if (scope === 'cloud') { baseRub = 3800000; weeks = 8; }
    if (scope === 'security') { baseRub = 2900000; weeks = 6; }
    if (scope === 'erp') { baseRub = 6500000; weeks = 14; }

    if (size === 'mid') { baseRub *= 1.4; weeks += 2; }
    if (size === 'ent') { baseRub *= 2.2; weeks += 6; }

    const low = Math.round(baseRub * 0.9);
    const high = Math.round(baseRub * 1.25);

    if (budgetDisplay) budgetDisplay.textContent = `${low.toLocaleString('ru-RU')} ₽ - ${high.toLocaleString('ru-RU')} ₽`;
    if (timelineDisplay) timelineDisplay.textContent = `${weeks} - ${weeks + 3} недель`;
  }

  scopeSelect.addEventListener('change', update);
  sizeSelect.addEventListener('change', update);
  update();
}

// 3. Форма запроса предложения
function initRfpForm() {
  const form = document.getElementById('rfpForm');

  if (!form) return;

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    const btn = form.querySelector('button[type="submit"]');
    btn.textContent = 'Регистрация запроса...';
    btn.disabled = true;

    setTimeout(() => {
      const code = 'APX-' + Math.floor(1000 + Math.random() * 9000);
      form.innerHTML = `
        <div style="background:#090e1a; border:1px solid var(--border); border-radius:8px; padding:2rem; text-align:center;">
          <h3 style="color:var(--gold); margin-bottom:0.5rem;">Запрос успешно зарегистрирован</h3>
          <p style="color:var(--muted); font-size:0.95rem;">Номер обращения: <strong>${code}</strong>. Ведущий партнер практики свяжется с вами в течение рабочего дня.</p>
        </div>
      `;
    }, 850);
  });
}
