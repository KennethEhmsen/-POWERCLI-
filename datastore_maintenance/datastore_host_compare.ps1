param(
    [parameter(Mandatory=$true)]
    $D1,
    [parameter(Mandatory=$true)]
    $D2
)

diff (get-datastore -name $D1 | get-vmhost) (get-datastore -name $D2 | get-vmhost)
