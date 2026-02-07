<?php
/**
 * opensky-proxy.php (ADSB.lol → OpenSky-style states)
 *
 * Matches your existing output format exactly:
 * {
 *   "time": <unix>,
 *   "states": [ [...], ... ]
 * }
 *
 * Notes:
 * - Keeps the same field semantics you already use:
 *   - velocity stays in knots (because your dump1090 code uses gs directly)
 *   - alt/geoAlt stay in feet (because your dump1090 code uses alt_baro/alt_geom directly)
 * - This is intentional so your map parsing doesn’t need to change.
 */

header("Content-Type: application/json");

/** -----------------------------
 * CONFIG (ADSB.lol /point)
 * ----------------------------- */
$adsblol_base = 'https://api.adsb.lol/v2/point';

// Defaults (set these to your preferred airport later via settings DB)
$default_lat = 40.6413;   // KGRR
$default_lon = -73.7781;  // KGRR
$default_radius = 80;     // NM (1..250)

/** -----------------------------
 * Optional overrides (?lat=&lon=&radius=)
 * ----------------------------- */
$lat = isset($_GET['lat']) ? (float)$_GET['lat'] : $default_lat;
$lon = isset($_GET['lon']) ? (float)$_GET['lon'] : $default_lon;
$radius = isset($_GET['radius']) ? (int)$_GET['radius'] : $default_radius;

// Clamp radius to ADSB.lol limits
if ($radius < 1) $radius = 1;
if ($radius > 250) $radius = 250;

// Validate lat/lon
if ($lat < -90 || $lat > 90 || $lon < -180 || $lon > 180) {
	echo json_encode(['error' => 'Invalid lat/lon'], JSON_PRETTY_PRINT);
	exit;
}

/** -----------------------------
 * Fetch ADSB.lol
 * ----------------------------- */
$adsblol_url = sprintf('%s/%s/%s/%d', $adsblol_base, $lat, $lon, $radius);

$ch = curl_init($adsblol_url);
curl_setopt_array($ch, [
	CURLOPT_RETURNTRANSFER => true,
	CURLOPT_TIMEOUT => 10,
	CURLOPT_FOLLOWLOCATION => true,
	CURLOPT_HTTPHEADER => ['Accept: application/json'],
]);
$json = curl_exec($ch);
$http = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$err  = curl_error($ch);
curl_close($ch);

if ($http !== 200 || !$json) {
	echo json_encode([
		'error' => 'Failed to fetch ADSB.lol data',
		'http' => $http,
		'curl_error' => $err ?: null,
		'url' => $adsblol_url
	], JSON_PRETTY_PRINT);
	exit;
}

$data = json_decode($json, true);
if (!is_array($data)) {
	echo json_encode([
		'error' => 'ADSB.lol returned invalid JSON',
		'url' => $adsblol_url
	], JSON_PRETTY_PRINT);
	exit;
}

/** -----------------------------
 * ADSB.lol aircraft list extraction
 * (key names can vary; try common ones)
 * ----------------------------- */
$aircraftList = null;

if (isset($data['ac']) && is_array($data['ac'])) {
	$aircraftList = $data['ac'];
} elseif (isset($data['aircraft']) && is_array($data['aircraft'])) {
	$aircraftList = $data['aircraft'];
} elseif (isset($data['data']) && is_array($data['data'])) {
	$aircraftList = $data['data'];
} elseif (array_keys($data) === range(0, count($data) - 1)) {
	// Root array fallback
	$aircraftList = $data;
}

if (!$aircraftList) {
	echo json_encode([
		'error' => 'ADSB.lol response missing aircraft list',
		'url' => $adsblol_url,
		'keys' => array_keys($data),
	], JSON_PRETTY_PRINT);
	exit;
}

/** -----------------------------
 * Normalize to OpenSky-style `states`
 * (matching your dump1090 mapping)
 * ----------------------------- */
$states = [];
$time = time();

foreach ($aircraftList as $ac) {
	if (!is_array($ac)) continue;

	// Skip aircraft with no position data
	if (!isset($ac['lat']) || !isset($ac['lon'])) {
		continue;
	}

	// Common hex keys
	$hex = $ac['hex'] ?? ($ac['icao'] ?? ($ac['icao24'] ?? ''));
	if ($hex === '') continue;

	$callsign = trim($ac['flight'] ?? ($ac['callsign'] ?? $hex));
	$originCountry = $ac['country'] ?? 'N/A';

	$lonVal = $ac['lon'];
	$latVal = $ac['lat'];

	// Match dump1090-style fields (keep in same units as your existing code)
	$velocity = $ac['gs'] ?? null;        // knots (leave as-is)
	$track    = $ac['track'] ?? null;     // degrees
	$vRate    = $ac['baro_rate'] ?? null; // often ft/min; leave as-is
	$squawk   = $ac['squawk'] ?? null;

	$spi = false;
	$onGround = false;        // ADSB.lol may not provide; keep consistent
	$positionSource = null;   // you used null before

	$alt = isset($ac['alt_baro']) ? (float)$ac['alt_baro'] : null;     // feet (leave as-is)
	$geoAlt = isset($ac['alt_geom']) ? (float)$ac['alt_geom'] : $alt;  // feet (leave as-is)

	$states[] = [
		$hex,           // 0 - ICAO24
		$callsign,      // 1 - Callsign
		$originCountry, // 2 - Origin Country
		$time,          // 3 - Time Position
		$time,          // 4 - Last Contact
		$lonVal,        // 5 - Longitude
		$latVal,        // 6 - Latitude
		$alt,           // 7 - Baro Altitude
		$onGround,      // 8 - On Ground
		$velocity,      // 9 - Velocity (knots)
		$track,         // 10 - True Track
		$vRate,         // 11 - Vertical Rate
		null,           // 12 - Sensors
		$geoAlt,        // 13 - Geo Altitude
		$squawk,        // 14 - Squawk
		$spi,           // 15 - SPI
		$positionSource // 16 - Position Source
	];
}

echo json_encode([
	'time' => time(),
	'states' => $states
], JSON_PRETTY_PRINT);