<?php

/**
 * XenForo configuration, driven entirely from the environment.
 *
 * Adapted from XenForo's own MIT-licensed `src/config.docker.php` in
 * https://github.com/xenforo-ltd/cli — see ../NOTICE.md. The development-mode
 * branch has been dropped (this is a production runtime) and a few defaults are
 * tightened, but the environment variable names are kept identical so anything
 * XenForo documents for their Docker tooling applies here unchanged.
 *
 * Every value supports the `<NAME>_FILE` indirection: set `XF_DB_PASSWORD_FILE`
 * to a path and the value is read from that file instead. That is how Kubernetes
 * secrets reach this config without ever becoming environment variables — a
 * secret in the environment leaks into `phpinfo()` and any child process, while
 * a file mount does not. Both end up in process memory once read, so this
 * narrows exposure rather than eliminating it.
 */

if (!function_exists('getenv_docker'))
{
	function getenv_docker(string $name, string $default = ''): string
	{
		$filename = getenv("{$name}_FILE");
		if ($filename !== false)
		{
			return rtrim(file_get_contents($filename), "\r\n");
		}

		$value = getenv($name);
		if ($value === false)
		{
			return $default;
		}

		return $value;
	}
}

// --- Database ----------------------------------------------------------------

$config['db']['host'] = getenv_docker('XF_DB_HOST', 'localhost');
$config['db']['port'] = (int) getenv_docker('XF_DB_PORT', '3306');
$config['db']['username'] = getenv_docker('XF_DB_USER');
$config['db']['password'] = getenv_docker('XF_DB_PASSWORD');
$config['db']['dbname'] = getenv_docker('XF_DB_DATABASE');

$config['fullUnicode'] = true;
$config['searchInnoDb'] = true;

// --- Output ------------------------------------------------------------------

$config['enableCssSplitting'] = true;

// Caddy owns compression and Content-Length in front of PHP-FPM. Doing either
// here as well produces double-encoded responses and wrong lengths.
$config['enableContentLength'] = false;
$config['enableGzip'] = false;

// --- Cache -------------------------------------------------------------------

// Off by default. A low-traffic forum does not need Redis, and the image only
// carries the redis extension when built with PHP_BUILD_REDIS=1.
if (getenv_docker('XF_CACHE_ENABLE'))
{
	$config['cache']['enabled'] = true;
	$config['cache']['sessions'] = (bool) getenv_docker('XF_CACHE_SESSIONS');
	$config['cache']['provider'] = 'Redis';
	$config['cache']['config'] = [
		'host' => getenv_docker('XF_CACHE_HOST'),
	];

	if (getenv_docker('XF_CACHE_PAGES'))
	{
		$config['pageCache']['enabled'] = true;
		$config['cache']['context']['page']['provider'] = 'Redis';
		$config['cache']['context']['page']['config'] = [
			'host' => getenv_docker('XF_CACHE_HOST'),
		];
	}
}

// --- Behaviour ---------------------------------------------------------------

$config['debug'] = (bool) getenv_docker('XF_DEBUG');
$config['cookie']['prefix'] = getenv_docker('XF_COOKIE_PREFIX', 'xf_');
$config['enableMail'] = (bool) getenv_docker('XF_MAIL_ENABLE');

// Lets an admin install add-ons by uploading a zip in the control panel. This is
// only safe because the forum tree is a writable PersistentVolume rather than a
// read-only image layer.
$config['enableAddOnArchiveInstaller'] = true;

$c->extend('options', function ($options)
{
	$options['boardTitle'] = getenv_docker('XF_TITLE', 'XenForo');
	$options['defaultEmailAddress'] = getenv_docker('XF_EMAIL');
	$options['contactEmailAddress'] = getenv_docker('XF_CONTACT_EMAIL');
	$options['useFriendlyUrls'] = true;

	if (getenv_docker('XF_MAIL_ENABLE'))
	{
		$options['emailTransport'] = [
			'emailTransport' => 'smtp',
			'smtpHost' => getenv_docker('XF_MAIL_HOST'),
			'smtpPort' => (int) getenv_docker('XF_MAIL_PORT'),
			'smtpAuth' => 'login',
			'smtpLoginUsername' => getenv_docker('XF_MAIL_USERNAME'),
			'smtpLoginPassword' => getenv_docker('XF_MAIL_PASSWORD'),
			'smtpSsl' => (bool) getenv_docker('XF_MAIL_SSL'),
		];
	}

	if (isset($options['xfesConfig']))
	{
		$options['xfesConfig']['host'] = getenv_docker('XF_XFES_SEARCH_HOST', 'localhost');
		$options['xfesConfig']['port'] = (int) getenv_docker('XF_XFES_SEARCH_PORT', '9200');
		$options['xfesConfig']['username'] = getenv_docker('XF_XFES_SEARCH_USER');
		$options['xfesConfig']['password'] = getenv_docker('XF_XFES_SEARCH_PASSWORD');
		$options['xfesConfig']['index'] = getenv_docker('XF_XFES_SEARCH_INDEX');
	}

	if (getenv_docker('XF_IMAGICK_ENABLE'))
	{
		$options['imageLibrary'] = 'imPecl';
	}

	return $options;
});

// --- Local escape hatch ------------------------------------------------------

// Anything this file does not model goes here. `config.override.php` lives on the
// PersistentVolume, so it survives image upgrades and is the right place for
// one-off tweaks you do not want to encode as environment variables. XenForo's
// own Docker config carries the same seam.
$override = __DIR__ . '/config.override.php';
if (file_exists($override) && is_file($override))
{
	require $override;
}
