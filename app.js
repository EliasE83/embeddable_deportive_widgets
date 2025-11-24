// === Estado compartido, sin colisiones entre scripts ===
window.__flutterBridge = window.__flutterBridge || {};
if (typeof window.__flutterBridge.initialized !== 'boolean') {
  window.__flutterBridge.initialized = false;
}

window.__lastFlutterH = 0;

/* ===== Shim SEGURO para Node/Element/HTMLElement/ChildNode.prototype.remove ===== */
(function installSafeRemoveShim(force) {
  // Detecta si remove() está roto (lanzando cuando el nodo no tiene padre)
  function isRemoveBroken() {
    try {
      const x = document.createElement('div');
      x.remove(); // la nativa NO lanza en detached nodes
      return false;
    } catch (_) {
      return true;
    }
  }

  // Evita re-patches innecesarios
  if (!force && !isRemoveBroken()) return;

  function safeRemove() {
    const p = this && (this.parentNode || this.parentElement);
    if (p) {
      try { p.removeChild(this); } catch (_) { }
    }
    // igual que la nativa: no retorna nada
  }

  const targets = [
    window.Node && Node.prototype,
    window.Element && Element.prototype,
    window.HTMLElement && HTMLElement.prototype,
    window.ChildNode && ChildNode.prototype
  ].filter(Boolean);

  for (const proto of targets) {
    try {
      Object.defineProperty(proto, 'remove', {
        value: safeRemove,
        configurable: true,
        writable: true
      });
    } catch (_) { /* no-op */ }
  }
})();
/* ===== Fin shim ===== */

