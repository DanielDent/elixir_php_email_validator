<?php
/**
 * Authoritative verdict oracle for the differential test suite.
 *
 * Reads base64-encoded inputs (one per line) either from the file named in
 * argv[1], or from STDIN if no argument is given. For each input it calls the
 * REAL filter_var() twice — default flags and FILTER_FLAG_EMAIL_UNICODE — and
 * prints one TSV row:
 *
 *     <base64_input>\t<default 0|1>\t<unicode 0|1>
 *
 * "1" means filter_var accepted the address (returned the string), "0" means
 * it rejected it (returned false). Carrying the input as base64 lets the
 * corpus contain arbitrary bytes (spaces, NUL, newlines, invalid UTF-8).
 *
 * This script is intentionally tiny and dependency-free so it is obvious that
 * the golden verdicts come straight from PHP itself.
 */

$argvFile = $argv[1] ?? null;
$in = $argvFile !== null ? fopen($argvFile, 'rb') : fopen('php://stdin', 'rb');
if ($in === false) {
    fwrite(STDERR, "cannot open input\n");
    exit(2);
}
$out = fopen('php://stdout', 'wb');

while (($line = fgets($in)) !== false) {
    $line = rtrim($line, "\r\n");
    if ($line === '') {
        continue;
    }
    $input = base64_decode($line, true);
    if ($input === false) {
        fwrite(STDERR, "invalid base64 on input line: {$line}\n");
        exit(3);
    }
    $d = filter_var($input, FILTER_VALIDATE_EMAIL) !== false ? '1' : '0';
    $u = filter_var($input, FILTER_VALIDATE_EMAIL, FILTER_FLAG_EMAIL_UNICODE) !== false ? '1' : '0';
    fwrite($out, $line . "\t" . $d . "\t" . $u . "\n");
}

exit(0);
