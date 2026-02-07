<?php
/**
 * If “nothing shows on the map”, 99% of the time it’s one of these:
 * - WRONG local dump1090 URL (your script uses 10.42.0.1 + /skyaware/... which is often not correct)
 * - ADSB.lol response parsing key mismatch (you’re not actually getting an aircraft list)
 * - Map code expects velocity in m/s (OpenSky uses m/s) and/or ignores invalid states
 *
 * Fix approach:
 * - Try multiple known dump1090 URLs (localhost first)
 * - Add a ?debug=1 mode to see counts + first aircraft record
 * - Normalize units (knots → m/s, feet → meters) so OpenSky-ish consumers behave
 *
 * Save as: /var/www/homebase/opensky-proxy.php (or wherever your map fetches)
 */

declare(strict_types=1);

header("Content-Type: application/json; charset=utf-8");

/** -----------------------------
 * CONFIG
 * ----------------------------- */

// Try these in order. Most reliable is localhost.
$dump1090_candidates = [
  'http://127.0.0.1:8080/data/aircraft.json',             // common dump1090-fa web root
  'http://localhost:8080/data/aircraft.json',
  'http://127.0.0.1:8080/skyaware/data/aircraft.json',    // if SkyAware is mounted under /skyaware
  'http://localhost:8080/skyaware/data/aircraft.json',
];

// ADSB.lol point endpoint
$adsblol_base = 'https://api.adsb.lol/v2/point';

// Enable/disable fallback
$adsblol_enabled = true;

// Defaults (set these to your receiver location; DO NOT use JFK unless you are near JFK)
$default_lat = 42.8808;   // KGRR
$default_lon = -85.5228;  // KGRR
$default_radius = 80;     // nm (1..250)

// Query overrides (?lat=..&lon=..&radius=..)
$lat = isset($_GET['lat']) ? (float)$_GET['lat'] : $default_lat;
$lon = isset($_GET['lon']) ? (float)$_GET['lon'] : $default_lon;
$radius = isset($_GET['radius']) ? (int)$_GET['radius'] : $default_radius;
$debug = isset($_GET['debug']) && $_GET['debug'] !== '0';

// Clamp radius
$radius = max(1, min(250, $radius));

/** -----------------------------
 * HELPERS
 * ----------------------------- */

function respond(array $payload, int $code = 200): void {
  http_response_code($code);
  echo json_encode($payload, JSON_PRETTY_PRINT);
  exit;
}

