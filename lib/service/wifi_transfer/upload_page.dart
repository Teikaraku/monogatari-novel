const String uploadPageHtml = r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>物语 · 传书</title>
  <style>
    :root {
      color-scheme: light dark;
      --background: #F2F2F7;
      --card: #FFFFFF;
      --text: #1C1C1E;
      --secondary: #8E8E93;
      --accent: #FF2D55;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --background: #000;
        --card: #1C1C1E;
        --text: #F2F2F7;
        --secondary: #AEAEB2;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      padding: 0 16px;
      background: var(--background);
      color: var(--text);
      font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
    }
    main { max-width: 560px; margin: 0 auto; padding: 32px 0; }
    header { margin-bottom: 24px; }
    h1 { display: flex; align-items: center; gap: 10px; margin: 0; font-size: 28px; font-weight: bold; }
    .badge { background: var(--accent); color: #FFFFFF; font-size: 12px; border-radius: 6px; padding: 4px 8px; }
    .subtitle { color: var(--secondary); font-size: 14px; margin: 12px 0 0; }
    #drop-zone {
      display: block;
      width: 100%;
      padding: 28px;
      border: 2px dashed #D1D1D6;
      border-radius: 16px;
      background: var(--card);
      color: inherit;
      font: inherit;
      text-align: center;
      cursor: pointer;
    }
    #drop-zone.dragging { border-color: var(--accent); background: rgba(255,45,85,.06); }
    #drop-zone svg { display: block; width: 48px; height: 48px; margin: 0 auto 16px; color: var(--accent); }
    .prompt { display: block; font-size: 17px; }
    .hint { display: block; font-size: 14px; color: var(--secondary); margin-top: 8px; }
    #file-list { margin-top: 20px; padding: 0; list-style: none; background: var(--card); border-radius: 16px; }
    .file-row { position: relative; padding: 18px 16px; overflow: hidden; }
    .file-row + .file-row { border-top: .5px solid #D1D1D6; }
    .file-row:first-child { border-top-left-radius: 16px; border-top-right-radius: 16px; }
    .file-row:last-child { border-bottom-left-radius: 16px; border-bottom-right-radius: 16px; }
    .file-content { display: flex; align-items: center; gap: 12px; }
    .file-name {
      flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 15px;
    }
    .status { flex-shrink: 0; font-size: 13px; color: var(--secondary); }
    .uploading .status { color: var(--accent); font-variant-numeric: tabular-nums; }
    .complete .status { color: #34C759; }
    .failed .status { color: #FF3B30; }
    .progress { display: none; position: absolute; bottom: 0; left: 0; right: 0; height: 3px; background: #E5E5EA; }
    .uploading .progress { display: block; }
    .progress-bar { width: 0; height: 100%; background: var(--accent); }
    footer { margin-top: 28px; color: var(--secondary); font-size: 12px; text-align: center; }
  </style>
</head>
<body>
  <main>
    <header>
      <h1>物语 <span class="badge">传书</span></h1>
      <p class="subtitle">支持 EPUB · MOBI · AZW3 · FB2 · TXT · PDF</p>
    </header>
    <button id="drop-zone" type="button">
      <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="3" aria-hidden="true">
        <path d="M24 32V8M14 18L24 8L34 18M8 30V40H40V30" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
      <span class="prompt">拖拽书籍到这里</span>
      <span class="hint">或点击选择文件</span>
    </button>
    <input id="file-input" type="file" multiple accept=".epub,.mobi,.azw3,.fb2,.txt,.pdf" hidden>
    <ul id="file-list" hidden></ul>
    <footer>请保持 物语 打开并停留在传书页面</footer>
  </main>
  <script>
    (() => {
      const input = document.getElementById('file-input');
      const dropZone = document.getElementById('drop-zone');
      const fileList = document.getElementById('file-list');
      const queue = [];
      const reasons = new Map([
        ['unsupported', '格式不支持'], ['too_large', '文件过大'], ['busy', '稍后重试']
      ]);
      let active = 0;
      let dragDepth = 0;

      function setStatus(item, state, text) {
        item.row.className = 'file-row ' + state;
        item.status.textContent = text;
      }

      function enqueue(files) {
        for (const file of files) {
          const row = document.createElement('li');
          const content = document.createElement('div');
          content.className = 'file-content';
          const name = document.createElement('span');
          name.className = 'file-name';
          name.textContent = file.name;
          const status = document.createElement('span');
          status.className = 'status';
          const progress = document.createElement('div');
          progress.className = 'progress';
          const bar = document.createElement('div');
          bar.className = 'progress-bar';
          content.append(name, status);
          progress.append(bar);
          row.append(content, progress);
          fileList.append(row);
          const item = {file, row, status, bar, retries: 0};
          setStatus(item, 'waiting', '等待');
          queue.push(item);
        }
        fileList.hidden = fileList.children.length === 0;
        pump();
      }

      function pump() {
        while (active < 2 && queue.length > 0) {
          upload(queue.shift());
        }
      }

      function upload(item) {
        active += 1;
        setStatus(item, 'uploading', '0%');
        item.bar.style.width = '0%';
        const xhr = new XMLHttpRequest();
        let finished = false;

        function finish(ok, error) {
          if (finished) return;
          finished = true;
          active -= 1;
          if (ok) {
            setStatus(item, 'complete', '✓ 已传到手机');
          } else {
            setStatus(item, 'failed', '失败 ' + (reasons.get(error) || '网络错误'));
            if (error === 'busy' && item.retries === 0) {
              item.retries += 1;
              setTimeout(() => {
                setStatus(item, 'waiting', '等待');
                queue.push(item);
                pump();
              }, 2000);
            }
          }
          pump();
        }

        xhr.upload.onprogress = (event) => {
          if (finished || !event.lengthComputable || event.total <= 0) return;
          const percent = Math.min(100, Math.floor(event.loaded * 100 / event.total));
          item.status.textContent = percent + '%';
          item.bar.style.width = percent + '%';
        };
        xhr.onload = () => {
          let response;
          try {
            response = JSON.parse(xhr.responseText);
          } catch (_) {
            finish(false, 'network');
            return;
          }
          finish(xhr.status === 200 && response && response.ok === true, response && response.error);
        };
        xhr.onerror = () => finish(false, 'network');
        xhr.onabort = () => finish(false, 'network');
        xhr.ontimeout = () => finish(false, 'network');
        try {
          xhr.open('POST', window.location.pathname + 'upload');
          const data = new FormData();
          data.append('file', item.file);
          xhr.send(data);
        } catch (_) {
          finish(false, 'network');
        }
      }

      dropZone.addEventListener('click', () => input.click());
      input.addEventListener('change', () => {
        enqueue(input.files);
        input.value = '';
      });
      dropZone.addEventListener('dragenter', (event) => {
        event.preventDefault();
        dragDepth += 1;
        dropZone.classList.add('dragging');
      });
      dropZone.addEventListener('dragover', (event) => {
        event.preventDefault();
        event.dataTransfer.dropEffect = 'copy';
      });
      dropZone.addEventListener('dragleave', (event) => {
        event.preventDefault();
        dragDepth = Math.max(0, dragDepth - 1);
        if (dragDepth === 0) dropZone.classList.remove('dragging');
      });
      dropZone.addEventListener('drop', (event) => {
        event.preventDefault();
        dragDepth = 0;
        dropZone.classList.remove('dragging');
        enqueue(event.dataTransfer.files);
      });
    })();
  </script>
</body>
</html>
''';
