<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Geofence ADS-B Tracker</title>

  <link rel="stylesheet" href="https://unpkg.com/leaflet/dist/leaflet.css" />
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/leaflet-draw/dist/leaflet.draw.css" />
  <link rel="stylesheet" href="style.css" />
</head>
<body>

  <div id="map"></div>

  <!-- Sidebar / Bottom Sheet -->
  <aside id="sidebar">
    <div id="sidebar-handle"></div>

    <!-- 🔑 SCROLL CONTAINER (ONLY THIS SCROLLS) -->
    <div id="sidebar-scroll">

      <!-- 🔑 CONTENT CONTAINER (ALL PADDING LIVES HERE) -->
      <div id="sidebar-content">

        <!-- Aircraft card injected by JS -->
        <div id="selected-aircraft-container"></div>

        <section class="alerts-section">
          <h2>Geofence Alerts</h2>
          <div id="alert-list">
            <p>Draw a fence or activate rings.</p>
          </div>
        </section>

      </div>
    </div>
  </aside>

  <script src="https://unpkg.com/leaflet/dist/leaflet.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/leaflet-draw@1.0.4/dist/leaflet.draw.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/@turf/turf@6.5.0/turf.min.js"></script>
  <script src="opensky.js?v=7"></script>
</body>
</html>