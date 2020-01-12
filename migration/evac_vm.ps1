Get-VM -Location $args[0] | select-object -first $args[2] | Move-VM -Destination (Get-Vmhost $args[1])

