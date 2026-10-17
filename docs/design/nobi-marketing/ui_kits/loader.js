/* A small module shim for pages that consume this design system's sources directly.

   Babel's in-browser transformer only compiles the entry script, so imported .jsx
   files fail. KNLoad fetches the sources, drops their import/export lines, compiles
   each with the CLASSIC JSX runtime (the automatic runtime injects an import that
   cannot survive being evaluated as a function body) and evaluates them in order
   against one shared scope, which it returns. */
window.KNLoad = async function (files, seed) {
  const R = window.React;
  const scope = Object.assign({
    React: R,
    useState: R.useState, useEffect: R.useEffect, useMemo: R.useMemo,
    useRef: R.useRef, useId: R.useId, useCallback: R.useCallback,
  }, seed || null);

  // Fetch everything at once; evaluation still happens in dependency order.
  const sources = await Promise.all(files.map(async (file) => {
    const res = await fetch(file);
    if (!res.ok) throw new Error('KNLoad: ' + file + ' → ' + res.status);
    return res.text();
  }));

  for (let src of sources) {
    src = src.replace(/^[ \t]*import[\s\S]*?from\s+['"][^'"]+['"];?[ \t]*$/gm, '');
    src = src.replace(/^[ \t]*export[ \t]+/gm, '');

    const declared = [];
    for (const m of src.matchAll(/^(?:function|const|let|class)\s+(\w+)/gm)) declared.push(m[1]);

    const code = Babel.transform(src, { presets: [['react', { runtime: 'classic' }]] }).code;
    const keys = Object.keys(scope);
    const fn = new Function(...keys, code + '\nreturn { ' + declared.join(', ') + ' };');
    Object.assign(scope, fn(...keys.map(k => scope[k])));
  }

  return scope;
};

/* Find the compiled design-system bundle's namespace, if one is on the page.
   Every property read is guarded: enumerating window touches cross-origin frames,
   which throws SecurityError and would otherwise abort the caller before it mounts. */
window.KNBundle = function (need) {
  for (const key of Object.getOwnPropertyNames(window)) {
    let value;
    try { value = window[key]; } catch (e) { continue; }
    if (!value || typeof value !== 'object') continue;
    let ok = true;
    for (const name of need) {
      let member;
      try { member = value[name]; } catch (e) { ok = false; break; }
      if (typeof member !== 'function') { ok = false; break; }
    }
    if (ok) return value;
  }
  return null;
};

/* Load the compiled bundle if it exists. Resolves either way — before the
   design-system compiler has run there is no such file, and that is not an error.
   Injected dynamically rather than written as a <script src> so the page carries no
   reference to a file that may not exist yet. */
window.KNBundleScript = function (url) {
  return new Promise(function (resolve) {
    if (document.querySelector('script[data-kn-bundle]')) return resolve();
    const el = document.createElement('script');
    el.src = url;
    el.setAttribute('data-kn-bundle', '');
    el.onload = function () { resolve(); };
    el.onerror = function () { resolve(); };
    document.head.appendChild(el);
  });
};

/* Mount helper for the component cards.

   Components come from the compiled bundle when the design-system compiler has run,
   and from the sources otherwise, so a card renders either way. The card's own demo
   is always compiled from its .jsx — it is not part of the bundle — and is evaluated
   with the resolved components already in scope. */
window.KNCard = async function (need, componentFiles, demoFile, bundleUrl) {
  await window.KNBundleScript(bundleUrl || '../../_ds_bundle.js');
  const bundled = window.KNBundle(need);
  const seed = {};
  if (bundled) {
    for (const name of need) seed[name] = bundled[name];
  } else {
    Object.assign(seed, await window.KNLoad(componentFiles));
  }
  return window.KNLoad([demoFile], seed);
};
