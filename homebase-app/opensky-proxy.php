<?php
/**
 * opensky-proxy.php
 *
 * Purpose:
 * - Primary: fetch local dump1090 SkyAware aircraft.json and normalize to OpenSky-like `states`
 * - Fallback: if local feed is unavailable/empty, fetch ADSB.lol `/v2/point/{lat}/{lon}/{radius}`
 *
 * Output shape (OpenSky-style):
 * {
 *   "time": 1234567890,
 *   "states": [ [icao24, callsign, originCountry, timePosition, lastContact, lon, lat, baroAlt, onGround, velocity, track, vRate, sensors, geoAlt, squawk, spi, positionSource], ... ]
 * }
 *
 * Notes:
 * - ADSB.lol radius is nautical miles (0..250)
 * - Local dump1090 uses `gs` (knots) and `track` (degrees)
 * - ADSB.lol uses `gs` (knots) and `track` (degrees) in the docs screenshot
 */

/** -----------------------------
 *  CONFIG
 *  ----------------------------- */

// Local dump1090 aircraft.json endpoint (SkyAware)
$dump1090_url = 'http://10.42.0.1:8080/skyaware/data/aircraft.json';

// ADSB.lol base
$adsblol_base = 'https://api.adsb.lol/v2/point';

// Fallback enabled toggle (can be replaced with user DB setting later)
$adsblol_enabled = true;

// Default lat/lon/radius (replace with DB settings later)
$default_lat = null;      // e.g. 42.8808
$default_lon = null;      // e.g. -85.5228
$default_radius = 50;     // nm (1..250)

// Allow overriding lat/lon/radius by query string (optional)
$q_lat = isset($_GET['lat']) ? (float)$_GET['lat'] : null;
$q_lon = isset($_GET['lon']) ? (float)$_GET['lon'] : null;
$q_radius = isset($_GET['radius']) ? (int)$_GET['radius'] : null;

// Resolve lat/lon/radius
$lat = $q_lat ?? $default_lat;
$lon = $q_lon ?? $default_lon;
$radius = $q_radius ?? $default_radius;

// Clamp radius to ADSB.lol spec (0..250; use 1..250 to avoid pointless calls)
if ($radius < 1) $radius = 1;
if ($radius > 250) $radius = 250;

// Basic response headers
header("Content-Type: application/json");

// Small helper: safe JSON output
function respond_json(array $payload, int $code = 200): void {
  http_response_code($code);
  echo json_encode($payload, JSON_PRETTY_PRINT);
  exit;
}

// Small helper: HTTP GET (curl) with timeout
function http_get(string $url, int $timeoutSeconds = 6): ?string {
  $ch = curl_init($url);
  curl_setopt_array($ch, [
	CURLOPT_RETURNTRANSFER => true,
	CURLOPT_TIMEOUT => $timeoutSeconds,
	CURLOPT_FOLLOWLOCATION => true,
	CURLOPT_HTTPHEADER => [
	  'Accept: application/json'
	],
  ]);
  $resp = curl_exec($ch);
  $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
  curl_close($ch);

  if ($code !== 200 || !$resp) return null;
  return $resp;
}

/** -----------------------------
 *  1) Try LOCAL dump1090 feed
 *  ----------------------------- */

$local_json = @file_get_contents($dump1090_url);

if ($local_json) {
  $data = json_decode($local_json, true);

  // dump1090 aircraft.json should have `aircraft` array
  if (is_array($data) && !empty($data['aircraft']) && is_array($data['aircraft'])) {
	$states = [];

	foreach ($data['aircraft'] as $ac) {
	  // Skip aircraft with no position
	  if (!isset($ac['lat'], $ac['lon'])) continue;

	  $hex = $ac['hex'] ?? '';
	  if ($hex === '') continue;

	  $callsign = trim($ac['flight'] ?? $hex);
	  $originCountry = 'N/A';
	  $time = time();

	  $lonVal = (float)$ac['lon'];
	  $latVal = (float)$ac['lat'];

	  // dump1090 fields
	  $alt = isset($ac['alt_baro']) ? (float)$ac['alt_baro'] : null;
	  $geoAlt = isset($ac['alt_geom']) ? (float)$ac['alt_geom'] : $alt;

	  $velocity = isset($ac['gs']) ? (float)$ac['gs'] : null;     // knots
	  $track = isset($ac['track']) ? (float)$ac['track'] : null;  // degrees
	  $vRate = isset($ac['baro_rate']) ? (float)$ac['baro_rate'] : null;
	  $squawk = $ac['squawk'] ?? null;

	  $spi = false;
	  $onGround = false;          // dump1090 has `ground` sometimes; if you have it, set it here
	  $positionSource = null;

	  $states[] = [
		$hex,        // 0 ICAO24
		$callsign,   // 1 Callsign
		$originCountry, // 2 Origin country
		$time,       // 3 Time position
		$time,       // 4 Last contact
		$lonVal,     // 5 Longitude
		$latVal,     // 6 Latitude
		$alt,        // 7 Baro altitude
		$onGround,   // 8 On ground
		$velocity,   // 9 Velocity (knots)
		$track,      // 10 Track (deg)
		$vRate,      // 11 Vertical rate
		null,        // 12 Sensors
		$geoAlt,     // 13 Geo altitude
		$squawk,     // 14 Squawk
		$spi,        // 15 SPI
		$positionSource // 16 Position source
	  ];
	}

	// If we have any aircraft, return local feed
	if (!empty($states)) {
	  respond_json([
		'time' => time(),
		'source' => 'local_dump1090',
		'states' => $states
	  ]);
	}
  }
}

