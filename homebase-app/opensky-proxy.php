<?php
/**
 * opensky-proxy.php (ADSB.lol ONLY)
 *
 * Purpose:
 * - Fetch ADSB.lol `/v2/point/{lat}/{lon}/{radius}` and normalize to OpenSky-like `states`
 * - No local dump1090 at all (for troubleshooting / validation)
 *
 * Usage:
 * - /opensky-proxy.php
 * - /opensky-proxy.php?lat=42.8808&lon=-85.5228&radius=80
 * - /opensky-proxy.php?debug=1
 *
 * Notes:
 * - radius is NM (1..250)
 * - This outputs velocity in m/s and altitude in meters (OpenSky-ish),
 *   because many map implementations assume those units.
 */

declare(strict_types=1);

header("Content-Type: application/json; charset=utf-8");

/** -----------------------------
 * CONFIG
 * ----------------------------- */

// ADSB.lol base endpoint
$adsblol_base = 'https://api.adsb.lol/v2/point';

// Default location (KGRR)
$default_lat = 42.8808;
$default_lon = -85.5228;
$default_radius = 80; // nm (1..250)

/** -----------------------------
 * INPUTS
 * ----------------------------- */

$lat = isset($_GET['lat']) ? (float)$_GET['lat'] : $default_lat;
$lon = isset($_GET['lon']) ? (float)$_GET['lon'] : $default_lon;
$radius = isset($_GET['radius']) ? (int)$_GET['radius'] : $default_radius;
$debug = isset($_GET['debug']) && $_GET['debug'] !== '0';

// Clamp radius (ADSB.lol spec 0..250; use 1..250)
$radius = max(1, min(250, $radius));

if ($lat < -90 || $lat > 90 || $lon < -180 || $lon > 180) {
  http_response_code(400);
  echo json_encode(['error' => 'Invalid lat/lon'], JSON_PRETTY_PRINT);
  exit;
}

/** -----------------------------
 * HELPERS
 * ----------------------------- */

function respond(array $payload, int $code = 200): void {
  http_response_code($code);
  echo json_encode($payload, JSON_PRETTY_PRINT);
  exit;
}

// Knots → m/s (OpenSky expects m/s)
function knots_to_ms(?float $knots): ?float {
  if ($knots === null) return null;
  return $knots * 0.514444;
}

// Feet → meters (OpenSky expects meters)
function feet_to_meters(?float $ft): ?float {
  if ($ft === null) return null;
  return $ft * 0.3048;
}

// HTTP GET via cURL (preferred) with timeout
function http_get(string $url, int $timeoutSeconds = 8): array {
  $ch = curl_init($url);
  curl_setopt_array($ch, [
	CURLOPT_RETURNTRANSFER => true,
	CURLOPT_TIMEOUT => $timeoutSeconds,
	CURLOPT_FOLLOWLOCATION => true,
	CURLOPT_HTTPHEADER => ['Accept: application/json'],
  ]);
  $body = curl_exec($ch);
  $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
  $err  = curl_error($ch);
  curl_close($ch);

  return [$code, $body ?: null, $err ?: null];
}

/** -----------------------------
 * FETCH ADSB.LOL
 * ----------------------------- */

$adsblol_url = sprintf('%s/%s/%s/%d', $adsblol_base, $lat, $lon, $radius);
[$code, $body, $err] = http_get($adsblol_url, 10);

if ($code !== 200 || !$body) {
  respond([
	'error' => 'ADSB.lol fetch failed',
	'http' => $code,
	'curl_error' => $err,
	'url' => $adsblol_url,
  ], 502);
}

$data = json_decode($body, true);
if (!is_array($data)) {
  respond([
	'error' => 'ADSB.lol returned invalid JSON',
	'url' => $adsblol_url,
	'raw' => substr((string)$body, 0, 500),
  ], 502);
}