async function loadFlutter_special() {
  const container = document.getElementById('flutter-container');
  if (!container || window.__flutterBridge.initialized) return;

  // Determinar minHeight basado en el widget
  const widgetPath = window.flutterWidgetPath || 'flutter/';
  const isGameCenter = widgetPath.includes('game_center');
  const minHeight = isGameCenter ? '1200px' : '1000px';

  // Inicialización del contenedor: no fijamos una gran altura para evitar huecos
  container.style.height = 'auto';
  container.style.minHeight = '50000px';//minHeight;
  container.style.overflow = 'visible'; // evitar scroll interno del contenedor
  container.style.maxHeight = 'none';
  container.style.opacity = '0'; // Ocultar durante carga inicial
  container.style.transition = 'opacity 0.3s ease-in-out';

  if (!container.getAttribute('data-stream-src')) {
    container.setAttribute('data-stream-src', 'https://blackbearsports.tv/');
  }

  const view = document.getElementById('flutter-view');
  if (view) {
    view.style.touchAction = 'initial'; // ocultar vista previa si existe
  }

  // API para que Flutter notifique la altura total y para compatibilidad con scroll
  try {
    // Estado de carga del widget
    let heightStabilized = false;
    let lastHeight = 0;
    let stabilityTimer = null;
    let loadingStartTime = null;
    let showSpinnerTimer = null;
    let maxWaitTimer = null;
    const STABILITY_DELAY = 300; // ms para considerar altura estable
    const SPINNER_DELAY = 500; // ms antes de mostrar spinner
    const MAX_WAIT_TIME = 5000; // ms máximo de espera antes de forzar la visualización

    // Función para añadir relleno extra en escritorio
    function _getBottomExtra() {
      const widgetPath = window.flutterWidgetPath || 'flutter/';
      const isGameCenter = widgetPath.includes('game_center');
      const w = window.innerWidth || document.documentElement.clientWidth || 0;
      return w >= 900 ? isGameCenter ? 100 : 25 : 20;
    }

    // Función para medir el DOM, usada solo como último recurso
    function measureContentHeight(c) {
      try {
        const crect = c.getBoundingClientRect();
        let maxBottom = crect.top;
        const nodes = c.querySelectorAll('*');
        for (let i = 0; i < nodes.length; i++) {
          const el = nodes[i];
          if (el === c) continue;
          const style = window.getComputedStyle(el);
          if (style.display === 'none' || style.visibility === 'hidden' || style.position === 'fixed') continue;
          const r = el.getBoundingClientRect();
          if (!r || !isFinite(r.bottom) || r.height <= 0 || r.width <= 0) continue;
          if (r.bottom > maxBottom) maxBottom = r.bottom;
        }
        const contentH = Math.max(0, maxBottom - crect.top);
        return Math.ceil(contentH);
      } catch (_) { return 0; }
    }

    // Función para mostrar el contenedor cuando la altura se estabiliza
    function showContainerWhenStable(currentHeight) {
      const c = document.getElementById('flutter-container');
      if (!c || heightStabilized) return;

      const heightChanged = Math.abs(currentHeight - lastHeight) > 5;
      const isFirstUpdate = lastHeight === 0 && currentHeight > 0;

      if (heightChanged || isFirstUpdate) {
        lastHeight = currentHeight;
        if (stabilityTimer) clearTimeout(stabilityTimer);

        stabilityTimer = setTimeout(() => {
          heightStabilized = true;
          c.style.opacity = '1';
          if (maxWaitTimer) clearTimeout(maxWaitTimer);
          stabilityTimer = null;
        }, STABILITY_DELAY);
      }
    }

    function applyContainerHeightFromDom(prefH) {
      try {
        const c = document.getElementById('flutter-container');
        if (!c) return;

        const extra = _getBottomExtra();
        let finalHeight = 0;
        const h = Number(prefH);

        if (isFinite(h) && h > 0) {
          finalHeight = Math.ceil(h) + 80;
        } else {
          const domH = measureContentHeight(c);
          if (domH > 0) {
            finalHeight = domH;
          } else if (h === 0) {
            c.style.height = 'auto';
            if (!heightStabilized) {
              heightStabilized = true;
              c.style.opacity = '1';
              if (maxWaitTimer) clearTimeout(maxWaitTimer);
            }
            return;
          }
        }

        if (finalHeight > 0) {
          lastAppliedHeight = finalHeight;
          lastUpdateTime = Date.now();
          c.style.height = finalHeight + 'px';

          showContainerWhenStable(finalHeight);
        }
      } catch (_) { }
    }

    window.setFlutterContainerHeight = function (h) {
      window.__lastFlutterH = h;
      applyContainerHeightFromDom(h);
    };

    window.__applyFlutterContainerHeightFromDom = applyContainerHeightFromDom;

    // Función para resetear el estado cuando se recarga el widget
    window.__resetFlutterLoadingState = function () {
      heightStabilized = false;
      lastHeight = 0;
      loadingStartTime = Date.now();

      if (stabilityTimer) clearTimeout(stabilityTimer);
      if (showSpinnerTimer) clearTimeout(showSpinnerTimer);
      if (maxWaitTimer) clearTimeout(maxWaitTimer);

      const c = document.getElementById('flutter-container');

      if (c) {
        c.style.height = 'auto';
        const widgetPath = window.flutterWidgetPath || 'flutter/';
        const isGameCenter = widgetPath.includes('game_center');
        c.style.minHeight = isGameCenter ? '1200px' : '1000px';
        c.style.opacity = '0';
      }

      maxWaitTimer = setTimeout(() => {
        if (!heightStabilized) {
          heightStabilized = true;
          if (c) c.style.opacity = '1';
        }
      }, MAX_WAIT_TIME);
    };

    if (typeof window.setFlutterWidgetScrollable !== 'function') {
      window.setFlutterWidgetScrollable = function (_isScrollable) { /* no-op */ };
    }
  } catch (_) { }

  try {
    // Asegura el shim justo antes de cargar runtime de Flutter
    (function reapplySafeRemoveShim() {
      try {
        const x = document.createElement('div');
        let broken = false;
        try { x.remove(); } catch (_) { broken = true; }
        if (broken) {
          (function (force) {
            function safeRemove() {
              const p = this && (this.parentNode || this.parentElement);
              if (p) { try { p.removeChild(this); } catch (_) { } }
            }
            const targets = [
              window.Node && Node.prototype,
              window.Element && Element.prototype,
              window.HTMLElement && HTMLElement.prototype,
              window.ChildNode && ChildNode.prototype
            ].filter(Boolean);
            for (const proto of targets) {
              try {
                Object.defineProperty(proto, 'remove', {
                  value: safeRemove,
                  configurable: true,
                  writable: true
                });
              } catch (_) { }
            }
          })(true);
        }
      } catch (_) { }
    })();

    // Elimina cualquier script anterior que contenga la ruta del widget
    const existingScripts = document.querySelectorAll(`script[src*="${widgetPath}"]`);
    existingScripts.forEach(script => script.remove());

    // Carga el script de Flutter (flutter.js)
    const flutterScript = document.createElement('script');
    flutterScript.src = widgetPath + 'flutter.js';
    flutterScript.defer = true;
    flutterScript.crossOrigin = 'anonymous';

    await new Promise((resolve, reject) => {
      flutterScript.onload = resolve;
      flutterScript.onerror = reject;
      document.body.appendChild(flutterScript);
    });

    await new Promise(resolve => setTimeout(resolve, 1000));

    // Configura el objeto _flutter para el loader
    window._flutter = {
      loader: {
        loadEntrypoint: function () {
          return Promise.resolve();
        },
        didCreateEngineInitializer: async function (engineInitializer) {
          try {
            // Reafirma el shim justo antes de inicializar el engine
            (function reapplySafeRemoveShim() {
              try {
                const x = document.createElement('div');
                let broken = false;
                try { x.remove(); } catch (_) { broken = true; }
                if (broken) {
                  (function (force) {
                    function safeRemove() {
                      const p = this && (this.parentNode || this.parentElement);
                      if (p) { try { p.removeChild(this); } catch (_) { } }
                    }
                    const targets = [
                      window.Node && Node.prototype,
                      window.Element && Element.prototype,
                      window.HTMLElement && HTMLElement.prototype,
                      window.ChildNode && ChildNode.prototype
                    ].filter(Boolean);
                    for (const proto of targets) {
                      try {
                        Object.defineProperty(proto, 'remove', {
                          value: safeRemove,
                          configurable: true,
                          writable: true
                        });
                      } catch (_) { }
                    }
                  })(true);
                }
              } catch (_) { }
            })();

            // Fix para alto DPR en móviles: limitar el devicePixelRatio
            const originalDPR = window.devicePixelRatio;
            // Limitar devicePixelRatio: en Android usar 0.710, en otros dispositivos 2.0
            const isAndroid = /Android/i.test(navigator.userAgent || '');
            const maxDPR = isAndroid ? 0.5 : 2.0;
            if (originalDPR > maxDPR) {
              Object.defineProperty(window, 'devicePixelRatio', {
                get: function() { return maxDPR; },
                configurable: true
              });
            }

            const appRunner = await engineInitializer.initializeEngine({
              renderer: 'canvaskit',
              hostElement: container,
              assetBase: widgetPath
            });
            await appRunner.runApp();

            // Normaliza el DOM generado por Flutter HTML
            (function normalizeFlutterDom() {
              try {
                const view = container.querySelector('flutter-view');
                if (view) {
                  view.style.setProperty('touch-action', 'auto', 'important');
                }

                function applyStyles() {
                  try {
                    const pane = container.querySelector('flt-glass-pane');

                    // Debug: detectar problemas de DPR en móviles
                    if (/Android|iPhone|iPad|iPod/i.test(navigator.userAgent)) {
                      const dpr = window.devicePixelRatio;
                      const viewportHeight = window.innerHeight;
                      const containerHeight = container.offsetHeight;
                      
                      if (dpr > 2.5 && containerHeight > 5000) {
                        console.warn('[Flutter DPR Fix] Alto DPR detectado:', {
                          dpr: dpr,
                          viewportHeight: viewportHeight,
                          containerHeight: containerHeight,
                          userAgent: navigator.userAgent
                        });
                      }
                    }

                    if (pane) {
                      pane.style.display = 'block';
                      pane.style.position = 'relative';
                      pane.style.width = '100%';
                      pane.style.height = 'auto';
                      pane.style.minHeight = '0';
                      pane.style.overflow = 'visible';
                      pane.style.touchAction = 'pan-y pinch-zoom';
                      pane.style.paddingTop = '0';
                    }

                    const sceneHost = container.querySelector('flt-scene-host');
                    if (sceneHost) {
                      sceneHost.style.display = 'block';
                      sceneHost.style.position = 'relative';
                      sceneHost.style.width = '100%';
                      sceneHost.style.height = '100%';
                      sceneHost.style.overflow = 'visible';
                      sceneHost.style.touchAction = 'pan-y pinch-zoom';
                    }

                    container.style.touchAction = 'pan-y pinch-zoom';
                    container.style.pointerEvents = 'auto';
                  } catch (_) { }
                }

                applyStyles();
                if (typeof window.__applyFlutterContainerHeightFromDom === 'function') {
                  window.__applyFlutterContainerHeightFromDom();
                }

                // Observa re-renderizados con debounce para evitar loops
                let mutationTimer = null;
                const mo = new MutationObserver(() => {
                  if (mutationTimer) clearTimeout(mutationTimer);
                  mutationTimer = setTimeout(() => {
                    applyStyles();
                    if (typeof window.__applyFlutterContainerHeightFromDom === 'function') {
                      if (window.__lastFlutterH > 0) {
                        window.__applyFlutterContainerHeightFromDom(window.__lastFlutterH);
                      }
                    }
                  }, 50);
                });
                mo.observe(container, { childList: true, subtree: true, attributes: true, attributeFilter: ['style'] });

                [0, 300, 800, 2000].forEach((t) => setTimeout(() => {
                  applyStyles();
                  if (typeof window.__applyFlutterContainerHeightFromDom === 'function') {
                    window.__applyFlutterContainerHeightFromDom();
                  }
                }, t));

                const onResize = () => {
                  try {
                    applyStyles();
                    if (typeof window.__applyFlutterContainerHeightFromDom === 'function') {
                      window.__applyFlutterContainerHeightFromDom();
                    }
                  } catch (_) { }
                };
                window.addEventListener('resize', onResize, { passive: true });
                window.addEventListener('orientationchange', onResize, { passive: true });
              } catch (_) { }
            })();
          } catch (e) {
            console.error('Error al ejecutar la aplicación Flutter:', e);
          }
        }
      }
    };

    // Carga el script principal de la aplicación Flutter
    await new Promise((resolve, reject) => {
      const mainScript = document.createElement('script');
      mainScript.src = widgetPath + 'main.dart.js';
      mainScript.defer = true;
      mainScript.crossOrigin = 'anonymous';
      mainScript.onload = resolve;
      mainScript.onerror = reject;
      document.body.appendChild(mainScript);
    });

    window.__flutterBridge.initialized = true;
  } catch (error) {
    console.error('Error cargando Flutter:', error);
    window.__flutterBridge.initialized = false;
  }
}

