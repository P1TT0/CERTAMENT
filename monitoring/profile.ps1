# Azure Functions loads AzTable from requirements.psd1.
$ErrorActionPreference = 'Stop'
Import-Module Az.Storage -ErrorAction Stop
Import-Module AzTable -ErrorAction Stop
