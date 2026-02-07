<?php
header("Content-Type: application/json");

$dump1090_url = 'http://homebase.local/adsb/1090/';
$json = file_get_contents($dump1090_url);

if (!$json) {
	echo json_encode(['error' => 'Failed to fetch dump1090 data']);
	exit;
}

$data = json_decode($json, true);

$states = [];

foreach ($data['aircraft'] as $ac) {
	// Skip aircraft with no position data
	if (!isset($ac['lat']) || !isset($ac['lon'])) {
		continue;
	}

	$hex = $ac['hex'] ?? '';
	$callsign = trim($ac['flight'] ?? $hex);
	$originCountry = 'N/A';
	$time = time();

	$lon = $ac['lon'];
	$lat = $ac['lat'];
	// $alt = $ac['alt_baro'] ?? null;
	$velocity = $ac['gs'] ?? null;              // ground speed
	$track = $ac['track'] ?? null;              // heading
	$vRate = $ac['baro_rate'] ?? null;
	// $geoAlt = $ac['alt_geom'] ?? $alt;
	$squawk = $ac['squawk'] ?? null;
	$spi = false;                               // not available
	$onGround = false;                          // assume airborne
	$positionSource = null;                     // not provided
	
	$alt = isset($ac['alt_baro']) ? (float)$ac['alt_baro'] : null;
$geoAlt = isset($ac['alt_geom']) ? (float)$ac['alt_geom'] : $alt;

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
		$velocity,        // 9 - Velocity (m/s or knots)
		$track,           // 10 - True Track
		$vRate,           // 11 - Vertical Rate
		null,             // 12 - Sensors
		$geoAlt,          // 13 - Geo Altitude
		$squawk,          // 14 - Squawk
		$spi,             // 15 - SPI
		$positionSource   // 16 - Position Source
	];
}

echo json_encode([
	'time' => time(),
	'states' => $states
], JSON_PRETTY_PRINT);