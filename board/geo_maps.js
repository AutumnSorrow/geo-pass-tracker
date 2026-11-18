// 高三地理课前通关系统 v6.0 · 自适应一体机多分辨率缩放、局部动态靶点与点击全屏放大图库加载器

const VALID_DIAGRAMS = new Set([
  "map_pacific", "map_atlantic", "map_indian", "map_china_terrain",
  "diag_enso", "diag_rock_cycle", "diag_fold_fault", "diag_fault",
  "diag_unconformity", "diag_river_terrace", "diag_alluvial_fan", "diag_dune_contour",
  "diag_vertical_zones", "diag_isobar_thermal", "diag_cyclone_fronts",
  "diag_climate_model", "diag_climograph", "diag_hydrograph", "diag_sun_path"
]);

// 已生成高清无标号干净底图的多要素大图及其精确原生画布像素尺寸 [width, height]
const CLEAN_DIMS = {
  "map_pacific": [1280, 790],
  "map_atlantic": [1280, 790],
  "map_indian": [1300, 790],
  "map_china_terrain": [1280, 790],
  "diag_climate_model": [1280, 790],
  "diag_rock_cycle": [1280, 790],
  "diag_cyclone_fronts": [1280, 790]
};

function escSvg(s) {
  return String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

window.GEO_CLOUD_BOARD_BASES = [
  "https://autumnsorrow.github.io/geo-pass-tracker/board/",
  "https://gcore.jsdelivr.net/gh/AutumnSorrow/geo-pass-tracker@main/board/",
  "https://testingcf.jsdelivr.net/gh/AutumnSorrow/geo-pass-tracker@main/board/"
];

window.geoImgFallback = function(el, relSrc) {
  const idx = parseInt(el.dataset.fbIdx || '0', 10);
  const bases = window.GEO_CLOUD_BOARD_BASES || [];
  if (idx < bases.length) {
    el.dataset.fbIdx = String(idx + 1);
    el.src = bases[idx] + relSrc + '?t=' + (window.GEO_RUNTIME_VER || Date.now());
  }
};

window.renderGeoDiagram = function(diagId, mode, customMarkers) {
  if (!diagId || (!VALID_DIAGRAMS.has(diagId) && !/^[a-zA-Z0-9_-]+$/.test(diagId))) return '';
  const dims = (window.GEO_EXTRA_CLEAN_DIMS && window.GEO_EXTRA_CLEAN_DIMS[diagId]) || CLEAN_DIMS[diagId];

  // 回顾点杀专属：在干净底图上通过同坐标系 SVG 仅高亮渲染本次抽问的 2~4 个靶点
  if (mode === 'quiz' && Array.isArray(customMarkers) && customMarkers.length > 0 && dims) {
    const [vw, vh] = dims;
    const cleanSrc = `diagrams/${diagId}_clean.png`;
    const nodes = customMarkers.map(m => {
      const lbl = String(m.label || '');
      let units = 0;
      for (const ch of lbl) units += (ch.charCodeAt(0) > 255 ? 1 : 0.68);
      const bw = Math.max(66, Math.round(units * 32 + 30));
      const bh = 58;
      const x0 = Math.round(m.x - bw / 2);
      const y0 = Math.round(m.y - bh / 2);
      let fill = '#071326', stroke = '#FACC15', glow = 'rgba(250,204,21,0.34)', tcol = '#FEF08A';
      if (m.type === 'star') {
        fill = '#580822'; stroke = '#FB7185'; glow = 'rgba(251,113,133,0.36)'; tcol = '#FFE4E6';
      } else if (m.type === 'area') {
        fill = '#082F49'; stroke = '#38BDF8'; glow = 'rgba(56,189,248,0.34)'; tcol = '#E0F2FE';
      }
      const fsize = lbl.length >= 3 ? 27 : 31;
      return `<g class="svg-target-node">
        <rect x="${x0 - 5}" y="${y0 - 5}" width="${bw + 10}" height="${bh + 10}" rx="15" fill="none" stroke="${glow}" stroke-width="6" />
        <rect x="${x0}" y="${y0}" width="${bw}" height="${bh}" rx="12" fill="${fill}" stroke="${stroke}" stroke-width="3.8" />
        <text x="${m.x}" y="${m.y}" dy="0.36em" text-anchor="middle" fill="${tcol}" font-size="${fsize}" font-weight="900" font-family="Microsoft YaHei, PingFang SC, sans-serif">${escSvg(lbl)}</text>
      </g>`;
    }).join('');

    return `<div class="map-holder" onclick="zoomDiagramEl(this)" title="点击全屏放大查看">
      <svg class="geo-svg" viewBox="0 0 ${vw} ${vh}" preserveAspectRatio="xMidYMid meet">
        <image href="${cleanSrc}" x="0" y="0" width="${vw}" height="${vh}" />
        ${nodes}
      </svg>
      <span class="zoom-hint">🎯 已隐去无关标号 · 仅标本题必答项（点图放大）</span>
    </div>`;
  }

  const suffix = (mode === 'quiz') ? 'quiz' : 'ans';
  const src = `diagrams/${diagId}_${suffix}.png`;
  return `<div class="map-holder" onclick="zoomDiagramEl(this)" title="点击全屏放大查看">
    <img src="${src}" alt="${diagId}" onerror="window.geoImgFallback && window.geoImgFallback(this, '${src}')" />
    <span class="zoom-hint">🔍 点图全屏放大</span>
  </div>`;
};
