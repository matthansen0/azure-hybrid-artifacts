# Azure Functions profile - runs once when the Function App cold-starts.
# Authenticates using the system-assigned Managed Identity.

if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity | Out-Null
    Write-Host "Connected to Azure using Managed Identity."
}
