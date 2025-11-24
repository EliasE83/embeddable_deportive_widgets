// VIEJO 
// === Estado compartido, sin colisiones entre scripts ===
window.__flutterBridge = window.__flutterBridge || {};
if (typeof window.__flutterBridge.initialized !== 'boolean') {
  window.__flutterBridge.initialized = false;
}

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
      try { p.removeChild(this); } catch (_) {}
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

async function loadFlutter_generic() {
    const container = document.getElementById('flutter-container');
    if (!container || window.__flutterBridge.initialized) return;

    container.style.height = '1000px'; // altura inicial
    // Se usa la ruta definida para el widget; si no existe, se usa "flutter/" por defecto.
    const widgetPath = window.flutterWidgetPath || 'flutter/';

    if (!container.getAttribute('data-stream-src')) {
      container.setAttribute('data-stream-src', 'https://blackbearsports.tv/');
    }

    try {
        // Asegura el shim justo antes de cargar runtime de Flutter (por si el padre re-parchó)
        (function reapplySafeRemoveShim() {
          try {
            // fuerza parche si volvió a quedar roto
            const x = document.createElement('div');
            let broken = false;
            try { x.remove(); } catch(_) { broken = true; }
            if (broken) {
              (function(force){ /* mismo contenido del shim, en línea y forzado */
                function safeRemove() {
                  const p = this && (this.parentNode || this.parentElement);
                  if (p) { try { p.removeChild(this); } catch (_) {} }
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
                  } catch (_) {}
                }
              })(true);
            }
          } catch(_) {}
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

        // Espera un breve lapso antes de cargar el entry point
        await new Promise(resolve => setTimeout(resolve, 1000));

        // Configura el objeto _flutter para el loader
        window._flutter = {
            loader: {
                loadEntrypoint: function() {
                    return Promise.resolve();
                },
                didCreateEngineInitializer: async function(engineInitializer) {
                    try {
                        // Reafirma el shim justo antes de inicializar el engine
                        (function reapplySafeRemoveShim() {
                          try {
                            const x = document.createElement('div');
                            let broken = false;
                            try { x.remove(); } catch(_) { broken = true; }
                            if (broken) {
                              (function(force){
                                function safeRemove() {
                                  const p = this && (this.parentNode || this.parentElement);
                                  if (p) { try { p.removeChild(this); } catch (_) {} }
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
                                  } catch (_) {}
                                }
                              })(true);
                            }
                          } catch(_) {}
                        })();

                        const appRunner = await engineInitializer.initializeEngine({
                            renderer: 'html',     // si quieres canvaskit, cambia a 'canvaskit'
                            hostElement: container,
                            assetBase: widgetPath
                        });
                        await appRunner.runApp();
                    } catch (e) {
                        console.error('Error al ejecutar la aplicación Flutter:', e);
                    }
                }
            }
        };

        // Carga el script principal de la aplicación Flutter (main.dart.js)
        await new Promise((resolve, reject) => {
            const mainScript = document.createElement('script');
            mainScript.src = widgetPath + 'main.dart.js';
            mainScript.defer = true;
            mainScript.crossOrigin = 'anonymous';
            mainScript.onload = resolve;
            mainScript.onerror = reject;
            document.body.appendChild(mainScript);
        });

        // Ajusta el estilo del canvas para mostrarlo correctamente
        setTimeout(() => {
            const canvas = container.querySelector('canvas');
            if (canvas) {
                canvas.style.setProperty('display', 'flex', 'important');
            }
        }, 1500);

        window.__flutterBridge.initialized = true;
    } catch (error) {
        console.error('Error cargando Flutter:', error);
        window.__flutterBridge.initialized = false;
    }
}

// ===== EXPORTACIÓN: Necesaria para que app.js pueda usar esta función =====
window.loadFlutter_generic = loadFlutter_generic;

window.addEventListener('unload', () => {
    const scripts = document.querySelectorAll('script[src*="flutter"]');
    scripts.forEach(script => script.remove());
    const container = document.getElementById('flutter-container');
    if (container) {
        container.innerHTML = '';
    }
    window.__flutterBridge.initialized = false;
});

// Variable global para indicar si Flutter está activamente scrolleando su contenido
// true: Flutter está scrolleando internamente, el padre NO debe scrollear.
// false: Flutter ha llegado a un límite de scroll, el padre PUEDE scrollear.
let isFlutterWidgetHandlingScroll = false;

