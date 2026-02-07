// ===============================
// MAP SETUP
// ===============================
const map = L.map('map').setView([42.88, -85.52], 6);

L.tileLayer(
  'https://api.mapbox.com/styles/v1/mapbox/dark-v11/tiles/{z}/{x}/{y}?access_token=pk.eyJ1Ijoicm5pbGxlciIsImEiOiJjbWYyMjJ6dG8wZTRsMmlvaDdhano3MWZmIn0.aSigGIPSNUdwsDLJ-ux0ww',
  { tileSize: 512, zoomOffset: -1, attribution: '© Mapbox' }
).addTo(map);

// ===============================
// LAYERS
// ===============================
const drawnItems = new L.FeatureGroup().addTo(map);
const aircraftLayer = L.layerGroup().addTo(map);
const ringsLayer = L.layerGroup().addTo(map);
const ringLabelsLayer = L.layerGroup().addTo(map);

// ===============================
// STATE
// ===============================
let geofence = null;
let ringCenter = null;
let ringsModeActive = false;
let alertLog = [];

// Caches
const lastHeadingByHex = new Map();
const aircraftInfoCache = new Map();

// ===============================
// CLICK FIX (inject CSS override)
// Your CSS sets .aircraft-icon { pointer-events:none; } which blocks clicks.
// This override makes the MARKER clickable, while keeping inner pieces non-clicky.
// ===============================
(function injectPointerEventsFix() {
  const style = document.createElement("style");
  style.innerHTML = `
    .leaflet-marker-icon { pointer-events: auto !important; }
    .aircraft-icon { pointer-events: auto !important; }
    .aircraft-arrow, .aircraft-label { pointer-events: none !important; }
  `;
  document.head.appendChild(style);
})();

// ===============================
// DRAW CONTROL (GEOFENCE)
// ===============================
const drawControl = new L.Control.Draw({
  edit: { featureGroup: drawnItems },
  draw: {
    polyline: false,
    rectangle: false,
    circle: false,
    marker: false,
    circlemarker: false
  }
});
map.addControl(drawControl);

// ===============================
// SIDEBAR ALTITUDE UI + SELECTED AIRCRAFT CARD
// ===============================
const alertListEl = document.getElementById("alert-list");
const sidebar = document.getElementById("sidebar");

// Insert UI at the top of sidebar: threshold + selected aircraft card container
sidebar.insertAdjacentHTML(
  "afterbegin",
  `
  <div style="margin-bottom:12px;">
    <div style="color:#0cf;font-weight:700;margin-bottom:6px;">
      Alert if altitude ≤
    </div>
    <div style="display:flex;gap:8px;align-items:center;">
      <input
        id="altitudeThreshold"
        type="number"
        min="0"
        step="100"
        value="2294"
        style="width:140px;padding:6px;border-radius:8px;border:1px solid #333;"
      />
      <span style="color:#aaa;">ft</span>
    </div>
    <div style="color:#666;font-size:0.85rem;margin-top:6px;">
      Only aircraft inside the blue area and below this altitude appear.
    </div>

    <div id="selected-aircraft-card"
      style="
        display:none;
        margin-top:12px;
        padding:12px;
        border-radius:12px;
        background:#141414;
        border:1px solid #2a2a2a;
        box-shadow:0 10px 30px rgba(0,0,0,0.35);
      ">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px;">
        <div style="font-weight:800;color:#0cf;">Aircraft</div>
        <button id="selected-aircraft-close"
          style="
            border:none;
            background:#222;
            color:#aaa;
            border-radius:10px;
            padding:4px 10px;
            cursor:pointer;
          ">Close</button>
      </div>

      <div id="selected-aircraft-body" style="font-size:0.92rem;line-height:1.25;color:#ddd;">
        <!-- filled by JS -->
      </div>
    </div>

    <hr style="border:none;border-top:1px solid #333;margin:12px 0;">
  </div>
`
);

const altitudeInput = document.getElementById("altitudeThreshold");

altitudeInput.addEventListener("input", () => {
  alertLog = [];
  updateSidebar();
});

// Selected aircraft card helpers
const selectedCard = document.getElementById("selected-aircraft-card");
const selectedBody = document.getElementById("selected-aircraft-body");
const selectedClose = document.getElementById("selected-aircraft-close");

selectedClose?.addEventListener("click", () => {
  selectedCard.style.display = "none";
});

// ===============================
// GEOFENCE EVENTS
// ===============================
map.on(L.Draw.Event.CREATED, e => {
  drawnItems.clearLayers();
  drawnItems.addLayer(e.layer);
  geofence = e.layer.toGeoJSON();
  clearRings();
  alertLog = [];
  updateSidebar();
});

map.on(L.Draw.Event.DELETED, () => {
  geofence = null;
  alertLog = [];
  updateSidebar();
});

