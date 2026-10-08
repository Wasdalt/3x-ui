// Движок веб-инструментов OmniConvert (Клиентская часть)
document.addEventListener('DOMContentLoaded', () => {
  initToolTabs();
  initImageConverter();
  initJsonTools();
  initCryptoTools();
  initBase64Tools();
});

// 1. Переключение вкладок инструментов
function initToolTabs() {
  const tabs = document.querySelectorAll('.tool-tab-btn');
  const panels = document.querySelectorAll('.tool-panel');

  tabs.forEach(tab => {
    tab.addEventListener('click', () => {
      tabs.forEach(t => t.classList.remove('active'));
      panels.forEach(p => p.classList.remove('active'));

      tab.classList.add('active');
      const targetId = tab.dataset.target;
      const targetPanel = document.getElementById(targetId);
      if (targetPanel) targetPanel.classList.add('active');
    });
  });
}

// 2. Конвертер изображений (HTML5 Canvas и Blob в памяти браузера)
function initImageConverter() {
  const dropzone = document.getElementById('imageDropzone');
  const fileInput = document.getElementById('imageFileInput');
  const previewBox = document.getElementById('imagePreviewBox');
  const previewImg = document.getElementById('previewThumbnail');
  const fileMeta = document.getElementById('fileMetaInfo');
  const convertBtn = document.getElementById('convertImageBtn');
  const resultBox = document.getElementById('imageResultBox');
  const downloadLink = document.getElementById('imageDownloadLink');
  const resultStats = document.getElementById('resultStatsInfo');
  const formatSelect = document.getElementById('targetFormatSelect');

  let currentFile = null;

  if (!dropzone || !fileInput) return;

  dropzone.addEventListener('click', () => fileInput.click());

  dropzone.addEventListener('dragover', (e) => {
    e.preventDefault();
    dropzone.classList.add('dragover');
  });

  dropzone.addEventListener('dragleave', () => dropzone.classList.remove('dragover'));

  dropzone.addEventListener('drop', (e) => {
    e.preventDefault();
    dropzone.classList.remove('dragover');
    if (e.dataTransfer.files.length) handleFile(e.dataTransfer.files[0]);
  });

  fileInput.addEventListener('change', () => {
    if (fileInput.files.length) handleFile(fileInput.files[0]);
  });

  function handleFile(file) {
    if (!file.type.startsWith('image/')) {
      alert('Пожалуйста, выберите файл изображения (PNG, JPG, WEBP).');
      return;
    }
    currentFile = file;
    const reader = new FileReader();
    reader.onload = (e) => {
      previewImg.src = e.target.result;
      previewBox.style.display = 'flex';
      fileMeta.textContent = `${file.name} (${(file.size / 1024).toFixed(1)} КБ)`;
      if (resultBox) resultBox.classList.remove('active');
    };
    reader.readAsDataURL(file);
  }

  if (convertBtn) {
    convertBtn.addEventListener('click', () => {
      if (!currentFile) {
        alert('Сначала выберите изображение для конвертации.');
        return;
      }
      convertBtn.textContent = 'Обработка в Canvas...';
      convertBtn.disabled = true;

      const img = new Image();
      img.onload = () => {
        const canvas = document.createElement('canvas');
        canvas.width = img.width;
        canvas.height = img.height;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(img, 0, 0);

        const targetMime = formatSelect.value || 'image/webp';
        const ext = targetMime.split('/')[1] || 'webp';

        canvas.toBlob((blob) => {
          convertBtn.textContent = 'Конвертировать файл';
          convertBtn.disabled = false;

          if (blob) {
            const url = URL.createObjectURL(blob);
            downloadLink.href = url;
            const baseName = currentFile.name.replace(/\.[^/.]+$/, '');
            downloadLink.download = `${baseName}-converted.${ext}`;
            resultStats.textContent = `Размер на выходе: ${(blob.size / 1024).toFixed(1)} КБ (Формат: ${ext.toUpperCase()})`;
            resultBox.classList.add('active');
          }
        }, targetMime, 0.92);
      };
      img.src = previewImg.src;
    });
  }
}