/**
 * ADSB.lol /point response: aircraft list key can vary.
 * Try common keys.
 */
$aircraftList = null;

if (isset($data['ac']) && is_array($data['ac'])) {
  $aircraftList = $data['ac'];
} elseif (isset($data['aircraft']) && is_array($data['aircraft'])) {
  $aircraftList = $data['aircraft'];
} elseif (isset($data['data']) && is_array($data['data'])) {
  $aircraftList = $data['data'];
} elseif (array_keys($data) === range(0, count($data) - 1)) {
  // Root array
  $aircraftList = $data;
}

if (!$aircraftList) {
  respond([
	'error' => 'ADSB.lol response did not include an aircraft list (update parsing keys)',
	'url' => $adsblol_url,
	'top_level_keys' => array_keys($data),
	'sample' => $data,
  ], 502);
}

/** -----------------------------
 * NORMALIZE → OpenSky-style states
 * ----------------------------- */

$states = [];
$now = time();

foreach ($aircraftList as $ac) {
  if (!is_array($ac)) continue;

  $latVal = $ac['lat'] ?? null;
  $lonVal = $ac['lon'] ?? null;
  if ($latVal === null || $lonVal === null) continue;

  // Common hex keys
  $hex = $ac['hex'] ?? ($ac['icao'] ?? ($ac['icao24'] ?? ''));
  if (!$hex) continue;

  // Callsign
  $callsign = trim((string)($ac['flight'] ?? ($ac['callsign'] ?? $hex)));
  $originCountry = (string)($ac['country'] ?? 'N/A');

  // ADSB.lol fields commonly mirror dump1090 naming:
  // alt_baro, alt_geom (often feet)
  $alt_ft = isset($ac['alt_baro']) ? (float)$ac['alt_baro'] : null;
  $geo_ft = isset($ac['alt_geom']) ? (float)$ac['alt_geom'] : $alt_ft;

  // Convert to meters
  $alt_m = feet_to_meters($alt_ft);
  $geo_m = feet_to_meters($geo_ft);

  // Speed in knots → m/s
  $vel_ms = isset($ac['gs']) ? knots_to_ms((float)$ac['gs']) : null;

  $track = isset($ac['track']) ? (float)$ac['track'] : null;
  $vRate = isset($ac['baro_rate']) ? (float)$ac['baro_rate'] : null; // may be ft/min; leaving raw unless your map needs conversion
  $squawk = $ac['squawk'] ?? null;

  $states[] = [
	(string)$hex,        // 0 icao24
	$callsign,           // 1 callsign
	$originCountry,      // 2 originCountry
	$now,                // 3 timePosition
	$now,                // 4 lastContact
	(float)$lonVal,      // 5 lon
	(float)$latVal,      // 6 lat
	$alt_m,              // 7 baroAltitude (meters)
	false,               // 8 onGround
	$vel_ms,             // 9 velocity (m/s)
	$track,              // 10 trueTrack
	$vRate,              // 11 verticalRate (raw)
	null,                // 12 sensors
	$geo_m,              // 13 geoAltitude (meters)
	$squawk,             // 14 squawk
	false,               // 15 spi
	'adsblol',           // 16 positionSource
  ];
}

/** -----------------------------
 * OUTPUT
 * ----------------------------- */

if ($debug) {
  respond([
	'time' => time(),
	'source' => 'adsblol_point_only',
	'request' => [
	  'lat' => $lat,
	  'lon' => $lon,
	  'radius_nm' => $radius,
	  'url' => $adsblol_url,
	],
	'counts' => [
	  'aircraft_list' => is_array($aircraftList) ? count($aircraftList) : 0,
	  'states' => count($states),
	],
	'sample_aircraft' => $aircraftList[0] ?? null,
	'sample_state' => $states[0] ?? null,
	'states' => $states,
  ]);
}

respond([
  'time' => time(),
  'source' => 'adsblol_point_only',
  'states' => $states
]);