// ===============================
// RINGS TOOL CONTROL
// ===============================
const RingsControl = L.Control.extend({
  options: { position: 'topleft' },
  onAdd() {
    const container = L.DomUtil.create('div', 'leaflet-bar');

    const ringBtn = L.DomUtil.create('a', '', container);
    ringBtn.innerHTML = '⭕';
    ringBtn.title = 'Activate Distance Rings';
    ringBtn.href = '#';

    const clearBtn = L.DomUtil.create('a', '', container);
    clearBtn.innerHTML = '✖';
    clearBtn.title = 'Clear Rings';
    clearBtn.href = '#';

    L.DomEvent.on(ringBtn, 'click', e => {
      L.DomEvent.stop(e);
      ringsModeActive = true;
      ringBtn.style.background = '#222';
    });

    L.DomEvent.on(clearBtn, 'click', e => {
      L.DomEvent.stop(e);
      clearRings();
      ringBtn.style.background = '';
    });

    return container;
  }
});
map.addControl(new RingsControl());

// ===============================
// RINGS LOGIC
// ===============================
function milesToMeters(mi) {
  return mi * 1609.34;
}

function clearRings() {
  ringCenter = null;
  ringsLayer.clearLayers();
  ringLabelsLayer.clearLayers();
  alertLog = [];
  updateSidebar();
}

function setRings(latlng) {
  clearRings();
  ringCenter = latlng;

  [5, 10, 15, 20].forEach(miles => {
    const circle = L.circle(latlng, {
      radius: milesToMeters(miles),
      color: '#0cf',
      weight: 2,
      fillOpacity: 0.05
    }).addTo(ringsLayer);

    L.marker(circle.getBounds().getNorthEast(), {
      icon: L.divIcon({
        className: 'label-ring',
        html: `${miles} sm`,
        iconSize: [50, 20]
      })
    }).addTo(ringLabelsLayer);
  });
}

map.on('click', e => {
  if (!ringsModeActive) return;
  setRings(e.latlng);
  ringsModeActive = false;
});

// ===============================
// AIRCRAFT LOOKUP
// ===============================
async function fetchAircraftInfo(icao24) {
  const key = String(icao24 || "").toLowerCase();
  if (!key) return null;

  if (aircraftInfoCache.has(key)) return aircraftInfoCache.get(key);

  try {
    const res = await fetch(`/api/move/aircraft_lookup.php?icao=${encodeURIComponent(key)}`, {
      cache: "no-store"
    });
    const data = await res.json();
    aircraftInfoCache.set(key, data);
    return data;
  } catch {
    return null;
  }
}

// ===============================
// OPENSKY FETCH
// ===============================
const API_URL = "opensky-proxy.php";
const MS_TO_KTS = 1.94384;

function chooseAltitude(baro, geo) {
  const g = Number(geo);
  const b = Number(baro);
  if (Number.isFinite(g) && g > 0) return g;
  if (Number.isFinite(b) && b > 0) return b;
  return null;
}

function speedToColor(kts) {
  if (!Number.isFinite(kts)) return "#2ea9ff";
  if (kts < 120) return "#2ea9ff";
  if (kts < 320) return "#ffd000";
  return "#ff3b3b";
}

function altitudeToOpacity(altFt) {
  if (!Number.isFinite(altFt)) return 1;
  const max = 40000;
  return Math.max(0.35, 1 - altFt / max);
}

function climbDescSymbol(vRate) {
  if (!Number.isFinite(vRate)) return "";
  if (vRate > 200) return "▲";
  if (vRate < -200) return "▼";
  return "";
}

function smoothHeading(hex, newHeading) {
  if (!Number.isFinite(newHeading)) return 0;
  const prev = lastHeadingByHex.get(hex) ?? newHeading;
  let delta = newHeading - prev;
  if (delta > 180) delta -= 360;
  if (delta < -180) delta += 360;
  const eased = prev + delta * 0.35;
  const norm = (eased % 360 + 360) % 360;
  lastHeadingByHex.set(hex, norm);
  return norm;
}

// ===============================
// FLIGHTRADAR-STYLE CARD
// ===============================
function showAircraftCard(payload) {
  selectedCard.style.display = "block";

  const title = payload.registration || payload.callsign || payload.hex || "Unknown";
  const sub = [payload.typecode, payload.manufacturer, payload.model].filter(Boolean).join(" • ");

  selectedBody.innerHTML = `
    <div style="font-size:1.05rem;font-weight:900;color:#fff;margin-bottom:4px;">
      ${escapeHtml(title)}
    </div>
    ${sub ? `<div style="color:#aaa;margin-bottom:10px;">${escapeHtml(sub)}</div>` : ""}

    <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;">
      <div style="background:#101010;border:1px solid #262626;border-radius:10px;padding:10px;">
        <div style="color:#777;font-size:0.8rem;">Altitude</div>
        <div style="font-weight:800;">${escapeHtml(String(payload.altitude ?? "N/A"))} ft</div>
      </div>
      <div style="background:#101010;border:1px solid #262626;border-radius:10px;padding:10px;">
        <div style="color:#777;font-size:0.8rem;">Speed</div>
        <div style="font-weight:800;">${escapeHtml(String(payload.speed ?? "N/A"))} kt</div>
      </div>
      <div style="background:#101010;border:1px solid #262626;border-radius:10px;padding:10px;">
        <div style="color:#777;font-size:0.8rem;">Heading</div>
        <div style="font-weight:800;">${escapeHtml(String(payload.heading ?? "N/A"))}°</div>
      </div>
      <div style="background:#101010;border:1px solid #262626;border-radius:10px;padding:10px;">
        <div style="color:#777;font-size:0.8rem;">Vertical</div>
        <div style="font-weight:800;">${escapeHtml(String(payload.vertical ?? "—"))}</div>
      </div>
    </div>
  `;

  // mobile: open sheet
  maybeOpenSidebar();
}