// Esta función es llamada desde Flutter (a través de dart:js)
window.setFlutterWidgetScrollable = function(flutterIsScrollingInternally) {
  isFlutterWidgetHandlingScroll = flutterIsScrollingInternally;
  // console.log('[JS] Recibido de Flutter: Flutter manejando scroll:', isFlutterWidgetHandlingScroll);
};

// =====================================================================
// ===== VARIABLES PARA EL SCROLL SUAVIZADO =====
// =====================================================================
let targetY = window.scrollY; // A dónde queremos que vaya el scroll
let currentY = window.scrollY; // Dónde está el scroll actualmente (versión suavizada)
const easing = 0.12; // Factor de suavizado (ajústalo entre 0.05 y 0.2 para cambiar la sensación)
let ticking = false; // Flag para asegurar que el bucle de animación se ejecute una sola vez por frame

// Bucle de animación que se ejecuta en cada frame para suavizar el movimiento
function smoothScrollLoop() {
  const diff = targetY - currentY;

  // Si la diferencia es muy pequeña, detenemos el bucle para ahorrar recursos
  if (Math.abs(diff) < 1) {
    currentY = targetY; // Ajustamos a la posición final
    ticking = false;
    return;
  }

  // Movemos la posición actual un porcentaje (el 'easing') hacia el objetivo
  currentY += diff * easing;

  // Realizamos el scroll a la nueva posición suavizada
  window.scrollTo(0, currentY);

  // Solicitamos el siguiente frame para continuar la animación
  requestAnimationFrame(smoothScrollLoop);
}

// Listener para el evento 'wheel' (scroll de ratón/trackpad)
window.addEventListener('wheel', (event) => {
  const flutterContainer = document.getElementById('flutter-container');

  // Verificar si el evento de scroll se originó dentro del contenedor de Flutter
  const isEventInsideFlutterWidget = flutterContainer && flutterContainer.contains(event.target);
  const isFlutterIframeFocused = document.activeElement && document.activeElement.tagName === 'IFRAME' &&
  flutterContainer.contains(document.activeElement);

  if (isEventInsideFlutterWidget || isFlutterIframeFocused) {
    if (isFlutterWidgetHandlingScroll) {
      event.preventDefault(); // Detiene el scroll del documento HTML padre
      event.stopPropagation(); // Evita que el evento se propague a otros listeners del padre
    }
  }
}, { passive: false }); // ¡IMPORTANTE! 'passive: false' es necesario para usar event.preventDefault()

// Listener para el evento 'keydown' (teclas de flecha, PageUp/Down, Spacebar)
window.addEventListener('keydown', (event) => {
  const flutterContainer = document.getElementById('flutter-container');
  const isFlutterIframeFocused = document.activeElement &&
  document.activeElement.tagName === 'IFRAME' &&
  flutterContainer.contains(document.activeElement);

  // Solo intervenimos si el foco está en el iframe de Flutter
  if (isFlutterIframeFocused) {
    // Considera solo las teclas que usualmente causan scroll en la ventana
    const scrollKeys = ['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', 'Space'];
    if (scrollKeys.includes(event.key)) {
      if (isFlutterWidgetHandlingScroll) {
        event.preventDefault();
        event.stopPropagation();
      }
    }
  }
}, { passive: false });

window.addEventListener('touchmove', (event) => {
  const flutterContainer = document.getElementById('flutter-container');
  const isInside = flutterContainer && flutterContainer.contains(event.target);

  if (isInside) {
    if (isFlutterWidgetHandlingScroll) {
      // Flutter aún scrollea: bloqueamos el scroll padre
      event.preventDefault();
      event.stopPropagation();
    }
  }
}, { passive: false });

window.addEventListener('touchmove', (e) => {
  if (!isFlutterWidgetHandlingScroll) {
    const touch = e.touches[0];
    if (window.lastTouchY !== undefined) {
      const dy = touch.clientY - window.lastTouchY;

      // EN LUGAR DE HACER scrollBy, actualizamos la variable objetivo
      targetY -= dy;

      // Limitamos el objetivo para que no se pase de los límites de la página
      const maxScroll = document.documentElement.scrollHeight - window.innerHeight;
      targetY = Math.max(0, Math.min(targetY, maxScroll));
      
      // Si el bucle de animación no está corriendo, lo iniciamos
      if (!ticking) {
        ticking = true;
        requestAnimationFrame(smoothScrollLoop);
      }
    }
    // Actualizamos la última posición del dedo
    window.lastTouchY = touch.clientY;
  }
}, { passive: false });

window.addEventListener('touchend', () => {
  window.lastTouchY = undefined;
});