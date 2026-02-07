<?php
/**
 * opensky-proxy.php (ADSB.lol ONLY)
 *
 * Converts ADSB.lol /v2/point/{lat}/{lon}/{radius} output
 * into an OpenSky-like response:
 *   { "time": <unix>, "states": [ [...], ... ] }
 *
 * Query params:
 *   ?lat=40.6413&lon=-73.7781&radius=150
 *   ?debug=1  (adds source + url + counts)
 */

header("Content-Type: application/json");

// --------------------
// Config / defaults
// --------------------
$adsblol_base = 'https://api.adsb.lol/v2/point';

// Defaults (JFK-ish)
$lat = isset($_GET['lat']) ? (float)$_GET['lat'] : 40.6413;
$lon = isset($_GET['lon']) ? (float)$_GET['lon'] : -73.7781;
$radius = isset($_GET['radius']) ? (int)$_GET['radius'] : 150; // nm 0..250
$debug = !empty($_GET['debug']);

// Clamp radius
if ($radius < 1) $radius = 1;
if ($radius > 250) $radius = 250;

// Validate lat/lon
if ($lat < -90 || $lat > 90 || $lon < -180 || $lon > 180) {
  http_response_code(400);
  echo json_encode(['error' => 'Invalid lat/lon'], JSON_PRETTY_PRINT);
  exit;
}

// Build URL
$adsblol_url = sprintf('%s/%s/%s/%d', $adsblol_base, $lat, $lon, $radius);

// --------------------
// HTTP GET via cURL
// --------------------
$ch = curl_init($adsblol_url);
curl_setopt_array($ch, [
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_TIMEOUT => 10,
  CURLOPT_FOLLOWLOCATION => true,
  CURLOPT_HTTPHEADER => [
	'Accept: application/json'
  ],
]);

$body = curl_exec($ch);
$err  = curl_error($ch);
$code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

if ($code !== 200 || !$body) {
  http_response_code(502);
  echo json_encode([
	'error' => 'Failed to fetch ADSB.lol',
	'http' => $code,
	'curl_error' => $err ?: null,
	'url' => $adsblol_url
  ], JSON_PRETTY_PRINT);
  exit;
}

// --------------------
// Parse JSON
// --------------------
$data = json_decode($body, true);
if (!is_array($data)) {
  http_response_code(502);
  echo json_encode([
	'error' => 'ADSB.lol returned invalid JSON',
	'url' => $adsblol_url
  ], JSON_PRETTY_PRINT);
  exit;
}

/**
 * ADSB.lol /v2/point commonly returns aircraft list under:
 *   - $data['ac']   (most common)
 * Some versions may use:
 *   - $data['aircraft']
 *   - root array
 */
$aircraftList = null;

if (isset($data['ac']) && is_array($data['ac'])) {
  $aircraftList = $data['ac'];
} elseif (isset($data['aircraft']) && is_array($data['aircraft'])) {
  $aircraftList = $data['aircraft'];
} elseif (array_keys($data) === range(0, count($data) - 1)) {
  // root array
  $aircraftList = $data;
}

if (!$aircraftList) {
  http_response_code(502);
  echo json_encode([
	'error' => 'ADSB.lol response did not include aircraft list',
	'url' => $adsblol_url,
	'top_level_keys' => array_keys($data)
  ], JSON_PRETTY_PRINT);
  exit;
}

// --------------------
// Convert to OpenSky-like states
// --------------------
$now = time();
$states = [];

foreach ($aircraftList as $ac) {
  // Need position
  if (!isset($ac['lat'], $ac['lon'])) continue;

  // Identify hex/icao
  $hex = $ac['hex'] ?? ($ac['icao'] ?? ($ac['icao24'] ?? ''));
  $hex = strtolower(trim((string)$hex));
  if ($hex === '') continue;

  // Callsign/flight
  $callsign = trim((string)($ac['flight'] ?? ($ac['callsign'] ?? '')));
  if ($callsign === '') $callsign = $hex;

  $originCountry = (string)($ac['country'] ?? 'N/A');

  // ADSB.lol fields (common)
  $alt = isset($ac['alt_baro']) ? (float)$ac['alt_baro'] : null;
  $geoAlt = isset($ac['alt_geom']) ? (float)$ac['alt_geom'] : $alt;

  $velocity = isset($ac['gs']) ? (float)$ac['gs'] : null;     // knots
  $track    = isset($ac['track']) ? (float)$ac['track'] : null; // degrees
  $vRate    = isset($ac['baro_rate']) ? (float)$ac['baro_rate'] : null;

  $squawk = $ac['squawk'] ?? null;

  // On-ground: ADSB.lol sometimes has "ground" or "on_ground"
  $onGround = false;
  if (isset($ac['ground'])) $onGround = (bool)$ac['ground'];
  if (isset($ac['on_ground'])) $onGround = (bool)$ac['on_ground'];

  $spi = false;
  $positionSource = 'adsblol';

  $states[] = [
	$hex,          // 0  ICAO24
	$callsign,     // 1  Callsign
	$originCountry,// 2  Origin Country
	$now,          // 3  Time Position
	$now,          // 4  Last Contact
	(float)$ac['lon'], // 5 Longitude
	(float)$ac['lat'], // 6 Latitude
	$alt,          // 7  Baro Altitude
	$onGround,     // 8  On Ground
	$velocity,     // 9  Velocity (knots)
	$track,        // 10 True Track
	$vRate,        // 11 Vertical Rate
	null,          // 12 Sensors
	$geoAlt,       // 13 Geo Altitude
	$squawk,       // 14 Squawk
	$spi,          // 15 SPI
	$positionSource// 16 Position Source
  ];
}

// --------------------
// Output
// --------------------
$out = [
  'time' => $now,
  'states' => $states
];

if ($debug) {
  $out['debug'] = [
	'source' => 'adsblol_point',
	'url' => $adsblol_url,
	'aircraft_list_count' => count($aircraftList),
	'states_count' => count($states),
	'top_level_keys' => array_keys($data),
  ];
}

echo json_encode($out, JSON_PRETTY_PRINT);