/** -----------------------------
 *  2) FALLBACK to ADSB.lol
 *  ----------------------------- */

if (!$adsblol_enabled) {
  respond_json(['error' => 'Failed to fetch local dump1090 data (fallback disabled)'], 502);
}

// Must have lat/lon for ADSB.lol point endpoint
if ($lat === null || $lon === null) {
  respond_json([
	'error' => 'Local feed unavailable and ADSB.lol fallback missing lat/lon',
	'hint'  => 'Provide ?lat=...&lon=...&radius=... or set defaults in this file'
  ], 500);
}

// Validate lat/lon
if ($lat < -90 || $lat > 90 || $lon < -180 || $lon > 180) {
  respond_json(['error' => 'Invalid lat/lon for ADSB.lol fallback'], 400);
}

$adsblol_url = sprintf('%s/%s/%s/%d', $adsblol_base, $lat, $lon, $radius);
$adsb_json = http_get($adsblol_url, 8);

if (!$adsb_json) {
  respond_json(['error' => 'Failed to fetch local dump1090 data AND ADSB.lol fallback failed'], 502);
}

$adsb = json_decode($adsb_json, true);
if (!is_array($adsb)) {
  respond_json(['error' => 'ADSB.lol returned invalid JSON'], 502);
}

/**
 * ADSB.lol response shape varies by endpoint/version.
 * Commonly:
 * - A list of aircraft under something like `ac`, `aircraft`, or root array.
 *
 * The screenshot you shared shows a single aircraft in `closest`.
 * For /point, expect multiple aircraft.
 *
 * The logic below tries common keys and normalizes.
 */
$aircraftList = null;

if (isset($adsb['ac']) && is_array($adsb['ac'])) {
  $aircraftList = $adsb['ac'];
} elseif (isset($adsb['aircraft']) && is_array($adsb['aircraft'])) {
  $aircraftList = $adsb['aircraft'];
} elseif (isset($adsb['states']) && is_array($adsb['states'])) {
  // If ADSB.lol ever returns OpenSky-like states already (rare), just pass it through
  respond_json([
	'time' => time(),
	'source' => 'adsblol_passthrough',
	'states' => $adsb['states']
  ]);
} elseif (is_array($adsb) && array_keys($adsb) === range(0, count($adsb) - 1)) {
  // Root array
  $aircraftList = $adsb;
}

if (!$aircraftList) {
  respond_json([
	'error' => 'ADSB.lol response did not contain an aircraft list',
	'source' => 'adsblol',
	'debug_keys' => array_keys($adsb)
  ], 502);
}

$states = [];
$now = time();

foreach ($aircraftList as $ac) {
  // Expect lat/lon + hex/icao
  $latVal = $ac['lat'] ?? null;
  $lonVal = $ac['lon'] ?? null;
  if ($latVal === null || $lonVal === null) continue;

  // Common hex keys: hex, icao, icao24
  $hex = $ac['hex'] ?? ($ac['icao'] ?? ($ac['icao24'] ?? ''));
  if ($hex === '') continue;

  $callsign = trim($ac['flight'] ?? ($ac['callsign'] ?? $hex));
  $originCountry = $ac['country'] ?? 'N/A';

  // ADSB.lol fields from docs screenshot:
  // - alt_baro, alt_geom, gs, track, baro_rate, squawk
  $alt = isset($ac['alt_baro']) ? (float)$ac['alt_baro'] : null;
  $geoAlt = isset($ac['alt_geom']) ? (float)$ac['alt_geom'] : $alt;

  $velocity = isset($ac['gs']) ? (float)$ac['gs'] : null;     // knots
  $track = isset($ac['track']) ? (float)$ac['track'] : null;  // degrees
  $vRate = isset($ac['baro_rate']) ? (float)$ac['baro_rate'] : null;

  $squawk = $ac['squawk'] ?? null;
  $spi = false;
  $onGround = false;
  $positionSource = 'adsblol';

  $states[] = [
	$hex,
	$callsign,
	$originCountry,
	$now,
	$now,
	(float)$lonVal,
	(float)$latVal,
	$alt,
	$onGround,
	$velocity,
	$track,
	$vRate,
	null,
	$geoAlt,
	$squawk,
	$spi,
	$positionSource
  ];
}

respond_json([
  'time' => time(),
  'source' => 'adsblol_point',
  'adsblol' => [
	'lat' => $lat,
	'lon' => $lon,
	'radius_nm' => $radius,
	'url' => $adsblol_url
  ],
  'states' => $states
]);