// 3. Форматирование и валидация JSON
function initJsonTools() {
  const jsonInput = document.getElementById('jsonInput');
  const formatBtn = document.getElementById('formatJsonBtn');
  const minifyBtn = document.getElementById('minifyJsonBtn');
  const copyBtn = document.getElementById('copyJsonBtn');
  const statusEl = document.getElementById('jsonStatus');

  if (!jsonInput || !formatBtn) return;

  formatBtn.addEventListener('click', () => {
    try {
      const parsed = JSON.parse(jsonInput.value.trim());
      jsonInput.value = JSON.stringify(parsed, null, 2);
      if (statusEl) {
        statusEl.textContent = 'Корректный JSON успешно отформатирован';
        statusEl.style.color = 'var(--primary)';
      }
    } catch (err) {
      if (statusEl) {
        statusEl.textContent = 'Ошибка синтаксиса: ' + err.message;
        statusEl.style.color = '#ef4444';
      }
    }
  });

  if (minifyBtn) {
    minifyBtn.addEventListener('click', () => {
      try {
        const parsed = JSON.parse(jsonInput.value.trim());
        jsonInput.value = JSON.stringify(parsed);
        if (statusEl) {
          statusEl.textContent = 'JSON сжат в одну строку';
          statusEl.style.color = 'var(--primary)';
        }
      } catch (err) {
        if (statusEl) {
          statusEl.textContent = 'Ошибка синтаксиса: ' + err.message;
          statusEl.style.color = '#ef4444';
        }
      }
    });
  }

  if (copyBtn) {
    copyBtn.addEventListener('click', () => {
      navigator.clipboard.writeText(jsonInput.value).then(() => {
        copyBtn.textContent = 'Скопировано!';
        setTimeout(() => copyBtn.textContent = 'Копировать JSON', 1500);
      });
    });
  }
}

// 4. Криптография и генерация UUID
function initCryptoTools() {
  const uuidBtn = document.getElementById('genUuidBtn');
  const uuidDisplay = document.getElementById('uuidResultDisplay');
  const hashInput = document.getElementById('hashInputText');
  const hashOutput = document.getElementById('hashOutputDisplay');

  if (uuidBtn && uuidDisplay) {
    function gen() {
      const id = typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : '10000000-1000-4000-8000-100000000000'.replace(/[018]/g, c => (c ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> c / 4).toString(16));
      uuidDisplay.textContent = id;
    }
    uuidBtn.addEventListener('click', gen);
    gen();
  }

  if (hashInput && hashOutput) {
    async function calcHash() {
      const text = hashInput.value;
      if (!text) { hashOutput.textContent = 'Введите текст выше для расчета хэша...'; return; }
      const msgUint8 = new TextEncoder().encode(text);
      const hashBuffer = await crypto.subtle.digest('SHA-256', msgUint8);
      const hashArray = Array.from(new Uint8Array(hashBuffer));
      const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
      hashOutput.textContent = hashHex;
    }
    hashInput.addEventListener('input', calcHash);
    calcHash();
  }
}

// 5. Base64 кодирование/декодирование
function initBase64Tools() {
  const b64Input = document.getElementById('base64Input');
  const b64Output = document.getElementById('base64Output');
  const encBtn = document.getElementById('b64EncodeBtn');
  const decBtn = document.getElementById('b64DecodeBtn');

  if (!b64Input || !b64Output) return;

  if (encBtn) {
    encBtn.addEventListener('click', () => {
      try {
        b64Output.value = btoa(unescape(encodeURIComponent(b64Input.value)));
      } catch (e) {
        b64Output.value = 'Ошибка кодирования: ' + e.message;
      }
    });
  }

  if (decBtn) {
    decBtn.addEventListener('click', () => {
      try {
        b64Output.value = decodeURIComponent(escape(atob(b64Input.value.trim())));
      } catch (e) {
        b64Output.value = 'Некорректная Base64 строка';
      }
    });
  }
}
