param(
    [parameter(Mandatory=$true)] $cluster,
    [parameter(Mandatory=$true)] $file
    )

function copy_drs_rule {
    param(
	[parameter(Mandatory=$true)] $rule,
	[parameter(Mandatory=$true)] $target_cluster
    )

	New-DrsRule -cluster $target_cluster -Name $rule.Name -Enabled ([bool]::Parse($rule.Enabled)) -KeepTogether ([System.Convert]::ToBoolean($rule.KeepTogether)) -RunAsync:$false -VM ($rule.name.split("-") | % { Get-VM -name $_ })
}

$rule = import-csv $file

copy_drs_rule -rule $rule -target_cluster $cluster
