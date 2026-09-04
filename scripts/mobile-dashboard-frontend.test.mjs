import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import test from "node:test";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const dashboard = path.join(root, "AIQuotaBar/Resources/MobileDashboard");

const readText = (name) => readFile(path.join(dashboard, name), "utf8");

function namedFunction(source, name, preamble = "") {
  let start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `missing ${name}`);
  if (source.slice(Math.max(0, start - 6), start) === "async ") start -= 6;
  const bodyMarker = source.indexOf(") {", start);
  const firstBrace = bodyMarker + 2;
  assert.notEqual(bodyMarker, -1, `missing body for ${name}`);
  let depth = 0;
  for (let index = firstBrace; index < source.length; index += 1) {
    if (source[index] === "{") depth += 1;
    if (source[index] === "}") depth -= 1;
    if (depth === 0) {
      const declaration = source.slice(start, index + 1);
      return Function(`"use strict"; ${preamble}; return (${declaration});`)();
    }
  }
  throw new Error(`unterminated ${name}`);
}

test("PWA installs with the AI Quota identity and complete icon set", async () => {
  const manifest = JSON.parse(await readText("manifest.webmanifest"));
  assert.equal(manifest.name, "AI Quota");
  assert.equal(manifest.short_name, "AI Quota");
  assert.equal(manifest.background_color, "#000000");
  assert.equal(manifest.theme_color, "#000000");

  const iconContracts = new Map([
    ["/icon-192.png", [192, 192]],
    ["/icon-512.png", [512, 512]],
    ["/icon-maskable-512.png", [512, 512]],
  ]);
  for (const icon of manifest.icons) {
    if (!iconContracts.has(icon.src)) continue;
    assert.deepEqual(icon.sizes.split("x").map(Number), iconContracts.get(icon.src));
  }
  assert.equal(manifest.icons.find((icon) => icon.src.includes("maskable"))?.purpose, "maskable");

  for (const [file, dimensions] of [
    ["icon-192.png", [192, 192]],
    ["icon-512.png", [512, 512]],
    ["icon-maskable-512.png", [512, 512]],
    ["apple-touch-icon.png", [180, 180]],
  ]) {
    const png = await readFile(path.join(dashboard, file));
    assert.equal(png.toString("ascii", 1, 4), "PNG");
    assert.deepEqual([png.readUInt32BE(16), png.readUInt32BE(20)], dimensions);
  }
});

test("HTML is unnumbered, installable, and exposes the compact monitor regions", async () => {
  const html = await readText("index.html");
  assert.match(html, /<title>AI Quota<\/title>/);
  assert.match(html, /name="application-name" content="AI Quota"/);
  assert.match(html, /name="apple-mobile-web-app-title" content="AI Quota"/);
  assert.match(html, /<html lang="en" data-color-scheme="auto">/);
  assert.match(html, /id="install-copy"/);
  assert.match(html, /Add to Home Screen/);
  assert.match(html, /class="task-energy-field"/);
  assert.match(html, /class="matrix-rain-canvas" id="matrix-rain-canvas"/);
  assert.match(html, /class="task-telemetry-marquee" id="task-telemetry-marquee"/);
  assert.match(html, /class="matrix-idle-grain"/);
  assert.equal((html.match(/class="task-wave"/g) || []).length, 5);
  assert.equal((html.match(/<canvas/g) || []).length, 1);
  assert.doesNotMatch(html, /wake-media-(?:button|status)|Enable while working/);
  assert.match(html, /class="idle-blackout"[\s\S]*class="idle-screen-stage"/);
  assert.equal((html.match(/class="idle-screensaver-field"/g) || []).length, 1);
  assert.equal((html.match(/class="idle-screensaver-word"/g) || []).length, 1);
  assert.match(html, /id="idle-blackout"[\s\S]*aria-live="polite"[\s\S]*aria-hidden="true"[\s\S]*hidden/);
  assert.doesNotMatch(html, /id="task-state-symbol"/);
  assert.match(html, /class="ticker-window"/);
  assert.doesNotMatch(html, /class="section-index"|>0[1-4]</);
});