function http_get(string $url, int $timeoutSeconds = 6): array {
  // Prefer cURL if installed, otherwise fallback to file_get_contents.
  if (function_exists('curl_init')) {
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

  $ctx = stream_context_create([
	'http' => [
	  'timeout' => $timeoutSeconds,
	  'header'  => "Accept: application/json\r\n",
	]
  ]);

  $body = @file_get_contents($url, false, $ctx);
  $code = 0;

  // Try to parse HTTP response code from $http_response_header
  global $http_response_header;
  if (isset($http_response_header[0]) && preg_match('#HTTP/\S+\s+(\d{3})#', $http_response_header[0], $m)) {
	$code = (int)$m[1];
  }

  return [$code, $body ?: null, null];
}

// Unit normalization (OpenSky expects meters + m/s)
function knots_to_ms(?float $knots): ?float {
  if ($knots === null) return null;
  return $knots * 0.514444;
}
function feet_to_meters(?float $ft): ?float {
  if ($ft === null) return null;
  return $ft * 0.3048;
}

/** -----------------------------
 * 1) LOCAL dump1090
 * ----------------------------- */

$local_used = null;
$local_data = null;
$local_error = null;

foreach ($dump1090_candidates as $url) {
  [$code, $body, $err] = http_get($url, 4);
  if ($code === 200 && $body) {
	$json = json_decode($body, true);
	if (is_array($json) && isset($json['aircraft']) && is_array($json['aircraft'])) {
	  $local_used = $url;
	  $local_data = $json;
	  break;
	}
  }
  $local_error = $local_error ?: ($err ?: "HTTP $code");
}

if ($local_data && !empty($local_data['aircraft'])) {
  $states = [];
  $now = time();

  foreach ($local_data['aircraft'] as $ac) {
	if (!isset($ac['lat'], $ac['lon'])) continue;

	$hex = $ac['hex'] ?? '';
	if ($hex === '') continue;

	$callsign = trim((string)($ac['flight'] ?? $hex));
	$originCountry = 'N/A';

	$lonVal = (float)$ac['lon'];
	$latVal = (float)$ac['lat'];

	// dump1090 altitudes are typically feet; normalize to meters for OpenSky-ish output
	$alt_ft = isset($ac['alt_baro']) ? (float)$ac['alt_baro'] : null;
	$geo_ft = isset($ac['alt_geom']) ? (float)$ac['alt_geom'] : $alt_ft;

	$alt_m  = feet_to_meters($alt_ft);
	$geo_m  = feet_to_meters($geo_ft);

	// dump1090 gs is knots; normalize to m/s
	$vel_ms = knots_to_ms(isset($ac['gs']) ? (float)$ac['gs'] : null);

	$track  = isset($ac['track']) ? (float)$ac['track'] : null;
	$vRate  = isset($ac['baro_rate']) ? (float)$ac['baro_rate'] : null; // often ft/min; leave as-is unless your map needs m/s
	$squawk = $ac['squawk'] ?? null;

	$onGround = isset($ac['ground']) ? (bool)$ac['ground'] : false;

	$states[] = [
	  $hex,          // 0 ICAO24
	  $callsign,     // 1 Callsign
	  $originCountry,// 2 Origin country
	  $now,          // 3 Time position
	  $now,          // 4 Last contact
	  $lonVal,       // 5 Lon
	  $latVal,       // 6 Lat
	  $alt_m,        // 7 Baro altitude (meters)
	  $onGround,     // 8 On ground
	  $vel_ms,       // 9 Velocity (m/s)
	  $track,        // 10 Track (deg)
	  $vRate,        // 11 Vertical rate (raw)
	  null,          // 12 Sensors
	  $geo_m,        // 13 Geo altitude (meters)
	  $squawk,       // 14 Squawk
	  false,         // 15 SPI
	  'dump1090',    // 16 Position source
	];
  }

  if ($debug) {
	respond([
	  'time' => time(),
	  'source' => 'local_dump1090',
	  'local_url_used' => $local_used,
	  'count_aircraft_raw' => count($local_data['aircraft']),
	  'count_states' => count($states),
	  'sample_aircraft_raw' => $local_data['aircraft'][0] ?? null,
	  'sample_state' => $states[0] ?? null,
	  'states' => $states,
	]);
  }

  respond([
	'time' => time(),
	'source' => 'local_dump1090',
	'states' => $states
  ]);
}

/** -----------------------------
 * 2) ADSB.lol fallback
 * ----------------------------- */

if (!$adsblol_enabled) {
  respond(['error' => 'Local dump1090 unavailable and ADSB.lol fallback disabled'], 502);
}

if ($lat < -90 || $lat > 90 || $lon < -180 || $lon > 180) {
  respond(['error' => 'Invalid lat/lon for ADSB.lol fallback'], 400);
}

$adsblol_url = sprintf('%s/%s/%s/%d', $adsblol_base, $lat, $lon, $radius);
[$code, $body, $err] = http_get($adsblol_url, 8);

if ($code !== 200 || !$body) {
  respond([
	'error' => 'Failed to fetch local dump1090 AND ADSB.lol fallback failed',
	'local_error' => $local_error,
	'adsblol_http' => $code,
	'adsblol_error' => $err,
	'adsblol_url' => $adsblol_url
  ], 502);
}

$adsb = json_decode($body, true);
if (!is_array($adsb)) {
  respond(['error' => 'ADSB.lol returned invalid JSON', 'adsblol_url' => $adsblol_url], 502);
}

// Try common aircraft-list keys for /point
$aircraftList = null;
if (isset($adsb['ac']) && is_array($adsb['ac'])) $aircraftList = $adsb['ac'];
if (!$aircraftList && isset($adsb['aircraft']) && is_array($adsb['aircraft'])) $aircraftList = $adsb['aircraft'];
if (!$aircraftList && isset($adsb['data']) && is_array($adsb['data'])) $aircraftList = $adsb['data'];
if (!$aircraftList && array_keys($adsb) === range(0, count($adsb) - 1)) $aircraftList = $adsb;

if (!$aircraftList) {
  respond([
	'error' => 'ADSB.lol response did not contain an aircraft list (update parsing keys)',
	'adsblol_url' => $adsblol_url,
	'debug_keys' => array_keys($adsb),
	'sample' => $adsb
  ], 502);
}

$states = [];
$now = time();

foreach ($aircraftList as $ac) {
  if (!is_array($ac)) continue;
  if (!isset($ac['lat'], $ac['lon'])) continue;

  $hex = $ac['hex'] ?? ($ac['icao'] ?? ($ac['icao24'] ?? ''));
  if (!$hex) continue;

  $callsign = trim((string)($ac['flight'] ?? ($ac['callsign'] ?? $hex)));
  $originCountry = (string)($ac['country'] ?? 'N/A');

  $alt_ft = isset($ac['alt_baro']) ? (float)$ac['alt_baro'] : null;
  $geo_ft = isset($ac['alt_geom']) ? (float)$ac['alt_geom'] : $alt_ft;

  $alt_m = feet_to_meters($alt_ft);
  $geo_m = feet_to_meters($geo_ft);

  $vel_ms = knots_to_ms(isset($ac['gs']) ? (float)$ac['gs'] : null);
  $track  = isset($ac['track']) ? (float)$ac['track'] : null;
  $vRate  = isset($ac['baro_rate']) ? (float)$ac['baro_rate'] : null;
  $squawk = $ac['squawk'] ?? null;

  $states[] = [
	(string)$hex,
	$callsign,
	$originCountry,
	$now,
	$now,
	(float)$ac['lon'],
	(float)$ac['lat'],
	$alt_m,
	false,
	$vel_ms,
	$track,
	$vRate,
	null,
	$geo_m,
	$squawk,
	false,
	'adsblol'
  ];
}

if ($debug) {
  respond([
	'time' => time(),
	'source' => 'adsblol_point',
	'local_error' => $local_error,
	'adsblol_url' => $adsblol_url,
	'count_states' => count($states),
	'sample_state' => $states[0] ?? null,
	'states' => $states
  ]);
}

respond([
  'time' => time(),
  'source' => 'adsblol_point',
  'adsblol_url' => $adsblol_url,
  'states' => $states
]);