window.addEventListener('unload', () => {
  const scripts = document.querySelectorAll('script[src*="flutter"]');
  scripts.forEach(script => script.remove());
  const container = document.getElementById('flutter-container');
  if (container) {
    container.innerHTML = '';
  }
  window.__flutterBridge.initialized = false;
});

// === Router para elegir loader según widgetPath / widgetKey ===
(function () {
  function widgetKeyFromPath(p) {
    if (!p) return '';
    const s = String(p).toLowerCase();
    const last = s.replace(/\/+$/, '').split('/').pop();
    return last || s;
  }

  function isSpecialWidgetKey(key) {
    return key === 'season_schedule_widget' 
    || key === 'game_center_widget'
    || key === 'scoreboard_widget'
    || key === 'season_standing_widget'
    || key === 'player_profile_widget'
    || key === 'web';
  }

  // Carga old_app.js dinámicamente si no está disponible
  async function ensureGenericAvailable() {
    if (typeof window.loadFlutter_generic === 'function') {
      return;
    }

    console.log('[Router] Cargando old_app.js dinámicamente...');

    return new Promise((resolve, reject) => {
      const script = document.createElement('script');

      // Prioridad 1: Usar ruta configurada manualmente
      if (window.oldAppJsPath) {
        script.src = window.oldAppJsPath;
        console.log('[Router] Usando ruta manual para old_app.js:', script.src);
      } else {
        // Prioridad 2: Obtener la ruta base de app.js
        const appJsScript = document.querySelector('script[src*="app.js"]');
        let oldAppPath = 'old_app.js';

        if (appJsScript && appJsScript.src) {
          const appJsUrl = new URL(appJsScript.src);
          const pathParts = appJsUrl.pathname.split('/');
          pathParts.pop();
          const baseDir = pathParts.join('/');
          oldAppPath = appJsUrl.origin + baseDir + '/old_app.js';
        }

        script.src = oldAppPath;
        console.log('[Router] Ruta calculada automáticamente para old_app.js:', script.src);
      }

      script.defer = true;

      script.onload = () => {
        if (typeof window.loadFlutter_generic === 'function') {
          console.log('[Router] old_app.js cargado exitosamente');
          resolve();
        } else {
          reject(new Error('[Router] old_app.js se cargó pero loadFlutter_generic no está disponible'));
        }
      };

      script.onerror = () => {
        reject(new Error('[Router] Error al cargar old_app.js. Verifica la ruta del archivo.'));
      };

      document.head.appendChild(script);
    });
  }

  window.loadFlutter = async function () {
    const widgetPath = window.flutterWidgetPath || 'flutter/';
    const explicitKey = (window.flutterWidgetKey || '').toLowerCase();
    const key = explicitKey || widgetKeyFromPath(widgetPath);

    console.log(`[Router] Widget detectado: "${key}" (path: ${widgetPath})`);

    window.__flutterWidgetPath = widgetPath;

    if (isSpecialWidgetKey(key)) {
      console.log('[Router] Usando loadFlutter_special');
      if (typeof window.loadFlutter_special !== 'function') {
        console.error('[Router] loadFlutter_special no está definido');
        return;
      }
      return window.loadFlutter_special();
    } else {
      console.log('[Router] Usando loadFlutter_generic (old_app.js)');
      try {
        await ensureGenericAvailable();
      } catch (e) {
        console.error(e.message);
        return;
      }
      return window.loadFlutter_generic();
    }
  };

  window.addEventListener('unload', () => {
    try {
      const wp = window.__flutterWidgetPath || window.flutterWidgetPath || 'flutter/';
      document.querySelectorAll(`script[src^="${wp}"]`).forEach(s => s.remove());
      const container = document.getElementById('flutter-container');
      if (container) container.innerHTML = '';
      window.__flutterBridge.initialized = false;
      if (window.__normalizedMo && typeof window.__normalizedMo.disconnect === 'function') {
        window.__normalizedMo.disconnect();
      }
    } catch (_) { }
  });
})();