test("dashboard appearance is allowlisted, themeable, and keeps OLED blackout black", async () => {
  const html = await readText("index.html");
  const css = await readText("app.css");
  const script = await readText("app.js");
  const envelopeSource = namedFunction(script, "renderEnvelope").toString();
  const applySource = namedFunction(
    script,
    "applyColorScheme",
    'const COLOR_SCHEMES = new Set(["auto", "dark", "light"]); const state = { colorScheme: "auto", resolvedColorScheme: null }; const THEME_COLORS = { dark: "#000000", light: "#f6f7f4" };',
  ).toString();
  const resolveLight = namedFunction(
    script,
    "resolveColorScheme",
    "const systemColorScheme = { matches: true }",
  );
  const resolveDark = namedFunction(
    script,
    "resolveColorScheme",
    "const systemColorScheme = { matches: false }",
  );

  assert.match(html, /name="theme-color" content="#000000"/);
  assert.match(html, /name="color-scheme" content="light dark"/);
  assert.match(css, /:root\[data-color-scheme="light"\]\s*\{/);
  assert.match(css, /@media \(prefers-color-scheme: light\)/);
  assert.match(css, /:root\[data-color-scheme="auto"\]\s*\{/);
  assert.match(css, /--page-background:\s*#f6f7f4/);
  assert.match(css, /--chart-axis:\s*#4f5a4f/);
  assert.equal(resolveLight("auto"), "light");
  assert.equal(resolveDark("auto"), "dark");
  assert.equal(resolveLight("dark"), "dark");
  assert.match(envelopeSource, /COLOR_SCHEMES\.has\(envelope\.colorScheme\)/);
  assert.match(envelopeSource, /applyColorScheme\(nextColorScheme\)/);
  assert.match(envelopeSource, /languageChanged \|\| colorSchemeChanged/);
  assert.match(applySource, /document\.documentElement\.dataset\.colorScheme = next/);
  assert.match(applySource, /themeColor\.content = THEME_COLORS\[resolved\]/);
  assert.match(script, /systemColorScheme\.addEventListener\("change"/);
  assert.match(script, /refreshThemeDependentVisuals/);
  assert.match(script, /cssToken\("--chart-grid"/);
  assert.match(script, /cssToken\("--chart-axis"/);
  assert.match(script, /cssToken\("--rain-rgb"/);
  assert.doesNotMatch(script, /context\.(?:fillStyle|strokeStyle) = "#[0-9a-fA-F]{6}"/);
  assert.match(css, /\.idle-blackout\s*\{[^}]*background:\s*#000000/s);
});

test("viewport and iOS gestures keep browser and standalone displays at 1x", async () => {
  const html = await readText("index.html");
  const script = await readText("app.js");
  assert.match(
    html,
    /name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover"/,
  );
  assert.match(html, /apple-mobile-web-app-capable" content="yes"/);
  assert.match(html, /id="gate"[^>]*hidden/);

  const preventViewportGesture = namedFunction(
    script,
    "preventViewportGesture",
  );
  for (const type of ["gesturestart", "gesturechange", "gestureend"]) {
    let prevented = false;
    preventViewportGesture({
      type,
      preventDefault() { prevented = true; },
    });
    assert.equal(prevented, true, `${type} must be cancelled`);
  }
  let multiTouchPrevented = false;
  preventViewportGesture({
    type: "touchmove",
    touches: [{}, {}],
    preventDefault() { multiTouchPrevented = true; },
  });
  assert.equal(multiTouchPrevented, true);

  let singleTouchPrevented = false;
  preventViewportGesture({
    type: "touchmove",
    touches: [{}],
    preventDefault() { singleTouchPrevented = true; },
  });
  assert.equal(singleTouchPrevented, false, "single-finger scrolling stays available");
  assert.match(
    script,
    /\["gesturestart", "gesturechange", "gestureend"\][\s\S]*passive: false/,
  );
  assert.match(
    script,
    /addEventListener\("touchmove", preventViewportGesture, \{[\s\S]*?passive: false/,
  );
});

test("CSS scales the full dashboard in both orientations with equal status rows", async () => {
  const css = await readText("app.css");
  assert.match(
    css,
    /\.page\s*\{[^}]*width:\s*100%;[^}]*max-width:\s*none;[^}]*margin:\s*0;/s,
  );
  assert.doesNotMatch(css, /\.page\s*\{[^}]*width:\s*min\(100%,\s*88rem\)/s);
  assert.match(css, /@media \(orientation: landscape\)/);
  assert.match(
    css,
    /@media \(orientation: landscape\)[\s\S]*#dashboard\s*\{[^}]*grid-template-columns:\s*minmax\(0, 1fr\) minmax\(0, 1fr\)/,
  );
  assert.match(
    css,
    /@media \(orientation: landscape\)[\s\S]*#dashboard\s*\{[^}]*grid-template-rows:\s*repeat\(3, minmax\(0, 1fr\)\) 2\.142857rem/,
  );
  assert.match(
    css,
    /@media \(orientation: landscape\)[\s\S]*:root\s*\{[^}]*font-size:\s*max\(12px, min\(1\.724138vw, 3\.733333dvh\)\)/,
  );
  assert.doesNotMatch(
    css,
    /@media \(orientation: landscape\)[\s\S]*#dashboard\s*\{[^}]*grid-template-rows:[^;}]*max-content/,
  );
  assert.doesNotMatch(
    css,
    /@media \(orientation: landscape\)[\s\S]*#dashboard\s*\{[^}]*grid-template-columns:[^;}]*1\.55fr/,
  );
  assert.match(
    css,
    /@media \(orientation: portrait\)[\s\S]*:root\s*\{[^}]*font-size:\s*max\(12px, min\(3\.733333vw, 1\.724138dvh\)\)/,
  );
  assert.match(
    css,
    /@media \(orientation: portrait\)[\s\S]*#dashboard\s*\{[^}]*grid-template-rows:\s*minmax\(0, 1fr\)\s*minmax\(0, 2fr\)\s*minmax\(0, 1fr\)\s*minmax\(0, 1fr\)\s*2\.285714rem/,
  );
  assert.match(
    css,
    /@media \(orientation: portrait\)[\s\S]*height: 100dvh;[\s\S]*overflow: hidden/,
  );
  assert.match(
    css,
    /@media \(orientation: portrait\)[\s\S]*\.task-hero\s*\{[^}]*grid-template-columns:\s*fit-content\(58%\) minmax\(0, 1fr\)/,
  );
  assert.match(
    css,
    /@media \(orientation: portrait\)[\s\S]*\.task-state-meta\s*\{[^}]*grid-column:\s*2;[^}]*display:\s*grid;/,
  );
  assert.doesNotMatch(
    css,
    /@media \(orientation: portrait\)[\s\S]*grid-template-rows:\s*84px minmax\(0, 1fr\) 104px 112px 32px/,
  );
  assert.match(
    css,
    /@media \(max-width: 22rem\) and \(orientation: portrait\)[\s\S]*\.task-state-title\s*\{[^}]*font-size:\s*2\.285714rem/,
  );
  assert.match(css, /env\(safe-area-inset-top\)/);
  assert.match(css, /env\(safe-area-inset-right\)/);
  assert.match(css, /env\(safe-area-inset-bottom\)/);
  assert.match(css, /env\(safe-area-inset-left\)/);
  assert.match(css, /\.task-state-title\s*\{[^}]*font-size:\s*2\.571429rem/s);
  assert.match(css, /\.quota-value\s*\{[^}]*font-size:\s*1\.857143rem/s);
  assert.match(css, /\.quota-model\s*\{[^}]*font-size:\s*1\.142857rem/s);
  assert.match(css, /\.ticker-track\s*\{[^}]*font-size:\s*1rem/s);
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/);
  assert.match(css, /\.matrix-idle-grain\s*\{[^}]*radial-gradient/s);
  assert.match(css, /\.matrix-rain-canvas\s*\{[^}]*image-rendering:\s*pixelated/s);
  assert.match(css, /\.task-wave\s*\{[^}]*radial-gradient/s);
  assert.doesNotMatch(css, /background-clip:\s*text/);
  assert.doesNotMatch(css, /border-(left|right):\s*[2-9]/);
});

test("all authored keyframe properties are compositor-friendly", async () => {
  const css = await readText("app.css");
  const keyframeNames = [...css.matchAll(/@keyframes\s+([\w-]+)/g)].map((match) => match[1]);
  assert.deepEqual(keyframeNames.sort(), [
    "matrix-idle-breathe",
    "protection-ticker",
    "task-wave-travel",
  ]);
  const disallowed = /\b(width|height|padding|margin|top|right|bottom|left|color|background|border[^:]*)\s*:/;
  for (const name of keyframeNames) {
    const start = css.indexOf(`@keyframes ${name}`);
    const firstBrace = css.indexOf("{", start);
    let depth = 0;
    let end = firstBrace;
    for (; end < css.length; end += 1) {
      if (css[end] === "{") depth += 1;
      if (css[end] === "}") depth -= 1;
      if (depth === 0) break;
    }
    const body = css.slice(firstBrace, end + 1);
    assert.doesNotMatch(body, disallowed, `${name} animates a layout or paint property`);
  }
});

test("dashboard JS consumes exact schema v3 telemetry and keeps legacy fallbacks", async () => {
  const script = await readText("app.js");
  assert.match(script, /snapshot\?\.menuBar/);
  assert.match(script, /menuBar\.ringPercent/);
  assert.match(script, /menuBar\.paceDeltaPercent/);
  assert.match(script, /model\.rendersAreaChart === true/);
  assert.match(script, /model\.isCurrentIntervalPercentMode !== false/);
  assert.match(script, /model\.usesReverseProgressTint === true/);
  assert.match(script, /protection\?\.hasActiveTasks/);
  assert.match(script, /slice\(-60\)/);
  assert.match(script, /bucket\.connectionAges/);
  assert.match(script, /bucket\.oldestConnectionAge/);
  assert.match(script, /bucket\.connectionCount/);
  assert.match(script, /CONTENT_ROTATE_MS/);
  assert.match(script, /PIXEL_SHIFT_MS/);
  assert.match(script, /is-state-boosted/);
  assert.doesNotMatch(script, /serviceWorker\.register/);
});

test("PWA install credential is fragment-only, claimed in standalone, and removed immediately", async () => {
  const html = await readText("index.html");
  const css = await readText("app.css");
  const script = await readText("app.js");
  assert.match(html, /rel="manifest" href="\/manifest\.webmanifest"/);
  assert.match(script, /new URLSearchParams\(fragment\)/);
  assert.match(script, /parameters\.get\("install"\)/);
  assert.match(script, /installFromURL\.length <= 256/);
  assert.match(script, /history\.replaceState/);
  assert.match(script, /headers\.Authorization = `PWAInstall \$\{credential\}`/);
  assert.match(script, /if \(!isStandaloneDisplay\(\) \|\| state\.token\)/);
  assert.match(script, /isStandaloneDisplay\(\)[\s\S]*t\("reinstallCopy"\)/);
  assert.match(script, /isReady &&[\s\S]*refreshManifestLink\(\)/);
  assert.match(script, /const INSTALL_CLAIM_RETRY_MS = \[0, 400, 1_200\]/);
  assert.match(script, /if \(response\.status === 401\)/);
  assert.match(
    script,
    /storeToken\(token\);[\s\S]*state\.installCredential = "";/,
  );
  assert.match(script, /state\.installClaimInFlight/);
  assert.match(html, /id="pairing-retry-button"/);
  assert.match(
    css,
    /\.pairing-retry-button\s*\{[^}]*min-height:\s*44px/s,
  );
  assert.doesNotMatch(
    script,
    /localStorage\.(?:setItem|getItem)\([^\n]*install/i,
  );
  assert.doesNotMatch(script, /[?&]token=/);
  assert.doesNotMatch(script, /[?&]install=/);
});

test("pairing-off roots claim silently while pairing-on keeps the manual fallback", async () => {
  const html = await readText("index.html");
  const script = await readText("app.js");
  const claimSource = namedFunction(
    script,
    "claimTokenWithoutPairingCode",
  ).toString();
  const prepareSource = namedFunction(script, "prepareAndConnect").toString();
  const bootstrapSource = namedFunction(script, "refreshPWABootstrap").toString();

  assert.match(html, /id="gate"[^>]*hidden/);
  assert.match(script, /const HEALTH_PATH = "\/api\/v1\/health"/);
  assert.match(claimSource, /health\?\.requiresPairingCode !== false/);
  assert.match(claimSource, /baseAwareURL\(HEALTH_PATH, requestBase\)/);
  assert.match(claimSource, /method: "GET"/);
  assert.match(claimSource, /baseAwareURL\(PWA_CLAIM_PATH, requestBase\)/);
  assert.match(claimSource, /method: "POST"/);
  assert.match(claimSource, /credentials: "include"/);
  assert.doesNotMatch(claimSource, /Authorization|\bbody\s*:/);
  assert.ok(
    claimSource.indexOf("requiresPairingCode") <
      claimSource.indexOf("baseAwareURL(PWA_CLAIM_PATH"),
    "health policy must be known before attempting a credential-free claim",
  );
  assert.match(
    prepareSource,
    /if \(!state\.token\)[\s\S]*claimTokenWithoutPairingCode\(\)[\s\S]*if \(!state\.token\)[\s\S]*claimStandaloneToken\(\)/,
  );
  assert.match(prepareSource, /showPairingGate\(invalidToken \|\| state\.installCredentialRejected\)/);
  assert.doesNotMatch(bootstrapSource, /showPairingGate/);
  assert.match(prepareSource, /else await prepareAndConnect\(true\)/);
  assert.doesNotMatch(html, /00000000/);
  assert.match(claimSource, /state\.installCredential = ""/);
});

test("working-only wake eligibility rejects idle, legacy, hidden, and disconnected states", async () => {
  const script = await readText("app.js");
  const isExplicitWorkingProtection = namedFunction(
    script,
    "isExplicitWorkingProtection",
  );
  const workingWakeEligible = namedFunction(script, "workingWakeEligible");
  assert.equal(
    isExplicitWorkingProtection({ hasActiveTasks: true, status: "active" }),
    true,
  );
  assert.equal(isExplicitWorkingProtection({ activeTaskCount: 3 }), false);
  assert.equal(
    isExplicitWorkingProtection({ hasActiveTasks: false, status: "active" }),
    false,
  );
  assert.equal(
    isExplicitWorkingProtection({ hasActiveTasks: true, status: "failed" }),
    false,
  );

  const active = {
    enabled: true,
    workActive: true,
    connected: true,
    hidden: false,
  };
  assert.equal(workingWakeEligible(active), true);
  for (const field of ["enabled", "workActive", "connected"]) {
    assert.equal(workingWakeEligible({ ...active, [field]: false }), false);
  }
  assert.equal(workingWakeEligible({ ...active, hidden: true }), false);
  assert.match(script, /deactivateWorkingWake\(\{ reset = false \} = \{\}\)/);
  assert.match(script, /stopWakeMedia\(\{ reset \}\)/);
  assert.match(script, /void releaseWakeLock\(\)/);
  assert.match(script, /requestWakeLock\(generation\)/);
});

test("wake media stays background-only with no visible action or tab stop", async () => {
  const html = await readText("index.html");
  const css = await readText("app.css");
  const script = await readText("app.js");
  const videoRule = css.match(/\.task-ambient-video\s*\{([^}]*)\}/s)?.[1] || "";
  assert.match(videoRule, /width:\s*12px/);
  assert.match(videoRule, /height:\s*12px/);
  assert.match(videoRule, /background:\s*var\(--activity-background\)/);
  assert.doesNotMatch(videoRule, /display:\s*none/);
  assert.doesNotMatch(videoRule, /opacity:\s*0(?:;|\s)/);
  assert.doesNotMatch(html, /wake-media-(?:button|status)|Enable while working/);
  assert.doesNotMatch(css, /\.wake-media-(?:button|status)/);
  assert.doesNotMatch(script, /wakeMedia(?:Button|Status)|authorizeWorkingWake/);
});

test("quota curve keeps the pace guide alongside forecasts and series marks", async () => {
  const script = await readText("app.js");
  const quotaTimeTicks = namedFunction(script, "quotaTimeTicks");
  const hour = 3_600_000;
  const day = 86_400_000;
  assert.deepEqual(quotaTimeTicks(0, 4 * hour), [0.25, 0.5, 0.75]);
  assert.equal(quotaTimeTicks(0, 24 * hour).length, 23);
  assert.deepEqual(quotaTimeTicks(0, 3 * day), [1 / 3, 2 / 3]);
  assert.deepEqual(quotaTimeTicks(0, 9 * day), []);
  assert.match(script, /const left = 30;[\s\S]*const right = 8;[\s\S]*const top = 8;[\s\S]*const bottom = 18;/);
  assert.match(script, /const hasPace = model\.hasCurrentIntervalPace === true/);
  assert.match(script, /model\.hasCurrentIntervalPace == null/);
  assert.match(script, /model\.paceGuideTone === "reserve"/);
  assert.match(script, /context\.setLineDash\(\[3, 3\]\)/);
  assert.match(script, /context\.setLineDash\(\[2, 3\]\)/);
  assert.match(script, /gradient\.addColorStop\(0, rgba\(tint, 0\.22\)\)/);
  assert.match(script, /gradient\.addColorStop\(1, rgba\(tint, 0\.03\)\)/);
  assert.match(script, /context\.lineWidth = 2/);
  assert.match(script, /context\.arc\(point\.x, point\.y, 2,/);
  assert.match(script, /Array\.isArray\(model\.consumptionForecasts\)/);
  assert.match(script, /context\.setLineDash\(\[5, 4\]\)/);
  assert.match(script, /Math\.min\(forecastExhaustion, endTimestamp\)/);
  assert.match(script, /forecastOpacities = \[0\.62, 0\.44, 0\.31, 0\.22, 0\.15\]/);
});

test("primary quota curve renders matching 5h or weekly cycle history", async () => {
  const css = await readText("app.css");
  const script = await readText("app.js");
  const orderedUtilizationCycles = namedFunction(
    script,
    "orderedUtilizationCycles",
  );
  const cycleLeftPercent = namedFunction(
    script,
    "cycleLeftPercent",
    `const safeNumber = (value, fallback = 0) => {
       const number = Number(value);
       return Number.isFinite(number) ? number : fallback;
     };
     const clamp = (value, minimum, maximum) =>
       Math.min(maximum, Math.max(minimum, safeNumber(value)))`,
  );
  const renderSource = namedFunction(script, "renderQuotaModel").toString();
  const cyclesSource = namedFunction(script, "renderQuotaCycles").toString();
  const model = {
    resetsAt: "2026-08-08T03:35:00Z",
    remainingPercent: 94,
  };
  assert.deepEqual(
    orderedUtilizationCycles({
      cycles: [
        { resetsAt: "2026-08-08T03:35:00Z", usedPercent: 18 },
        { resetsAt: "2026-08-01T03:35:00Z", usedPercent: 65 },
      ],
    }).map((cycle) => cycle.usedPercent),
    [65, 18],
  );
  assert.equal(
    cycleLeftPercent(
      { resetsAt: "2026-08-08T03:35:30Z", usedPercent: 18 },
      model,
    ),
    94,
    "The in-progress cycle mirrors the current remaining value.",
  );
  assert.equal(
    cycleLeftPercent(
      { resetsAt: "2026-08-01T03:35:00Z", usedPercent: 65 },
      model,
    ),
    35,
  );
  assert.match(cyclesSource, /model\.isShortWindow === true \? "shortCycles" : "weeklyCycles"/);
  assert.match(cyclesSource, /cycleLeftPercent\(cycle, model\)/);
  assert.match(renderSource, /renderQuotaCycles\(model\)/);
  assert.match(renderSource, /row\.classList\.add\("has-cycles"\)/);
  assert.match(css, /\.quota-model-card\.has-cycles\s*\{[^}]*2\.428571rem/s);
  assert.match(css, /\.quota-cycle-bars\s*\{[^}]*align-items:\s*stretch/s);
  assert.match(css, /\.quota-cycle-used\s*\{[^}]*background:\s*var\(--green\)/s);
});

test("quota ordering selects at most one stable primary chart and renders complete quotes", async () => {
  const script = await readText("app.js");
  const orderedQuotaModels = namedFunction(script, "orderedQuotaModels");
  const quota = {
    providers: [
      {
        id: "openai",
        models: [
          { modelName: "secondary", displayOrder: 1, rendersAreaChart: true },
          { modelName: "primary", displayOrder: 0, rendersAreaChart: false },
        ],
      },
    ],
  };
  assert.deepEqual(
    orderedQuotaModels(quota).map(({ model }) => model.modelName),
    ["primary", "secondary"],
  );
  quota.providers[0].models.reverse();
  assert.deepEqual(
    orderedQuotaModels(quota).map(({ model }) => model.modelName),
    ["primary", "secondary"],
  );
  assert.equal(
    orderedQuotaModels({ providers: [{ id: "openai", models: [] }] }).length,
    0,
  );

  const renderQuotaSource = namedFunction(script, "renderQuota").toString();
  const quoteSource = namedFunction(script, "renderQuotaQuote").toString();
  const modelSource = namedFunction(script, "renderQuotaModel").toString();
  const rotateSource = namedFunction(script, "rotateCoreContent").toString();
  assert.match(renderQuotaSource, /findIndex[\s\S]*rendersAreaChart === true/);
  assert.match(
    renderQuotaSource,
    /if \(models\.length === 0\)[\s\S]*replaceChildren\(emptyState\(t\("emptyQuota"\)\)\)[\s\S]*return/,
  );
  assert.match(renderQuotaSource, /"quota-primary"/);
  assert.doesNotMatch(renderQuotaSource, /`quota-\$\{index\}`/);
  assert.match(quoteSource, /providerName[\s\S]*accountName[\s\S]*model\.modelName/);
  assert.match(quoteSource, /paceDeltaPercent/);
  assert.match(quoteSource, /quotaUsedText/);
  assert.match(quoteSource, /quotaWeeklyText/);
  assert.match(quoteSource, /quotaResetText/);
  for (const source of [modelSource, quoteSource]) {
    assert.match(source, /typeof model\.accountName === "string"/);
    assert.match(source, /\.filter\(Boolean\)\.join\(" \/ "\)/);
    assert.doesNotMatch(source, /defaultAccount/);
    assert.doesNotMatch(source, /\$\{accountName\}[^`]*`\s*,?\s*\)\s*;?\s*$/m);
    assert.doesNotMatch(source, /localStorage|sessionStorage|\.title\s*=/);
  }
  assert.match(rotateSource, /querySelectorAll\("\.quota-quote-strip"\)/);
  assert.doesNotMatch(rotateSource, /firstElementChild/);
});

test("activity summary state matrix never promotes stale or unavailable work", async () => {
  const script = await readText("app.js");
  const normalizedActivitySummary = namedFunction(
    script,
    "normalizedActivitySummary",
    `const ACTIVITY_STATES = new Set(["idle", "working", "stale", "unavailable"]);
     const ACTIVITY_EVENT_COPY_KEYS = { taskStarted: "eventTaskStarted", taskFinished: "eventTaskFinished" };
     const ACTIVITY_PHASE_COPY_KEYS = { thinking: "phaseThinking", usingTool: "phaseUsingTool", unknown: "phaseUnknown" };
     const ACTIVITY_TOOL_CATEGORY_COPY_KEYS = { shell: "toolShell", other: "toolOther" };
     const ACTIVITY_TOOL_STATUS_COPY_KEYS = { inProgress: "toolInProgress", unknown: "toolStatusUnknown" };
     const safeNumber = (value, fallback = 0) => {
       const number = Number(value);
       return Number.isFinite(number) ? number : fallback;
     }`,
  );
  const protection = { activeTaskCount: 4, lastActivityAt: "2026-08-01T00:00:00Z" };
  const working = normalizedActivitySummary({
    state: "working",
    activeTaskCount: 2,
    oldestStartedAt: "2026-08-01T00:00:00Z",
    elapsedSeconds: 90,
    phase: "usingTool",
    toolCategory: "shell",
    toolStatus: "inProgress",
    progressLines: ["Running approved checks", "Reviewing results", "ignored"],
    recentEvents: [{ kind: "taskStarted", at: "2026-08-01T00:00:01Z" }],
  }, protection);
  assert.equal(working.state, "working");
  assert.equal(working.elapsedSeconds, 90);
  assert.equal(working.phase, "usingTool");
  assert.equal(working.toolCategory, "shell");
  assert.equal(working.toolStatus, "inProgress");
  assert.deepEqual(working.progressLines, ["Running approved checks", "Reviewing results"]);
  assert.equal(working.recentEvents.length, 1);

  for (const activityState of ["idle", "stale", "unavailable"]) {
    const summary = normalizedActivitySummary({
      state: activityState,
      activeTaskCount: 7,
      oldestStartedAt: "2026-08-01T00:00:00Z",
      elapsedSeconds: 90,
    }, protection);
    assert.equal(summary.state, activityState);
    assert.equal(summary.oldestStartedAt, null);
    assert.equal(summary.elapsedSeconds, null);
    assert.deepEqual(summary.progressLines, []);
  }
  const empty = normalizedActivitySummary({
    state: "idle",
    activeTaskCount: 0,
    elapsedSeconds: 90,
    recentEvents: [{ kind: "rawTitle", at: "2026-08-01T00:00:01Z" }],
  }, protection);
  assert.equal(empty.activeTaskCount, 0);
  assert.deepEqual(empty.recentEvents, []);
  assert.deepEqual(empty.progressLines, []);

  const protectionSource = namedFunction(script, "renderProtection").toString();
  assert.match(
    protectionSource,
    /const tasks = activitySummary\.state === "working" \? reportedTasks : 0/,
  );
  assert.match(
    protectionSource,
    /renderActivityTelemetry\([\s\S]*activitySummary,[\s\S]*warning,[\s\S]*activityDetailLines\(activitySummary\)/,
  );
  assert.match(
    protectionSource,
    /updateTaskState\(tasks, activitySummary\.state !== "idle"\)/,
  );
});

test("active provider mix drives hero copy, quota order, and section visibility", async () => {
  const css = await readText("app.css");
  const script = await readText("app.js");
  const activityProviderMix = namedFunction(
    script,
    "activityProviderMix",
    "const safeNumber = (value) => Number.isFinite(Number(value)) ? Number(value) : 0",
  );

  assert.equal(activityProviderMix(null), "none");
  assert.equal(
    activityProviderMix({ state: "idle", activeTaskCount: 0 }),
    "none",
  );
  assert.equal(
    activityProviderMix({ state: "stale", activeTaskCount: 2, activeProviders: ["kimi"] }),
    "none",
  );
  assert.equal(
    activityProviderMix({
      state: "working",
      activeTaskCount: 1,
      activeProviders: ["kimi"],
    }),
    "kimi",
  );
  assert.equal(
    activityProviderMix({
      state: "working",
      activeTaskCount: 2,
      activeProviders: ["kimi", "codex", "kimi", "other"],
    }),
    "mixed",
  );
  // Snapshots from older builds lack the field: derive from working tasks.
  assert.equal(
    activityProviderMix({
      state: "working",
      activeTaskCount: 1,
      tasks: [{ state: "working", source: "Kimi Code" }],
    }),
    "kimi",
  );
  assert.equal(
    activityProviderMix({
      state: "working",
      activeTaskCount: 2,
      tasks: [
        { state: "working", modelProvider: "Kimi" },
        { state: "working", modelProvider: "OpenAI" },
        { state: "stale", source: "Kimi Code" },
      ],
    }),
    "mixed",
  );

  const envelopeSource = namedFunction(script, "renderEnvelope").toString();
  assert.match(
    envelopeSource,
    /dataset\.activeProviders = state\.activeProviderMix/,
  );
  assert.match(
    envelopeSource,
    /activityProviderMix\(snapshot\.activitySummary\)[\s\S]*renderQuota\(/,
  );

  const commitSource = namedFunction(script, "commitTaskState").toString();
  assert.match(commitSource, /dataset\.activeProviders = providerMix/);
  assert.match(commitSource, /taskStateKickerKimi/);
  assert.match(commitSource, /taskStateKickerGeneric/);

  const renderQuotaSource = namedFunction(script, "renderQuota").toString();
  assert.match(
    renderQuotaSource,
    /hasChanged\("quota", \{ quota, providerMix \}/,
  );
  assert.match(renderQuotaSource, /provider\?\.id === "kimi"/);

  assert.match(script, /taskStateKickerKimi: "Kimi activity"/);
  assert.match(script, /taskStateKickerKimi: "Kimi 活动"/);
  assert.match(script, /taskStateKickerGeneric: "Activity"/);
  assert.match(script, /taskStateKickerGeneric: "活动"/);

  assert.match(
    css,
    /body\[data-active-providers="kimi"\] \.route-section,\s*body\[data-active-providers="kimi"\] \.connections-section\s*\{[^}]*display:\s*none/s,
  );
});

test("grainy digital rain is bounded, state-derived, and lifecycle controlled", async () => {
  const html = await readText("index.html");
  const css = await readText("app.css");
  const script = await readText("app.js");
  const taskRainProfile = namedFunction(
    script,
    "taskRainProfile",
    "const safeNumber = (value) => Number.isFinite(Number(value)) ? Number(value) : 0",
  );
  assert.deepEqual(taskRainProfile(1), { columns: 18, framesPerSecond: 5 });
  assert.deepEqual(taskRainProfile(2), { columns: 24, framesPerSecond: 6 });
  assert.deepEqual(taskRainProfile(99), { columns: 30, framesPerSecond: 7 });

  const taskRainSeed = namedFunction(
    script,
    "taskRainSeed",
    `const ACTIVITY_EVENT_COPY_KEYS = { taskStarted: "eventTaskStarted" };
     const safeNumber = (value, fallback = 0) => {
       const number = Number(value);
       return Number.isFinite(number) ? number : fallback;
     }`,
  );
  const summary = {
    state: "working",
    activeTaskCount: 1,
    oldestStartedAt: "2026-08-01T00:00:00Z",
    lastActivityAt: "2026-08-01T00:00:01Z",
    recentEvents: [{ kind: "taskStarted", at: "2026-08-01T00:00:01Z" }],
    progressLines: [],
  };
  assert.equal(
    taskRainSeed(summary),
    taskRainSeed({ ...summary, title: "secret", output: "raw tool output" }),
  );
  assert.notEqual(
    taskRainSeed(summary),
    taskRainSeed({ ...summary, progressLines: ["Approved progress"] }),
  );
  assert.equal((html.match(/class="matrix-rain-canvas"/g) || []).length, 1);
  assert.match(css, /\.matrix-rain-canvas\s*\{[^}]*z-index:\s*0;[^}]*pointer-events:\s*none/s);
  assert.match(css, /\.task-energy-field\s*\{[^}]*position:\s*absolute;[^}]*inset:\s*0;[^}]*z-index:\s*0/s);
  assert.match(script, /tailLength:\s*4 \+ Math\.floor\(random\(\) \* 5\)/);
  assert.match(script, /for \(let tail = column\.tailLength; tail >= 1; tail -= 1\)/);
  const foregroundRules = [...css.matchAll(
    /\.task-(?:state-copy|state-meta|title-line|state-title|state-detail|state-warning|telemetry-line|kicker)(?:[\s,:][^{]*)?\{([^}]*)\}/g,
  )].map((match) => match[1]).join("\n");
  assert.doesNotMatch(foregroundRules, /background|backdrop|filter|mask/);
  assert.match(script, /Math\.min\(cap, window\.devicePixelRatio \|\| 1\)/);
  assert.match(script, /window\.setTimeout\([\s\S]*1_000 \/ profile\.framesPerSecond/);
  assert.match(script, /reducedMotion[\s\S]*if \(reducedMotion\) return/);
  assert.match(script, /state\.connected[\s\S]*!document\.hidden/);
  assert.match(script, /stopTaskRain\(\{ clear: true \}\)/);
  assert.doesNotMatch(css, /(?:filter|box-shadow):/);
});

test("activity background effect switches independently and defaults safely", async () => {
  const css = await readText("app.css");
  const script = await readText("app.js");
  const envelopeSource = namedFunction(script, "renderEnvelope").toString();
  const telemetrySource = namedFunction(script, "renderActivityTelemetry").toString();
  const seedSource = namedFunction(script, "taskRainSeed").toString();
  assert.match(envelopeSource, /ACTIVITY_EFFECTS\.has\([\s\S]*"grainyDigitalRain"/);
  assert.match(envelopeSource, /document\.body\.dataset\.activityEffect = nextActivityEffect/);
  assert.match(envelopeSource, /snapshot\.activitySummary/);
  assert.match(
    envelopeSource,
    /if \(activityEffectChanged \|\| colorSchemeChanged\) configureTaskRain\(true\)/,
  );
  assert.match(css, /data-activity-effect="grainyDigitalRain"/);
  assert.match(css, /data-activity-effect="dotWaves"/);
  assert.match(css, /data-activity-effect="taskTelemetryMarquee"/);
  assert.doesNotMatch(telemetrySource, /localStorage|dataset|setAttribute/);
  assert.doesNotMatch(seedSource, /detail|title|output|localStorage|dataset/);
});

test("task telemetry barrage carries every approved per-task field safely", async () => {
  const css = await readText("app.css");
  const script = await readText("app.js");
  const fragments = namedFunction(
    script,
    "taskTelemetryFragments",
    `const TASK_TELEMETRY_MAX_LANES = 5;
     const TASK_TELEMETRY_FIELD_ORDER = ["title", "state", "phase", "project", "gitBranch", "source", "model", "modelProvider", "reasoningEffort", "sandboxPolicy", "approvalMode", "tokensUsed", "activeSubtasks", "subtaskNames", "createdAt", "startedAt", "elapsed", "lastUpdated", "cliVersion", "tool", "recentEvent", "progress"];
     const state = { language: "en", taskTelemetryFields: new Set(TASK_TELEMETRY_FIELD_ORDER) };
     const fingerprint = JSON.stringify;
     const ACTIVITY_PHASE_COPY_KEYS = { testing: "phaseTesting", unknown: "phaseUnknown" };
     const ACTIVITY_TOOL_CATEGORY_COPY_KEYS = { shell: "toolShell" };
     const ACTIVITY_TOOL_STATUS_COPY_KEYS = { inProgress: "toolInProgress" };
     const ACTIVITY_EVENT_COPY_KEYS = { toolStarted: "eventToolStarted" };
     const t = (key, values = {}) => values.n == null ? key : key + " " + values.n;
     const formatDate = () => "START";
     const formatInteger = (value) => "INTEGER_" + value;
     const formatDuration = () => "DURATION";
     const formatRelative = () => "RELATIVE";
     const shuffledTaskTelemetryFragments = (_task, _index, fields) => fields;
     const applyTaskTelemetrySpeedTiers = (rows) => rows.map((row) => ({ ...row, speedTier: 0 }));`,
  );
  const taskFixture = {
    state: "working",
    title: "Review active tasks",
    projectName: "ai-quota-bar",
    gitBranch: "codex/task-barrage",
    source: "vscode / user",
    model: "gpt-5.6-sol",
    modelProvider: "openai",
    reasoningEffort: "xhigh",
    sandboxPolicy: "danger-full-access",
    approvalMode: "never",
    tokensUsed: 12345,
    activeSubtaskCount: 2,
    subtaskNames: ["Curie", "Turing"],
    createdAt: "2026-08-02T23:55:00Z",
    startedAt: "2026-08-03T00:00:00Z",
    elapsedSeconds: 120,
    lastActivityAt: "2026-08-03T00:02:00Z",
    cliVersion: "1.2.3",
    phase: "testing",
    toolCategory: "shell",
    toolStatus: "inProgress",
    progressLines: ["Running the focused suite"],
    recentEvents: [{ kind: "toolStarted", at: "2026-08-03T00:01:00Z" }],
  };
  const lines = fragments({
    activeTaskCount: 1,
    tasks: [taskFixture],
  }).map((row) => row.text).join("|");
  for (const expected of [
    "Review active tasks",
    "ai-quota-bar",
    "codex/task-barrage",
    "vscode / user",
    "gpt-5.6-sol",
    "openai",
    "xhigh",
    "danger-full-access",
    "never",
    "INTEGER_12345",
    "taskTelemetrySubtasks 2",
    "Curie / Turing",
    "START",
    "DURATION",
    "RELATIVE",
    "phaseTesting",
    "toolShell",
    "toolInProgress",
    "eventToolStarted",
    "Running the focused suite",
    "1.2.3",
  ]) assert.match(lines, new RegExp(expected.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));

  const taskRows = fragments({
    activeTaskCount: 2,
    tasks: [
      { ...taskFixture, title: "ONLY_TASK_ALPHA" },
      { ...taskFixture, title: "ONLY_TASK_BRAVO" },
    ],
  });
  assert.equal(taskRows.length, 2, "one active task maps to one barrage row");
  assert.match(taskRows[0].text, /ONLY_TASK_ALPHA/);
  assert.doesNotMatch(taskRows[0].text, /ONLY_TASK_BRAVO/);
  assert.match(taskRows[1].text, /ONLY_TASK_BRAVO/);
  assert.doesNotMatch(taskRows[1].text, /ONLY_TASK_ALPHA/);
  const selectedRow = fragments(
    { activeTaskCount: 1, tasks: [taskFixture] },
    new Set(["title", "tool"]),
  )[0].text;
  assert.match(selectedRow, /Review active tasks/);
  assert.match(selectedRow, /toolShell/);
  assert.doesNotMatch(selectedRow, /gpt-5\.6-sol|Running the focused suite|DURATION/);

  const shuffledCopy = namedFunction(script, "shuffledCopy");
  const seededRandom = namedFunction(script, "seededRandom");
  const fieldSeed = namedFunction(
    script,
    "taskTelemetryFieldSeed",
    `const state = { taskTelemetryOrderSalt: 1 };
     const fingerprint = JSON.stringify;`,
  );
  const shuffledFields = namedFunction(
    script,
    "shuffledTaskTelemetryFragments",
    `const state = { taskTelemetryOrderSalt: 1 };
     const fingerprint = JSON.stringify;
     const shuffledCopy = ${shuffledCopy.toString()};
     const seededRandom = ${seededRandom.toString()};
     const taskTelemetryFieldSeed = ${fieldSeed.toString()};`,
  );
  const fieldNames = [
    "TITLE", "STATE", "PHASE", "PROJECT", "MODEL", "ELAPSED", "TOOL",
  ];
  const firstOrder = shuffledFields(taskFixture, 0, fieldNames, 0x1234_5678);
  const repeatedOrder = shuffledFields(
    { ...taskFixture, tokensUsed: 99_999, lastActivityAt: "later" },
    0,
    fieldNames,
    0x1234_5678,
  );
  const secondLaneOrder = shuffledFields(
    taskFixture,
    1,
    fieldNames,
    0x1234_5678,
  );
  assert.deepEqual(firstOrder, repeatedOrder, "live values never reshuffle a task row");
  assert.notDeepEqual(firstOrder, secondLaneOrder, "each task lane gets its own field order");
  assert.deepEqual(
    [...firstOrder].sort(),
    [...fieldNames].sort(),
    "field randomization neither drops nor duplicates telemetry",
  );

  const renderSource = namedFunction(
    script,
    "renderTaskTelemetryMarquee",
  ).toString();
  assert.match(renderSource, /replaceChildren/);
  assert.match(script, /const TASK_TELEMETRY_MAX_LANES = 5/);
  assert.doesNotMatch(renderSource, /replaceChildren\(\.\.\.tracks\)/);
  assert.doesNotMatch(renderSource, /innerHTML|insertAdjacentHTML|setInterval/);
  assert.match(css, /inset-block-start:\s*var\(--telemetry-lane-start, 0%\)/);
  assert.match(css, /block-size:\s*var\(--telemetry-lane-height, 100%\)/);
  assert.match(css, /font-size:\s*var\(--telemetry-font-size, 11px\)/);
  assert.match(css, /\.task-telemetry-track\s*\{[\s\S]*transform:\s*translate3d/);
  assert.doesNotMatch(css, /@keyframes task-telemetry-cross/);
  const laneAnimationSource = namedFunction(
    script,
    "startTaskTelemetryLaneAnimation",
  ).toString();
  assert.match(laneAnimationSource, /track\.animate/);
  assert.match(laneAnimationSource, /easing:\s*"linear"/);
  assert.match(laneAnimationSource, /updatePlaybackRate/);
  assert.doesNotMatch(laneAnimationSource, /requestAnimationFrame|offsetWidth|clientWidth/);
  assert.match(
    css,
    /@media \(prefers-reduced-motion: reduce\)[\s\S]*\.task-telemetry-track\s*\{[\s\S]*transform:/,
  );

  const container = {
    children: [],
    replaceCount: 0,
    get childElementCount() { return this.children.length; },
    get lastElementChild() { return this.children.at(-1) || null; },
    append(node) {
      node.remove = () => {
        const index = this.children.indexOf(node);
        if (index >= 0) this.children.splice(index, 1);
      };
      this.children.push(node);
    },
    replaceChildren(...nodes) {
      this.replaceCount += 1;
      this.children = nodes;
    },
  };
  globalThis.__taskTelemetryContainer = container;
  const render = namedFunction(
    script,
    "renderTaskTelemetryMarquee",
    `const TASK_TELEMETRY_MAX_LANES = 5;
     const elements = { taskTelemetryMarquee: globalThis.__taskTelemetryContainer };
     const refreshTaskTelemetryViewportScale = () => 1;
     const taskTelemetryFragments = (summary) => summary.fragments.map((text, index) => ({ key: "task-" + index, text }));
     const hasChanged = () => true;
     const stopTaskTelemetryMotion = () => {};
     const configureTaskTelemetryMotion = () => {};
     const updateTaskTelemetryLane = (lane, row) => { lane.receivedRow = row; };
     const setTaskTelemetryLaneSpeed = (lane, tier) => { lane.receivedSpeedTier = tier; };
     const taskTelemetryCurrentOffset = () => 0;
     const ensureTaskTelemetryTail = () => {};
     const element = (_tag, className) => ({
       className,
       dataset: {},
       textContent: "",
       children: [],
       get childElementCount() { return this.children.length; },
       get firstElementChild() { return this.children[0] || null; },
       get lastElementChild() { return this.children.at(-1) || null; },
       append(node) {
         node.remove = () => {
           const index = this.children.indexOf(node);
           if (index >= 0) this.children.splice(index, 1);
         };
         this.children.push(node);
       },
       style: {
         writes: 0,
         values: new Map(),
         setProperty(name, value) {
           this.writes += 1;
           this.values.set(name, value);
         },
       },
     });`,
  );
  for (let count = 1; count <= 5; count += 1) {
    render({ fragments: Array.from({ length: count }, (_, index) => `T${index}`) });
    assert.equal(
      container.children.length,
      count,
      `${count} active tasks render ${count} barrage rows`,
    );
  }
  assert.deepEqual(
    container.children.map((track) => track.style.values.get("--telemetry-lane-start")),
    ["0%", "20%", "40%", "60%", "80%"],
  );
  assert.deepEqual(
    container.children.map((track) => track.style.values.get("--telemetry-lane-height")),
    ["20%", "20%", "20%", "20%", "20%"],
  );
  assert.deepEqual(
    container.children.map((track) => track.style.values.get("--telemetry-font-size")),
    ["13cqh", "13cqh", "13cqh", "13cqh", "13cqh"],
  );
  const originalTracks = [...container.children];
  render({ fragments: ["A2", "B2", "C2", "D2", "E2"] });
  assert.deepEqual(
    container.children,
    originalTracks,
    "live telemetry updates preserve moving track nodes",
  );
  assert.deepEqual(
    originalTracks.map((lane) => lane.receivedRow.text),
    ["A2", "B2", "C2", "D2", "E2"],
  );
  assert.equal(container.replaceCount, 0, "active updates never replace tracks");
  delete globalThis.__taskTelemetryContainer;

  const ageTier = namedFunction(
    script,
    "taskTelemetryAgeTier",
    `const TASK_TELEMETRY_AGE_THRESHOLDS_SECONDS = [180, 600, 1800, 5400];`,
  );
  assert.deepEqual(
    [0, 179, 180, 599, 600, 1799, 1800, 5399, 5400].map(ageTier),
    [0, 0, 1, 1, 2, 2, 3, 3, 4],
  );
  const assignSpeedTiers = namedFunction(
    script,
    "applyTaskTelemetrySpeedTiers",
    `const TASK_TELEMETRY_SPEEDS_PX_PER_SECOND = [48, 40, 34, 29, 25];
     const TASK_TELEMETRY_AGE_THRESHOLDS_SECONDS = [180, 600, 1800, 5400];
     const taskTelemetryAgeTier = ${ageTier.toString()};`,
  );
  const freshRows = assignSpeedTiers([
    { key: "newest", ageSeconds: 10 },
    { key: "older", ageSeconds: 20 },
  ]);
  assert.deepEqual(
    freshRows.map((row) => row.speedTier),
    [0, 1],
    "a second fresh task makes the older lane one speed tier slower",
  );
  assert.equal(
    assignSpeedTiers([{ key: "long", ageSeconds: 7_200 }])[0].speedTier,
    4,
    "a long-running task remains slow even when it is the only lane",
  );
  const refreshViewportScale = namedFunction(
    script,
    "refreshTaskTelemetryViewportScale",
    `const TASK_TELEMETRY_REFERENCE_ROOT_FONT_SIZE_PX = 14;
     const state = { taskTelemetryViewportScale: 1 };
     const document = { documentElement: {} };
     const window = { getComputedStyle: () => ({ fontSize: "28px" }) };`,
  );
  assert.equal(refreshViewportScale(), 2);
  const scaledSpeed = namedFunction(
    script,
    "taskTelemetrySpeedPxPerSecond",
    `const TASK_TELEMETRY_SPEEDS_PX_PER_SECOND = [48, 40, 34, 29, 25];
     const taskTelemetryViewportScale = () => 2;`,
  );
  assert.equal(scaledSpeed(0), 96, "marquee speed scales with the dashboard");
  const setLaneSpeed = namedFunction(
    script,
    "setTaskTelemetryLaneSpeed",
    `const TASK_TELEMETRY_SPEEDS_PX_PER_SECOND = [48, 40, 34, 29, 25];
     const TASK_TELEMETRY_REFERENCE_SPEED_PX_PER_SECOND = 44;
     const taskTelemetrySpeedPxPerSecond = (tier) => TASK_TELEMETRY_SPEEDS_PX_PER_SECOND[tier];
     const taskTelemetryLaneState = (lane) => lane.laneState;`,
  );
  const playbackRates = [];
  const speedLane = {
    dataset: {},
    laneState: {
      speedTier: 0,
      speedPxPerSecond: 48,
      animation: { updatePlaybackRate: (rate) => playbackRates.push(rate) },
    },
  };
  setLaneSpeed(speedLane, 3);
  assert.equal(speedLane.dataset.telemetrySpeedTier, "4");
  assert.equal(speedLane.laneState.speedPxPerSecond, 29);
  assert.deepEqual(playbackRates, [29 / 44]);

  const updateLane = namedFunction(
    script,
    "updateTaskTelemetryLane",
    `const taskTelemetryGapPx = () => 48;
     const taskTelemetryLaneState = (lane) => lane.laneState;
     const taskTelemetryCurrentOffset = (lane) => lane.laneState.baseOffset;
     const resetTaskTelemetryLane = () => { throw new Error("unexpected reset"); };
     const appendTaskTelemetryMessage = (track, text) => track.append({ textContent: text, offsetLeft: 1000 });`,
  );
  const visibleMessage = { textContent: "VISIBLE", offsetLeft: 0 };
  const movingTrack = {
    children: [visibleMessage],
    get lastElementChild() { return this.children.at(-1) || null; },
    append(node) { this.children.push(node); },
  };
  const movingLane = {
    firstElementChild: movingTrack,
    laneState: { taskKey: "same", latestText: "VISIBLE", baseOffset: 10 },
  };
  updateLane(movingLane, { key: "same", text: "NEXT" });
  assert.equal(visibleMessage.textContent, "VISIBLE", "visible subtitle stays frozen");
  assert.equal(movingTrack.children.length, 2, "new snapshot appends behind visible text");
  updateLane(movingLane, { key: "same", text: "LATEST" });
  assert.equal(movingTrack.children.length, 2, "offscreen tail snapshots coalesce");
  assert.equal(movingTrack.children[1].textContent, "LATEST");
});

test("idle blackout requires a live confirmed idle signal and isolates the dashboard", async () => {
  const html = await readText("index.html");
  const css = await readText("app.css");
  const script = await readText("app.js");
  const idleBlackoutEligible = namedFunction(script, "idleBlackoutEligible");
  const randomUnit = namedFunction(script, "randomUnit");
  const idleScreensaverPosition = namedFunction(
    script,
    "idleScreensaverPosition",
    `const randomUnit = ${randomUnit.toString()};`,
  );
  const seededRandom = (initialSeed) => {
    let seed = initialSeed >>> 0;
    return () => {
      seed = (seed * 1_664_525 + 1_013_904_223) >>> 0;
      return seed / 0x1_0000_0000;
    };
  };
  const firstPosition = idleScreensaverPosition(seededRandom(1));
  const secondPosition = idleScreensaverPosition(seededRandom(2));
  const nextPosition = idleScreensaverPosition(seededRandom(3), firstPosition);
  for (const position of [firstPosition, secondPosition, nextPosition]) {
    assert.ok(position.x >= 36 && position.x <= 64);
    assert.ok(position.y >= 32 && position.y <= 68);
  }
  assert.notDeepEqual(firstPosition, secondPosition, "each IDLE entry gets a fresh position");
  assert.ok(
    Math.hypot(nextPosition.x - firstPosition.x, nextPosition.y - firstPosition.y) >= 15,
    "successive positions visibly move the oversized word",
  );
  const eligible = {
    enabled: true,
    activityState: "idle",
    connected: true,
    hidden: false,
  };
  assert.equal(idleBlackoutEligible(eligible), true);
  for (const field of ["enabled", "connected"]) {
    assert.equal(idleBlackoutEligible({ ...eligible, [field]: false }), false);
  }
  assert.equal(idleBlackoutEligible({ ...eligible, hidden: true }), false);
  for (const activityState of ["working", "stale", "unavailable", undefined]) {
    assert.equal(idleBlackoutEligible({ ...eligible, activityState }), false);
  }

  const setSource = namedFunction(script, "setIdleBlackout").toString();
  const randomizeSource = namedFunction(script, "randomizeIdleScreensaver").toString();
  const scheduleSource = namedFunction(script, "scheduleIdleScreensaverMove").toString();
  const envelopeSource = namedFunction(script, "renderEnvelope").toString();
  const disconnectSource = namedFunction(script, "disconnect").toString();
  assert.match(script, /taskIdle: "Idle",\s*idleBlackout: "IDLE"/);
  assert.match(script, /taskIdle: "空闲",\s*idleBlackout: "空闲"/);
  assert.match(envelopeSource, /envelope\.idleBlackoutMarqueeEnabled === true/);
  assert.match(envelopeSource, /configureIdleBlackout\([\s\S]*snapshot\.activitySummary/);
  assert.match(setSource, /elements\.page\.inert = true/);
  assert.match(setSource, /elements\.page\.setAttribute\("aria-hidden", "true"\)/);
  assert.match(setSource, /elements\.idleBlackout\.hidden = false/);
  assert.match(setSource, /randomizeIdleScreensaver\(\)/);
  assert.ok(
    setSource.indexOf("randomizeIdleScreensaver()")
      < setSource.indexOf("elements.idleBlackout.hidden = false"),
    "IDLE randomness is applied once before the screen becomes visible",
  );
  assert.match(randomizeSource, /--idle-x/);
  assert.match(randomizeSource, /--idle-y/);
  assert.match(setSource, /scheduleIdleScreensaverMove\(\)/);
  assert.match(setSource, /stopIdleScreensaverMotion\(\)/);
  assert.match(scheduleSource, /window\.setTimeout/);
  assert.match(scheduleSource, /randomizeIdleScreensaver\(\)/);
  assert.match(setSource, /stopTaskRain\(\{ clear: true \}\)/);
  assert.doesNotMatch(setSource, /connect\(|disconnect\(|localStorage|sessionStorage/);
  assert.match(disconnectSource, /state\.connected = false;[\s\S]*setIdleBlackout\(false\)/);
  assert.match(css, /body\[data-idle-blackout="true"\] \.page[\s\S]*display:\s*none/);
  assert.match(
    css,
    /body\[data-idle-blackout="true"\] \.skip-link[\s\S]*display:\s*none/,
  );
  assert.match(css, /\.idle-blackout\s*\{[^}]*background:\s*#000000/);
  assert.match(css, /\.idle-screensaver-field\s*\{[^}]*inset:\s*0/s);
  assert.match(css, /\.idle-screensaver-word\s*\{[^}]*inset-block-start:\s*0/s);
  assert.match(css, /\.idle-screensaver-word\s*\{[^}]*inset-inline-start:\s*0/s);
  assert.match(css, /font-size:\s*min\(80vh, 36vw\)/);
  assert.match(
    css,
    /\.idle-screensaver-word\s*\{[^}]*translate3d\(var\(--idle-x, 50vw\), var\(--idle-y, 50vh\), 0\)[^}]*translate3d\(-50%, -50%, 0\)[^}]*rotate\(var\(--idle-rotation, 0deg\)\)/s,
  );
  assert.match(css, /@media \(orientation: portrait\)[\s\S]*--idle-rotation:\s*90deg/);
  assert.match(
    css,
    /@media \(prefers-reduced-motion: reduce\)[\s\S]*\.idle-screensaver-word\s*\{[^}]*transition:\s*none/,
  );
  assert.doesNotMatch(css, /\.idle-(?:blackout|screensaver)[\s\S]{0,800}(?:filter|box-shadow):/);
  assert.equal((html.match(/id="idle-blackout"/g) || []).length, 1);
  const idleCSS = css.slice(
    css.indexOf(".idle-blackout"),
    css.indexOf("[hidden]"),
  );
  assert.doesNotMatch(idleCSS, /(?:linear|radial|conic)-gradient|box-shadow|filter:/);
  assert.doesNotMatch(idleCSS, /--idle-(?:scale|opacity)/);
  assert.doesNotMatch(html, /--idle-(?:x|y):/);
});

test("approved progress lines override allowlisted L0 details without empty slots", async () => {
  const script = await readText("app.js");
  const activityDetailLines = namedFunction(
    script,
    "activityDetailLines",
    `const ACTIVITY_PHASE_COPY_KEYS = { thinking: "phaseThinking", unknown: "phaseUnknown" };
     const ACTIVITY_TOOL_CATEGORY_COPY_KEYS = { shell: "toolShell" };
     const ACTIVITY_TOOL_STATUS_COPY_KEYS = { inProgress: "toolInProgress" };
     const t = (key) => key`,
  );
  const base = {
    state: "working",
    activeTaskCount: 1,
    phase: "thinking",
    toolCategory: "shell",
    toolStatus: "inProgress",
    progressLines: [],
  };
  assert.deepEqual(activityDetailLines(base), [
    "phaseThinking",
    "activityTool · toolShell · toolInProgress",
  ]);
  assert.deepEqual(
    activityDetailLines({ ...base, progressLines: ["Safe one", "Safe two"] }),
    ["Safe one", "Safe two"],
  );
  assert.deepEqual(
    activityDetailLines({ ...base, state: "stale", progressLines: ["Safe one"] }),
    [],
  );
  assert.deepEqual(
    activityDetailLines({ ...base, activeTaskCount: 0, progressLines: ["Safe one"] }),
    [],
  );
  const source = namedFunction(script, "activityDetailLines").toString();
  assert.doesNotMatch(source, /localStorage|sessionStorage|dataset|setAttribute/);
});

test("protection ticker keeps one DOM track and restores normalized animation phase", async () => {
  const script = await readText("app.js");
  const renderProtectionSource = namedFunction(
    script,
    "renderProtection",
  ).toString();
  assert.doesNotMatch(renderProtectionSource, /replaceChildren/);
  assert.match(script, /state\.protectionTickerSemantic/);
  assert.match(script, /const phase = tickerPhase\(ticker\.track\)/);
  assert.match(script, /restoreTickerPhase\(ticker\.track, phase\)/);
  assert.match(script, /if \(semantic === state\.protectionTickerSemantic\) return/);
});

test("recent route switches compress only Unicode-safe meaningful repeated prefixes", async () => {
  const script = await readText("app.js");
  const compressedRouteTarget = namedFunction(script, "compressedRouteTarget");
  const routeTransitionText = namedFunction(
    script,
    "routeTransitionText",
    `const compressedRouteTarget = ${compressedRouteTarget.toString()}`,
  );
  assert.equal(compressedRouteTarget("xxx01", "xxx02"), "02");
  assert.equal(
    compressedRouteTarget("Hong Kong Premium 01", "Hong Kong Premium 02"),
    "02",
  );
  assert.equal(compressedRouteTarget("东京线01", "东京线02"), "02");
  assert.equal(
    compressedRouteTarget("🛰️ Hong Kong 01", "🛰️ Hong Kong 02"),
    "02",
  );
  assert.equal(
    compressedRouteTarget("🇭🇰 香港 01", "🇭🇰 香港 02"),
    "02",
  );
  assert.equal(compressedRouteTarget("abc", "abd"), "abd");
  assert.equal(compressedRouteTarget("a01", "a02"), "a02");
  assert.equal(compressedRouteTarget("A01", "A02"), "A02");
  assert.equal(compressedRouteTarget("abcdef", "abcxyz"), "abcxyz");
  assert.equal(compressedRouteTarget("same 🚀", "same 🚀"), "same 🚀");
  assert.equal(compressedRouteTarget("route-alpha", "route-beta"), "beta");
  assert.equal(routeTransitionText("Same Route", "Same Route"), "Same Route");
  assert.equal(
    routeTransitionText("🇭🇰 香港 01", "🇭🇰 香港 02"),
    "🇭🇰 香港 01 → 02",
  );
});

test("status telemetry uses one compact type size and preserves important long-value tails", async () => {
  const css = await readText("app.css");
  const script = await readText("app.js");
  assert.match(
    css,
    /\.compact-label,\s*\.metric-label\s*\{[^}]*font-size:\s*0\.928571rem;[^}]*line-height:\s*1\.15;/s,
  );
  assert.match(
    css,
    /\.compact-value\s*\{[^}]*font-size:\s*0\.928571rem;[^}]*line-height:\s*1\.15;/s,
  );
  assert.match(
    css,
    /\.metric-value\s*\{[^}]*font-size:\s*0\.928571rem;[^}]*line-height:\s*1\.15;/s,
  );
  assert.doesNotMatch(
    css,
    /\.compact-primary\s*\{[^}]*font-size:/s,
  );
  assert.match(css, /\.route-live-delay\s*\{[^}]*flex:\s*0 0 auto/s);
  assert.match(css, /\.route-switch-time,[\s\S]*flex:\s*0 0 auto/s);
  assert.match(
    css,
    /\.route-switch\s*\{[^}]*grid-template-columns:\s*4\.5rem minmax\(0, 1fr\)/s,
  );
  assert.match(
    css,
    /\.route-switch-target\s*\{[^}]*flex:\s*0 1 auto;[^}]*max-width:\s*48%/s,
  );
  assert.match(css, /\.active-summary-duration\s*\{[^}]*font-variant-numeric:\s*tabular-nums/s);
  assert.match(script, /className|route-switch-from/);
  assert.match(script, /"route-switch-target"/);
  assert.match(script, /"active-summary-duration"/);
  assert.match(script, /appendTailPreservedText\(\s*routeName/);
  const splitTailPreservedText = namedFunction(
    script,
    "splitTailPreservedText",
  );
  const longValue = `🚀${"超长线路".repeat(20)}-TAIL-9999`;
  const parts = splitTailPreservedText(longValue);
  assert.equal(parts.lead.startsWith("🚀"), true);
  assert.equal(parts.tail.endsWith("TAIL-9999"), true);
});

test("Connections shows the exact top-level longest active duration", async () => {
  const script = await readText("app.js");
  const source = namedFunction(script, "renderConnections").toString();
  const longestActiveDurationText = namedFunction(
    script,
    "longestActiveDurationText",
    `const safeNumber = (value, fallback = 0) => {
       const number = Number(value);
       return Number.isFinite(number) ? number : fallback;
     };
     const t = (key) => ({
       noConnections: "No active OpenAI connections.",
       unavailable: "Unavailable",
     })[key];
     const formatDuration = (value) => {
       const seconds = Math.max(0, Math.round(safeNumber(value)));
       if (seconds < 60) return \`${"${seconds}"}s\`;
       if (seconds < 3600) return \`${"${Math.floor(seconds / 60)}"}m ${"${seconds % 60}"}s\`;
       const hours = Math.floor(seconds / 3600);
       return \`${"${hours}"}h ${"${Math.floor((seconds % 3600) / 60)}"}m\`;
     }`,
  );
  const truncated = {
    activeCount: 150,
    longestActiveDuration: 7_200,
    active: [{ duration: 5 }, { duration: 300 }],
    history: [{ oldestConnectionAge: 2_592_000 }],
  };
  assert.equal(longestActiveDurationText(truncated), "2h 0m");
  assert.equal(
    longestActiveDurationText({
      activeCount: 0,
      longestActiveDuration: 86_400,
      history: [{ oldestConnectionAge: 2_592_000 }],
    }),
    "No active OpenAI connections.",
  );
  assert.equal(
    longestActiveDurationText({ activeCount: 1, longestActiveDuration: null }),
    "Unavailable",
  );
  assert.equal(
    longestActiveDurationText({
      activeCount: 1,
      longestActiveDuration: 315_360_000,
    }),
    "87600h 0m",
  );
  assert.match(script, /longestActive: "Longest active"/);
  assert.match(script, /longestActive: "最长活跃"/);
  assert.match(source, /t\("longestActive"\)/);
  assert.match(source, /longestActiveDurationText\(connections\)/);
  assert.doesNotMatch(source, /primaryConnection|active\[0\]/);
  assert.match(script, /connections\?\.longestActiveDuration/);
});

test("Activity, Route, and Connections share landscape height while the link map fills its panel", async () => {
  const css = await readText("app.css");
  const script = await readText("app.js");
  const connectionMapData = namedFunction(
    script,
    "connectionMapData",
    `const safeNumber = (value, fallback = 0) => {
       const number = Number(value);
       return Number.isFinite(number) ? number : fallback;
     };`,
  );
  const mapData = connectionMapData([
    {
      timestamp: "2026-08-03T00:00:00Z",
      connectionAges: [10, 200, 100],
    },
    {
      timestamp: "2026-08-03T00:01:00Z",
      connectionCount: 2,
      oldestConnectionAge: 500,
    },
  ]);
  assert.equal(mapData.ageValues.length, 60);
  assert.deepEqual(mapData.ageValues.at(-2), [200, 100, 10]);
  assert.deepEqual(mapData.ageValues.at(-1), [500, 500]);
  assert.equal(mapData.maximumConnections, 3);
  assert.equal(mapData.precision, "fallback");
  assert.match(
    css,
    /\.connections-section\s*\{[^}]*grid-template-rows:\s*auto minmax\(0, 1fr\)/s,
  );
  assert.match(
    css,
    /#connections-content\s*\{[^}]*grid-template-rows:\s*auto minmax\(0, 1fr\) auto/s,
  );
  assert.match(
    css,
    /\.active-link-map\s*\{[^}]*align-items:\s*stretch/s,
  );
  assert.match(
    css,
    /\.link-dot-matrix\s*\{[^}]*height:\s*100%/s,
  );
  assert.match(css, /\.connections-live-view\s*\{[^}]*display:\s*contents/s);
  assert.doesNotMatch(script, /element\("span",\s*`link-dot/);
  assert.match(namedFunction(script, "drawActiveLinkMap").toString(), /context\.fillRect/);
  assert.match(namedFunction(script, "scheduleActiveLinkMap").toString(), /requestAnimationFrame/);
  assert.match(
    namedFunction(script, "redrawCharts").toString(),
    /renderConnections\(state\.snapshot\.connections, true\)/,
  );
  assert.match(
    namedFunction(script, "redrawCharts").toString(),
    /renderTaskTelemetryMarquee\(state\.activitySummary, true\)/,
  );
});

test("dot waves retain zero-through-five mapping and idle uses neutral grain", async () => {
  const script = await readText("app.js");
  const waves = Array.from({ length: 5 }, () => ({
    powered: false,
    classList: {
      toggle(_name, enabled) {
        this.owner.powered = enabled;
      },
      owner: null,
    },
  }));
  for (const wave of waves) wave.classList.owner = wave;
  globalThis.__energyWaves = waves;
  globalThis.__energyBody = { dataset: {} };
  const updateEnergyWave = namedFunction(
    script,
    "updateEnergyWave",
    `const safeNumber = (value) => Number.isFinite(Number(value)) ? Number(value) : 0;
     const document = {
       querySelectorAll: () => globalThis.__energyWaves,
       body: globalThis.__energyBody,
     }`,
  );
  for (let count = 0; count <= 5; count += 1) {
    updateEnergyWave(count, true);
    assert.equal(waves.filter((wave) => wave.powered).length, count);
    assert.equal(globalThis.__energyBody.dataset.taskWaves, String(count));
  }
  updateEnergyWave(5, false);
  assert.equal(waves.filter((wave) => wave.powered).length, 0);
  assert.equal(globalThis.__energyBody.dataset.taskWaves, "0");
  updateEnergyWave(99, true);
  assert.equal(waves.filter((wave) => wave.powered).length, 5);
  delete globalThis.__energyWaves;
  delete globalThis.__energyBody;

  const css = await readText("app.css");
  const html = await readText("index.html");
  assert.equal((html.match(/class="task-wave"/g) || []).length, 5);
  assert.match(css, /body\[data-dashboard-state="idle"\] \.matrix-idle-grain/);
  assert.match(css, /animation:\s*matrix-idle-breathe 8s/);
  assert.match(css, /body\[data-dashboard-state="off"\] \.matrix-idle-grain/);
  assert.match(css, /body\[data-dashboard-state="failed"\] \.matrix-idle-grain/);
  assert.match(css, /data-activity-effect="dotWaves"[^}]*\.task-wave-field/);
  assert.match(
    css,
    /@media \(prefers-reduced-motion: reduce\)[\s\S]*\.task-wave\.is-powered\s*\{[^}]*animation:\s*none !important;[^}]*transform:/s,
  );
  assert.doesNotMatch(css, /\.task-(?:energy-field|wave)[\s\S]{0,500}(?:filter|box-shadow):/);
});

test("Codex activity spans the exact dashboard edges without a traditional frame", async () => {
  const css = await readText("app.css");
  const heroRule = css.match(/\.task-hero\s*\{([^}]*)\}/s)?.[1] || "";
  assert.match(heroRule, /width:\s*100%/);
  assert.match(heroRule, /justify-self:\s*stretch/);
  assert.match(heroRule, /border:\s*0/);
  assert.match(heroRule, /outline:\s*0/);
  assert.doesNotMatch(heroRule, /border:\s*1px|box-shadow|filter/);
  assert.match(
    css,
    /@media \(orientation: landscape\)[\s\S]*\.task-hero\s*\{[^}]*width:\s*100%/s,
  );
});

test("saved LAN addresses accept only private roots and strip pair secrets from records", async () => {
  const script = await readText("app.js");
  const normalizeLANAddress = namedFunction(
    script,
    "normalizeLANAddress",
    "const DEFAULT_LAN_PORT = 18765",
  );
  assert.deepEqual(normalizeLANAddress("192.168.1.8"), {
    origin: "http://192.168.1.8:18765",
    token: "",
  });
  assert.deepEqual(normalizeLANAddress("Mac-Studio.local:19000"), {
    origin: "http://mac-studio.local:19000",
    token: "",
  });
  assert.deepEqual(
    normalizeLANAddress("http://10.0.0.8:18765/#token=abc_DEF-123"),
    { origin: "http://10.0.0.8:18765", token: "abc_DEF-123" },
  );
  for (const rejected of [
    "https://192.168.1.8",
    "http://localhost:18765",
    "http://127.0.0.1:18765",
    "http://8.8.8.8:18765",
    "http://[fe80::1]:18765",
    "http://user@192.168.1.8:18765",
    "http://192.168.1.8:18765/path",
    "http://192.168.1.8:18765/?x=1",
    "http://192.168.1.8:18765/#other=x",
    "http://192.168.1.8:0",
    "192.168.1",
  ]) {
    assert.equal(normalizeLANAddress(rejected), null, rejected);
  }
  assert.match(script, /SAVED_ADDRESSES_KEY/);
  assert.match(script, /MAX_SAVED_ADDRESSES = 8/);
  assert.match(script, /\.slice\(0, MAX_SAVED_ADDRESSES\)/);
  assert.match(script, /fetch\(baseAwareURL\("\/api\/v1\/health", origin\)/);
  assert.match(script, /mode: "cors"/);
  assert.match(script, /credentials: "omit"/);
  assert.match(script, /redirect: "error"/);
  assert.match(script, /ADDRESS_CHECK_TIMEOUT_MS = 1_500/);
  assert.doesNotMatch(script, /window\.location\.assign|window\.location\.href\s*=/);
  assert.match(script, /setActiveBaseURL\(normalized\.origin\)/);
  assert.match(
    script,
    /\.map\(\(\{ origin, lastUsedAt, lastSuccessAt, lastReachableAt \}\) => \(\{/,
  );
});

test("manual fallback pairs by short code without putting credentials in URLs or saved addresses", async () => {
  const html = await readText("index.html");
  const script = await readText("app.js");
  assert.match(html, /data-pairing-code-input/);
  assert.match(html, /autocomplete="one-time-code"/);
  assert.match(html, /inputmode="numeric"/);
  assert.match(html, /maxlength="8"/);
  assert.match(script, /This saved token is no longer valid\. Enter the current 8-digit code/);
  assert.match(script, /已保存的令牌已失效，请输入[^"]*8 位配对码/);
  assert.doesNotMatch(script, /Remove it|先删除|重新添加到主屏幕/);
  assert.match(script, /const MANUAL_CLAIM_PATH = "\/api\/v1\/pwa\/manual-claim"/);
  assert.match(script, /MANUAL_CLAIM_TIMEOUT_MS = 3_000/);
  assert.match(script, /\/\^\\d\{8\}\$\/u\.test\(code\)/);
  assert.match(script, /body: JSON\.stringify\(\{ code \}\)/);
  assert.match(script, /credentials: "omit"/);
  assert.match(script, /redirect: "error"/);
  assert.match(script, /"Content-Type": "application\/json"/);
  assert.match(script, /payload\?\.serverInstanceID/);
  assert.match(script, /storeToken\(token\);/);
  assert.match(script, /selectActiveBase\(normalized\.origin\)/);
  assert.match(script, /addressInput\.value = "";\s*codeInput\.value = "";/);
  assert.doesNotMatch(script, /[?&](?:code|token)=/);
  assert.doesNotMatch(
    script,
    /\.map\(\(\{ origin, lastUsedAt, lastSuccessAt, lastReachableAt, (?:token|code)/,
  );
  const manualClaimSource = namedFunction(
    script,
    "claimWithTemporaryCode",
  ).toString();
  assert.doesNotMatch(manualClaimSource, /Authorization|Cookie/);
  assert.match(manualClaimSource, /credentials: "omit"/);
  assert.match(
    manualClaimSource,
    /storeToken\(token\);[\s\S]*selectActiveBase\(normalized\.origin,[\s\S]*updateSavedAddress\([\s\S]*elements\.gate\.hidden = true;/,
  );
  const clearTokenSource = namedFunction(script, "clearToken").toString();
  assert.doesNotMatch(
    clearTokenSource,
    /ACTIVE_BASE_KEY|SAVED_ADDRESSES_KEY|activeBaseURL|savedAddresses/,
  );
  const healthSource = namedFunction(script, "checkSavedAddress").toString();
  assert.doesNotMatch(healthSource, /Authorization|Bearer|state\.token/);

  const manualClaimErrorKey = namedFunction(script, "manualClaimErrorKey");
  assert.equal(
    manualClaimErrorKey(401, "invalid_pairing_code"),
    "pairingCodeRejected",
  );
  assert.equal(
    manualClaimErrorKey(429, "pairing_rate_limited"),
    "pairingRateLimited",
  );
  assert.equal(
    manualClaimErrorKey(503, "pairing_unavailable"),
    "pairingUnavailable",
  );
  assert.equal(manualClaimErrorKey(400, "invalid_request"), "pairingRequestFailed");
});

test("base-aware fetch stream aborts stale bases and gates every event by connection epoch", async () => {
  const script = await readText("app.js");
  const baseAwareURL = namedFunction(
    script,
    "baseAwareURL",
    `const state = { activeBaseURL: "http://192.168.1.8:18765" };
     const window = { location: { origin: "http://shell.local:18765" } }`,
  );
  assert.equal(
    baseAwareURL("/api/v1/events"),
    "http://192.168.1.8:18765/api/v1/events",
  );
  assert.equal(
    baseAwareURL("/api/v1/health", "http://mac.local:19000"),
    "http://mac.local:19000/api/v1/health",
  );
  assert.match(script, /baseAwareURL\(EVENTS_PATH, requestBase\)/);
  assert.match(script, /Authorization: `Bearer \$\{requestToken\}`/);
  assert.match(script, /requestEpoch === state\.connectionEpoch/);
  assert.match(script, /requestBase === \(state\.activeBaseURL \|\| window\.location\.origin\)/);
  assert.match(script, /if \(state\.controller\) state\.controller\.abort\(\)/);
  assert.match(script, /consumeEventStream\(response, controller\.signal, isCurrent\)/);
  assert.match(script, /if \(!isCurrent\(\)\) return;/);
  assert.match(script, /state\.connectionEpoch \+= 1/);
  assert.match(script, /baseAwareURL\(PWA_CLAIM_PATH, window\.location\.origin\)/);
  assert.match(script, /new URL\(requestBase\)\.origin !== window\.location\.origin/);

  globalThis.__mobileDashboardRendered = [];
  const consumeEventStream = namedFunction(
    script,
    "consumeEventStream",
    `const t = () => "error";
     const renderEnvelope = (value) => globalThis.__mobileDashboardRendered.push(value)`,
  );
  const eventBytes = new TextEncoder().encode('data: {"snapshot":{"id":1}}\n\n');
  const response = {
    body: new ReadableStream({
      start(controller) {
        controller.enqueue(eventBytes);
        controller.close();
      },
    }),
  };
  await assert.rejects(
    consumeEventStream(response, { aborted: false }, () => false),
    /stream_closed/,
  );
  assert.deepEqual(globalThis.__mobileDashboardRendered, []);

  const response2 = {
    body: new ReadableStream({
      start(controller) {
        controller.enqueue(eventBytes);
        controller.close();
      },
    }),
  };
  await assert.rejects(
    consumeEventStream(response2, { aborted: false }, () => true),
    /stream_closed/,
  );
  assert.equal(globalThis.__mobileDashboardRendered.length, 1);
  delete globalThis.__mobileDashboardRendered;
});

test("standalone root attempts HttpOnly cookie claim when no install fragment exists", async () => {
  const script = await readText("app.js");
  const claimSource = namedFunction(script, "claimStandaloneToken").toString();
  assert.match(claimSource, /const credential = state\.installCredential/);
  assert.doesNotMatch(claimSource, /if \(!credential/);
  assert.match(claimSource, /if \(credential\) \{/);
  assert.match(claimSource, /headers\.Authorization = `PWAInstall/);
  assert.match(claimSource, /credentials: "include"/);
});

test("task telemetry lane disposal releases animations through repeated count changes", async () => {
  const script = await readText("app.js");
  const lifecycleMap = new WeakMap();
  const liveAnimations = new Set();
  const allLanes = [];
  const lifecycleState = { taskTelemetryMaintenanceTimer: 41 };
  const container = {
    children: [],
    get childElementCount() { return this.children.length; },
    get lastElementChild() { return this.children.at(-1) || null; },
    append(node) {
      node.remove = () => {
        const index = this.children.indexOf(node);
        if (index >= 0) this.children.splice(index, 1);
        node.removed = true;
      };
      this.children.push(node);
    },
    replaceChildren(...nodes) { this.children = nodes; },
  };

  let cancelCount = 0;
  const createAnimation = (track) => {
    const animation = {
      currentTime: 1_000,
      onfinish: () => {},
      cancel() {
        assert.equal(this.onfinish, null, "finish handler clears before cancel");
        cancelCount += 1;
        liveAnimations.delete(this);
      },
    };
    animation.track = track;
    liveAnimations.add(animation);
    return animation;
  };

  globalThis.__taskTelemetryLifecycleMap = lifecycleMap;
  globalThis.__taskTelemetryLiveAnimations = liveAnimations;
  globalThis.__taskTelemetryAllLanes = allLanes;
  globalThis.__taskTelemetryContainer = container;
  globalThis.__taskTelemetryLifecycleState = lifecycleState;
  globalThis.__taskTelemetryCreateAnimation = createAnimation;

  const cancelAnimation = namedFunction(script, "cancelTaskTelemetryAnimation");
  globalThis.__cancelTaskTelemetryAnimation = cancelAnimation;
  const cancelLaneAnimation = namedFunction(
    script,
    "cancelTaskTelemetryLaneAnimation",
    `const taskTelemetryLaneStates = globalThis.__taskTelemetryLifecycleMap;
     const cancelTaskTelemetryAnimation = globalThis.__cancelTaskTelemetryAnimation;
     const taskTelemetryCurrentOffset = (lane) =>
       taskTelemetryLaneStates.get(lane).baseOffset + 7;`,
  );
  globalThis.__cancelTaskTelemetryLaneAnimation = cancelLaneAnimation;
  const disposeLane = namedFunction(
    script,
    "disposeTaskTelemetryLane",
    `const taskTelemetryLaneStates = globalThis.__taskTelemetryLifecycleMap;
     const cancelTaskTelemetryAnimation = globalThis.__cancelTaskTelemetryAnimation;
     const cancelTaskTelemetryLaneAnimation = globalThis.__cancelTaskTelemetryLaneAnimation;`,
  );
  globalThis.__disposeTaskTelemetryLane = disposeLane;

  const render = namedFunction(
    script,
    "renderTaskTelemetryMarquee",
    `const elements = { taskTelemetryMarquee: globalThis.__taskTelemetryContainer };
     const refreshTaskTelemetryViewportScale = () => 1;
     const taskTelemetryFragments = (summary) => summary.rows;
     const hasChanged = () => true;
     const stopTaskTelemetryMotion = () => {};
     const configureTaskTelemetryMotion = () => {};
     const disposeTaskTelemetryLane = globalThis.__disposeTaskTelemetryLane;
     const taskTelemetryLaneStates = globalThis.__taskTelemetryLifecycleMap;
     const updateTaskTelemetryLane = (lane, row) => {
       let laneState = taskTelemetryLaneStates.get(lane);
       if (!laneState) {
         laneState = { baseOffset: 0, animation: null };
         taskTelemetryLaneStates.set(lane, laneState);
       }
       laneState.taskKey = row.key;
       if (!laneState.animation) {
         laneState.animation = globalThis.__taskTelemetryCreateAnimation(
           lane.firstElementChild,
         );
       }
     };
     const setTaskTelemetryLaneSpeed = () => {};
     const taskTelemetryCurrentOffset = () => 0;
     const ensureTaskTelemetryTail = () => {};
     const element = (_tag, className) => {
       const node = {
         className,
         children: [],
         dataset: {},
         removed: false,
         get childElementCount() { return this.children.length; },
         get firstElementChild() { return this.children[0] || null; },
         get lastElementChild() { return this.children.at(-1) || null; },
         append(child) {
           child.parentLane = this;
           this.children.push(child);
         },
         replaceChildren(...children) { this.children = children; },
         getAnimations() {
           return Array.from(globalThis.__taskTelemetryLiveAnimations)
             .filter((animation) => animation.track === this);
         },
         style: { setProperty() {} },
       };
       if (className === "task-telemetry-lane") {
         globalThis.__taskTelemetryAllLanes.push(node);
       }
       return node;
     };`,
  );
  const rows = (count) => Array.from({ length: count }, (_, index) => ({
    key: `task-${index}`,
    text: `Task ${index}`,
    speedTier: index,
  }));

  render({ rows: rows(5) });
  assert.equal(liveAnimations.size, 5);
  for (let iteration = 0; iteration < 50; iteration += 1) {
    render({ rows: rows(1) });
    assert.equal(container.children.length, 1);
    assert.equal(liveAnimations.size, 1, `shrink ${iteration} releases four lanes`);
    render({ rows: rows(5) });
    assert.equal(container.children.length, 5);
    assert.equal(liveAnimations.size, 5, `grow ${iteration} owns only five lanes`);
  }

  const stopMotion = namedFunction(
    script,
    "stopTaskTelemetryMotion",
    `const state = globalThis.__taskTelemetryLifecycleState;
     const elements = { taskTelemetryMarquee: globalThis.__taskTelemetryContainer };
     const taskTelemetryLaneStates = globalThis.__taskTelemetryLifecycleMap;
     const taskTelemetryLaneState = (lane) => taskTelemetryLaneStates.get(lane);
     const cancelTaskTelemetryLaneAnimation = globalThis.__cancelTaskTelemetryLaneAnimation;
     const window = { clearInterval() {} };`,
  );
  stopMotion();
  stopMotion();
  assert.equal(lifecycleState.taskTelemetryMaintenanceTimer, null);
  assert.equal(liveAnimations.size, 0, "effect switch or disconnect stops every animation");
  assert.equal(container.children.length, 5, "a stop preserves resumable lane DOM");

  render({ rows: [] });
  render({ rows: [] });
  assert.equal(container.children.length, 0, "zero tasks is idempotently empty");
  assert.equal(liveAnimations.size, 0);
  assert.ok(allLanes.every((lane) => lane.removed && lane.children.length === 0));
  assert.match(
    namedFunction(script, "configureTaskTelemetryMotion").toString(),
    /if \(!taskTelemetryMotionAllowed\(\)\) \{[\s\S]*stopTaskTelemetryMotion\(\)/,
  );
  assert.match(
    namedFunction(script, "disconnect").toString(),
    /state\.connected = false;[\s\S]*stopTaskTelemetryMotion\(\)/,
  );
  assert.ok(cancelCount >= 205, "every detached or stopped lane was cancelled");

  delete globalThis.__taskTelemetryLifecycleMap;
  delete globalThis.__taskTelemetryLiveAnimations;
  delete globalThis.__taskTelemetryAllLanes;
  delete globalThis.__taskTelemetryContainer;
  delete globalThis.__taskTelemetryLifecycleState;
  delete globalThis.__taskTelemetryCreateAnimation;
  delete globalThis.__cancelTaskTelemetryAnimation;
  delete globalThis.__cancelTaskTelemetryLaneAnimation;
  delete globalThis.__disposeTaskTelemetryLane;
});
