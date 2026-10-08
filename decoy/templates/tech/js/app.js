// Интерактивный движок конфигуратора облака Vortex Cloud
document.addEventListener('DOMContentLoaded', () => {
  initConfigurator();
  initLocations();
  initDeployModal();
});

function initConfigurator() {
  const cpuSlider = document.getElementById('cpuSlider');
  const ramSlider = document.getElementById('ramSlider');
  const ssdSlider = document.getElementById('ssdSlider');

  const cpuVal = document.getElementById('cpuValue');
  const ramVal = document.getElementById('ramValue');
  const ssdVal = document.getElementById('ssdValue');

  const summaryCpu = document.getElementById('summaryCpu');
  const summaryRam = document.getElementById('summaryRam');
  const summarySsd = document.getElementById('summarySsd');

  const priceMonthly = document.getElementById('priceMonthly');
  const priceHourly = document.getElementById('priceHourly');

  function calculate() {
    const cpus = parseInt(cpuSlider.value, 10);
    const ram = parseInt(ramSlider.value, 10);
    const ssd = parseInt(ssdSlider.value, 10);

    const cpuWord = cpus === 1 ? 'ядро' : (cpus < 5 ? 'ядра' : 'ядер');
    cpuVal.textContent = `${cpus} vCPU ${cpuWord}`;
    ramVal.textContent = `${ram} ГБ ECC RAM`;
    ssdVal.textContent = `${ssd} ГБ NVMe Gen4`;

    if (summaryCpu) summaryCpu.textContent = `${cpus} ${cpuWord}`;
    if (summaryRam) summaryRam.textContent = `${ram} ГБ`;
    if (summarySsd) summarySsd.textContent = `${ssd} ГБ`;

    // Расчет в рублях: 350 руб/vCPU + 180 руб/ГБ RAM + 6 руб/ГБ NVMe
    const total = Math.round(cpus * 350 + ram * 180 + ssd * 6);
    const hourly = (total / 720).toFixed(2);

    if (priceMonthly) priceMonthly.textContent = `${total.toLocaleString('ru-RU')} ₽`;
    if (priceHourly) priceHourly.textContent = `${hourly} ₽ / час`;
  }

  [cpuSlider, ramSlider, ssdSlider].forEach(slider => {
    if (slider) slider.addEventListener('input', calculate);
  });

  calculate();
}

function initLocations() {
  const locButtons = document.querySelectorAll('.loc-btn');
  const summaryLoc = document.getElementById('summaryLoc');

  locButtons.forEach(btn => {
    btn.addEventListener('click', () => {
      locButtons.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      const locName = btn.dataset.location || 'Хельсинки, FI';
      if (summaryLoc) summaryLoc.textContent = locName;
    });
  });

  // Эмуляция живой задержки сети
  setInterval(() => {
    document.querySelectorAll('.ping-tag').forEach(tag => {
      const base = parseInt(tag.dataset.base || '18', 10);
      const jitter = Math.floor(Math.random() * 4) - 2;
      tag.textContent = `${Math.max(4, base + jitter)} мс`;
    });
  }, 2200);
}

function initDeployModal() {
  const deployBtn = document.getElementById('deployInstanceBtn');
  const modal = document.getElementById('deployModal');
  const closeModal = document.getElementById('closeDeployModal');
  const termBody = document.getElementById('deployTerminalBody');

  if (!deployBtn || !modal) return;

  deployBtn.addEventListener('click', () => {
    modal.classList.add('active');
    termBody.innerHTML = '<div style="color:var(--dim);">Инициализация конвейера развертывания...</div>';

    const steps = [
      '[1/4] Резервирование узла кластера AMD EPYC 9004...',
      '[2/4] Разметка дискового массива NVMe PCIe Gen5 (ext4)...',
      '[3/4] Маршрутизация Anycast IPv4 и выделение префикса /64 IPv6...',
      '[4/4] Генерация ключей SSH и запуск агента cloud-init...',
      '✓ Развертывание завершено! Сервер запущен: vps-8421-srv.mesh'
    ];

    steps.forEach((step, idx) => {
      setTimeout(() => {
        const line = document.createElement('div');
        line.style.marginTop = '0.5rem';
        line.style.color = idx === steps.length - 1 ? 'var(--emerald)' : '#93c5fd';
        line.textContent = step;
        termBody.appendChild(line);
      }, (idx + 1) * 750);
    });
  });

  if (closeModal) {
    closeModal.addEventListener('click', () => modal.classList.remove('active'));
  }
}
