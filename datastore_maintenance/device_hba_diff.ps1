param(
    [parameter(Mandatory=$true)]
    $h1,
    [parameter(Mandatory=$true)]
    $h2
)

diff (get-scsilun -vmhost $h1) (get-scsilun -vmhost $h2)