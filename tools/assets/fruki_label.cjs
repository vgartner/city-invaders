// Reproducible vector label composition. Only the white brand lettering is
// masked from the project's existing public-domain Commons reference.
// The two-sided arrangement is a gameplay adaptation, not a print master.
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');
const out = process.argv[2];
const ref = process.argv[3];
if (!out || !ref) throw new Error('Usage: node fruki_label.cjs OUT_DIR EXISTING_LOGO_JPG');
fs.mkdirSync(out, { recursive: true });
const logo = fs.readFileSync(ref).toString('base64');
const defs = `<defs>
<clipPath id="wordClip"><path d="M161 118 L287 90 L280 134 L154 157 Z"/></clipPath>
<filter id="whiteLetters" color-interpolation-filters="sRGB" x="-10%" y="-10%" width="120%" height="120%">
<feColorMatrix type="matrix" values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  2.4 4.8 .8 0 -7"/>
</filter></defs>`;
function face(cx) {
  return `<g>
  <text x="${cx}" y="142" font-family="Arial,sans-serif" font-size="26" font-weight="bold" text-anchor="middle" fill="#e9f1d7" letter-spacing="2">REFRIGERANTE DE GUARANÁ</text>
  <circle cx="${cx}" cy="470" r="302" fill="#c20a2f"/>
  <path d="M${cx-228} 680 C${cx-150} 572 ${cx+48} 674 ${cx+245} 556 C${cx+170} 711 ${cx-46} 699 ${cx-228} 680 Z" fill="#e2bd32"/>
  <g transform="translate(${cx} 450) scale(4.25) translate(-222 -124)">
    <g clip-path="url(#wordClip)"><image href="data:image/jpeg;base64,${logo}" width="446" height="270" filter="url(#whiteLetters)"/></g>
  </g>
  <text x="${cx}" y="837" font-family="Arial,sans-serif" font-size="67" font-weight="bold" text-anchor="middle" fill="#ffffff" letter-spacing="2">GUARANÁ</text>
  <text x="${cx}" y="910" font-family="Arial,sans-serif" font-size="35" font-weight="bold" text-anchor="middle" fill="#edf3de">350 ml</text>
  <g transform="translate(${cx-242} 872)">
    <path d="M-12 -17 C-69 -78 -17 -94 7 -39 C45 -89 78 -44 24 -12" fill="#8ac144"/>
    <ellipse cx="-9" cy="0" rx="24" ry="29" fill="#c92332"/>
    <ellipse cx="30" cy="13" rx="22" ry="27" fill="#d43638"/>
    <ellipse cx="-7" cy="-2" rx="12" ry="15" fill="#f0e8d0"/>
    <ellipse cx="31" cy="12" rx="11" ry="13" fill="#f0e8d0"/>
    <ellipse cx="-5" cy="-1" rx="7" ry="9" fill="#242016"/>
    <ellipse cx="33" cy="13" rx="7" ry="9" fill="#242016"/>
  </g>
  </g>`;
}
const wrap = `${defs}<rect width="2048" height="1024" fill="#008235"/>
<path d="M0 83 Q256 54 512 83 T1024 83 T1536 83 T2048 83" fill="none" stroke="#66a93b" stroke-width="5"/>
<path d="M0 966 Q256 995 512 966 T1024 966 T1536 966 T2048 966" fill="none" stroke="#66a93b" stroke-width="5"/>
${face(512)}${face(1536)}`;
const root = content => `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="2048" height="2048" viewBox="0 0 2048 2048">${content}</svg>`;
const color = root(wrap + `<rect y="1024" width="2048" height="1024" fill="#c9cfd3"/>
<rect x="1792" y="1792" width="256" height="256" fill="#31383b"/>`);
const mr = root(`<rect width="2048" height="1024" fill="#ff730a"/>
<rect y="1024" width="2048" height="1024" fill="#ff57f2"/>
<rect x="1792" y="1792" width="256" height="256" fill="#ff6bbf"/>`);
// Fine metal brushing is confined to the unprinted atlas half. The printed
// body stays smooth; geometric rims/tab/scoring carry the large details.
let brushed = '';
for (let y=1026; y<1792; y+=4) brushed += `<path d="M0 ${y} H2048" stroke="#8082ff" stroke-width="1"/>`;
const normal = root(`<rect width="2048" height="2048" fill="#8080ff"/>${brushed}`);
(async () => {
  for (const [name, svg] of [['basecolor',color],['metallic_roughness',mr],['normal',normal]]) {
    fs.writeFileSync(path.join(out,`fruki_${name}.svg`),svg);
    await sharp(Buffer.from(svg)).png().toFile(path.join(out,`fruki_${name}.png`));
  }
  fs.writeFileSync(path.join(out,'fruki_label_manifest.json'), JSON.stringify({
    texture_size:[2048,2048], wrap_region_pixels:[0,0,2048,1024],
    logo_centres_u:[0.25,0.75], angular_separation_degrees:180,
    uv_origin:'Blender bottom-left; wrap uses v=0.5..1',
    note:'Original vector label arrangement for game readability; not official packaging artwork.'
  },null,2));
})();
