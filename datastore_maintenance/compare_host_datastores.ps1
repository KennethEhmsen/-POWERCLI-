param(
    [parameter(Mandatory=$true)]
    $sourcehost,
    [parameter(Mandatory=$true)]
    $hoststocompare
)


$source = get-datastore -vmhost	$sourcehost

foreach ($h in $hoststocompare) {
	write $h.name
  	diff $source (get-datastore -vmhost $h)
	write ' '
}
