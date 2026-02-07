<?php
/**
 * opensky-proxy.php
 *
 * Output: OpenSky-style JSON
 * {
 *   "time": 1234567890,
 *   "states": [ [icao24, callsign, originCountry, timePosition, lastContact, lon, lat, baroAlt, onGround, velocity, track, vRate, sensors, geoAlt, squawk, spi, positionSource], ... ]
 * }
 *
 * Modes:
 * - Local (default): reads Homebase dump1090 JSON and converts to OpenSky-style states
 * - ADSB.lol (optional): if enabled, uses ADSB.lol ONLY (does not attempt local)
 *
 * Enable ADSB.lol:
 * - Query string: ?use_adsblol=1
 * - Or set $USE_ADSBLOL_DEFAULT = true
 *
 * ADSB.lol params (when enabled):
 * - ?lat=...&lon=...&radius=...  (radius in nautical miles, 1..250)
 */

header("Content-Type: application/json");

/** -----------------------------
 *  CONFIG
 *  ----------------------------- */

// Local Homebase dump1090 endpoint (your existing local path)
$dump1090_url = 'http://homebase.local/adsb/1090/';

// ADSB.lol endpoint base
$adsblol_base = 'https://api.adsb.lol/v2/point';

// Default toggle (set true to always use ADSB.lol unless overridden)
$USE_ADSBLOL_DEFAULT = true;

// Default ADSB.lol location (KGRR example)
$DEFAULT_LAT = 42.8808;
$DEFAULT_LON = -85.5228;
$DEFAULT_RADIUS = 80; // nm (1..250)

// Optional debug output
$debug = !empty($_GET['debug']);

/** -----------------------------
 *  HELPERS
 *  ----------------------------- */

function respond_json(array $payload, int $code = 200): void {
	http_response_code($code);
	echo json_encode($payload, JSON_PRETTY_PRINT);
	exit;
}

function http_get_json(string $url, int $timeoutSeconds = 10): array {
	$ch = curl_init($url);
	curl_setopt_array($ch, [
		CURLOPT_RETURNTRANSFER => true,
		CURLOPT_TIMEOUT => $timeoutSeconds,
		CURLOPT_FOLLOWLOCATION => true,
		CURLOPT_HTTPHEADER => ['Accept: application/json'],
	]);
	$body = curl_exec($ch);
	$err  = curl_error($ch);
	$code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
	curl_close($ch);

	if ($code !== 200 || !$body) {
		return [
			'ok' => false,
			'code' => $code,
			'error' => $err ?: 'Request failed',
			'body' => null,
		];
	}

	$data = json_decode($body, true);
	if (!is_array($data)) {
		return [
			'ok' => false,
			'code' => 502,
			'error' => 'Invalid JSON from upstream',
			'body' => $body,
		];
	}

	return [
		'ok' => true,
		'code' => 200,
		'error' => null,
		'data' => $data,
	];
}

/**
 * Convert dump1090 SkyAware aircraft.json to OpenSky states
 */
function states_from_dump1090(array $data): array {
	$states = [];
	$time = time();

	if (empty($data['aircraft']) || !is_array($data['aircraft'])) {
		return $states;
	}

	foreach ($data['aircraft'] as $ac) {
		// Skip aircraft with no position data
		if (!isset($ac['lat']) || !isset($ac['lon'])) continue;

		$hex = strtolower(trim((string)($ac['hex'] ?? '')));
		if ($hex === '') continue;

		$callsign = trim((string)($ac['flight'] ?? $hex));
		$originCountry = 'N/A';

		$lon = (float)$ac['lon'];
		$lat = (float)$ac['lat'];

		// Altitudes
		$alt = isset($ac['alt_baro']) ? (float)$ac['alt_baro'] : null;
		$geoAlt = isset($ac['alt_geom']) ? (float)$ac['alt_geom'] : $alt;

		// Speed/track
		$velocity = isset($ac['gs']) ? (float)$ac['gs'] : null;        // knots
		$track    = isset($ac['track']) ? (float)$ac['track'] : null;  // degrees
		$vRate    = isset($ac['baro_rate']) ? (float)$ac['baro_rate'] : null;

		$squawk = $ac['squawk'] ?? null;

		$spi = false;
		$onGround = false;          // dump1090 sometimes has "ground" — set it if present
		if (isset($ac['ground'])) $onGround = (bool)$ac['ground'];

		$positionSource = null;

		$states[] = [
			$hex,             // 0 - ICAO24
			$callsign,        // 1 - Callsign
			$originCountry,   // 2 - Origin Country
			$time,            // 3 - Time Position
			$time,            // 4 - Last Contact
			$lon,             // 5 - Longitude
			$lat,             // 6 - Latitude
			$alt,             // 7 - Baro Altitude
			$onGround,        // 8 - On Ground
			$velocity,        // 9 - Velocity (knots)
			$track,           // 10 - True Track
			$vRate,           // 11 - Vertical Rate
			null,             // 12 - Sensors
			$geoAlt,          // 13 - Geo Altitude
			$squawk,          // 14 - Squawk
			$spi,             // 15 - SPI
			$positionSource   // 16 - Position Source
		];
	}

	return $states;
}

/**
 * Convert ADSB.lol /v2/point response to OpenSky states
 */