function escapeHtml(str) {
  return String(str)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

async function fetchOpenSky() {
  const res = await fetch(API_URL, { cache: "no-store" });
  const data = await res.json();
  const states = data.states || [];

  aircraftLayer.clearLayers();
  const threshold = Number(altitudeInput.value);

  states.forEach(state => {
    const hex = String(state[0] || "").toLowerCase();
    const lon = Number(state[5]);
    const lat = Number(state[6]);
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) return;

    const alt = chooseAltitude(state[7], state[13]);
    const speedMs = Number(state[9]);
    const speedKts = Number.isFinite(speedMs) ? speedMs * MS_TO_KTS : NaN;

    const headingRaw = Number(state[10]);
    const heading = smoothHeading(hex, headingRaw);

    const vRate = Number(state[11]);
    const climbSym = climbDescSymbol(vRate);

    const color = speedToColor(speedKts);
    const opacity = altitudeToOpacity(alt);

    const icon = L.divIcon({
      className: "", // keep clean
      html: `
        <div class="aircraft-icon" style="color:${color};opacity:${opacity}">
          <div class="aircraft-arrow"
               style="transform: translateX(-50%) rotate(${heading}deg);"></div>
          <div class="aircraft-label">
            ${hex.toUpperCase()}<br>${alt ? Math.round(alt) : '—'} ft ${climbSym}
          </div>
        </div>
      `,
      iconSize: [44, 44],
      iconAnchor: [22, 22]
    });

    const marker = L.marker([lat, lon], { icon }).addTo(aircraftLayer);

    // Make sure clicking works + show FR24-style card
    marker.on("click", async () => {
      const info = await fetchAircraftInfo(hex);
      showAircraftCard({
        hex: hex.toUpperCase(),
        registration: info?.registration || null,
        manufacturer: info?.manufacturer || null,
        model: info?.model || null,
        typecode: info?.typecode || null,
        callsign: null,
        altitude: alt ? Math.round(alt) : null,
        speed: Number.isFinite(speedKts) ? Math.round(speedKts) : null,
        heading: Number.isFinite(headingRaw) ? Math.round(headingRaw) : null,
        vertical: climbSym || "—"
      });

      // Optional: also show Leaflet popup if you still want it
      // marker.bindPopup(`...`).openPopup();
    });

    // Replace hex label with tail number when available
    fetchAircraftInfo(hex).then(info => {
      if (!info?.registration) return;

      const el = marker.getElement();
      const label = el?.querySelector(".aircraft-label");
      if (label) {
        label.innerHTML = `${info.registration}<br>${alt ? Math.round(alt) : '—'} ft ${climbSym}`;
      }

      // IMPORTANT: also update alerts list if this aircraft is already logged
      const alert = alertLog.find(a => a.key === hex);
      if (alert && alert.callsign === hex.toUpperCase()) {
        alert.callsign = info.registration;
        updateSidebar();
      }
    });

    // Alerts
    if (alt == null || alt > threshold) return;

    const pt = turf.point([lon, lat]);
    const inside =
      (geofence && turf.booleanPointInPolygon(pt, geofence)) ||
      (ringCenter && map.distance([lat, lon], ringCenter) <= milesToMeters(20));

    if (!inside) return;

    if (!alertLog.some(a => a.key === hex)) {
      alertLog.push({
        key: hex,
        callsign: hex.toUpperCase(), // later replaced by registration
        altitude: Math.round(alt)
      });
      updateSidebar();
      maybeOpenSidebar();
    }
  });

  updateSidebar();
}

// ===============================
// SIDEBAR
// ===============================
function updateSidebar() {
  alertListEl.innerHTML = "";

  if (!geofence && !ringCenter) {
    alertListEl.innerHTML = "<p>Draw a fence or activate rings.</p>";
    return;
  }

  if (!alertLog.length) {
    alertListEl.innerHTML = "<p>No alerts.</p>";
    return;
  }

  alertLog.forEach(a => {
    alertListEl.insertAdjacentHTML(
      "beforeend",
      `<div class="alert"><strong>${escapeHtml(a.callsign)}</strong><br>${escapeHtml(a.altitude)} ft</div>`
    );
  });
}

function maybeOpenSidebar() {
  if (window.innerWidth <= 768) sidebar.classList.add("open");
}

// ===============================
// START
// ===============================
fetchOpenSky();
setInterval(fetchOpenSky, 5000);





const sidebarHandle = document.getElementById("sidebar-handle");

sidebarHandle?.addEventListener("click", () => {
  sidebar.classList.toggle("open");
});