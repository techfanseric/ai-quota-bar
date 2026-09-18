// Reuse the shipped dashboard HTML, CSS and rendering functions. Replace only
// live initialization with fictional data; omit pairing/network event handlers.
import {readFile,writeFile} from 'node:fs/promises';
const source='../AIQuotaBar/Resources/MobileDashboard/';
export async function buildMobilePreview(){
 let html=await readFile(source+'index.html','utf8');
 html=html.replace(/<link[^>]+(?:manifest|apple-touch-icon)[^>]*>/g,'').replace('href="/app.css"','href="/mobile-preview.css"').replace('src="/app.js"','src="/mobile-preview.js"').replace('src="/wake-ambient.mp4"','');
 await writeFile('dist-pages/mobile-preview.html',html);
 await writeFile('dist-pages/mobile-preview.css',await readFile(source+'app.css'));
 const app=await readFile(source+'app.js','utf8');const marker='  let resizeTimer = null;';
 if(!app.includes(marker))throw new Error('Dashboard boot boundary changed; review website preview adapter.');
 const fixture=await readFile('scripts/mobile-preview-fixture.js','utf8');
 await writeFile('dist-pages/mobile-preview.js',app.slice(0,app.indexOf(marker))+fixture+'\n})();\n');
}