function states_from_adsblol(array $adsb): array {
	$states = [];
	$now = time();

	// Aircraft list usually lives under "ac"
	$aircraftList = null;
	if (isset($adsb['ac']) && is_array($adsb['ac'])) {
		$aircraftList = $adsb['ac'];
	} elseif (isset($adsb['aircraft']) && is_array($adsb['aircraft'])) {
		$aircraftList = $adsb['aircraft'];
	} elseif (array_keys($adsb) === range(0, count($adsb) - 1)) {
		// Root array fallback
		$aircraftList = $adsb;
	}

	if (!$aircraftList) return $states;

	foreach ($aircraftList as $ac) {
		if (!isset($ac['lat'], $ac['lon'])) continue;

		$hex = $ac['hex'] ?? ($ac['icao'] ?? ($ac['icao24'] ?? ''));
		$hex = strtolower(trim((string)$hex));
		if ($hex === '') continue;

		$callsign = trim((string)($ac['flight'] ?? ($ac['callsign'] ?? '')));
		if ($callsign === '') $callsign = $hex;

		$originCountry = (string)($ac['country'] ?? 'N/A');

		$alt = isset($ac['alt_baro']) ? (float)$ac['alt_baro'] : null;
		$geoAlt = isset($ac['alt_geom']) ? (float)$ac['alt_geom'] : $alt;

		$velocity = isset($ac['gs']) ? (float)$ac['gs'] : null;        // knots
		$track    = isset($ac['track']) ? (float)$ac['track'] : null;  // degrees
		$vRate    = isset($ac['baro_rate']) ? (float)$ac['baro_rate'] : null;

		$squawk = $ac['squawk'] ?? null;

		$onGround = false;
		if (isset($ac['ground'])) $onGround = (bool)$ac['ground'];
		if (isset($ac['on_ground'])) $onGround = (bool)$ac['on_ground'];

		$spi = false;
		$positionSource = 'adsblol';

		$states[] = [
			$hex,                 // 0 ICAO24
			$callsign,            // 1 Callsign
			$originCountry,       // 2 Origin Country
			$now,                 // 3 Time Position
			$now,                 // 4 Last Contact
			(float)$ac['lon'],    // 5 Longitude
			(float)$ac['lat'],    // 6 Latitude
			$alt,                 // 7 Baro Altitude
			$onGround,            // 8 On Ground
			$velocity,            // 9 Velocity (knots)
			$track,               // 10 Track (deg)
			$vRate,               // 11 Vertical Rate
			null,                 // 12 Sensors
			$geoAlt,              // 13 Geo Altitude
			$squawk,              // 14 Squawk
			$spi,                 // 15 SPI
			$positionSource       // 16 Position Source
		];
	}

	return $states;
}

/** -----------------------------
 *  MODE SELECTION
 *  ----------------------------- */

// If enabled: ADSB.lol ONLY (turns off local)
$use_adsblol = $USE_ADSBLOL_DEFAULT;
if (isset($_GET['use_adsblol'])) {
	// Accept: 1/0, true/false, yes/no
	$v = strtolower(trim((string)$_GET['use_adsblol']));
	$use_adsblol = in_array($v, ['1', 'true', 'yes', 'on'], true);
}

if ($use_adsblol) {
	// ADSB.lol params
	$lat = isset($_GET['lat']) ? (float)$_GET['lat'] : $DEFAULT_LAT;
	$lon = isset($_GET['lon']) ? (float)$_GET['lon'] : $DEFAULT_LON;
	$radius = isset($_GET['radius']) ? (int)$_GET['radius'] : $DEFAULT_RADIUS;

	// Validate
	if ($lat < -90 || $lat > 90 || $lon < -180 || $lon > 180) {
		respond_json(['error' => 'Invalid lat/lon'], 400);
	}
	if ($radius < 1) $radius = 1;
	if ($radius > 250) $radius = 250;

	$adsblol_url = sprintf('%s/%s/%s/%d', $adsblol_base, $lat, $lon, $radius);

	$resp = http_get_json($adsblol_url, 10);
	if (!$resp['ok']) {
		respond_json([
			'error' => 'Failed to fetch ADSB.lol',
			'url' => $adsblol_url,
			'http' => $resp['code'],
			'detail' => $resp['error'],
		], 502);
	}

	$states = states_from_adsblol($resp['data']);

	$out = [
		'time' => time(),
		'states' => $states
	];

	if ($debug) {
		$out['debug'] = [
			'mode' => 'adsblol_only',
			'url' => $adsblol_url,
			'states_count' => count($states),
			'top_level_keys' => array_keys($resp['data']),
		];
	}

	respond_json($out);
}

/** -----------------------------
 *  LOCAL MODE (default)
 *  ----------------------------- */

$json = @file_get_contents($dump1090_url);

if (!$json) {
	respond_json(['error' => 'Failed to fetch dump1090 data'], 502);
}

$data = json_decode($json, true);
if (!is_array($data)) {
	respond_json(['error' => 'Invalid JSON from local dump1090 feed'], 502);
}

$states = states_from_dump1090($data);

$out = [
	'time' => time(),
	'states' => $states
];

if ($debug) {
	$out['debug'] = [
		'mode' => 'local_dump1090_only',
		'url' => $dump1090_url,
		'states_count' => count($states),
		'top_level_keys' => array_keys($data),
	];
}

respond_json($out);